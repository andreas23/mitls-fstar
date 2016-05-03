module TestClient13

open FStar.Seq
open FStar.HyperHeap
open Platform.Bytes
open Platform.Error
open HandshakeMessages
open Handshake
open TLSError
open TLSInfo
open TLSConstants
open TLSInfo
open StreamAE
open CoreCrypto

(* FlexRecord *)

let config =
    let sigPref = [CoreCrypto.RSASIG] in
    let hashPref = [Hash CoreCrypto.SHA256] in
    let sigAlgPrefs = sigAlgPref sigPref hashPref in
    let l =         [ TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 ] in
    let csn = cipherSuites_of_nameList l in
     {TLSInfo.defaultConfig with
         minVer = TLS_1p3;
    	 maxVer = TLS_1p3;
	 ciphersuites = csn;
	 }

let id = {
    msId = noMsId;
    kdfAlg = PRF_SSL3_nested;
    pv = TLS_1p3;
    aeAlg = (AEAD CoreCrypto.AES_128_GCM CoreCrypto.SHA256);
    csrConn = bytes_of_hex "";
    ext = {
      ne_extended_ms = false;
      ne_extended_padding = false;
      ne_secure_renegotiation = RI_Unsupported;
      ne_supported_curves = None;
      ne_supported_point_formats = None;
      ne_server_names = None;
      ne_signature_algorithms = None;
      ne_keyShare = None
    };
    writer = Client
  }

let encryptor_TLS13_AES_GCM_128_SHA256 kv iv: writer id = 
    // needed to match length requirements?
    let kv: StreamAE.key id = kv |> unsafe_coerce in
    let iv: StreamAE.iv id  = iv |> unsafe_coerce in

    assume (~ (authId id));
    StreamAE.coerce HyperHeap.root id kv iv

let decryptor_TLS13_AES_GCM_128_SHA256 kv iv: reader id = 
  let wr = encryptor_TLS13_AES_GCM_128_SHA256 kv iv in 
  genReader HyperHeap.root wr


//CF 16-04-30 it may be better to pass in a "Content.fragment i"

val encryptRecord_TLS13_AES_GCM_128_SHA256: writer id -> Content.contentType -> bytes -> bytes
let encryptRecord_TLS13_AES_GCM_128_SHA256 w ct plain = 
  // let pv = TLS_1p3 in
  let text = plain in
  // Range.frange -> Range.range
  let len = length text in
  let rg: Range.frange id = 0, len in

  let f = Content.mk_fragment id ct rg plain in 
  StreamAE.encrypt w (len+1) f // the extra byte is for CT with no padding

(* was:
  match ct with
  |  Content.Application_data -> 
       let f: DataStream.fragment id rg = text |> unsafe_coerce in
       let f: StreamPlain.plain id (len+1) = Content.CT_Data #id rg f |> unsafe_coerce in
         StreamAE.encrypt w (len+1) f
  |  Content.Handshake ->
       let f: StreamPlain.plain id (len+1) = Content.CT_Handshake #id rg text |> unsafe_coerce in
         StreamAE.encrypt w (len+1) f
*)


let decryptRecord_TLS13_AES_GCM_128_SHA256 rd ct cipher = 
//  IO.print_string ("cipher:"^(Platform.Bytes.print_bytes cipher)^"\n");
  let (Some d) = StreamAE.decrypt #id rd (length cipher - (StreamAE.ltag id)) cipher in
  Content.repr id d

(* We should use Content.mk_fragment |> Content.repr, not Record.makePacket *)
(* Even better, we should move to TLS.send *)
//let makePacket ct ver (data: b:bytes { repr_bytes (length b) <= 2}) =
//      abyte 22z
//   @| versionBytes ver
//   @| bytes_of_int 2 (length data) 
//   @| data 

let sendRecord tcp pv ct msg str = 
  let r = Record.makePacket ct pv msg in
  let Correct _ = Platform.Tcp.send tcp r in
  IO.print_string ("Sending "^Content.ctToString ct^"Data("^str^")\n")

val really_read_rec: bytes -> Platform.Tcp.networkStream -> nat -> optResult string bytes
let rec really_read_rec prev tcp len = 
    if (len <= 0) 
    then Correct(prev)
    else 
      match Platform.Tcp.recv tcp len with
      | Correct b -> 
            let lb = length b in
      	    if (lb >= len) then Correct(prev @| b)
      	    else really_read_rec (prev @| b) tcp (len - lb)
      | e -> e
      
let really_read = really_read_rec empty_bytes

let recvRecord tcp pv = 
  match really_read tcp 5 with 
  | Correct header ->
      match Record.parseHeader header with  
      | Correct (ct,pv,len)  ->
         match really_read tcp len  with
         | Correct payload -> (ct,pv,payload)

let makeHSRecord pv hs_msg log =
  let hs = HandshakeMessages.handshakeMessageBytes pv hs_msg in
  (string_of_handshakeMessage hs_msg,hs,log@|hs)

