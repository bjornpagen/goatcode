# 80 — Validation

How the design's laws stay true: named falsifiers that try to kill them,
replay determinism against the ledger, and measurement discipline for the one
claim everything rides on — that speculation pays. Readers: the test suite;
the ledger's telemetry reader; anyone about to quote a GOAT CODE number.

## The falsifier discipline

**Every law in these docs has a named test that tries to kill it, not an
example that happens to pass.** The roster, each entry naming the law and its
owning doc:

- **F1 — max-of-legs.** A diamond theory's wall clock is the slowest leg,
  never the sum: the dependency structure IS the schedule
  (`40-scheduling.md` § eager start, § read-time binding).
- **F2 — no head-of-line blocking.** A slow node on an open port never delays
  an unrelated ready node.
- **F3 — squash precision.** A fault or dead hypothesis squashes exactly the
  provenance-closed subtree; siblings retire undisturbed; the falsifier
  builds a graph where any over- or under-squash changes a committed tuple
  and asserts none does (`50-commit.md`).
- **F4 — dispatch purity.** No I/O, logging, or await on the
  settlement-to-issue path beyond the ledger append; enforced by
  instrumentation in test builds (`40-scheduling.md`).
- **F5 — abort by construction.** Kill a run at arbitrary points (fault
  injection at every yield class); committed state contains only
  fully-retired nodes' effects; worktree drops leave no orphan state
  (`50-commit.md`).
- **F6 — witness honesty.** A node whose executor is rigged to *claim* a
  dependency it never read, or to hide one it did read, gets the witness the
  ledger observed, both times (`30-channels.md` § mechanized witnesses).
- **F7 — free-commit.** An upstream that lands byte-identically to the
  hypothesis advances no generation, fires no invalidation, and its
  speculators retire with zero reconcile events (`50-commit.md` § law 2 —
  the economic keystone gets its own falsifier).
- **F8 — drift routing table.** Each drift class in `40-scheduling.md`'s
  table, constructed deliberately, routes as the table says — including the
  per-consumer refinement (a breaking change to an unread field routes
  additive for that consumer).
- **F9 — speculation is semantics-free.** The same theory and seed, run with
  speculation on and off, commits the same tuples (mod fresh-id renaming —
  the replay canonicalizer handles it) and the same law verdicts. The
  falsifier runs the review theory both ways with rigged executors
  (deterministic fake agents) and diffs.
- **F10 — repair-lane boundedness.** A permanently-invalid rigged executor
  faults after exactly the configured repair budget; nothing invalid ever
  crosses the codec boundary (`60-agents.md`, `20-contracts.md` § failure
  surface).
- **F11 — unidirectionality.** No API surface, tool grant, or channel
  operation lets a node write to any relation its statement doesn't mint
  into; the adversarial sweep drives planner-shaped garbage at admission and
  wire-shaped garbage at the codec, asserting no panic and no write
  (`30-channels.md`, `20-contracts.md`).
- **F12 — effect gating.** A speculative node's tool surface contains no
  non-idempotent effect tool, under every template configuration the suite
  can generate (`30-channels.md` § event taxonomy).
- **F13 — admission soundness.** Every theory the weak-acyclicity check
  admits quiesces on rigged executors with bounded fanout data; every
  rejected theory carries a real cycle path (checked by hand-verified
  fixtures) (`10-theory.md` § termination).
- **F14 — provisional identity.** Squashed nodes' minted ids never appear in
  committed tuples; committed id space is dense and replay-stable
  (`50-commit.md` § provisional identity).
- **F15 — compile-time probes.** Every state these docs declare
  *unrepresentable* has a negative compilation test: a probe file of
  programs that must NOT typecheck — a speculative `unique` value flowing
  into committed structures (`50-commit.md`), a non-idempotent effect tool
  in a speculative grant (`60-agents.md`), a wrong-relation phantom ref
  (`20-contracts.md`), `Run.exec` on an unadmitted theory, a bare
  `Switch.throw` (`70-api.md`), a wrongly-typed payload published through a
  correctly-named relation (`30-channels.md` § pre-opened channels) — each
  asserted to fail with the expected error class. Doc rule 8's claims are checkable claims, and this is their
  checker: an "unrepresentable" that compiles is a doc bug or a type bug,
  and either way the suite goes red.

