(* In-process libcurl transport for the provider lanes (http.mli owns the
   rationale: no subprocess may sit between the harness and a model). *)

type error = { code : string; message : string }

(* libcurl's global state is initialized once, lazily, so linking this
   module costs nothing until the first live call (tests never reach it:
   falsifiers run on rigged providers only). *)
let initialized = lazy (Curl.global_init Curl.CURLINIT_GLOBALALL)

let post_json ~headers ~url ~body ~timeout_s =
  Lazy.force initialized;
  let handle = Curl.init () in
  Fun.protect
    ~finally:(fun () -> Curl.cleanup handle)
    (fun () ->
      let response = Buffer.create 4096 in
      Curl.set_url handle url;
      Curl.set_post handle true;
      Curl.set_postfields handle body;
      Curl.set_postfieldsize handle (String.length body);
      Curl.set_httpheader handle
        (List.map (fun (name, value) -> name ^ ": " ^ value) headers);
      Curl.set_timeout handle (int_of_float (Float.ceil timeout_s));
      Curl.set_writefunction handle (fun chunk ->
          Buffer.add_string response chunk;
          String.length chunk);
      match Curl.perform handle with
      | () -> Ok (Curl.get_responsecode handle, Buffer.contents response)
      | exception Curl.CurlException (code, _errno, name) ->
          Error { code = name; message = Curl.strerror code })

module Request = struct
  type t = {
    headers : (string * string) list;
    url : string;
    body : string;
    timeout_s : float;
  }
end

