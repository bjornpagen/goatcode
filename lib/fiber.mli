(** The cooperative fiber substrate: control flow reified as data,
    interpreted by a handler.

    A fiber's suspensions are a {b typed instruction set} — the effect
    vocabulary below — and the scheduler is an evaluator over it: one
    domain, no preemption, a deterministic loop over a ready queue, a
    parked table, and an in-flight transfer table. This is doc rule 8
    applied to the engine's own control flow (docs/architecture/README.md):
    what a node does between suspensions is opaque OCaml, but {e every}
    point where it touches the world — an operand read, a yield, a
    provider call — is a value the scheduler pattern-matches on.

    The scheduler's view of every fiber is a printable state
    ({!status}, {!dump}): ready / running / parked-on-address / in-flight /
    settled. Continuations never substitute for that evented state — a
    captured continuation is ephemeral runtime detail, exactly as ephemeral
    as the HTTP call it wraps; the ledger, not the heap, is this project's
    source of truth (docs/architecture/30-channels.md § the ledger).

    Waiting happens at reads, never at issue: a parked fiber costs nothing
    and resumes on an external {!wake} — this module is the runtime
    chase.ml's parking story RUNS on. Every dispatched node is a fiber:
    the read itself parks (continuation held, keyed by the address it
    waits on) and {!wake} resumes exactly the fibers waiting on the
    address that changed — the engine's old whole-instance parked list
    and its requeue-everything-on-any-retirement are gone
    (docs/architecture/40-scheduling.md § read-time binding;
    docs/architecture/30-channels.md § pre-opened channels). *)

