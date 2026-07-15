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
    whatever the status. The blocking lane stands: non-fiber callers (the
    provider lanes today) keep this entry; the multi lane below exists for
    the fiber scheduler and changes nothing here. *)

(** One POST request as data — the argument list of {!post_json}, reified
    so a transfer can be carried, scripted, and started asynchronously. *)
module Request : sig
  type t = {
    headers : (string * string) list;
    url : string;
    body : string;
    timeout_s : float;
  }
end

(** The async lane: curl-multi transfers the fiber scheduler drives. This
    module owns transfers, never the event loop — [start] registers,
    [completions] drains, [wait] blocks for socket activity, and the
    {b caller} decides when each is called. The scheduler owns the loop
    (its ready queue and parked tables are the state the loop serves); a
    transport that ran its own loop would be a second scheduler
    (docs/architecture/40-scheduling.md § ports and priority: the dispatch
    path has one owner). *)
module Multi : sig
  type t
  (** One multi stack plus its in-flight table. Single-domain use only, like
      everything on this substrate. *)

  type token = int
  (** Names one in-flight transfer, minted at [start], never reused within
      a [t]. The scheduler keys its in-flight fiber table by this. *)

  val create : unit -> t

  val start : t -> Request.t -> token
  (** Register a transfer and return immediately; bytes move only inside
      [completions]/[wait] calls (libcurl multi performs on demand). *)

  val completions : t -> (token * (int * string, error) result) list
  (** Drive pending transfers without blocking and drain every completion,
      in libcurl's completion order. As with {!post_json}, a non-2xx status
      is data, never an [error]. *)

  val wait : t -> timeout_s:float -> bool
  (** Block until socket activity or [timeout_s]; [true] means activity
      (call [completions]). Never blocks past the timeout, so a scheduler
      quiesce check is never starved. *)

  val in_flight : t -> int
  (** Transfers started and not yet drained — the scheduler's
      anything-left-to-wait-for check. *)
end