let sendHSRecord tcp pv hs_msg log = 
  let (str,hs,log) = makeHSRecord pv hs_msg log in
  sendRecord tcp pv Content.Handshake hs str;
  log

let recvHSRecord tcp pv kex log = 
  let (Content.Handshake,rpv,pl) = recvRecord tcp pv in
  match Handshake.parseHandshakeMessages (Some pv) (Some kex) pl with
  | Correct (rem,[(hs_msg,to_log)]) -> 
     	    (IO.print_string ("Received HS("^(string_of_handshakeMessage hs_msg)^")\n");
	     (hs_msg,log @| to_log))
  | Error (x,z) -> IO.print_string (z^"\n"); failwith "error"

let recvCCSRecord tcp pv = 
  let (Content.Change_cipher_spec,_,ccs) = recvRecord tcp pv in
  IO.print_string "Received CCS\n";
  ccs

let recvEncHSRecord tcp pv kex log rd = 
  let (Content.Application_data,_,cipher) = recvRecord tcp pv in
  let payload = decryptRecord_TLS13_AES_GCM_128_SHA256 rd Content.Handshake cipher in
  let Correct (rem,hsm) = Handshake.parseHandshakeMessages (Some pv) (Some kex) payload in 
  let [(hs_msg,to_log)] = hsm in
  IO.print_string ("Received HS("^(string_of_handshakeMessage hs_msg)^")\n");
  hs_msg, log @| to_log	      

let recvEncAppDataRecord tcp pv rd = 
  let (Content.Application_data,_,cipher) = recvRecord tcp pv in
  let payload = decryptRecord_TLS13_AES_GCM_128_SHA256 rd Content.Application_data cipher in
  IO.print_string "Received Data:\n";
  IO.print_string ((iutf8 payload)^"\n");
  payload

(* Flex Handshake *)

let deriveKeys_TLS13_AES_GCM_128_SHA256 (secret:bytes) (phase:string) (context:bytes) = 
  let cekb = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
      	     secret (phase ^ ", client write key") context 16 in
  let civb = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
      	     secret (phase ^ ", client write iv") context 12 in
  let sekb = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
      	     secret (phase ^ ", server write key") context 16 in
  let sivb = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
      	     secret (phase ^ ", server write iv") context 12 in
  (cekb,civb,sekb,sivb)

let derive_handshake_keys (gxy:CommonDH.secret) (log:bytes) = 
  let log_hash = CoreCrypto.hash CoreCrypto.SHA256 log in
  let zeroes = Platform.Bytes.abytes (String.make 32 (Char.char_of_int 0)) in
  let xES = HSCrypto.hkdf_extract CoreCrypto.SHA256 zeroes gxy in
  IO.print_string ("zeroes:"^(Platform.Bytes.print_bytes zeroes)^"\n");
  IO.print_string ("gxy:"^(Platform.Bytes.print_bytes gxy)^"\n");
  IO.print_string ("xES:"^(Platform.Bytes.print_bytes xES)^"\n");
  let (ck,civ,sk,siv) = deriveKeys_TLS13_AES_GCM_128_SHA256 xES "handshake key expansion" log_hash in
  IO.print_string ("client AES_GCM write log_hash:"^(Platform.Bytes.print_bytes log_hash)^"\n");
  IO.print_string ("client AES_GCM write key:"^(Platform.Bytes.print_bytes ck)^"\n");
  IO.print_string ("client AES_GCM salt: iv:"^(Platform.Bytes.print_bytes civ)^"\n");
  IO.print_string ("server AES_GCM write key:"^(Platform.Bytes.print_bytes sk)^"\n");
  IO.print_string ("server AES_GCM salt:"^(Platform.Bytes.print_bytes siv)^"\n");
  (xES,ck,civ,sk,siv)

let derive_finished_keys (xSS:bytes) (xES:bytes) (log:bytes) = 
  let log_hash = CoreCrypto.hash CoreCrypto.SHA256 log in
  let mSS = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
            xSS "expanded static secret" log_hash 32 in
  let mES = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
            xES "expanded ephemeral secret" log_hash 32 in
  let ms = HSCrypto.hkdf_extract CoreCrypto.SHA256 mSS mES in	    
  let cfk = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
            ms "client finished" empty_bytes 32 in
  let sfk = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
            ms "server finished" empty_bytes 32 in
  let ts0 = HSCrypto.hkdf_expand_label CoreCrypto.SHA256
            ms "traffic secret" log_hash 32 in
  (ms,cfk,sfk,ts0)  
  


