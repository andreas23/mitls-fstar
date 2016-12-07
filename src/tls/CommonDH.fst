﻿module CommonDH

open Platform.Bytes
open Platform.Error
open CoreCrypto
open TLSConstants

type group =
  | FFDH of DHGroup.group
  | ECDH of ECGroup.group

type params =
  | FFP of DHGroup.params
  | ECP of ECGroup.params

type key = 
  | FFKey of DHGroup.key
  | ECKey of ECGroup.key

type share =
  | FFShare of DHGroup.group * DHGroup.share
  | ECShare of ECGroup.group * ECGroup.share

type secret = bytes

val group_of_namedGroup: namedGroup -> Tot (option group)
let group_of_namedGroup g =
  match g with
  | SEC ec    -> Some (ECDH ec) 
  | FFDHE dhe -> Some (FFDH (DHGroup.Named dhe))
  | _ -> None

val same_group: share -> share -> Tot bool
let same_group a b = match a, b with
  | FFShare (g1, _), FFShare(g2, _) -> g1=g2
  | ECShare (g1, _), ECShare(g2, _) -> g1=g2
  | _ -> false

val share_of_key: key -> Tot share
let share_of_key = function
  | ECKey k -> let (g,s) = ECGroup.share_of_key k in ECShare(g,s)
  | FFKey k -> let (g,s) = DHGroup.share_of_key k in FFShare(g,s)

val default_group: group
let default_group = FFDH (DHGroup.Named FFDHE2048)

val keygen: group -> St key
let keygen = function
  | FFDH g -> FFKey (DHGroup.keygen g)
  | ECDH g -> ECKey (ECGroup.keygen g)

val dh_responder: key -> St (key * secret)
let dh_responder = function
  | FFKey gx -> 
    let y, shared = DHGroup.dh_responder gx in
    FFKey y, shared
  | ECKey gx -> 
    let y, shared = ECGroup.dh_responder gx in
    ECKey y, shared

let has_priv: key -> Type0 = function
  | FFKey k -> Some? k.dh_private
  | ECKey k -> Some? k.ec_priv

val dh_initiator: x:key{has_priv x} -> key -> St secret
let dh_initiator x gy =
  match x, gy with
  | FFKey x, FFKey gy -> DHGroup.dh_initiator x gy
  | ECKey x, ECKey gy -> ECGroup.dh_initiator x gy
  | _, _ -> empty_bytes (* TODO: add refinement/index to rule out cross cases *)


val key_params: key -> Tot params
let key_params k =
  match k with
  | FFKey k -> FFP k.dh_params
  | ECKey k -> ECP k.ec_params

(*
let checkParams dhdb minSize (p:parameters) =
    match p with
    | DHP_P(dhp) ->
      begin match dhdb with
        | None -> Error (TLSError.AD_internal_error, "Not possible")
        | Some db -> 
            (match DHGroup.checkParams db minSize dhp.dh_p dhp.dh_g with
            | Error(x) -> Error(x)
            | Correct(db, dhp) -> Correct(Some db, p))
      end
    | DHP_EC(ecp) -> correct (None, p)

let checkElement (p:parameters) (e:element) : option element  =
    match (p, e.dhe_p, e.dhe_ec) with
    | DHP_P(dhp), Some b, None ->
      begin match DHGroup.checkElement dhp b with
        | None -> None
        | Some x -> Some ({dhe_nil with dhe_p = Some x})
      end
    | DHP_EC(ecp), None, Some p ->
      begin match ECGroup.checkElement ecp p with
        | None -> None
        | Some p -> Some ({dhe_nil with dhe_ec = Some p})
      end
    | _ -> failwith "impossible"
*)
