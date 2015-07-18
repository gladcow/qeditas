(* Copyright (c) 2015 The Qeditas developers *)
(* Distributed under the MIT software license, see the accompanying
   file COPYING or http://www.opensource.org/licenses/mit-license.php. *)

open Sha256
open Hash
open Big_int
open Mathdata
open Assets
open Signat
open Tx
open Ctre
open Ctregraft

(*** 256 bits ***)
type stakemod = int64 * int64 * int64 * int64

let genesiscurrentstakemod : stakemod ref = ref (0L,0L,0L,0L)
let genesisfuturestakemod : stakemod ref = ref (0L,0L,0L,0L)

let set_genesis_stakemods x =
  let (x4,x3,x2,x1,x0) = hexstring_hashval x in
  sha256init();
  currblock.(0) <- x4;
  currblock.(1) <- x3;
  currblock.(2) <- x2;
  currblock.(3) <- x1;
  currblock.(4) <- x0;
  currblock.(5) <- 0x80000000l;
  for i = 6 to 14 do
    currblock.(i) <- 0l;
  done;
  currblock.(15) <- 160l;
  sha256round();
  let (y0,y1,y2,y3,y4,y5,y6,y7) = getcurrmd256() in
  sha256init();
  currblock.(0) <- y0;
  currblock.(1) <- y1;
  currblock.(2) <- y2;
  currblock.(3) <- y3;
  currblock.(4) <- y4;
  currblock.(5) <- y5;
  currblock.(6) <- y6;
  currblock.(7) <- y7;
  currblock.(8) <- 0x80000000l;
  for i = 9 to 14 do
    currblock.(i) <- 0l;
  done;
  currblock.(15) <- 256l;
  sha256round();
  let (z0,z1,z2,z3,z4,z5,z6,z7) = getcurrmd256() in
  let c a b =
    Int64.logor
      (Int64.shift_left (Int64.of_int32 (Int32.logand (Int32.shift_right_logical a 16) 0xffl)) 48)
      (Int64.logor
	 (Int64.shift_left (Int64.of_int32 (Int32.logand a 0xffl)) 32)
	 (Int64.logor
	    (Int64.shift_left (Int64.of_int32 (Int32.logand (Int32.shift_right_logical b 16) 0xffl)) 16)
	    (Int64.of_int32 (Int32.logand b 0xffl))))
  in
  genesiscurrentstakemod := (c y0 y1,c y2 y3,c y4 y5,c y6 y7);
  genesisfuturestakemod := (c z0 z1,c z2 z3,c z4 z5,c z6 z7);;
  
(*** Here the last 20 bytes (40 hex chars) of the block hash for a particular bitcoin block should be included.
 sha256 is used to extract 512 bits to set the genesis current and future stake modifiers.
 ***)
set_genesis_stakemods "0000000000000000000000000000000000000000";;

let genesistarget = ref (big_int_of_string "1000000000")
let genesisledgerroot : hashval ref = ref (0l,0l,0l,0l,0l)

let maturation_post_staking = 512L
let maturation_pre_staking = 512L
let not_close_to_mature = 32L

(*** base reward of 50 fraenks (50 trillion cants) like bitcoin, but assume the first 350000 blocks have passed. ***)
let basereward = 50000000000000000L

let rewfn blkh =
  if blkh < 11410000L then
    let blki = Int64.to_int blkh in
    Int64.shift_right basereward ((blki + 350000) / 210000)
  else
    0L

let hashstakemod sm =
  let (m3,m2,m1,m0) = sm in
  hashtag (hashlist [hashint64 m3;hashint64 m2;hashint64 m1;hashint64 m0]) 240l

(*** drop most significant bit of m3, shift everything, b is the new least siginificant bit of m0 ***)
let stakemod_pushbit b sm =
  let (m3,m2,m1,m0) = sm in
  let z3 = Int64.shift_left m3 1 in
  let z2 = Int64.shift_left m2 1 in
  let z1 = Int64.shift_left m1 1 in
  let z0 = Int64.shift_left m0 1 in
  ((if m2 < 0L then Int64.logor z3 1L else z3),
   (if m1 < 0L then Int64.logor z2 1L else z2),
   (if m0 < 0L then Int64.logor z1 1L else z1),
   (if b then Int64.logor z0 1L else z0))

let stakemod_lastbit sm =
  let (m3,_,_,_) = sm in
  m3 < 0L

let stakemod_firstbit sm =
  let (_,_,_,m0) = sm in
  Int64.logand m0 1L = 1L

(*** one round of sha256 combining the timestamp (least significant 32 bits only), the hash value of the stake's assetid and the stake modifier, then converted to a big_int to do arithmetic ***)
let hitval tm h sm =
  let (x0,x1,x2,x3,x4) = h in
  let (m3,m2,m1,m0) = sm in
  sha256init();
  currblock.(0) <- Int64.to_int32 tm;
  currblock.(1) <- x0;
  currblock.(2) <- x1;
  currblock.(3) <- x2;
  currblock.(4) <- x3;
  currblock.(5) <- x4;
  currblock.(6) <- Int64.to_int32 (Int64.shift_right_logical m3 32);
  currblock.(7) <- Int64.to_int32 m3;
  currblock.(8) <- Int64.to_int32 (Int64.shift_right_logical m2 32);
  currblock.(9) <- Int64.to_int32 m2;
  currblock.(10) <- Int64.to_int32 (Int64.shift_right_logical m1 32);
  currblock.(11) <- Int64.to_int32 m1;
  currblock.(12) <- Int64.to_int32 (Int64.shift_right_logical m0 32);
  currblock.(13) <- Int64.to_int32 m0;
  currblock.(14) <- 0x80000000l;
  currblock.(15) <- 448l;
  sha256round();
  md256_big_int (getcurrmd256())

(*** current stake modifier, future stake modifier, target (big_int, but assumed to be at most 256 bits ***)
type targetinfo = stakemod * stakemod * big_int

let hashtargetinfo ti =
  let (csm,fsm,tar) = ti in
  hashpair (hashstakemod csm)
    (hashpair (hashstakemod fsm)
       (big_int_hashval tar))

type postor =
  | PostorTrm of hashval option * tm * tp * hashval
  | PostorDoc of payaddr * hashval * hashval option * pdoc * hashval

let hashpostor r =
  match r with
  | PostorTrm(th,m,a,h) -> hashtag (hashopair2 th (hashpair (hashpair (hashtm m) (hashtp a)) h)) 192l
  | PostorDoc(gamma,nonce,th,d,h) ->
      hashtag (hashpair (hashpair (hashaddr (payaddr_addr gamma)) (hashpair nonce (hashopair2 th (hashpdoc d)))) h) 193l

let hashopostor r =
  match r with
  | Some(r) -> Some(hashpostor r)
  | None -> None

type blockheaderdata = {
    prevblockhash : hashval option;
    newtheoryroot : hashval option;
    newsignaroot : hashval option;
    newledgerroot : hashval;
    stake : int64;
    stakeaddr : p2pkhaddr;
    stakeassetid : hashval;
    stakebday : int64;
    stored : postor option;
    timestamp : int64;
    deltatime : int32;
    tinfo : targetinfo;
    prevledger : ctree;
  }

type blockheadersig = {
    blocksignat : signat;
    blocksignatrecid : int;
    blocksignatfcomp : bool;
  }

type blockheader = blockheaderdata * blockheadersig

type poforfeit = blockheader * blockheader * blockheaderdata list * blockheaderdata list * int64 * hashval list

type blockdelta = {
    stakeoutput : addr_preasset list;
    forfeiture : poforfeit option;
    prevledgergraft : cgraft;
    blockdelta_stxl : stx list
  }

type block = blockheader * blockdelta

(*** multiply stake by 1.25 ***)
let incrstake s =
  Int64.add s (Int64.shift_right s 2)

exception InappropriatePostor

(*** m should be a term abbreviated except for one leaf ***)
let rec check_postor_tm_r m =
  match m with
  | TmH(h) -> raise InappropriatePostor
  | DB(i) -> hashtm m
  | Prim(i) -> hashtm m
  | Ap(m,TmH(k)) -> check_postor_tm_r m
  | Ap(TmH(h),m) -> check_postor_tm_r m
  | Ap(_,_) -> raise InappropriatePostor
  | Imp(m,TmH(k)) -> check_postor_tm_r m
  | Imp(TmH(h),m) -> check_postor_tm_r m
  | Imp(_,_) -> raise InappropriatePostor
  | Lam(a,m) -> check_postor_tm_r m
  | All(a,m) -> check_postor_tm_r m
  | TTpAp(m,a) -> check_postor_tm_r m
  | TTpLam(m) -> check_postor_tm_r m
  | TTpAll(m) -> check_postor_tm_r m

(*** alpha is a p2pkhaddr, beta is a termaddr, and these types are both the same as hashval ***)
let check_postor_tm tm csm mtar alpha beta m =
  try
    let h = check_postor_tm_r m in
    let betah = hashpair beta h in
    let (x,_,_,_,_) = hashpair alpha betah in
    Int32.logand x 0xffffl  = 0l (*** one of every 65536 (beta,h) pairs can be used by each address alpha ***)
      &&
    lt_big_int (hitval tm betah csm) mtar
  with InappropriatePostor -> false

(*** d should be a proof with everything abbreviated except for one leaf ***)
let rec check_postor_pf_r d =
  match d with
  | Gpa(_) -> raise InappropriatePostor
  | Hyp(i) -> hashpf d
  | Known(h) -> hashpf d
  | PLam(TmH(_),d) -> check_postor_pf_r d
  | PLam(m,Gpa(_)) -> check_postor_tm_r m
  | PLam(_,_) -> raise InappropriatePostor
  | TLam(_,d) -> check_postor_pf_r d
  | PTmAp(Gpa(_),m) -> check_postor_tm_r m
  | PTmAp(d,TmH(_)) -> check_postor_pf_r d
  | PTmAp(_,_) -> raise InappropriatePostor
  | PPfAp(Gpa(_),d) -> check_postor_pf_r d
  | PPfAp(d,Gpa(_)) -> check_postor_pf_r d
  | PPfAp(_,_) -> raise InappropriatePostor
  | PTpAp(d,_) -> check_postor_pf_r d
  | PTpLam(d) -> check_postor_pf_r d

(*** ensure there's no extra information: nil or hash of the rest ***)
let check_postor_pdoc_e d =
  match d with
  | PDocNil -> ()
  | PDocHash(_) -> ()
  | _ -> raise InappropriatePostor

(*** d should be a partial doc abbreviated except for one leaf ***)
let rec check_postor_pdoc_r d =
  match d with
  | PDocNil -> raise InappropriatePostor
  | PDocHash(_) -> raise InappropriatePostor
  | PDocSigna(h,dr) -> check_postor_pdoc_r dr
  | PDocParam(h,a,dr) ->
      check_postor_pdoc_e dr;
      hashpair h (hashtp a)
  | PDocParamHash(h,dr) -> check_postor_pdoc_r dr
  | PDocDef(_,m,dr) ->
      check_postor_pdoc_e dr;
      check_postor_tm_r m
  | PDocDefHash(h,dr) -> check_postor_pdoc_r dr
  | PDocKnown(TmH(h),dr) -> check_postor_pdoc_r dr
  | PDocKnown(m,dr) ->
      check_postor_pdoc_e dr;
      check_postor_tm_r m
  | PDocConj(TmH(h),dr) -> check_postor_pdoc_r dr
  | PDocConj(m,dr) ->
      check_postor_pdoc_e dr;
      check_postor_tm_r m
  | PDocPfOf(TmH(_),d,dr) ->
      check_postor_pdoc_e dr;
      check_postor_pf_r d
  | PDocPfOf(m,Gpa(_),dr) ->
      check_postor_pdoc_e dr;
      check_postor_tm_r m
  | PDocPfOf(_,_,dr) -> raise InappropriatePostor
  | PDocPfOfHash(h,dr) -> check_postor_pdoc_r dr

(*** alpha is a p2pkhaddr, beta is a pubaddr, and these types are both the same as hashval ***)
let check_postor_pdoc tm csm mtar alpha beta m =
  try
    let h = check_postor_pdoc_r m in
    let betah = hashpair beta h in
    let (_,_,_,_,x) = hashpair alpha betah in
    Int32.logand x 0xffffl  = 0l (*** one of every 65536 (beta,h) pairs can be used by each address alpha ***)
      &&
    lt_big_int (hitval tm betah csm) mtar
  with InappropriatePostor -> false

(*** coinage experiment ***)
let coinage blkh bday v =
  if v >= 562949953421311L then (*** stakes larger than 562 fraenks do not age, to prevent int64 overflow **)
    v
  else
    let a = Int64.sub blkh bday in
    if a < 16384L then (*** coins stop aging in approximately 113 days ***)
      Int64.mul a v
    else
      Int64.mul 16384L v

(***
 hitval computes a big_int by hashing the deltatime (seconds since the previous block), the stake's asset id and the current stake modifier.
 If there is no proof of storage, then there's a hit if the hitval is less than the target times the stake.
 With a proof of storage, the stake is multiplied by 1.25 before the comparison is made.
 A proof of storage is either a term or partial document which abbreviates everything except one
 leaf. That leaf hashed with the hash of the root of the term/pdoc should hash with the stake address
 in a way that has 16 0 bits as the least significant bits.
 That is, for each stake address there are 0.0015% of proofs-of-storage that can be used by that address.
***)
let check_hit blkh bh =
  let (csm,fsm,tar) = bh.tinfo in
  match bh.stored with
  | None -> lt_big_int (hitval bh.timestamp bh.stakeassetid csm) (mult_big_int tar (big_int_of_int64 (coinage blkh bh.stakebday bh.stake)))
  | Some(PostorTrm(th,m,a,h)) -> (*** h is not relevant here; it is the asset id to look it up in the ctree ***)
      let beta = hashopair2 th (hashpair (tm_hashroot m) (hashtp a)) in
      let mtar = (mult_big_int tar (big_int_of_int64 (coinage blkh bh.stakebday (incrstake bh.stake)))) in
      lt_big_int (hitval bh.timestamp bh.stakeassetid csm) mtar
	&&
      check_postor_tm bh.timestamp csm mtar bh.stakeaddr beta m
  | Some(PostorDoc(gamma,nonce,th,d,h)) -> (*** h is not relevant here; it is the asset id to look it up in the ctree ***)
      let prebeta = hashpair (hashaddr (payaddr_addr gamma)) (hashpair nonce (hashopair2 th (pdoc_hashroot d))) in
      let mtar = (mult_big_int tar (big_int_of_int64 (coinage blkh bh.stakebday (incrstake bh.stake)))) in
      lt_big_int (hitval bh.timestamp bh.stakeassetid csm) mtar
	&&
      check_postor_pdoc bh.timestamp csm mtar bh.stakeaddr prebeta d

let coinstake b =
  let ((bhd,bhs),bd) = b in
  ([(p2pkhaddr_addr bhd.stakeaddr,bhd.stakeassetid)],bd.stakeoutput)

let hash_blockheaderdata bh =
  hashopair2 bh.prevblockhash
    (hashpair
       (hashopair2 bh.newtheoryroot
	  (hashopair2 bh.newsignaroot
	     bh.newledgerroot))
       (hashpair
	  (hashpair (hashint64 bh.stake) (hashpair bh.stakeaddr bh.stakeassetid))
	  (hashopair2
	     (hashopostor bh.stored)
	     (hashpair
		(hashtargetinfo bh.tinfo)
		(hashpair
		   (hashpair (hashint64 bh.timestamp) (hashint32 bh.deltatime))
		   (ctree_hashroot bh.prevledger))))))

let valid_blockheader_a blkh (bhd,bhs) (aid,bday,obl,v) =
  verify_p2pkhaddr_signat (hashval_big_int (hash_blockheaderdata bhd)) bhd.stakeaddr bhs.blocksignat bhs.blocksignatrecid bhs.blocksignatfcomp
    &&
  bhd.stakeassetid = aid
    &&
  bhd.stakebday = bday
    &&
  check_hit blkh bhd
    &&
  bhd.deltatime > 0l
    &&
  begin
    match obl with
    | None -> (*** stake belongs to staker ***)
	v = bhd.stake && (Int64.add bday maturation_pre_staking <= blkh || bday = 0L) (*** either it has aged enough or its part of the initial distribution (for bootstrapping) ***)
    | Some(beta,n) -> (*** stake may be on loan for staking ***)
	v = bhd.stake
	  &&
	Int64.add bday maturation_pre_staking <= blkh
	  &&
	n > Int64.add blkh not_close_to_mature
  end
    &&
  begin
    match bhd.stored with
    | None -> true
    | Some(PostorTrm(th,m,a,h)) ->
	let beta = hashopair2 th (hashpair (tm_hashroot m) (hashtp a)) in
	begin
	  match ctree_lookup_asset h bhd.prevledger (addr_bitseq (termaddr_addr beta)) with
	  | Some(_,_,_,OwnsObj(_,_)) -> true
	  | _ -> false
	end
    | Some(PostorDoc(gamma,nonce,th,d,h)) ->
	let prebeta = hashpair (hashaddr (payaddr_addr gamma)) (hashpair nonce (hashopair2 th (pdoc_hashroot d))) in
	let beta = hashval_pub_addr prebeta in
	begin
	  match ctree_lookup_asset h bhd.prevledger (addr_bitseq beta) with
	  | Some(_,_,_,DocPublication(_,_,_,_)) -> true
	  | _ -> false
	end
  end  

let valid_blockheader blkh (bhd,bhs) =
  match ctree_lookup_asset bhd.stakeassetid bhd.prevledger (addr_bitseq (p2pkhaddr_addr bhd.stakeaddr)) with
  | Some(aid,bday,obl,Currency(v)) -> (*** stake belongs to staker ***)
      valid_blockheader_a blkh (bhd,bhs) (aid,bday,obl,v)
  | _ -> false

let ctree_of_block (b:block) =
  let ((bhd,bhs),bd) = b in
  ctree_cgraft bd.prevledgergraft bhd.prevledger

let rec stxs_allinputs stxl =
  match stxl with
  | ((inpl,_),_)::stxr -> inpl @ stxs_allinputs stxr
  | [] -> []

let rec stxs_alloutputs stxl =
  match stxl with
  | ((_,outpl),_)::stxr -> outpl @ stxs_alloutputs stxr
  | [] -> []

(*** all txs of the block combined into one big transaction; used for checking validity of blocks ***)
let tx_of_block b =
  let ((bhd,_),bd) = b in
  ((p2pkhaddr_addr bhd.stakeaddr,bhd.stakeassetid)::stxs_allinputs bd.blockdelta_stxl,bd.stakeoutput @ stxs_alloutputs bd.blockdelta_stxl)

let coinstake b =
  let ((bhd,_),bd) = b in
  ([(p2pkhaddr_addr bhd.stakeaddr,bhd.stakeassetid)],bd.stakeoutput)

let txl_of_block b =
  let (_,bd) = b in
  coinstake b::List.map (fun (tx,_) -> tx) bd.blockdelta_stxl

let rec check_bhl pbh bhl oth =
  if pbh = Some(oth) then (*** if this happens, then it's not a genuine fork; one of the lists is a sublist of the other ***)
    raise Not_found
  else
    match bhl with
    | [] -> pbh
    | (bhd::bhr) ->
	if pbh = Some(hash_blockheaderdata bhd) then
	  check_bhl bhd.prevblockhash bhr oth
	else
	  raise Not_found

let rec check_poforfeit_a blkh alphabs v fal tr =
  Printf.printf "cpa v %Ld\n" v; flush stdout;
  match fal with
  | [] -> v = 0L
  | fa::far ->
      match ctree_lookup_asset fa tr alphabs with
      | Some(_,bday,_,Currency(u)) when Int64.add bday 6L >= blkh ->
	  Printf.printf "cpa u %Ld\n" u; flush stdout;
	  check_poforfeit_a blkh alphabs (Int64.sub v u) far tr
      | _ -> false

let check_poforfeit blkh ((bhd1,bhs1),(bhd2,bhs2),bhl1,bhl2,v,fal) tr =
  if hash_blockheaderdata bhd1 = hash_blockheaderdata bhd2 || List.length bhl1 > 5 || List.length bhl2 > 5 then
    false
  else
    let bhd1h = hash_blockheaderdata bhd1 in
    let bhd2h = hash_blockheaderdata bhd2 in
    (*** we only need to check the signatures hear at the heads by the bad actor bhd*.stakeaddr ***)
    if verify_p2pkhaddr_signat (hashval_big_int bhd1h) bhd1.stakeaddr bhs1.blocksignat bhs1.blocksignatrecid bhs1.blocksignatfcomp
	&&
      verify_p2pkhaddr_signat (hashval_big_int bhd2h) bhd2.stakeaddr bhs2.blocksignat bhs2.blocksignatrecid bhs2.blocksignatfcomp
    then
      try
	begin
	  if check_bhl (bhd1.prevblockhash) bhl1 bhd2h = check_bhl (bhd2.prevblockhash) bhl2 bhd1h then (*** bhd1.stakeaddr signed in two different forks within six blocks of fbh1 ***)
	    check_poforfeit_a blkh (addr_bitseq (p2pkhaddr_addr bhd1.stakeaddr)) v fal tr
	  else
	    false
	end
      with Not_found -> false
    else
      false

let valid_block_a tht sigt blkh b (aid,bday,obl,v) =
  let ((bhd,bhs),bd) = b in
  (*** The header is valid. ***)
  valid_blockheader_a blkh (bhd,bhs) (aid,bday,obl,v)
    &&
  tx_outputs_valid bd.stakeoutput
    &&
   (*** ensure that if the stake has an explicit obligation (e.g., it is borrowed for staking), then the obligation isn't changed; otherwise the staker could steal the borrowed stake; unchanged copy should be first output ***)
   begin
     match ctree_lookup_asset bhd.stakeassetid bhd.prevledger (addr_bitseq (p2pkhaddr_addr bhd.stakeaddr)) with
     | Some(_,_,Some(beta,n),Currency(v)) -> (*** stake may be on loan for staking ***)
	 begin
	   match bd.stakeoutput with
	   | (alpha2,(Some(beta2,n2),Currency(v2)))::(alpha3,(_,Currency(vs)))::_ -> (*** the first output must recreate the loaned asset and the second output must be the stake reward ***)
	       alpha2 = p2pkhaddr_addr bhd.stakeaddr
		 &&
	       beta2 = beta
		 &&
	       n2 = n
		 &&
	       v2 = v
		 &&
	       alpha3 = p2pkhaddr_addr bhd.stakeaddr
		 &&
	       vs >= rewfn blkh
	   | _ -> false
	 end
     | _ ->
	 begin
	   match bd.stakeoutput with
	   | (alpha3,(_,Currency(vs)))::_ -> (*** the first asset must be the stake reward, possibly with fees. fees can optionally be sent to other addresses in the rest of the output ***)
	       alpha3 = p2pkhaddr_addr bhd.stakeaddr
		 &&
	       vs >= rewfn blkh
	   | _ -> false
	 end
   end
    &&
  List.fold_left
    (fun b (alpha,(obl,u)) ->
      b &&
      match obl with
      | Some(a,n) -> n > Int64.add blkh maturation_post_staking
      | None -> true (*** This is different from the Coq formal specification. In practice we allow the default obligation and rely on maturation_pre_staking to ensure the stake is old enough before staking again. ***)
    )
    true
    bd.stakeoutput
    &&
  let tr = ctree_of_block b in (*** let tr be the ctree of the block, used often below ***)
  begin
    try
      let z = ctree_supports_tx tht sigt blkh (coinstake b) tr in
      z >= rewfn blkh
    with NotSupported -> false
  end
    &&
  (*** There are no duplicate transactions. ***)
  no_dups bd.blockdelta_stxl
    &&
  (*** The cgraft is valid. ***)
  cgraft_valid bd.prevledgergraft
    &&
  let stakealpha1 = p2pkhaddr_addr bhd.stakeaddr in
  let stakein = (stakealpha1,bhd.stakeassetid) in
  (*** Each transaction in the delta has supported elaborated assets and is appropriately signed. ***)
  (*** Also, each transaction in the delta is valid and supported without a reward. ***)
  (*** Also, no transaction has the stake asset as an input. ***)
  begin
    try
      List.fold_left
	(fun sgvb stau ->
	  match stau with
	  | ((inpl,_) as tau,_) ->
	      let aal = ctree_lookup_input_assets inpl tr in
	      let al = List.map (fun (_,a) -> a) aal in
	      sgvb
		&& not (List.mem stakein inpl)
		&& tx_signatures_valid blkh al stau
		&& tx_valid tau
		&& ctree_supports_tx_2 tht sigt blkh tau aal al tr <= 0L
	)
	true
	bd.blockdelta_stxl
    with NotSupported -> false
  end
    &&
  (*** No distinct transactions try to spend the same asset. ***)
  (*** Also, ownership is not created for the same address alpha by two txs in the block. ***)
  begin
    try
      let stxlr = ref bd.blockdelta_stxl in
      while !stxlr != [] do
	match !stxlr with
	| ((inpl1,outpl1),_)::stxr ->
	    let hl1 = List.map (fun (_,h) -> h) inpl1 in
	    let oo1 = ref [] in
	    let op1 = ref [] in
	    List.iter
	      (fun (alpha1,(obl1,u1)) ->
		match u1 with
		| OwnsObj(_,_) -> oo1 := alpha1::!oo1
		| OwnsProp(_,_) -> op1 := alpha1::!op1
		| _ -> ())
	      outpl1;
	    stxlr := stxr;
	    List.iter
	      (fun ((inpl2,outpl2),_) ->
		List.iter
		  (fun (_,h) ->
		    if List.mem h hl1 then
		      raise NotSupported (*** This is a minor abuse of this exception. There could be a separate exception for this case. ***)
		  ) inpl2;
		List.iter
		  (fun (alpha2,(obl2,u2)) ->
		    match u2 with
		    | OwnsObj(_,_) ->
			if List.mem alpha2 !oo1 then raise NotSupported
		    | OwnsProp(_,_) ->
			if List.mem alpha2 !op1 then raise NotSupported
		    | _ -> ()
		  )
		  outpl2
	      )
	      stxr
	| [] -> ()
      done;
      true
    with NotSupported -> false
  end
    &&
  (*** Ownership is not created for the same address alpha by the coinstake and a tx in the block. ***)
  begin
    try
      List.iter
	(fun (alpha,(obl,u)) ->
	  match u with
	  | OwnsObj(_,_) ->
	      List.iter
		(fun ((_,outpl2),_) ->
		  List.iter
		    (fun (alpha2,(obl2,u2)) ->
		      if alpha = alpha2 then
			match u2 with
			| OwnsObj(_,_) -> raise NotSupported
			| _ -> ())
		    outpl2)
		bd.blockdelta_stxl
	  | OwnsProp(_,_) ->
	      List.iter
		(fun ((_,outpl2),_) ->
		  List.iter
		    (fun (alpha2,(obl2,u2)) ->
		      if alpha = alpha2 then
			match u2 with
			| OwnsProp(_,_) -> raise NotSupported
			| _ -> ())
		    outpl2)
		bd.blockdelta_stxl
	  | _ -> ()
	)
	bd.stakeoutput;
      true
    with NotSupported -> false
  end
    &&
   let (forfeitval,forfok) =
     begin
     match bd.forfeiture with
     | None -> (0L,true)
     | Some(bh1,bh2,bhl1,bhl2,v,fal) ->
	 let forfok = check_poforfeit blkh (bh1,bh2,bhl1,bhl2,v,fal) tr in
  	 (v,forfok)
     end
   in
   forfok
     &&
  (*** The total inputs and outputs match up with the declared fee. ***)
  let tau = tx_of_block b in (*** let tau be the combined tx of the block ***)
  let (inpl,outpl) = tau in
  let aal = ctree_lookup_input_assets inpl tr in
  let al = List.map (fun (_,a) -> a) aal in
  out_cost outpl = Int64.add (asset_value_sum al) (Int64.add (rewfn blkh) forfeitval)
    &&
  (***
      The root of the transformed ctree is the newledgerroot in the header.
      Likewise for the transformed tht and sigt.
   ***)
  match txl_octree_trans blkh (coinstake b::List.map (fun (tx,_) -> tx) bd.blockdelta_stxl) (Some(tr)) with
  | Some(tr2) ->
      bhd.newledgerroot = ctree_hashroot tr2
	&&
      bhd.newtheoryroot = ottree_hashroot (txout_update_ottree outpl tht)
	&&
      bhd.newsignaroot = ostree_hashroot (txout_update_ostree outpl sigt)
  | None -> false

let valid_block tht sigt blkh (b:block) =
  let ((bhd,_),_) = b in
  match ctree_lookup_asset bhd.stakeassetid bhd.prevledger (addr_bitseq (p2pkhaddr_addr bhd.stakeaddr)) with
  | Some(aid,bday,obl,Currency(v)) -> (*** stake belongs to staker ***)
      valid_block_a tht sigt blkh b (aid,bday,obl,v)
  | _ -> false

type blockchain = block * block list
type blockheaderchain = blockheader * blockheader list

let blockchain_headers bc =
  let ((bh,bd),bl) = bc in
  (bh,List.map (fun b -> let (bh,bd) = b in bh) bl)

let ledgerroot_of_blockchain bc =
  let (((bhd,bhs),bd),bl) = bc in
  bhd.newledgerroot

(*** retargeting at each step ***)
let retarget tar deltm =
   div_big_int
     (mult_big_int tar
       (big_int_of_int32
	  (Int32.add 1000l
	     (Int32.of_float (1000.0 *. (deltm /. 600.0) *. ((exp (1.0 /. deltm)) /. (exp (1.0 /. 600.0))))))))
     (big_int_of_int 2000)

let blockheader_succ bh1 bh2 =
  let (bhd1,bhs1) = bh1 in
  let (bhd2,bhs2) = bh2 in
  bhd2.prevblockhash = Some (hash_blockheaderdata bhd1)
    &&
  bhd2.timestamp = Int64.add bhd1.timestamp (Int64.of_int32 bhd2.deltatime)
    &&
  let (csm1,fsm1,tar1) = bhd1.tinfo in
  let (csm2,fsm2,tar2) = bhd2.tinfo in
  stakemod_pushbit (stakemod_lastbit fsm1) csm1 = csm2 (*** new stake modifier is old one shifted with one new bit from the future stake modifier ***)
    &&
  stakemod_pushbit (stakemod_firstbit fsm2) fsm1 = fsm2 (*** the new bit of the new future stake modifier fsm2 is freely chosen by the staker ***)
    &&
  eq_big_int tar2 (retarget tar1 (Int32.to_float bhd1.deltatime))

let rec valid_blockchain_aux blkh bl =
  match bl with
  | ((bh,bd)::(pbh,pbd)::br) ->
      if blkh > 1L then
	let (tht,sigt) = valid_blockchain_aux (Int64.sub blkh 1L) ((pbh,pbd)::br) in
	if blockheader_succ pbh bh && valid_block tht sigt blkh (bh,bd) then
	  (txout_update_ottree (tx_outputs (tx_of_block (bh,bd))) tht,
	   txout_update_ostree (tx_outputs (tx_of_block (bh,bd))) sigt)
	else
	  raise NotSupported
      else
	raise NotSupported
  | [(bh,bd)] ->
      let (bhd,bhs) = bh in
      if blkh = 1L && valid_block None None blkh (bh,bd)
	  && bhd.prevblockhash = None
	  && ctree_hashroot bhd.prevledger = !genesisledgerroot
	  && bhd.tinfo = (!genesiscurrentstakemod,!genesisfuturestakemod,!genesistarget)
      then
	(txout_update_ottree (tx_outputs (tx_of_block (bh,bd))) None,
	 txout_update_ostree (tx_outputs (tx_of_block (bh,bd))) None)
      else
	raise NotSupported
  | [] -> raise NotSupported

let valid_blockchain blkh bc =
  try
    let (b,bl) = bc in
    ignore (valid_blockchain_aux blkh (b::bl));
    true
  with NotSupported -> false

let rec valid_blockheaderchain_aux blkh bhl =
  match bhl with
  | (bh::pbh::bhr) ->
      if blkh > 1L then
	valid_blockheaderchain_aux (Int64.sub blkh 1L) (pbh::bhr)
	  && blockheader_succ pbh bh
	  && valid_blockheader blkh bh
      else
	false
  | [(bhd,bhs)] -> blkh = 1L && valid_blockheader blkh (bhd,bhs)
	&& bhd.prevblockhash = None
	&& ctree_hashroot bhd.prevledger = !genesisledgerroot
	&& bhd.tinfo = (!genesiscurrentstakemod,!genesisfuturestakemod,!genesistarget)
  | [] -> false

let valid_blockheaderchain blkh bhc =
  match bhc with
  | (bh,bhr) -> valid_blockheaderchain_aux blkh (bh::bhr)