(* libcurl's error constant name for a completion code. The single-handle
   lane gets this string from [CurlException]; the multi lane only receives
   the [curlCode], so the name is recovered here — a total table over the
   binding's constructors, mechanical by construction. *)
let code_name : Curl.curlCode -> string = function
  | Curl.CURLE_OK -> "CURLE_OK"
  | Curl.CURLE_UNSUPPORTED_PROTOCOL -> "CURLE_UNSUPPORTED_PROTOCOL"
  | Curl.CURLE_FAILED_INIT -> "CURLE_FAILED_INIT"
  | Curl.CURLE_URL_MALFORMAT -> "CURLE_URL_MALFORMAT"
  | Curl.CURLE_URL_MALFORMAT_USER -> "CURLE_URL_MALFORMAT_USER"
  | Curl.CURLE_COULDNT_RESOLVE_PROXY -> "CURLE_COULDNT_RESOLVE_PROXY"
  | Curl.CURLE_COULDNT_RESOLVE_HOST -> "CURLE_COULDNT_RESOLVE_HOST"
  | Curl.CURLE_COULDNT_CONNECT -> "CURLE_COULDNT_CONNECT"
  | Curl.CURLE_FTP_WEIRD_SERVER_REPLY -> "CURLE_FTP_WEIRD_SERVER_REPLY"
  | Curl.CURLE_FTP_ACCESS_DENIED -> "CURLE_FTP_ACCESS_DENIED"
  | Curl.CURLE_FTP_USER_PASSWORD_INCORRECT -> "CURLE_FTP_USER_PASSWORD_INCORRECT"
  | Curl.CURLE_FTP_WEIRD_PASS_REPLY -> "CURLE_FTP_WEIRD_PASS_REPLY"
  | Curl.CURLE_FTP_WEIRD_USER_REPLY -> "CURLE_FTP_WEIRD_USER_REPLY"
  | Curl.CURLE_FTP_WEIRD_PASV_REPLY -> "CURLE_FTP_WEIRD_PASV_REPLY"
  | Curl.CURLE_FTP_WEIRD_227_FORMAT -> "CURLE_FTP_WEIRD_227_FORMAT"
  | Curl.CURLE_FTP_CANT_GET_HOST -> "CURLE_FTP_CANT_GET_HOST"
  | Curl.CURLE_FTP_CANT_RECONNECT -> "CURLE_FTP_CANT_RECONNECT"
  | Curl.CURLE_FTP_COULDNT_SET_BINARY -> "CURLE_FTP_COULDNT_SET_BINARY"
  | Curl.CURLE_PARTIAL_FILE -> "CURLE_PARTIAL_FILE"
  | Curl.CURLE_FTP_COULDNT_RETR_FILE -> "CURLE_FTP_COULDNT_RETR_FILE"
  | Curl.CURLE_FTP_WRITE_ERROR -> "CURLE_FTP_WRITE_ERROR"
  | Curl.CURLE_FTP_QUOTE_ERROR -> "CURLE_FTP_QUOTE_ERROR"
  | Curl.CURLE_HTTP_NOT_FOUND -> "CURLE_HTTP_NOT_FOUND"
  | Curl.CURLE_WRITE_ERROR -> "CURLE_WRITE_ERROR"
  | Curl.CURLE_MALFORMAT_USER -> "CURLE_MALFORMAT_USER"
  | Curl.CURLE_FTP_COULDNT_STOR_FILE -> "CURLE_FTP_COULDNT_STOR_FILE"
  | Curl.CURLE_READ_ERROR -> "CURLE_READ_ERROR"
  | Curl.CURLE_OUT_OF_MEMORY -> "CURLE_OUT_OF_MEMORY"
  | Curl.CURLE_OPERATION_TIMEOUTED -> "CURLE_OPERATION_TIMEOUTED"
  | Curl.CURLE_FTP_COULDNT_SET_ASCII -> "CURLE_FTP_COULDNT_SET_ASCII"
  | Curl.CURLE_FTP_PORT_FAILED -> "CURLE_FTP_PORT_FAILED"
  | Curl.CURLE_FTP_COULDNT_USE_REST -> "CURLE_FTP_COULDNT_USE_REST"
  | Curl.CURLE_FTP_COULDNT_GET_SIZE -> "CURLE_FTP_COULDNT_GET_SIZE"
  | Curl.CURLE_HTTP_RANGE_ERROR -> "CURLE_HTTP_RANGE_ERROR"
  | Curl.CURLE_HTTP_POST_ERROR -> "CURLE_HTTP_POST_ERROR"
  | Curl.CURLE_SSL_CONNECT_ERROR -> "CURLE_SSL_CONNECT_ERROR"
  | Curl.CURLE_FTP_BAD_DOWNLOAD_RESUME -> "CURLE_FTP_BAD_DOWNLOAD_RESUME"
  | Curl.CURLE_FILE_COULDNT_READ_FILE -> "CURLE_FILE_COULDNT_READ_FILE"
  | Curl.CURLE_LDAP_CANNOT_BIND -> "CURLE_LDAP_CANNOT_BIND"
  | Curl.CURLE_LDAP_SEARCH_FAILED -> "CURLE_LDAP_SEARCH_FAILED"
  | Curl.CURLE_LIBRARY_NOT_FOUND -> "CURLE_LIBRARY_NOT_FOUND"
  | Curl.CURLE_FUNCTION_NOT_FOUND -> "CURLE_FUNCTION_NOT_FOUND"
  | Curl.CURLE_ABORTED_BY_CALLBACK -> "CURLE_ABORTED_BY_CALLBACK"
  | Curl.CURLE_BAD_FUNCTION_ARGUMENT -> "CURLE_BAD_FUNCTION_ARGUMENT"
  | Curl.CURLE_BAD_CALLING_ORDER -> "CURLE_BAD_CALLING_ORDER"
  | Curl.CURLE_HTTP_PORT_FAILED -> "CURLE_HTTP_PORT_FAILED"
  | Curl.CURLE_BAD_PASSWORD_ENTERED -> "CURLE_BAD_PASSWORD_ENTERED"
  | Curl.CURLE_TOO_MANY_REDIRECTS -> "CURLE_TOO_MANY_REDIRECTS"
  | Curl.CURLE_UNKNOWN_TELNET_OPTION -> "CURLE_UNKNOWN_TELNET_OPTION"
  | Curl.CURLE_TELNET_OPTION_SYNTAX -> "CURLE_TELNET_OPTION_SYNTAX"
  | Curl.CURLE_OBSOLETE -> "CURLE_OBSOLETE"
  | Curl.CURLE_SSL_PEER_CERTIFICATE -> "CURLE_SSL_PEER_CERTIFICATE"
  | Curl.CURLE_GOT_NOTHING -> "CURLE_GOT_NOTHING"
  | Curl.CURLE_SSL_ENGINE_NOTFOUND -> "CURLE_SSL_ENGINE_NOTFOUND"
  | Curl.CURLE_SSL_ENGINE_SETFAILED -> "CURLE_SSL_ENGINE_SETFAILED"
  | Curl.CURLE_SEND_ERROR -> "CURLE_SEND_ERROR"
  | Curl.CURLE_RECV_ERROR -> "CURLE_RECV_ERROR"
  | Curl.CURLE_SHARE_IN_USE -> "CURLE_SHARE_IN_USE"
  | Curl.CURLE_SSL_CERTPROBLEM -> "CURLE_SSL_CERTPROBLEM"
  | Curl.CURLE_SSL_CIPHER -> "CURLE_SSL_CIPHER"
  | Curl.CURLE_SSL_CACERT -> "CURLE_SSL_CACERT"
  | Curl.CURLE_BAD_CONTENT_ENCODING -> "CURLE_BAD_CONTENT_ENCODING"
  | Curl.CURLE_LDAP_INVALID_URL -> "CURLE_LDAP_INVALID_URL"
  | Curl.CURLE_FILESIZE_EXCEEDED -> "CURLE_FILESIZE_EXCEEDED"
  | Curl.CURLE_USE_SSL_FAILED -> "CURLE_USE_SSL_FAILED"
  | Curl.CURLE_SEND_FAIL_REWIND -> "CURLE_SEND_FAIL_REWIND"
  | Curl.CURLE_SSL_ENGINE_INITFAILED -> "CURLE_SSL_ENGINE_INITFAILED"
  | Curl.CURLE_LOGIN_DENIED -> "CURLE_LOGIN_DENIED"
  | Curl.CURLE_TFTP_NOTFOUND -> "CURLE_TFTP_NOTFOUND"
  | Curl.CURLE_TFTP_PERM -> "CURLE_TFTP_PERM"
  | Curl.CURLE_REMOTE_DISK_FULL -> "CURLE_REMOTE_DISK_FULL"
  | Curl.CURLE_TFTP_ILLEGAL -> "CURLE_TFTP_ILLEGAL"
  | Curl.CURLE_TFTP_UNKNOWNID -> "CURLE_TFTP_UNKNOWNID"
  | Curl.CURLE_REMOTE_FILE_EXISTS -> "CURLE_REMOTE_FILE_EXISTS"
  | Curl.CURLE_TFTP_NOSUCHUSER -> "CURLE_TFTP_NOSUCHUSER"
  | Curl.CURLE_CONV_FAILED -> "CURLE_CONV_FAILED"
  | Curl.CURLE_CONV_REQD -> "CURLE_CONV_REQD"
  | Curl.CURLE_SSL_CACERT_BADFILE -> "CURLE_SSL_CACERT_BADFILE"
  | Curl.CURLE_REMOTE_FILE_NOT_FOUND -> "CURLE_REMOTE_FILE_NOT_FOUND"
  | Curl.CURLE_SSH -> "CURLE_SSH"
  | Curl.CURLE_SSL_SHUTDOWN_FAILED -> "CURLE_SSL_SHUTDOWN_FAILED"
  | Curl.CURLE_AGAIN -> "CURLE_AGAIN"

module Multi = struct
  type token = int

  (* One in-flight transfer: the easy handle stays alive (and untouched)
     until libcurl reports it finished; [buffer] accumulates the body via
     the handle's write function. *)
  type transfer = { token : token; buffer : Buffer.t }

  type t = {
    mt : Curl.Multi.mt;
    mutable transfers : transfer list;  (* registration order *)
    mutable next_token : token;
  }

  let create () =
    Lazy.force initialized;
    { mt = Curl.Multi.create (); transfers = []; next_token = 0 }

  let start t (req : Request.t) =
    let token = t.next_token in
    t.next_token <- token + 1;
    let handle = Curl.init () in
    let buffer = Buffer.create 4096 in
    Curl.set_url handle req.url;
    Curl.set_post handle true;
    Curl.set_postfields handle req.body;
    Curl.set_postfieldsize handle (String.length req.body);
    Curl.set_httpheader handle
      (List.map (fun (name, value) -> name ^ ": " ^ value) req.headers);
    Curl.set_timeout handle (int_of_float (Float.ceil req.timeout_s));
    Curl.set_writefunction handle (fun chunk ->
        Buffer.add_string buffer chunk;
        String.length chunk);
    (* The token rides the handle itself (CURLOPT_PRIVATE): the finished
       handle ocurl returns is the same C handle in a DIFFERENT OCaml
       block ("NB: same handle, but different block", curl-helper.c), so
       physical identity cannot resolve completions — an equality that
       looked obviously right and failed only at runtime. *)
    Curl.set_private handle (string_of_int token);
    Curl.Multi.add t.mt handle;
    t.transfers <- t.transfers @ [ { token; buffer } ];
    token

  let pop_transfer t token =
    let mine, rest =
      List.partition (fun tr -> Int.equal tr.token token) t.transfers
    in
    t.transfers <- rest;
    match mine with [] -> None | tr :: _ -> Some tr

  let completions t =
    ignore (Curl.Multi.perform t.mt : int);
    let rec drain acc =
      match Curl.Multi.remove_finished t.mt with
      | None -> List.rev acc
      | Some (handle, code) -> (
          match
            Option.bind
              (int_of_string_opt (Curl.get_private handle))
              (pop_transfer t)
          with
          | None ->
              (* A handle the table doesn't know is a caller bug upstream;
                 cleaning it up is the only safe disposal. *)
              Curl.cleanup handle;
              drain acc
          | Some tr ->
              let outcome =
                match code with
                | Curl.CURLE_OK ->
                    Ok (Curl.get_responsecode handle, Buffer.contents tr.buffer)
                | c ->
                    Error { code = code_name c; message = Curl.strerror c }
              in
              Curl.cleanup handle;
              drain ((tr.token, outcome) :: acc))
    in
    drain []

  let wait t ~timeout_s =
    let timeout_ms = int_of_float (Float.ceil (timeout_s *. 1000.)) in
    Curl.Multi.wait ~timeout_ms t.mt

  let in_flight t = List.length t.transfers
end
