(** Direct HTTPS transport for the provider lanes, on in-process libcurl
    (ocurl). No subprocesses anywhere on this path: a shelled-out model
    session runs its own tool calls invisibly, which makes the
    mechanized-witness law unimplementable through one — direct calls with
    the harness owning the tool loop are the only design where every
    load/store is an evented, observable footprint
    (docs/architecture/30-channels.md § mechanized witnesses;
    docs/architecture/60-agents.md § the executor transport). *)

type error = {
  code : string;  (** libcurl's error constant name (e.g. CURLE_OPERATION_TIMEOUTED). *)
  message : string;
}
(** A transport-level failure: DNS, connect, TLS, timeout. HTTP status
    codes are never errors here — a non-2xx response is data the caller
    routes (provider fault handling is provider-specific). *)

val post_json :
  headers:(string * string) list ->
  url:string ->
  body:string ->
  timeout_s:float ->
  (int * string, error) result
(** One blocking POST. [headers] are (name, value) pairs — the caller
    supplies [content-type: application/json] along with its auth headers.
    Returns (HTTP status, response body) whenever the exchange completed,
    whatever the status. *)
