(** The append-only event log: the system's architectural state made
    durable.

    Every tool call every agent makes is an event; so is every firing,
    settlement, invalidation, and scheduler decision. The fired graph, every
    witness, and every settlement are reconstructible from the ledger — it
    is the journal replay checks against, and the reason
    [Date.now()]-class nondeterminism is banned from the scheduler
    (timestamps enter decisions only through the ledger;
    docs/architecture/30-channels.md § the ledger;
    docs/architecture/80-validation.md § replay determinism).

    One log, four named readers — {!Replay}, {!Telemetry},
    {!Predictor_history}, {!Witness_index} — per the anti-transcription
    rule: a counter with no named consumer is deleted. No logger rides the
    dispatch path; telemetry is a query over the ledger.

    This module also owns the spatial vocabulary the movement and commit
    layers share (addresses, generations, content hashes, footprints, delta
    refs) and the identity realms for nodes and hypotheses. *)

type node
(** The {!Id} realm of nodes: one firing of a dependency statement. A node
    id is [node Id.t]. *)

type hypothesis
(** The {!Id} realm of hypotheses (docs/architecture/40-scheduling.md
    § read-time binding). *)

(** Ledger time. Timestamps are assigned at append and are the only clock
    any scheduler decision may consult (replay determinism). *)
module Timestamp : sig
  type t

  val compare : t -> t -> int
  val to_seconds : t -> float
  val pp : Format.formatter -> t -> unit
end

(** Token accounting: fuel burned to buy wall clock — accounted, reported,
    backstopped, never the objective
    (docs/architecture/00-product.md § thesis). *)
module Usage : sig
  type t = { tokens_in : int; tokens_out : int }

  val zero : t
  val add : t -> t -> t
  val total : t -> int
end

(** A committed-state address: the unit that carries a generation and
    appears in footprints. *)
module Address : sig
  type t =
    | File of string  (** Repo-relative path in the committed tree. *)
    | Tuple of { relation : string; id : string }
        (** One committed tuple, by relation and wire id. *)
    | Contract of string
        (** A relation's contract; its generation input is the derived
            schema hash (docs/architecture/20-contracts.md § versioning). *)
    | Resource of string
        (** Shared machine state outside any worktree — the effect lock's
            domain (docs/architecture/30-channels.md § event taxonomy). *)

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val to_string : t -> string
  val pp : Format.formatter -> t -> unit
end

(** Per-address generations. Only semantic change advances one: byte-null
    deltas and hash-identical schema re-derivations advance nothing, which
    is why an upstream landing exactly what speculators predicted retires
    them for free (docs/architecture/50-commit.md § law 2). *)
module Generation : sig
  type t

  val zero : t
  val next : t -> t
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

(** Content identity for observed reads and hypothesis snapshots. *)
module Content_hash : sig
  type t

  val of_string : string -> t
  (** Hash the given bytes (not a parse of a hex digest). *)

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val to_hex : t -> string
  val pp : Format.formatter -> t -> unit
end

