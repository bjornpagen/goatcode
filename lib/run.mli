(** The host surface: one entry point, a settled map for an answer.

    [exec] is the only way work runs, and it accepts only
    {!Theory.admitted} — an unadmitted theory cannot reach the engine by
    any code path (docs/architecture/50-api.md § running). The answer is a
    value, never an exception: a run-level failure exists only for host
    misuse (config paths that don't exist), never for node failure or law
    violation — the map is the answer. *)

(** Everything the docs say the operator owns, and nothing that changes
    semantics: a run with speculation switched off retires the same tuples
    with the same law verdicts, only slower (falsifier F9 asserts exactly
    this equivalence). *)
type config = {
  repo : string;
      (** The git repository holding the committed branch — the ONE
          shared tree every node reads and writes (README.md § design of
          record vs shipped engine, row 4). *)
  committed_branch : string;
  ledger_path : string;
  ports : Chase.Port.t list;
      (** The port table: provider ceilings and other documented
          bottlenecks (docs/architecture/30-scheduling.md § ports). *)
  executors : Chase.executor_binding list;
      (** Runtime bindings for the theory's executors: rigged in tests,
          the direct provider lanes ([Agent.agent] over [Agent.Provider])
          live. *)
  backstops : Speculate.Backstops.t;
      (** Token ceiling and confidence floor
          (docs/architecture/30-scheduling.md § backstops). *)
  switches : Speculate.Switch.t list;
      (** Per-shape speculation off switches. Representation-enforced: a
          switch exists only with churn evidence attached
          ({!Speculate.Switch.throw}). *)
  merges : Retire.Merge_registry.t;
      (** Merge functions, registered here — at theory accept — and never
          improvised (docs/architecture/30-scheduling.md). *)
}

type misuse =
  | Missing_path of { field : string; path : string }
  | Unbound_executor of { executor : string }
      (** The theory names an executor the config doesn't bind. *)
  | Unknown_port of { executor : string; port : string }
(** Host misuse: the only run-level rejections. Node failures and law
    violations are entries in the settled map, never these. *)

(** One node's row in the settled map: settlement, timing decomposition,
    and speculation stamps (docs/architecture/50-api.md § the settled
    map). *)
type node_report = {
  settlement : Ledger.Settlement.t;
  timing : Ledger.Telemetry.timing;
      (** blocked (operand wait) / queued (port wait) / run. *)
  usage : Ledger.Usage.t;
  hypotheses : Ledger.hypothesis Id.t list;
      (** Hypotheses fired on; discharge times and drift notes are in the
          ledger, pulled by [Report.explain]. *)
}

type settled = {
  nodes : (Ledger.node Id.t * node_report) list;
  tuples : Retire.Committed.tuple list;
  laws : Theory.Law.verdict list;  (** Judged at quiescence, final state. *)
  ledger : Ledger.t;  (** The run's ledger, for the four readers. *)
}

val exec :
  theory:Theory.admitted ->
  seed:Theory.Tuple.t list ->
  config:config ->
  (settled, misuse) result
(** Run one theory to quiescence: converge the tree to the ledger's live
    frontier at open (boot IS crash recovery — a clean boot converges
    nothing, a boot over a crashed run's ledger materializes every live
    top; docs/architecture/20-medium.md § the crash story), pre-open
    channels, start every derivable node at t=0, chase, retire in
    dependency order, judge laws once against final state, and return the
    map. Runs on the cooperative fiber substrate ({!Fiber}): reads park
    mid-flight, provider calls overlap on one domain, squash
    discontinues — [exec] drives the scheduler to quiescence. Still one
    process, one domain (docs/architecture/50-api.md § running;
    docs/architecture/30-scheduling.md § read-time binding). *)

(** {2 In-flight observation} *)

type handle
(** A started run, observable while executing — the [Report.scoreboard]
    surface. Pull-only; polling it does not touch the dispatch path. *)

val start :
  theory:Theory.admitted ->
  seed:Theory.Tuple.t list ->
  config:config ->
  (handle, misuse) result
(** The same open path as {!exec} (boot = crash recovery: the frontier is
    re-derived and the tree converged before any node runs), returning
    the handle instead of driving to quiescence. *)

val ledger : handle -> Ledger.t
val wait : handle -> settled

(** {2 Replay} *)

type divergence = {
  at : Ledger.Timestamp.t;
  recorded : string;
  replayed : string;
}
(** A scheduler decision that failed to reproduce — evidence that some
    decision consulted unrecorded state. *)

val replay : Ledger.t -> (unit, divergence list) result
(** The ledger-completeness audit over a run's recorded trace: every
    judgment the trace makes re-derivable is re-derived from recorded
    events alone and asserted against what the ledger recorded — the
    clock (timestamps enter decisions only through the ledger, so append
    order is non-decreasing), settlement (every fired node settles
    exactly once), retire order (dependency order recomputed from firing
    provenance), and drift routing (each note's route re-derived from the
    policy table applied to its recorded class). A decision that
    consulted unrecorded state surfaces as a mismatch between the
    recorded rendering and the re-derived one.

    What this checker does {e not} do: firing order and speculation
    choices are recorded but not re-derived — their inputs include the
    admitted theory value and the run's backstop/switch configuration,
    which the ledger does not carry. Full re-execution (same theory, same
    seed, executor outputs substituted, every scheduler decision
    reproduced) is the recorded OPEN item, with its trigger
    (docs/architecture/50-api.md § replay determinism). *)
