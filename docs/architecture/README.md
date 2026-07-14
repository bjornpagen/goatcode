# GOAT CODE Architecture

These documents are the normative design. They are living documents, updated in
place — there are no work packets or compliance gates. Git history is the
changelog; the documents themselves describe **only the current reality**.

There is no formal specification tree yet (see OPEN items); until one exists,
these docs are the only normative home of GOAT CODE's semantics. Where a
mechanism is inherited from a prior artifact — the `issue` scheduler, bumbledb's
commit protocol, primer's contract catalog — the doc names the inheritance once
and then owns the mechanism outright: GOAT CODE's docs never defer to another
repo for their own semantics.

## Rules for these docs

1. **Every decision records its strongest alternative, why it lost, and what
   evidence would reverse it** — one paragraph. If we can't articulate the
   alternative, the decision isn't made yet.
2. **Every mechanism must name its reader** — a channel, stamp, counter, or
   predictor with no named consumer is deleted. (The anti-transcription rule.)
3. **Undecided things are marked `OPEN` with a closure trigger** (the event or
   milestone that forces the decision) and listed below. An OPEN item is a real
   state; the failure mode is code deciding it silently.
4. **When implementation contradicts a doc**, the doc is amended in the same
   change, or the code change doesn't land. Docs describe the system in the
   present tense.
5. **No history.** These documents never narrate how the design got here or
   describe previous engines. A measured number may appear as rationale for a
   current mechanism ("measured"); a story may not.
6. **Regime honesty.** Every performance or economics claim carries its regime
   (task-graph shape, model tier, token budget). A regime-free claim about when
   speculation pays is folklore by construction and doesn't land.
7. **The dependency-statement gate.** A statement form enters the theory
   grammar only when the harness holds a cheap mechanical enforcement plan for
   it (`10-theory.md` § the acceptance gate). This rule governs the docs too:
   no doc may specify a contract clause, law, or invariant without naming the
   machinery that judges it.
8. **Representation before control flow.** A new case is absorbed by
   changing the data, types, or invariants so it stops being special or
   stops being expressible — a branch, guard, flag, or mode lands only with
   a recorded reason the representation could not absorb it (essential
   complexity, named as such). Corollaries these docs must obey: every
   boundary **parses into a refined type, never validates** — a check
   performed at a boundary is carried as a type so it is never re-performed
   downstream; states the design forbids are **unrepresentable, not
   guarded** — where the docs claim a state cannot occur, the claim names
   the type or mode that makes it unconstructible, not the check that
   catches it; and policy that must branch is **reified as data** — a
   table or sum type in one place, inspectable, never conditionals spread
   through the engine. (Brooks's "representation is the essence of
   programming," Pike's Rule 5, Minsky's illegal states, King's
   parse-don't-validate — the lineage is this design's deepest prior art,
   `00-product.md`.)

## The documents

| Doc | Contents |
|---|---|
| `00-product.md` | Thesis, the wall-clock objective, the machine analogy and its limits, workload census, the default-on posture, non-goals, deleted vocabulary, prior art, success criteria |
| `10-theory.md` | The work representation: relations with mint/ref slots, the statement grammar (TGDs, EGDs, cardinality windows, retire laws), chase semantics, the acceptance gate, termination |
| `20-contracts.md` | The contract catalog: one supply, lowering to JSON Schema via ppx, codecs, prompt derivation, code-interface meta-contracts, drift as schema diff |
| `30-channels.md` | Channels and events: the unidirectional law, pre-opened channels (socket activation), the ledger, tool-call event taxonomy, invalidate-don't-update, footprints, mechanized witnesses |
| `40-scheduling.md` | The chase engine: the wall-clock objective, eager start, read-time binding, default-on speculation, ports and priority, the predictor, backstops, flush/reconcile/wait |
| `50-commit.md` | Retirement: worktree isolation, abort by construction, the generation-witness protocol, EGD conflicts, final-state judgment, squash precision |
| `60-agents.md` | The execution units: prompt assembly from contracts, validate-and-repair, the refusal fallback lane, tool grants, model pins |
| `70-api.md` | Host surface: declaring a theory in OCaml, running, the settled map, telemetry pull surfaces |
| `80-validation.md` | The falsifier roster, replay determinism, honest measurement of speculation wins, the speculation counters |

## OPEN items

- **Formal specification of the retire state machine.** The
  speculation/retire protocol (hypotheses, witnesses, squash, generation
  advance) is a small state machine and the plan of record is to specify it
  formally and prove witness soundness and squash completeness, linking spec to
  implementation empirically (oracles, never verified extraction). *Trigger:
  the first retire-protocol bug that a falsifier misses, or the protocol
  surviving three months unchanged — whichever comes first.*