(** A reference to an out-of-line payload (a store's net delta, a large
    artifact). Payloads live in the worktree or blob store, never inline in
    events or invalidations; consumers pull through the ref if and when
    they decide it matters (docs/architecture/30-channels.md § invalidate,
    don't update; the exact blob scheme is OPEN there). *)
module Delta_ref : sig
  type t

  val to_string : t -> string
  val pp : Format.formatter -> t -> unit
end

(** An address set: what a tool call touched, what an edge subscribes to,
    what conflict detection intersects
    (docs/architecture/30-channels.md § the ledger, § footprint
    filtering). *)
module Footprint : sig
  type t

  val empty : t
  val of_list : Address.t list -> t
  val to_list : t -> Address.t list
  val mem : t -> Address.t -> bool
  val union : t -> t -> t
  val inter : t -> t -> t
  val is_empty : t -> bool
end

(** A node's firing provenance: the statement fired, the tuples consumed,
    and the hypotheses inherited. Provenance is total — squash completeness
    (delete exactly the derivation subtree of a dead hypothesis) is a
    provenance walk, and the ledger stores it for free because firings are
    events (docs/architecture/10-theory.md § chase semantics). *)
module Provenance : sig
  type t = {
    statement : Theory.Statement.id;
    consumed : (string * string) list;
        (** (relation, tuple id) pairs the body match consumed. *)
    hypotheses : hypothesis Id.t list;
        (** Hypotheses this firing carries — its own and its ancestors'. *)
  }
end

(** A node's own failure: executor error or repair-lane exhaustion. The
    fault is the node's own throw, raw, never wrapped into a run-level
    rejection (docs/architecture/40-scheduling.md § settlement). *)
module Fault : sig
  type origin = Executor_error | Repair_exhausted | Context_exhausted

  type t = { origin : origin; message : string }
end

(** Why a node was killed from outside. Carries the cause chain: which
    hypothesis died, whose fault propagated
    (docs/architecture/40-scheduling.md § settlement). *)
module Squash_cause : sig
  type t =
    | Dead_hypothesis of hypothesis Id.t
    | Upstream_fault of node Id.t
    | Upstream_squash of node Id.t
    | Operator_abort
end

(** Precise settlement: every node settles exactly once, as one of three.
    The settled map, not an exception, is the answer the host receives
    (docs/architecture/40-scheduling.md § settlement). *)
module Settlement : sig
  type t =
    | Retired  (** Committed; head tuples inserted; worktree merged. *)
    | Faulted of Fault.t
    | Squashed of Squash_cause.t
end

(** The event taxonomy. Tool calls classify as exactly one of load / store /
    effect (docs/architecture/30-channels.md § event taxonomy); engine
    events record firings, hypotheses, invalidations, settlements, and
    every scheduler decision with its reason — so a reader of the ledger
    can always answer "why did this run twice"
    (docs/architecture/40-scheduling.md § drift routing). *)
module Event : sig
  type kind =
    | Load of {
        tool : string;
        observed : (Address.t * Generation.t * Content_hash.t) list;
            (** The witness triples this read contributes: captured by
                observation, never self-report
                (docs/architecture/30-channels.md § mechanized
                witnesses). *)
      }
    | Store of { tool : string; address : Address.t; delta : Delta_ref.t }
        (** A write against the node's own worktree; deltas are net
            (coalesced per yield in the store buffer). *)
    | Effect of { tool : string; resource : string; idempotent : bool }
        (** Shared machine state; acquired the footprint lock; the one
            class not squashable by construction — which is why
            speculative grants cannot contain the non-idempotent case
            (docs/architecture/60-agents.md § tool grants). *)
    | Agent_turn of { usage : Usage.t }
        (** One model turn's token bill, for the speculation account. *)
    | Fired of { provenance : Provenance.t; minted : (string * string) list }
        (** A statement fired this node; [minted] are its provisional
            (relation, id) existentials. *)
    | Hypothesis_taken of {
        hypothesis : hypothesis Id.t;
        address : Address.t;
        source : string;
        content : Content_hash.t;
        confidence : float;
      }
    | Hypothesis_discharged of { hypothesis : hypothesis Id.t }
    | Invalidation_sent of {
        address : Address.t;
        new_generation : Generation.t;
      }
    | Drift_note of { address : Address.t; cls : string; route : string }
        (** A drift note delivered at yield; [cls]/[route] are the wire
            renderings of [Speculate.Drift]'s typed forms. *)
    | Repair_attempt of { attempt : int; refusal : bool }
    | Settled of Settlement.t
    | Decision of {
        action : string;
        reason : string;
        counters : (string * float) list;
            (** The counters consulted, attached to the throw — reissue,
                flush, and switch decisions are explainable or they don't
                land. *)
      }
    | Pin_bump of { statement : string; executor : string; pin : string }
        (** Resets the shape's predictor counters
            (docs/architecture/60-agents.md § model pins). *)
    | Switch_thrown of {
        statement : string;
        executor : string;
        churn : float;
      }
        (** The per-shape speculation off switch, with the evidence
            (docs/architecture/40-scheduling.md § default-on). *)
    | Law_verdict of { law : string; satisfied : bool }
    | Correction of { subject : string; cause : string }
        (** A regression of a doc'd number, with a named cause
            (docs/architecture/00-product.md § success criteria). *)

  type t = {
    node : node Id.t option;
        (** [None] for run-level events (admission, quiescence, law
            verdicts). *)
    at : Timestamp.t;
    kind : kind;
  }
end

type t
(** An open ledger: single-writer append-only file in v0
    (docs/architecture/30-channels.md § OPEN items). *)

val create : path:string -> t
(** Open (creating if absent) the ledger at [path]. *)

val load : path:string -> t
(** Open an existing ledger read-only — the CLI's report/explain/replay
    entry (docs/architecture/70-api.md § the CLI). *)

val append : t -> ?node:node Id.t -> Event.kind -> Event.t
(** Append one event; the ledger assigns the timestamp and returns the
    stamped event. This is the one store the dispatch path owes
    (docs/architecture/40-scheduling.md § ports and priority). *)

(** {2 The four named readers} *)

(** Reader 1: resume/replay. The full stamped stream, in append order — what
    the replay-determinism falsifier re-executes decisions against
    (docs/architecture/80-validation.md § replay determinism). *)
module Replay : sig
  val events : t -> Event.t list
end

(** Reader 2: telemetry. Blocked/queue/run decomposition per node, token
    bills, all computed from event timestamps, all pull-only. *)
module Telemetry : sig
  type timing = { blocked_s : float; queued_s : float; run_s : float }

  val timing : t -> node Id.t -> timing option
  val usage : t -> node Id.t -> Usage.t
  val run_usage : t -> Usage.t
end

(** Reader 3: the predictor. Contract-survival and reconcile-cost history
    per task shape, per pin — the training data for
    [Speculate.Predictor] (docs/architecture/40-scheduling.md § the
    predictor). *)
module Predictor_history : sig
  type sample = {
    survived : bool;
    reconcile_tokens : int;
    flush_tokens : int;
    overlap_s : float;
  }

  val samples :
    t -> statement:string -> executor:string -> pin:string -> sample list
end

(** Reader 4: the witness index. Read-set and write-set extraction per
    node, consumed by conflict detection at retire — memory disambiguation,
    mechanized (docs/architecture/30-channels.md § mechanized witnesses). *)
module Witness_index : sig
  val reads :
    t -> node Id.t -> (Address.t * Generation.t * Content_hash.t) list
  (** Every triple the node's load events observed. An agent cannot
      fabricate a witness, cannot forget a dependency it consulted
      (falsifier F6). *)

  val writes : t -> node Id.t -> Footprint.t
  (** The node's store footprint, for the [disjoint] EGD. *)
end
