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
