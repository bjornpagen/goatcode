(** The chase engine: eager start, read-time binding, ports, settlement,
    quiescence.

    The engine is the standard chase, plus two refinements: nodes start
    eagerly and bind operands at read time (a read of a
    missing-but-hypothesizable operand takes the hypothesis by default),
    and provenance is total (every tuple records the firing that produced
    it and the tuples that firing consumed)
    (docs/architecture/10-theory.md § chase semantics;
    docs/architecture/40-scheduling.md).

    The objective every policy here derives from: wall-clock time, at all
    costs. Where a policy could save tokens by waiting, it does not wait
    (docs/architecture/40-scheduling.md § the objective). *)

(** Ports: structural hazards, declared, never defaulted. The house posture
    is no limits — a numeric bound exists only where a strictly documented
    bottleneck forces it, and "prudence" is not a bottleneck.
    Unboundedness is written, never implied
    (docs/architecture/40-scheduling.md § ports and priority). *)
module Port : sig
  type t

  val open_ : name:string -> t
  (** An unbounded port, explicitly. *)

  val bounded : name:string -> limit:int -> bottleneck:string -> t
  (** A concurrency bound with its forcing bottleneck named (a model
      provider's concurrency ceiling, N resident worktrees on one disk).
      The [bottleneck] argument is required by construction: a bound
      without a documented reason is unwritable. *)

  val name : t -> string
  val limit : t -> int option
end

(** Port-admission priority: resumed reads with witnessed operands, then
    eager starts and hypothesis-carrying work, FIFO within class. Witnessed
    work is never displaced by speculative work — the ordering that makes
    default-on safe on bounded ports: the worst case for a bad hypothesis
    is wasted tokens and a queued slot, never a delayed witnessed node.
    v0 never preempts an admitted slot
    (docs/architecture/40-scheduling.md § ports and priority). *)
module Priority : sig
  type cls =
    | Resumed_witnessed
        (** A suspended read whose operand is now witnessed. *)
    | Eager_or_speculative
        (** Eager prefixes and hypothesis-carrying work; among these, the
            predictor orders higher survival first
            ({!Speculate.Predictor.compare_for_port}). *)

  val compare : cls -> cls -> int
end

(** Read-time operand binding: the unit of waiting is the read
    (docs/architecture/40-scheduling.md § read-time binding). *)
module Read : sig
  type outcome =
    | Witnessed of {
        generation : Ledger.Generation.t;
        content : Ledger.Content_hash.t;
      }
        (** Committed, or snoopable in a producer's store buffer; the
            triple enters the observed witness. *)
    | Hypothesis of Speculate.Hypothesis.t
        (** Missing but hypothesizable: speculation proper begins here, not
            at issue — taken against a richer store buffer and a more
            settled contract than any issue-time guess could see. *)
    | Suspended
        (** Missing, no source (or chain confidence below the floor): the
            fiber parks, costing nothing, and resumes on the operand's
            first invalidation. *)
end

module Settlement = Ledger.Settlement
(** Every node settles exactly once: retired / faulted / squashed. A fault
    squashes exactly the transitive dependents; siblings retire
    undisturbed; the engine never converts a node failure into a run-level
    rejection (docs/architecture/40-scheduling.md § settlement). *)

(** Binding a theory's executor declarations to runtimes: rigged in tests,
    {!Agent.claude_cli} live. The binding is run configuration, never
    theory content — the theory names executors; the run supplies them. *)
type executor_binding = {
  executor : Theory.Executor.id;
  runtime : Agent.Executor.t;
  fallback : Agent.Executor.t option;
      (** The constrained-decode refusal lane
          (docs/architecture/60-agents.md § the fallback lane). *)
  repair_budget : Agent.Repair_budget.t;
  port : string;  (** Every executor names its port. *)
}

type t
(** A running chase over one admitted theory. *)

val create :
  theory:Theory.admitted ->
  ledger:Ledger.t ->
  committed:Retire.Committed.t ->
  channels:Channel.registry ->
  worktree_root:string ->
  ports:Port.t list ->
  executors:executor_binding list ->
  backstops:Speculate.Backstops.t ->
  switches:Speculate.Switch.t list ->
  merges:Retire.Merge_registry.t ->
  seed:Theory.Tuple.t list ->
  t
(** Assemble the engine. Channels are already open (admission pre-opened
    them); every statement instance derivable from the seed starts at t=0 —
    starting is not speculating: the eager prefix consumes no operands and
    has nothing to squash on operand grounds
    (docs/architecture/40-scheduling.md § eager start). Seed tuples pass
    the codec boundary like any wire data. *)

val step : t -> [ `Progressed | `Quiescent ]
(** Advance the engine by one scheduling action. The dispatch path is
    pure: between a settlement and the dispatch of its dependents, no I/O,
    no logging, no awaits beyond the ledger append (falsifier F4). Every
    reissue, flush, and reconcile is a [Decision] ledger event with its
    reason — the engine ships typed signals; the scheduler owns the loop,
    and no retry exists below it. *)

val run_to_quiescence : t -> unit
(** Drive {!step} until no statement can fire, no reads are left to serve,
    and every started node has settled
    (docs/architecture/40-scheduling.md § quiescence and completion). *)

val quiescent : t -> bool

val settlements : t -> (Ledger.node Id.t * Settlement.t) list
(** Every settled node with its precise settlement, cause chains intact. *)

val committed : t -> Retire.Committed.t
(** The committed state retirement built — the only writer was the retire
    path. *)

val judge : t -> (Theory.Law.verdict list, [ `Not_quiescent ]) result
(** Final-state law judgment, delegated to {!Retire.judge}. Judged once, at
    quiescence, against the merged final state — mid-run state is not final
    state, so a pre-quiescence call returns [`Not_quiescent] rather than a
    wrong-or-hedged verdict (docs/architecture/50-commit.md § final-state
    judgment). [Run.exec] calls it exactly once, after
    {!run_to_quiescence}. *)
