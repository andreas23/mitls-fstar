module MonotoneSeq
open FStar.Seq
open FStar.SeqProperties
module HH   = FStar.HyperHeap
module MR   = FStar.Monotonic.RRef
module SeqP = SeqProperties

let forall_intro (#a:Type) (#p:(x:a -> GTot Type0)) ($f:(x:a -> Lemma (p x)))
  : Lemma (forall (x:a). p x)
  = qintro f

(* Some basic stuff, should be moved to FStar.Squash, probably *)
let forall_intro_2 (#a:Type) (#b:(a -> Type)) (#p:(x:a -> b x -> GTot Type0))
                  ($f: (x:a -> y:b x -> Lemma (p x y)))
  : Lemma (forall (x:a) (y:b x). p x y)
  = let g : x:a -> Lemma (forall (y:b x). p x y) = fun x -> forall_intro (f x) in
    forall_intro g

let forall_intro_3 (#a:Type) (#b:(a -> Type)) (#c:(x:a -> y:b x -> Type)) (#p:(x:a -> y:b x -> z:c x y -> Type0))
		  ($f: (x:a -> y:b x -> z:c x y -> Lemma (p x y z)))
  : Lemma (forall (x:a) (y:b x) (z:c x y). p x y z)
  = let g : x:a -> Lemma (forall (y:b x) (z:c x y). p x y z) = fun x -> forall_intro_2 (f x) in
    forall_intro g

let exists_intro (#a:Type) (p:(a -> Type)) (witness:a)
  : Lemma (requires (p witness))
	  (ensures (exists (x:a). p x))
  = ()

let exists_elim (#a:Type) (#p:(a -> Type)) (#r:Type) ($f:(x:a -> Lemma (p x ==> r)))
  : Lemma ((exists (x:a). p x) ==> r)
  = forall_intro f

let exists_elim_2 (#a:Type) (#p:(a -> Type)) (#b:Type) (#q:(b -> Type)) (#r:Type) 
		 ($f:(x:a -> y:b -> Lemma ((p x /\ q y) ==> r)))
  : Lemma (((exists (x:a). p x) /\ (exists (y:b). q y)) ==> r)
  = forall_intro_2 f

////////////////////////////////////////////////////////////////////////////////

abstract let seq_extension (#a:Type) (s1:seq a) (s2:seq a) (s3:seq a) =
  equal s3 (append s1 s2)
  
abstract let grows (#a:Type) (s1:seq a) (s3:seq a) =
  exists (s2:seq a). seq_extension s1 s2 s3
  
let seq_extension_reflexive (#a:Type) (s:seq a) 
  : Lemma (ensures (grows s s)) 
  = exists_intro (fun w -> seq_extension s w s) (Seq.createEmpty #a)

let seq_extension_transitive (s1:seq 'a) (s2:seq 'a) (s3:seq 'a) (s1':seq 'a) (s2':seq 'a) 
  : Lemma ((seq_extension s1 s1' s2 /\ seq_extension s2 s2' s3)
            ==> seq_extension s1 (Seq.append s1' s2') s3) 
  = ()

let seq_extends_to_transitive_aux (s1:seq 'a) (s2:seq 'a) (s3:seq 'a) (s1':seq 'a) (s2':seq 'a)
  : Lemma ((seq_extension s1 s1' s2 /\ seq_extension s2 s2' s3)
            ==> grows s1 s3) 
  = seq_extension_transitive s1 s2 s3 s1' s2'

let grows_transitive (s1:seq 'a) (s2:seq 'a) (s3:seq 'a)
  : Lemma ((grows s1 s2 /\ grows s2 s3)
           ==> grows s1 s3) 
  = exists_elim_2 (seq_extends_to_transitive_aux s1 s2 s3)

open FStar.Monotonic.RRef
open FStar.HyperHeap

let lemma_grows_monotone (#a:Type)
  : Lemma (monotonic (seq a) (grows #a))
  = forall_intro (seq_extension_reflexive #a);
    forall_intro_3 (grows_transitive #a)

let snoc (s:seq 'a) (x:'a) 
  : Tot (seq 'a) 
  = Seq.append s (Seq.create 1 x)

let lemma_snoc_extends (s:seq 'a) (x:'a)
  : Lemma (requires True)
	  (ensures (grows s (SeqP.snoc s x)))
	  [SMTPat (grows s (SeqP.snoc s x))]
  = ()

let lemma_mem_snoc (s:seq 'a) (x:'a)
  : Lemma (ensures (SeqProperties.mem x (SeqP.snoc s x)))
  = SeqProperties.lemma_append_count s (Seq.create 1 x)

let alloc_mref_seq (#a:Type) (r:FStar.HyperHeap.rid) (init:seq a)
  : ST (m_rref r (seq a) grows)
       (requires (fun _ -> True))
       (ensures (fun h0 m h1 -> FStar.ST.ralloc_post r init h0 (as_rref m) h1))
  = lemma_grows_monotone #a;
    FStar.Monotonic.RRef.m_alloc r init

let mem (#a:Type) (#i:rid) (x:a) (r:m_rref i (seq a) grows) (h:t)
  : GTot Type0
  = b2t (SeqProperties.mem x (m_sel h r))

let at_least (#a:Type) (#i:rid) (n:nat) (x:a) (r:m_rref i (seq a) grows) (h:t) =
      mem x r h
      /\ Seq.length (m_sel h r) > n
      /\ Seq.index (m_sel h r) n = x

let at_least_is_stable (#a:Type) (#i:rid) (n:nat) (x:a) (r:m_rref i (seq a) grows)
  : Lemma (ensures stable_on_t r (at_least n x r))
  = let at_least_is_stable_aux:
		     h0:t
		   -> h1:t
		   -> Lemma ((at_least n x r h0
			    /\ grows (m_sel h0 r) (m_sel h1 r))
			    ==> at_least n x r h1) =
       fun h0 h1 -> forall_intro_2 (lemma_mem_append #a) in
    forall_intro_2 at_least_is_stable_aux

let write_at_end (#a:Type) (#i:rid) (r:m_rref i (seq a) grows) (x:a)
  : ST unit
       (requires (fun h -> True))
       (ensures (fun h0 _ h1 ->
	               m_contains r h1
		     /\ modifies_one i h0 h1
		     /\ modifies_rref i !{as_ref (as_rref r)} h0 h1
		     /\ m_sel h1 r = SeqP.snoc (m_sel h0 r) x
		     /\ witnessed (at_least (Seq.length (m_sel h0 r)) x r)))
  = m_recall r;
    let s0 = m_read r in
    let n = Seq.length s0 in
    m_write r (SeqP.snoc s0 x);
    at_least_is_stable n x r;
    lemma_mem_snoc s0 x;
    witness r (at_least n x r)

////////////////////////////////////////////////////////////////////////////////
//Mapping functions over monotone sequences
////////////////////////////////////////////////////////////////////////////////
val un_snoc: #a: Type -> s:seq a {Seq.length s > 0} -> Tot(seq a * a)
let un_snoc #a s =
  let last = Seq.length s - 1 in
  Seq.slice s 0 last, Seq.index s last

val map: ('a -> Tot 'b) -> s:seq 'a -> Tot (seq 'b)
    (decreases (Seq.length s))
let rec map f s = 
  if Seq.length s = 0 then Seq.createEmpty
  else let prefix, last = un_snoc s in
       SeqP.snoc (map f prefix) (f last)

val map_snoc: f:('a -> Tot 'b) -> s:seq 'a -> a:'a -> Lemma
  (map f (SeqP.snoc s a) = SeqP.snoc (map f s) (f a))
let map_snoc f s a = 
  let prefix, last = un_snoc (SeqP.snoc s a) in 
  cut (Seq.equal prefix s)

private let op_At s1 s2 = Seq.append s1 s2

val map_append: f:('a -> Tot 'b) -> s1:seq 'a -> s2:seq 'a -> Lemma
  (requires True)
  (ensures (map f (s1@s2) = (map f s1 @ map f s2)))
  (decreases (Seq.length s2))
#reset-options "--z3timeout 3 --initial_fuel 1 --max_fuel 1 --initial_ifuel 1 --max_ifuel 1"  
let rec map_append f s_1 s_2 = 
  if Seq.length s_2 = 0
  then (cut (Seq.equal (s_1@s_2) s_1);
        cut (Seq.equal (map f s_1 @ map f s_2) (map f s_1)))
  else (let prefix_2, last = un_snoc s_2 in
        let m_s_1 = map f s_1 in
  	let m_p_2 = map f prefix_2 in
  	let flast = f last in
  	cut (Seq.equal (s_1@s_2) (SeqP.snoc (s_1@prefix_2) last));         //map f (s1@s2) = map f (snoc (s1@p) last)
  	map_snoc f (Seq.append s_1 prefix_2) last;                       //              = snoc (map f (s1@p)) (f last)
        map_append f s_1 prefix_2;                                       //              = snoc (map f s_1 @ map f p) (f last)
  	cut (Seq.equal (SeqP.snoc (m_s_1 @ m_p_2) flast)
  		       (m_s_1 @ SeqP.snoc m_p_2 flast));                 //              = map f s1 @ (snoc (map f p) (f last))
        map_snoc f prefix_2 last)                                       //              = map f s1 @ map f (snoc p last)

let map_grows (f:'a -> Tot 'b) 
	      (s1:seq 'a) (s3:seq 'a) (s2:seq 'a)  
  : Lemma (seq_extension s1 s2 s3
	   ==> grows (map f s1) (map f s3))
  = map_append f s1 s2

let map_prefix (#a:Type) (#b:Type) (#i:rid) 
	       (r:m_rref i (seq a) grows) 
	       (f:a -> Tot b)
	       (bs:seq b)
	       (h:HH.t) =
  grows bs (map f (MR.m_sel h r))

let map_prefix_stable (#a:Type) (#b:Type) (#i:rid) (r:m_rref i (seq a) grows) (f:a -> Tot b) (bs:seq b) 
  : Lemma (MR.stable_on_t r (map_prefix r f bs))
  = let aux : h0:HH.t -> h1:HH.t -> Lemma 
      (map_prefix r f bs h0 
       /\ grows (MR.m_sel h0 r) (MR.m_sel h1 r)
       ==> map_prefix r f bs h1) = 
      fun h0 h1 -> 
	  let s1 = MR.m_sel h0 r in
	  let s3 = MR.m_sel h1 r in
	  exists_elim (map_grows f s1 s3);
	  grows_transitive bs (map f s1) (map f s3) in
    forall_intro_2 aux

////////////////////////////////////////////////////////////////////////////////
//Monotonic counters, bounded by the length of a log
////////////////////////////////////////////////////////////////////////////////
type log_t (i:rid) (a:Type) = m_rref i (seq a) grows

let increases (x:nat) (y:nat) = b2t (x <= y)

let at_most_log_len (#l:rid) (#a:Type) (x:nat) (log:log_t l a) 
    : HyperHeap.t -> GTot Type0 
    = fun h -> x <= Seq.length (m_sel h log)

open Platform.Bytes
//Note: we may want int counters, instead of nat counters 
//because the handshake uses an initial value of -1
type counter_val (#l:rid) (#a:Type) (i:rid) (log:log_t l a) (repr_max:nat) =
     (x:nat{repr_bytes x <= repr_max /\ witnessed (at_most_log_len x log)}) //never more than the length of the log
	 
type counter (#l:rid) (#a:Type) (i:rid) (log:log_t l a) (repr_max:nat) =
  m_rref i  //counter in region i
         (counter_val i log repr_max) //never more than the length of the log
	 increases //increasing

let monotonic_increases (x:unit)
  : Lemma (monotonic nat increases)
  = ()

let at_most_log_len_stable (#l:rid) (#a:Type) (x:nat) (l:log_t l a)
  : Lemma (stable_on_t l (at_most_log_len x l))
  = ()

(* assume val gcut : f:(unit -> GTot Type){f ()} -> Tot unit *)

let new_counter (#l:rid) (#a:Type) (#repr_max:nat)
		(i:rid) (init:nat) (log:log_t l a)
  : ST (counter i log repr_max)
       (requires (fun h -> 
	   repr_bytes init <= repr_max /\
	   init <= Seq.length (m_sel h log)))
       (ensures (fun h0 c h1 ->
		   modifies_one i h0 h1 /\
		   modifies_rref i Set.empty h0 h1 /\
		   m_fresh c h0 h1 /\
		   m_sel h1 c = init /\
		   Map.contains h1 i))
  = m_recall log; recall_region i;
    witness log (at_most_log_len init log);
    m_alloc i init

let increment_counter (#l:rid) (#a:Type) (#repr_max:nat)
		      (#i:rid) (#log:log_t l a) ($c:counter i log repr_max)
  : ST unit
       (requires (fun h -> 
	  let log = m_sel h log in 
	  let n = m_sel h c in 
	  n < Seq.length log  /\
	  repr_bytes (n + 1) <= repr_max))
       (ensures (fun h0 _ h1 -> 
	  modifies_one i h0 h1 /\
	  modifies_rref i !{as_ref (as_rref c)} h0 h1 /\
	  m_sel h1 c = m_sel h0 c + 1))
  = m_recall c; m_recall log;
    let n = m_read c + 1 in 
    witness log (at_most_log_len n log);
    m_write c n

let testify_counter (#i:rid) (#l:rid) (#a:Type0) (#log:log_t l a) (#repr_max:nat) (ctr:counter i log repr_max)
  : ST unit
       (requires (fun h -> True))
       (ensures (fun h0 _ h1 -> 
	   h0=h1 /\
	   at_most_log_len (m_sel h1 ctr) log h1))
  = let n = m_read ctr in 
    testify (at_most_log_len n log)

let test (i:rid) (l:rid) (a:Type0) (log:log_t l a) //(p:(nat -> Type))
         (r:counter i log 8) (h:HyperHeap.t) 
  = //assert (m_sel2 h r = HyperHeap.sel h (as_rref r));
    assert (m_sel h r = HyperHeap.sel h (as_rref r));
    assert (m_sel #_ #(counter_val i log 8) #_ h r = HyperHeap.sel h (as_rref r))


(* TODO: this fails with a silly inconsistent qualifier error *)
(* logic val mem_index: #a:Type -> #i:rid -> n:nat -> x:a -> r:m_rref i (seq a) grows -> t -> GTot Type0 *)
(* logic let mem_index #a #i n x r h =  *)
(*       mem x r h *)
(*       /\ Seq.length (m_sel h r) > n *)
(*       /\ Seq.index (m_sel h r) n = x *)
