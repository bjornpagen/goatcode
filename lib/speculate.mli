(** Speculation: hypotheses, drift classification, the survival-counter
    predictor, and the backstops.

    Speculation is default-on, everywhere — off is the exception that must
    be earned by evidence. Every read of a hypothesizable missing operand
    takes the hypothesis; the single off switch is per task shape and its
    constructor {e requires} the churn measurement that justifies it
    (docs/architecture/30-scheduling.md § speculation is default-on).
    Speculation targets contracts, never implementations: the hypothesis is
    the interface tuple, not the artifact bytes. *)

(** A task shape: the key of every speculation counter — (statement,
    executor), per model pin. A new pin is a new speculation regime
    (docs/architecture/30-scheduling.md § the predictor;
    docs/architecture/40-agents.md § model pins). *)
module Shape : sig
  type t = {
    statement : Theory.Statement.id;
    executor : Theory.Executor.id;
    pin : string;  (** {!Theory.Pin.key} of the executor's pin. *)
  }

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val to_string : t -> string
end

(** A hypothesis: the typed record of one read that proceeded on a guess.
    Taken at the blocking read — as late, and therefore as well-informed,
    as the work allows (docs/architecture/30-scheduling.md § read-time
    binding). *)
module Hypothesis : sig
  (** Where the guess came from; the predictor selects between sources when
      both exist. *)
  type source =
    | Issued_contract of {
        relation : string;
        schema : Contract.Schema_hash.t;
      }  (** A contract issued for the operand: the interface tuple. *)
    | Store_buffer of {
        producer : Ledger.node Id.t;
        snapshot : Ledger.Content_hash.t;
      }
        (** A partial artifact snooped from the producer's in-flight
            stores — the frontier's [In_flight] top
            (docs/architecture/20-medium.md § store-to-load
            forwarding). *)

  type t = {
    id : Ledger.hypothesis Id.t;
    consumer : Ledger.node Id.t;
    address : Ledger.Address.t;
    source : source;
    content : Ledger.Content_hash.t;
        (** Hash of the hypothesized value, compared against landing
            reality by the refresher. *)
    confidence : float;
        (** Chain confidence multiplies down a speculation chain; below the
            floor, reads suspend instead of hypothesizing
            (docs/architecture/30-scheduling.md § backstops). *)
  }
end

(** Drift, parsed once into a sum type and routed by a policy table — never
    conditionals threaded through the engine (doc rule 8: essential
    branching, reified as data;
    docs/architecture/30-scheduling.md § drift routing).

    Drift class is judged {e per consumer}, not per contract: a breaking
    change to a field the consumer's observed witness never read is
    additive from that consumer's perspective. *)
module Drift : sig
  (** The parse result. Each class carries the diff evidence that produced
      it. *)
  type cls =
    | Schema_identical
        (** Derived-schema hash equal: a rename-only refactor upstream. *)
    | Additive of { diff : Contract.Diff.t }
        (** The diff is pure additions. *)
    | Breaking_narrow of {
        diff : Contract.Diff.t;
        touched : Contract.Path.t list;
            (** The consumed paths the diff touches, from the consumer's
                observed witness. *)
      }
    | Breaking_broad of { diff : Contract.Diff.t; refired : bool }
        (** The diff touches a majority of consumed paths, or the
            producer's statement itself re-fired. *)
    | Producer_squashed

  val tag : cls -> Ledger.Drift.cls
  (** The class without its evidence — the compact typed form ledger
      events carry ({!Ledger.Drift}): the routing table's domain, and what
      [Drift_note] records. *)

  val table : (Ledger.Drift.cls * Ledger.Drift.route) list
  (** The routing policy, as data, in one place, inspectable. {!route} is
      its total-match twin; falsifier F8 constructs each class and asserts
      the route. Reconcile is the middle mode silicon lacks — "here is
      what changed, patch your work" — and it is where the design earns
      its keep (docs/architecture/00-product.md § the machine analogy). *)

  val route : cls -> Ledger.Drift.route

  val classify :
    landing:
      [ `Landed of Contract.Diff.t
      | `Refired of Contract.Diff.t
      | `Producer_squashed ] ->
    consumed:Contract.Path.t list ->
    cls
  (** The hypothesis refresher's parse of a landing against one consumer's
      observed reads. Performed once; the class carries its evidence. *)

  val payload_diff : was:Yojson.Safe.t -> landed:Yojson.Safe.t -> Contract.Diff.t
  (** Tuple-content drift as diff evidence: the landed payload against the
      snooped one, rendered in the same {!Contract.Diff} vocabulary schema
      drift uses (added / removed / changed payload paths), so {!classify}
      judges both drifts through one parse. Empty iff the payloads are
      structurally equal. *)

  (** A drift note: the compact rendering delivered to an agent at a yield
      point. It ends with the routing the scheduler already decided, so the
      agent never guesses its own fate
      (docs/architecture/40-agents.md § notes at yield). *)
  type note = {
    address : Ledger.Address.t;
    cls : cls;
    delta : Ledger.Delta_ref.t option;
    disposition : [ `Continue | `Patch_then_continue | `Stop_cleanly ];
        (** [`Stop_cleanly] is the humane form of squash for an agent
            mid-turn: finish no further work, emit nothing. *)
  }

  val disposition_of :
    Ledger.Drift.route -> [ `Continue | `Patch_then_continue | `Stop_cleanly ]
  (** The note's disposition, derived from the route the table already
      decided — one supply, so a note can never contradict its routing. *)
end

(** The hypothesis lifecycle, a sum-typed state machine:
    taken -> discharged | drifted{cls} | squashed. A [Taken] hypothesis
    blocks its consumer's retirement; the refresher settles it when the
    producer lands ({!landing}) or dies (the caller settles [Squashed]
    directly — a squash needs no content judgment)
    (docs/architecture/30-scheduling.md § read-time binding, § drift
    routing). *)
module Lifecycle : sig
  type t =
    | Taken  (** Pending: blocks the consumer's retirement. *)
    | Discharged  (** Landing reality matched; retirement unblocked. *)
    | Drifted of { cls : Drift.cls }
        (** Landing reality differed; the class carries the evidence and
            the scheduler routes it by the policy table. *)
    | Squashed  (** The producer died; the subtree dies with it. *)

  val landing :
    snooped:Yojson.Safe.t ->
    consumed:Contract.Path.t list ->
    landed:Yojson.Safe.t ->
    t
  (** The refresher's one judgment of a landing against one hypothesis:
      an identical landing is {!Discharged} silently (the free commit,
      falsifier F7); anything else parses into {!Drifted} with the
      payload-diff evidence, judged per consumer. Never returns [Taken]
      (a landing settles the state) and never [Squashed] (no landing
      exists to judge when the producer squashed). *)
end

(** Per-shape counters, all ledger-derived, each with its named reader
    (docs/architecture/50-api.md § the speculation counters). *)
module Counters : sig
  type t = {
    survival : float;  (** Hypotheses discharged unchanged / fired. *)
    reconcile_cost : float;  (** Mean tokens per drift-routed reconcile. *)
    flush_cost : float;  (** Mean tokens squashed per subtree flush. *)
    overlap_s : float;
        (** Wall clock actually overlapped per surviving hypothesis — the
            default-on ruling's standing evidence. *)
    suspended_reads_s : float;
        (** Read-suspension time with no hypothesis source: the planner
            pre-issue OPEN trigger. *)
    samples : int;
  }

  val of_ledger : Ledger.t -> Shape.t -> t
end

(** The v0 predictor: survival counters per shape. Under default-on it
    grants no permission; its three readers are port priority (among
    hypothesis-carrying candidates, higher survival first),
    hypothesis-source selection, and churn detection. Anything
    history-indexed (TAGE-shaped) waits for data; this module is the
    recorded upgrade slot (docs/architecture/30-scheduling.md § the
    predictor). *)
module Predictor : sig
  type t

  val of_ledger : Ledger.t -> t

  val survival : t -> Shape.t -> float option
  (** [None] for a fresh shape (no prior ledger history) — the regime
      headline measurements must be taken in
      (docs/architecture/50-api.md § honest measurement). *)

  val prefer_source :
    t ->
    Shape.t ->
    issued:Hypothesis.source ->
    snooped:Hypothesis.source ->
    Hypothesis.source
  (** Hypothesis-source selection when both a contract and a store-buffer
      snapshot exist. *)

  val compare_for_port : t -> Shape.t -> Shape.t -> int
  (** Port-priority comparator among hypothesis-carrying candidates:
      higher survival first, FIFO within ties
      (docs/architecture/30-scheduling.md § ports and priority). *)
end

(** Reconcile churn: the one measured regime where speculation lengthens
    wall clock (survival ≈ 0, drift predominantly breaking-broad, port
    contended, flush-reissue serializing). A measurement is obtainable only
    from a ledger — there is no public constructor — so the off switch
    cannot be thrown on folklore
    (docs/architecture/30-scheduling.md § speculation is default-on). *)
module Churn : sig
  type measurement

  val measure : Ledger.t -> shape:Shape.t -> measurement option
  (** [None] when the ledger shows no churn regime for the shape — in which
      case no switch can be built, by construction. *)

  val shape : measurement -> Shape.t

  val lengthening_s : measurement -> float
  (** Wall-clock lengthening attributable to reconcile/flush serialization
      on contended ports — the churn counter's definition. *)
end

(** The per-shape speculation off switch. {!Switch.throw} {e requires} a
    {!Churn.measurement}: a bare switch is not rejected by the config
    loader, it is unconstructible (doc rule 8; falsifier F15 asserts the
    negative compile). There is no force-on switch because on is the
    default; there is no global off because the objective doesn't have a
    global off. *)
module Switch : sig
  type t

  val throw :
    evidence:Churn.measurement -> thrown_by:[ `Operator | `Scheduler ] -> t
  (** Every throw is a ledger event with the numbers attached
      ([Ledger.Event.Switch_thrown]). *)

  val shape : t -> Shape.t
  val evidence : t -> Churn.measurement
  val thrown_by : t -> [ `Operator | `Scheduler ]
end

(** The two backstops: safety equipment, neither an objective
    (docs/architecture/30-scheduling.md § backstops). *)
module Backstops : sig
  type t = {
    token_ceiling : int;
        (** Per-run ceiling on spend under undischarged hypotheses. At the
            ceiling the scheduler admits only witnessed work until
            discharges catch up. Runaway protection for admitted theories
            whose data is bigger than expected; a run where it binds is an
            anomaly with a named cause, never a cost-control success. *)
    confidence_floor : float;
        (** Below the floor, reads suspend instead of hypothesizing:
            bounds flush-cascade depth in wall-clock terms — a wall-clock
            protection, not a token economy. *)
  }

  val default : t
  (** Generous by default; per-run configurable. *)

  val link_confidence : float
  (** One link's contribution to chain confidence: each hypothesis's
      confidence is its operand chain's product times this. A declared
      v0 constant (the floor's own documentation is calibrated to it:
      0.05 admits chains ~40 deep at 0.93 per link) — measurement-owned;
      a per-shape measured link factor is the recorded upgrade, in the
      predictor's slot (docs/architecture/30-scheduling.md
      § backstops). *)
end
