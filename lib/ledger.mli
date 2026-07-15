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
    refs), the identity realms for nodes and hypotheses, and the
    scheduler's decision and drift vocabularies ({!Decision}, {!Drift}) —
    sums, never wire strings, so a reader matches constructors and an
    unknown action is unrepresentable. *)

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
        (** Shared machine state outside the tree — the effect lock's
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
    artifact). Payloads live in git's object database, never inline in
    events or invalidations; consumers pull through the ref if and when
    they decide it matters (docs/architecture/30-channels.md § invalidate,
    don't update; docs/architecture/20-medium.md § event taxonomy — the
    blob store is git's object database). *)
module Delta_ref : sig
  type t

  val blob : string -> t option
  (** Parse a git object id exactly as [git hash-object] prints it (40 or
      64 lowercase hex digits) into a content-addressed ref — the one
      constructor a file store's delta has, so a store event can only name
      a blob that was hashed first (parse, don't validate). Minter: the
      agent layer's store tools. Readers of the oid: the retire step's
      landing (which builds the commit from these blobs, never from the
      tree), [Frontier.materialize], and consumers pulling deltas through
      invalidations (docs/architecture/20-medium.md § event taxonomy). *)

  val locator : string -> t
  (** A typed non-blob coordinate for movements with no bytes in the
      object store: payloads that live in committed structures (tuple and
      contract addresses — "relation/id", a contract name) and file
      deletions, which have no content to address. A file store's delta
      is never a locator — it is content-addressed through {!blob}. *)

  val oid : t -> string option
  (** The blob's object id when the ref is content-addressed ([None] for
      coordinate locators) — the hex [git cat-file] accepts. *)

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
    | Reissue_loser
        (** A completed attempt abandoned so its body match can reissue
            against the state that beat it: conflict losers and
            moved-witness reconciles. The reissue is the scheduler's next
            act, recorded beside this settlement
            (docs/architecture/40-scheduling.md § settlement). *)
    | No_producer
        (** A suspended read with no remaining producer: the operand can
            never be served, so the node settles and the run quiesces
            instead of hanging. *)
    | Operator_abort
end

(** Precise settlement: every node settles exactly once, as one of three.
    The settled map, not an exception, is the answer the host receives
    (docs/architecture/40-scheduling.md § settlement). *)
module Settlement : sig
  type t =
    | Retired  (** Committed; head tuples inserted; stores landed. *)
    | Faulted of Fault.t
    | Squashed of Squash_cause.t
end

(** The scheduler-decision vocabulary: the lifecycle every node walks
    (queued → admitted → dispatched; suspended ↔ resumed at blocking
    reads) plus the reissue/flush/abort rulings and the ceiling anomaly.
    A sum, never a string — an unknown action is unrepresentable, and
    {!Telemetry.timing} decomposes blocked/queued/run from these typed
    markers (docs/architecture/40-scheduling.md § ports and priority,
    § settlement). Throwing the per-shape speculation off switch is not
    here: it is its own event ({!Event.kind.Switch_thrown}), with the
    churn evidence attached. *)
module Decision : sig
  type t =
    | Queued of { port : string }
        (** Entered the named port's queue (ports are structural hazards,
            declared — docs/architecture/40-scheduling.md § ports). *)
    | Admitted of { port : string }  (** Won a slot on the named port. *)
    | Dispatched  (** Execution began; the run clock starts here. *)
    | Suspended  (** A read blocked with no hypothesis source; parked. *)
    | Resumed  (** The awaited operand landed; unparked. *)
    | Serialize_reissue
        (** Conflict loser reissued against the winner's state — the v0
            route for every write conflict
            (docs/architecture/50-commit.md § conflicts). *)
    | Flush_subtree
        (** A dead hypothesis's derivation subtree squashed
            (docs/architecture/40-scheduling.md § drift routing). *)
    | Abort_suspended
        (** A suspended read with no remaining producer settled so the
            run can quiesce. *)
    | Ceiling_bound
        (** The token ceiling bound: only witnessed work admitted until
            discharges catch up — an anomaly with a named cause, never a
            cost-control success
            (docs/architecture/40-scheduling.md § backstops). *)

  val to_string : t -> string
  (** The one wire rendering, for reports and replay divergence messages;
      never re-parsed. *)
end

(** Drift, as ledger events carry it: the class and the route, typed. The
    evidence-carrying parse ([Speculate.Drift.cls]) and the policy table
    live upstream in [Speculate]; events carry these compact forms because
    payloads never ride inline ({!Delta_ref}) — and replay re-judges each
    recorded route against the table without re-parsing any wire string
    (docs/architecture/40-scheduling.md § drift routing). *)
module Drift : sig
  type cls =
    | Schema_identical
    | Additive
    | Breaking_narrow
    | Breaking_broad
    | Producer_squashed

  type route =
    | Discharge_silently
    | Reconcile_note
    | Reconcile_delta
    | Flush_subtree

  val cls_to_string : cls -> string
  (** The one wire rendering, for reports; never re-parsed. *)

  val route_to_string : route -> string
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
        (** A write landed in the ONE shared tree at store time, its
            bytes content-addressed into git's object database first —
            [delta] is the blob oid for file content, a locator for
            deletions and committed-structure movements
            ({!Delta_ref}). *)
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
    | Drift_note of { address : Address.t; cls : Drift.cls; route : Drift.route }
        (** A drift note delivered at yield; the class's diff evidence
            stays with the note's out-of-line delta, never in the event. *)
    | Footprint_escape of { tool : string; address : Address.t }
        (** A load the retiring node's event stream proves, landing outside
            its edge's compiled delivery footprint: the node consulted
            state whose invalidations its subscription will never carry.
            Appended at retire, once per escaped address. The declaration
            is a filter, never a wall — correctness came from the observed
            witness; the escape is the grow-the-declaration witness, never
            a fault. Readers: the run-level [footprint_cover] verdict the
            engine appends to the settled map's laws, and [Report.explain]
            (docs/architecture/30-channels.md § footprint filtering). *)
    | Repair_attempt of { attempt : int; refusal : bool }
    | Settled of Settlement.t
    | Decision of {
        action : Decision.t;
        reason : string;
        counters : (string * float) list;
            (** The counters consulted, attached to the throw — reissue,
                flush, and switch decisions are explainable or they don't
                land. *)
      }
    | Pin_bump of {
        statement : Theory.Statement.id;
        executor : Theory.Executor.id;
        pin : string;
      }
        (** Resets the shape's predictor counters. Carries the typed
            identities — a reader reconstructs no id from a wire string
            (docs/architecture/60-agents.md § model pins). *)
    | Switch_thrown of {
        statement : Theory.Statement.id;
        executor : Theory.Executor.id;
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
  (** The node's span, partitioned by its {!Decision} lifecycle markers:
      queued between [Queued] and the next [Admitted]/[Dispatched], blocked
      between [Suspended] and the next [Resumed], running otherwise. The
      span opens at the node's first event and closes at its [Settled]
      event (or its last event, for a node still in flight). [None] for a
      node the ledger never saw. *)

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
    t ->
    statement:Theory.Statement.id ->
    executor:Theory.Executor.id ->
    pin:string ->
    sample list
  (** The shape's hypothesis lifecycles, keyed by the typed identities
      {!Event.kind.Pin_bump} records — no id is rebuilt from a wire
      string. *)
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