- **Durability and resume.** v0 is one process, in-memory graph, worktrees on
  disk; the ledger is replayable by design but no resume path is built.
  *Trigger: a real pipeline long enough that a crash costs more than a day of
  agent spend.*
- **Notification granularity for in-flight speculation** — check-on-yield
  decided for v0; continuous snooping is the recorded upgrade
  (`30-channels.md`). *Trigger: measured stale-speculation windows (ledger
  timestamps: invalidation append → consumer yield) dominating reconcile cost.*
- **Predictor structure.** v0 is per-task-shape survival counters; anything
  history-indexed (TAGE-shaped) waits for data. *Trigger: measured survival
  rates that are bimodal within one task shape — evidence that shape alone
  under-indexes.*
- **Port preemption.** v0 never preempts an admitted slot; the stop-cleanly
  requeue mechanism is designed, unbuilt (`40-scheduling.md`). *Trigger:
  measured witnessed-work queue time behind speculative occupants on a
  bounded port.*
- **Multi-machine execution.** The theory and ledger are location-transparent
  by construction; the scheduler is not. *Trigger: a workload whose port
  ceilings (model API concurrency) exceed one machine's usefulness — unlikely
  soon, since the bottleneck is provider ceilings, not cores.*
- **Human-in-the-loop nodes.** A human is representable as an execution unit
  with a very long latency distribution and no repair lane; nothing is built.
  *Trigger: the first pipeline that needs an approval gate.*
- **The `+ox` ppx compatibility census.** Which of the required ppx
  (`ppx_deriving_jsonschema`, `ppx_yojson_conv`) build unmodified under the
  OxCaml switch is an empirical fact recorded by the toolchain setup report.
  *Trigger: closes with the first green `dune build` — the boilerplate
  milestone.*

## Closed by ruling

Each recorded with its rationale in the owning doc; listed here so nothing is
re-litigated by accident:

- **Work is data.** The unit of orchestration is a theory — control flow
  reified as relations and statements, run by a small evaluator — never a
  script; this is doc rule 8 applied to the product itself
  (`00-product.md` § the representational bet, `10-theory.md`).
- **Every boundary parses.** Admission returns `Theory.admitted` (the only
  type `Run.exec` accepts); the codec boundary returns typed tuples with
  phantom-typed ref ids; the schema lint parses derived schemas into
  `Wire_schema.t`. No downstream code re-checks what a boundary proved
  (`10-theory.md`, `20-contracts.md`, `70-api.md`).
- **Wall clock is the objective, at all costs.** Tokens are backstops and
  reports, never gates; a policy that waits to save tokens is
  unconstitutional (`00-product.md`, `40-scheduling.md`).
- **Speculation is default-on, everywhere.** The only off switch is per task
  shape and requires measured reconcile churn — the one regime where
  speculation lengthens wall clock (`40-scheduling.md`).
- **Channels are pre-opened at admission; readiness is a property of a read,
  never of a node** — socket activation, with eager start and read-time
  hypothesis binding as consequences (`30-channels.md`, `40-scheduling.md`).
- **Channels are unidirectional, permanently.** Feedback is a forward edge
  firing a new generation; the scheduler is the only bidirectional party
  (`30-channels.md`).
- **Notifications are invalidations, never payloads** — consumers pull net
  deltas at their own yield points (`30-channels.md`).
- **No decode-time grammar constraint on the primary lane.** Freeform strong
  model + derived contract as reference + mechanical validation with
  diagnostic repair; constrained decoding survives only as the refusal
  fallback lane (`60-agents.md`).
- **The contract is data; everything else is derived.** Schema, codec, prompt
  prose, and `.mli` text all derive from one catalog value; a hand-carried
  second supply is unrepresentable (`20-contracts.md`).
- **The witness is the artifact, never an asserted version number**
  (`50-commit.md`).
- **Only semantic change advances a generation** — an upstream landing exactly
  the predicted contract retires its speculators for free (`50-commit.md`).
- **Speculative state aborts by construction** — squash drops a worktree and
  a ledger suffix; compensating actions are unrepresentable (`50-commit.md`).
- **The engine ships typed drift signals; replay is scheduler policy** — no
  hidden retry loop below the scheduler (`40-scheduling.md`).
- **Laws are judged at retire, against final state, once** — no per-event
  checking, no deferral modes (`50-commit.md`).
- **Speculation targets contracts, never implementations** — the hypothesis is
  the interface tuple, not the artifact bytes (`40-scheduling.md`).
- **Theories must be weakly acyclic at accept time** — chase termination is a
  static admission judgment, not a runtime hope; the token ceiling is a
  backstop, not the mechanism (`10-theory.md`).
- **OxCaml is the implementation substrate** — modes prove squash safety,
  effects carry the fibers; the decision block with alternatives is in
  `00-product.md`.