(** What a served read answers with — chase.mli's [Read.outcome], minus
    [Suspended]: suspension is not a value the fiber sees, it is the
    handler holding the continuation until {!wake}. The mid-flight read
    made real: "Witnessed — the read proceeds; Hypothesis — speculation
    proper begins here, not at issue" (chase.mli § Read). *)
module Operand : sig
  type t =
    | Witnessed of {
        generation : Ledger.Generation.t;
        content : Ledger.Content_hash.t;
      }
    | Hypothesis of Speculate.Hypothesis.t
end

(** {2 The effect vocabulary}

    The fiber's instruction set, as a typed sum. Performing one of these is
    the only way a fiber touches the scheduler; anything else it performs
    is a rogue effect, contained as a typed fault ({!settlement}), never a
    process crash. The constructors are public so the vocabulary is
    inspectable — but note the language records no effect in any signature:
    that a function performs [Read] is invisible to its type, which is why
    the vocabulary lives here, in one place, as the substrate's contract
    (the untyped-effects wound, docs/effects-evaluation.md). *)

type _ Effect.t +=
  | Read : Ledger.Address.t -> Operand.t Effect.t
        (** Request an operand. The handler answers witnessed or
            hypothesis ({!Operand.t}) — or holds the continuation, parking
            the fiber on the address until {!wake}. *)
  | Yield : Speculate.Drift.note list Effect.t
        (** The check-on-yield suspension point
            (docs/architecture/30-channels.md § delivery). The handler
            answers the drift notes that passed the fiber's footprint
            filter. A [`Stop_cleanly] disposition never reaches the fiber:
            the handler discontinues instead of resuming, so squash stops
            being a convention the fiber must honor and becomes a state the
            fiber cannot escape. *)
  | Http_post : Http.Request.t -> (int * string, Http.error) result Effect.t
        (** One provider-turn-shaped request. The fiber performs it and is
            parked on the transfer; the scheduler drives the transport
            (curl-multi in the live lane) and resumes on completion — N
            provider calls overlap on one domain with zero preemption. *)

exception Squash
(** What a squashed fiber's continuation is discontinued with. It unwinds
    the fiber's stack, so [Fun.protect] finalizers run
    — abort by construction, not compensation
    (docs/architecture/50-commit.md § abort by construction). Catching it
    buys the fiber nothing: squash is scheduler state, and every
    subsequent instruction the fiber performs is discontinued again; even
    a normal return after swallowing it settles as [Stopped], never
    [Returned]. *)

(** {2 Fiber-side operations}

    Wrappers over [perform]; callable only under a running scheduler —
    outside one they raise [Effect.Unhandled], the language's honest
    report that effects are dynamically scoped. *)

val read : Ledger.Address.t -> Operand.t
val yield : unit -> Speculate.Drift.note list
val http_post : Http.Request.t -> (int * string, Http.error) result

(** {2 The transport seam}

    The scheduler owns the event loop; a transport only starts transfers
    and reports completions. The live lane is {!Http.Multi}; tests rig the
    record directly (a scripted transport is how falsifiers prove overlap
    without a network). *)
module Transport : sig
  type token = Http.Multi.token

  type t = {
    submit : Http.Request.t -> token;
    poll : block:bool -> (token * (int * string, Http.error) result) list;
        (** Completions since the last poll. [block:true] may wait for
            activity but must return (possibly empty) in bounded time;
            [block:false] never waits. *)
  }

  val live : unit -> t
  (** Over {!Http.Multi}: [submit] is [start]; a blocking poll is [wait]
      then [completions]. *)
end

(** {2 Settlement} *)

(** Why a fiber stopped short of returning. The evidence travels with the
    stop — an external squash carries its cause chain, a clean stop
    carries the drift note that ordered it — so "why did this fiber die"
    is answerable from the value alone
    (docs/architecture/40-scheduling.md § settlement). *)
type stop =
  | Squashed of Ledger.Squash_cause.t  (** External {!squash}. *)
  | Stopped_cleanly of Speculate.Drift.note
      (** A [`Stop_cleanly] disposition delivered at {!Yield}. *)

(** Every fiber settles exactly once. [Faulted] covers the fiber's own
    raise {e and} a rogue (unvocabulary) effect — both are the node's own
    failure, contained as a value, never a scheduler crash. *)
type 'a settlement =
  | Returned of 'a
  | Stopped of stop
  | Faulted of Ledger.Fault.t

(** {2 The scheduler} *)

type t
(** One single-domain scheduler: ready queue (FIFO), parked table (fiber
    plus the address it waits on), in-flight table (fiber keyed by
    transfer token). Deterministic: spawn order, wake order, and the
    transport's completion order fully determine the schedule. *)

type id
(** A fiber's name in the scheduler's tables, minted at {!spawn} in spawn
    order. The public handle to park/squash state — continuations are
    never exposed, which is what makes resume-exactly-once an impossible
    call rather than a runtime crash ([Continuation_already_resumed] is
    unreachable through this interface; the internal one-shot wrapper is
    evidence in docs/effects-evaluation.md). *)

val id_to_string : id -> string
val id_equal : id -> id -> bool

type 'a handle
(** A spawned fiber and, once settled, its ['a settlement]. *)

val create :
  read:(id -> Ledger.Address.t -> Operand.t option) ->
  transport:Transport.t ->
  unit ->
  t
(** [read] is the mount's read-time binding policy — chase.ml's
    [read_operand] collapses onto it: [Some] answers the read now
    (witnessed or hypothesis); [None] parks the fiber on the address until
    {!wake}. The policy sees which fiber asks, so per-consumer judgments
    (shape switches, chain confidence) stay with the mount. *)

val spawn :
  t ->
  name:string ->
  ?on_yield:(unit -> Speculate.Drift.note list) ->
  (unit -> 'a) ->
  'a handle
(** Enqueue a fiber; it first runs at the next {!step}. [on_yield]
    (default: no notes) answers {!Yield} — the same seam as
    [Agent.Executor.run]'s [on_yield], so the agent loop mounts without
    reshaping. A note with [`Stop_cleanly] makes the handler discontinue:
    the fiber is settled [Stopped (Stopped_cleanly note)] and performs
    nothing further. *)

val id : _ handle -> id
val result : 'a handle -> 'a settlement option
(** [None] while the fiber is unsettled. *)

val wake : t -> key:Ledger.Address.t -> Operand.t -> int
(** An invalidation arrived: every fiber parked on [key] is moved to the
    ready queue (park order preserved) to resume with the given operand at
    the next {!step}. Returns how many woke; waking a key nobody parks on
    is 0 and a no-op — an invalidation racing a resume is normal traffic,
    not an error. This is the external half of chase.ml's
    "resume suspended reads" (its retirement today promotes {e every}
    parked instance; the mount wakes only the address that changed). *)

val squash : t -> id -> cause:Ledger.Squash_cause.t -> unit
(** Kill a fiber from outside, with its cause chain. A parked, ready, or
    in-flight fiber's continuation is discontinued with {!Squash} now
    (finalizers run before this returns); a not-yet-started fiber settles
    [Stopped] without ever running; a settled fiber is left alone. An
    in-flight fiber's transfer is abandoned — its completion arrives with
    no waiter and is dropped. *)

val step : t -> [ `Progressed | `Quiescent ]
(** One scheduling action: run the ready queue's head fiber to its next
    suspension, or — when nothing is ready and transfers are in flight —
    block on the transport and deliver completions. [`Quiescent] when
    neither applies. Parked fibers do not hold the scheduler open: their
    wake is external, so a quiescent scheduler with parked fibers is the
    mount's cue to serve or abort those reads (chase.ml's
    [resolve_parked]). *)

val run_until_quiescent : t -> unit
val quiescent : t -> bool

val has_ready : t -> bool
(** Something is in the ready queue — the next {!step} will run a fiber,
    not touch the transport. The mount's drain loop (run every ready fiber
    to its next suspension, then return to the engine) needs exactly this
    distinction: a drain that reached for the transport would serialize
    the very calls the substrate exists to overlap. *)

(** {2 Inspection}

    The evented view. Everything below is answerable without touching a
    continuation. *)

type status =
  | Ready
  | Running
  | Parked of Ledger.Address.t
  | In_flight of Transport.token
  | Settled of [ `Returned | `Stopped | `Faulted ]

val status : t -> id -> status

val parked : t -> (id * Ledger.Address.t) list
(** Park order — what the mount consults to serve or abort suspended
    reads. *)

val dump : t -> string
(** One line per fiber, spawn order: id, name, printed {!status}. *)