Rigged executors (deterministic fakes with scripted outputs, delays, faults,
and invalid-output injections) make the whole roster runnable in CI without
a model call. Live-model runs are validation of the *templates*, never of
the engine laws — the split keeps the falsifiers fast and the engine's
correctness independent of any provider's behavior.

## Replay determinism

`goat replay <ledger>` re-executes a run's decision trace: same theory, same
seed, executor outputs substituted from the ledger's recorded events. The
assertion is that every scheduler decision (firing order, speculation
choices, drift routes, retire order) reproduces exactly — which holds only
if every input to every decision was itself ledger-recorded. Replay is
therefore the audit that **the ledger is complete**: a decision that
consults unrecorded state diverges under replay and fails the check. This is
the mechanism behind the no-hidden-state posture (`30-channels.md` § the
ledger), and the reason `Date.now()`-class nondeterminism is banned from
the scheduler (timestamps enter decisions only through the ledger).

## Honest measurement of speculation

The headline claim — the default-on engine beats speculation-off by ≥1.5×
wall clock, with token overhead published per shape (`00-product.md`) — is
exactly the kind of claim that goes wrong, and the discipline is written
before the first measurement:

- **Fresh tasks only.** A benchmark task the predictor has history on is a
  memorized world: the counters converge on the benchmark's own contract
  stability and the measured win is trained, not general. Headline numbers
  come from tasks whose (statement, executor) shapes have no prior ledger
  history; warm-predictor numbers are reported separately and labeled as
  the trained regime. The instrument is part of the experiment.
- **Regime on every number.** A speedup is stated with its graph shape
  (depth, width, contract-survival rate observed), model pins, and exchange
  rate. A regime-free speedup claim about this harness does not land in
  these docs (README rule 6) — the harness whose thesis is that regime-free
  claims decay does not get to mint them.
- **The baseline is the same engine.** Speculation-off (F9's twin) is the
  control — same theory, same templates, same pins — so the measured delta
  is the mechanism, not incidental differences between harnesses.
- **Wasted-token accounting is gross, not net.** Squashed tokens count in
  full even when a squashed node's worktree contained salvageable work; if
  salvage lanes are ever built, they earn their accounting when they exist.

## The speculation counters

The ledger-derived counter set, each with its named reader:

| Counter | Definition | Reader |
|---|---|---|
| survival(shape, pin) | hypotheses discharged unchanged / fired | port priority + hypothesis-source selection (`40-scheduling.md`) |
| reconcile_cost(shape) | mean tokens per drift-routed reconcile | the token-overhead report |
| flush_cost(shape) | mean tokens squashed per subtree flush | the token-overhead report |
| churn(shape) | wall-clock lengthening attributable to reconcile/flush serialization on contended ports | the per-shape off switch — the ONLY evidence that throws it (`40-scheduling.md`) |
| overlap(shape) | wall-clock actually overlapped per surviving hypothesis | `Report.summarize`; the default-on ruling's standing evidence |
| suspended_reads(shape) | read-suspension time with no hypothesis source | the planner pre-issue OPEN trigger (`40-scheduling.md`) |
| stale_window | invalidation append → consumer yield latency | the check-on-yield OPEN trigger (`README.md`) |
| footprint_escapes(edge) | loads outside the declared footprint | theory authors (`30-channels.md`) |
| repair_rate(template, pin) | boundary repairs per invocation | the GCD-lane reversal trigger (`60-agents.md`) |
| retire_latency | ready-to-merged per node | the early-retire reversal trigger (`50-commit.md`) |

Every reversal trigger written in these docs that says "measured" names its
counter in this table or doesn't say "measured." The table is the docs'
promissory notes made auditable.

## OPEN items

- **Live-pipeline benchmark corpus.** The census workloads (`00-product.md`)
  need concrete, re-runnable instances (a real build-from-spec, a real
  review sweep) that stay fresh under the fresh-tasks rule — which means the
  corpus must be *replenished*, not fixed; the generation discipline for
  fresh-but-comparable tasks is undesigned. *Trigger: the first headline
  measurement — this OPEN item blocks it, deliberately.*
- **Chaos lane.** Fault injection (F5) covers engine crash points; injected
  *provider* pathologies (rate limits mid-run, silent truncation, refusal
  storms) are unscripted. *Trigger: the first live-run incident whose class
  a rigged executor could have rehearsed.*