let main host port =
  IO.print_string "===============================================\n Starting test TLS client...\n";
  let tcp = Platform.Tcp.connect host port in
  let log = empty_bytes in
  
  let (Some gx,ch,chb) = Handshake.prepareClientHello config None None in
  let pv = ch.ch_protocol_version in 
  let kex = TLSConstants.Kex_ECDHE in
  let log = sendHSRecord tcp pv (ClientHello ch) log in

  let ServerHello(sh),log = recvHSRecord tcp pv kex log in
  let Correct (n,ake) = Handshake.processServerHello config None [] ch sh in
  let pv = sh.sh_protocol_version in
  let cs = sh.sh_cipher_suite in
  let CipherSuite kex sa ae = cs in

  let Some (SEC ec,gyb) = n.n_extensions.ne_keyShare in
  let Correct gyb = vlparse 1 gyb in 
  IO.print_string ("server gy:"^(Platform.Bytes.print_bytes gyb)^"\n");

  let Some gyp = ECGroup.parse_point gx.ec_params gyb in  
  let gy = {ec_params = gx.ec_params; ec_point = gyp; ec_priv = None} in
  let gxy = CommonDH.dh_initiator (CommonDH.ECKey gx) (CommonDH.ECKey gy) in
  let (xES,ck,civ,sk,siv) = derive_handshake_keys gxy log in
  let wr = encryptor_TLS13_AES_GCM_128_SHA256 ck civ in
  let rd = decryptor_TLS13_AES_GCM_128_SHA256 sk siv in

  let l = CoreCrypto.aeadRealIVSize (alg id) in
  let extended = bytes_of_int l 0 in
  let aeIV = xor l extended siv in
  IO.print_string ("aeIV:"^(Platform.Bytes.print_bytes aeIV)^"\n");

  let EncryptedExtensions(ee),log = recvEncHSRecord tcp pv kex log rd in
  let Certificate(sc),log = recvEncHSRecord tcp pv kex log rd in
  let CertificateVerify(cv),log = recvEncHSRecord tcp pv kex log rd in
  let (ms,cfk,sfk,ts0) = derive_finished_keys xES xES log in
  let Finished(sfin),log = recvEncHSRecord tcp pv kex log rd in

  let log_hash = CoreCrypto.hash CoreCrypto.SHA256 log in
  let (ck,civ,sk,siv) = deriveKeys_TLS13_AES_GCM_128_SHA256 ts0 "application data key expansion" log_hash in
  let dwr = encryptor_TLS13_AES_GCM_128_SHA256 ck civ in
  let drd = decryptor_TLS13_AES_GCM_128_SHA256 sk siv in
  
  let cfin = {fin_vd = CoreCrypto.hmac CoreCrypto.SHA256 cfk (CoreCrypto.hash CoreCrypto.SHA256 log)} in 
  let (str,cfinb,log) = makeHSRecord pv (Finished cfin) log in
  IO.print_string "before encrypt \n";
  let efinb = encryptRecord_TLS13_AES_GCM_128_SHA256 wr Content.Handshake cfinb in
  sendRecord tcp pv Content.Application_data efinb str;

  let payload = "GET / HTTP/1.1\r\nHost: " ^ host ^ "\r\n\r\n" in
  let get = encryptRecord_TLS13_AES_GCM_128_SHA256 dwr Content.Application_data (utf8 payload) in
  sendRecord tcp pv Content.Application_data get "GET /";
  let ad = recvEncAppDataRecord tcp pv drd in

  

(*  
  let ms = TLSPRF.prf (pv,cs) pms (utf8 "master secret") (ch.ch_client_random @| sh.sh_server_random)  48 in
  IO.print_string ("master secret:"^(Platform.Bytes.print_bytes ms)^"\n");
  let (ck,civ,sk,siv) = deriveKeys_TLS12_AES_GCM_128_SHA256 ms ch.ch_client_random sh.sh_server_random in
  IO.print_string ("client AES_GCM write key:"^(Platform.Bytes.print_bytes ck)^"\n");
  IO.print_string ("client AES_GCM salt: iv:"^(Platform.Bytes.print_bytes civ)^"\n");
  IO.print_string ("server AES_GCM write key:"^(Platform.Bytes.print_bytes sk)^"\n");
  IO.print_string ("server AES_GCM salt:"^(Platform.Bytes.print_bytes siv)^"\n");

  let cfin = {fin_vd = TLSPRF.verifyData (pv,cs) ms Client log} in 
  let (str,cfinb,log) = makeHSRecord pv (Finished cfin) log in
  let efinb = encryptRecord_TLS12_AES_GCM_128_SHA256 wr Content.Handshake cfinb in
  sendRecord tcp pv Content.Change_cipher_spec HandshakeMessages.ccsBytes "Client";
  sendRecord tcp pv Content.Handshake efinb str;

  let _ = recvCCSRecord tcp pv in
  let Finished(sfin),log = recvEncHSRecord tcp pv kex log rd in

  let payload = "GET / HTTP/1.1\r\nHost: " ^ host ^ "\r\n\r\n" in
  let get = encryptRecord_TLS12_AES_GCM_128_SHA256 wr Content.Application_data (utf8 payload) in

  sendRecord tcp pv Content.Application_data get "GET /";
  let ad = recvEncAppDataRecord tcp pv rd in
*)
  ()

  



