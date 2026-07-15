(** The host surface: one entry point, a settled map for an answer.

    [exec] is the only way work runs, and it accepts only
    {!Theory.admitted} — an unadmitted theory cannot reach the engine by
    any code path (docs/architecture/70-api.md § running). The answer is a
    value, never an exception: a run-level failure exists only for host
    misuse (config paths that don't exist), never for node failure or law
    violation — the map is the answer. *)

(** Everything the docs say the operator owns, and nothing that changes
    semantics: a run with speculation switched off retires the same tuples
    with the same law verdicts, only slower (falsifier F9 asserts exactly
    this equivalence). *)
type config = {
  repo : string;  (** The git repository holding the committed branch. *)
  committed_branch : string;
  worktree_root : string;
  ledger_path : string;
  ports : Chase.Port.t list;
      (** The port table: provider ceilings and other documented
          bottlenecks (docs/architecture/40-scheduling.md § ports). *)
  executors : Chase.executor_binding list;
      (** Runtime bindings for the theory's executors: rigged in tests,
          the direct provider lanes ([Agent.agent] over [Agent.Provider])
          live. *)
  backstops : Speculate.Backstops.t;
      (** Token ceiling and confidence floor
          (docs/architecture/40-scheduling.md § backstops). *)
  switches : Speculate.Switch.t list;
      (** Per-shape speculation off switches. Representation-enforced: a
          switch exists only with churn evidence attached
          ({!Speculate.Switch.throw}). *)
  merges : Retire.Merge_registry.t;
      (** Merge functions, registered here — at theory accept — and never
          improvised (docs/architecture/50-commit.md). *)
}

type misuse =
  | Missing_path of { field : string; path : string }
  | Unbound_executor of { executor : string }
      (** The theory names an executor the config doesn't bind. *)
  | Unknown_port of { executor : string; port : string }
(** Host misuse: the only run-level rejections. Node failures and law
    violations are entries in the settled map, never these. *)

(** One node's row in the settled map: settlement, timing decomposition,
    and speculation stamps (docs/architecture/70-api.md § the settled
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
(** Run one theory to quiescence: pre-open channels, start every derivable
    node at t=0, chase, retire in dependency order, judge laws once
    against final state, and return the map. Runs on the cooperative
    fiber substrate ({!Fiber}): reads park mid-flight, provider calls
    overlap on one domain, squash discontinues — [exec] drives the
    scheduler to quiescence. Still one process, one domain
    (docs/architecture/70-api.md § running;
    docs/architecture/40-scheduling.md § read-time binding). *)

(** {2 In-flight observation} *)

type handle
(** A started run, observable while executing — the [Report.scoreboard]
    surface. Pull-only; polling it does not touch the dispatch path. *)

val start :
  theory:Theory.admitted ->
  seed:Theory.Tuple.t list ->
  config:config ->
  (handle, misuse) result

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
(** Re-execute a run's decision trace: same theory (recovered from the
    ledger), same seed, executor outputs substituted from recorded events.
    Every scheduler decision — firing order, speculation choices, drift
    routes, retire order — must reproduce exactly; replay is the audit
    that the ledger is complete
    (docs/architecture/80-validation.md § replay determinism). *)
