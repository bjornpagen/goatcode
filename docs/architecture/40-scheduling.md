# 40 — Scheduling

The chase engine: when nodes start (immediately), where they wait (at reads,
not at issue), and who decides what happens when a bet goes wrong. Readers:
the `Chase` and `Speculate` modules; `50-commit.md` (retirement consumes this
doc's hypothesis bookkeeping); `80-validation.md` (the counters this doc's
policies train on).

## The objective

**GOAT CODE optimizes wall-clock time, at all costs. Tokens are the fuel it
burns to buy wall clock — accounted, reported, backstopped, and never the
objective.** Every policy in this doc is derived from that sentence; where a
policy could save tokens by waiting, it does not wait. The operator's
calendar is the product (`00-product.md` § the objective).

## The staging law, under eager start

**Every node starts at the earliest moment it exists; every computation
within it runs at the earliest stage its inputs are fixed; waiting happens at
reads, never at issue.** The law's companion clause, constitutional: **pins
acknowledge; they never re-fix.** When an input a node consumed drifts, the
engine *records* the drift (a typed signal to the scheduler; a drift note to
the node at its next yield) — nothing implicitly re-runs anything.
Reconcile, reissue, and flush are explicit scheduler acts with recorded
reasons.

## Eager start (socket activation)

Inheritance stated once: s6/systemd socket activation — the supervisor opens
every socket before any service starts, so services start in any order and
dependency resolves at first read. GOAT CODE runs the same protocol:

**Every channel exists at admission, before any node runs
(`30-channels.md` § pre-opened channels). A statement instance starts the
moment it exists — never the moment its operands are ready:**

- **Known instances start at t=0.** A statement whose body match is already
  seeded, and every instance derivable from committed tuples, dispatches
  immediately, subject only to ports.
- **Data-generated instances start at materialization or hypothesis,
  whichever is earlier.** When `sweep` streams findings into its store
  buffer, `review` instances start against the snooped, uncommitted tuples
  (`30-channels.md` § store-to-load forwarding) — before `sweep` retires.
  The planner pre-issuing predicted contracts for not-yet-fired statements
  is the same mechanism one rung earlier (OPEN, below).
- **Starting is not speculating.** A node's opening work — loading context,
  reading the repo, scaffolding its approach — consumes no upstream
  operands, so the eager prefix runs unconditionally, with nothing to
  squash on operand grounds and no hypothesis attached. Agents front-load
  exactly this kind of work, which is why eager start pays even at zero
  hypothesis quality: the prefix was pure wall-clock overlap the old
  issue-on-readiness rule threw away.

## Read-time binding

**The unit of waiting is the read.** When a node's fiber reads an operand:

- **Witnessed** — the tuple is committed: the read proceeds; the (address,
  generation) enters the observed witness (`30-channels.md` § mechanized
  witnesses).
- **Uncommitted, hypothesizable** — the tuple sits in a producer's store
  buffer (parsed but unretired), or a contract is issued for it: the read
  returns a **hypothesis tuple**, recorded in provenance with its source
  and content hash, and the snooped content *also* enters the observed
  witness at the producer's uncommitted generation — the hypothesis is the
  lifecycle the refresher settles; the witness triple is the proof the
  commit point judges. This is speculation proper, and it begins *here*,
  not at issue.
- **Missing, no source** — nothing to hypothesize from (or the shape's off
  switch is thrown, or chain confidence is below the floor): the fiber
  suspends. A suspended fiber costs nothing (no tokens flow; the agent
  turn is parked at a yield) and resumes on the operand's first
  invalidation.

**Read-time hypotheses dominate issue-time hypotheses, by construction.**
The hypothesis is taken as late as the work allows — after the eager prefix,
often minutes into the producer's own run — so it is taken against a richer
store buffer and a more settled contract than any issue-time guess could
see. Moving speculation from issue time to read time simultaneously
shortens hypothesis lifetime (less time to be invalidated) and raises
hypothesis quality (more reality to hypothesize from). This is the mechanism
that makes default-on affordable; the survival counters measure it rather
than justify it.

Hypothesis lifecycle from here is unchanged in shape: head tuples carry
hypotheses in provenance; downstream firings inherit them; the **hypothesis
refresher** compares landing reality against each hypothesis (identical →
silent narrowing toward discharge; drift → a drift note at next yield;
producer squash → subtree squash); undischarged hypotheses block retirement
(`50-commit.md`).

## Speculation is default-on

**Decision.** **Every read of a hypothesizable missing operand takes the
hypothesis, everywhere, unless a per-shape off switch is thrown.** The off
switch exists for exactly one regime — the only one where speculation
*lengthens* wall clock: measured reconcile churn (survival ≈ 0, drift class
predominantly breaking-broad, port contended) where speculative occupancy
displaces witnessed work and the flush-reissue cycle serializes anyway. The
churn counter (`80-validation.md`) is the evidence; the switch is per
(statement, executor) shape, thrown by the operator or by the scheduler
citing the counter, and every throw is a ledger event with the numbers
attached. There is no force-on switch because on is the default; there is
no global off because the objective doesn't have a global off.
**Alternative:** expected-value gating in tokens (speculate iff
p(survive)·value − p(flush)·cost > 0, exchange-rate configured) — lost
because it optimizes the wrong objective: it trades the operator's wall
clock for token savings the operator never asked for, requires an
exchange-rate confession nobody can honestly supply, and makes the
harness's headline behavior (does it overlap or not?) depend on an
economic model instead of a mechanism. Token spend is real and is handled
where it belongs: as a backstop ceiling and a report.
**Alternative:** default-off with earned enablement per shape — lost with
the same objection amplified (the first run of a new theory is where wall
clock is worst and overlap matters most) plus socket activation removing
the cost asymmetry that made conservatism attractive: the eager prefix is
free, and read-time hypotheses are cheap to discharge.
**Reverses if:** never for the default; the per-shape churn switch is the
entire concession, and its threshold is measurement-owned.

## Ports and priority

**Ports are structural hazards, declared, never defaulted.** Every executor
names its port; a port is a concurrency bound. The house posture is no
limits — a numeric bound exists only where a strictly documented bottleneck
forces it (a model provider's concurrency ceiling, N resident worktrees on
one disk). "Prudence" is not a bottleneck. Unboundedness is written
(`Port.open_`), never implied.

On a contended port, admission priority is: **resumed reads with witnessed
operands, then eager starts and hypothesis-carrying work, FIFO within
class.** Witnessed work is never displaced by speculative work — that
ordering is what makes default-on safe on bounded ports: the worst case for
a bad hypothesis is wasted tokens and a queued slot, never a delayed
witnessed node. v0 has no preemption: an admitted node holds its slot to
its next yield (OPEN, below). **Decision.** **Alternative:** critical-path
weighting inside each class — deferred, not rejected: it needs critical-path
telemetry that doesn't exist until pipelines run; the slot is isolated in
the port admission comparator. **Reverses if:** measured cases where FIFO
admission visibly extends the critical path (the ledger names them).

**The dispatch path is pure.** Between a settlement and the dispatch of its
dependents the engine performs no I/O, no logging, no awaits beyond the
ledger append (which is the one store the path owes). Telemetry is pull.

## The predictor

**v0 is survival counters per task shape** — (statement id, executor id),
per model pin: hypothesis survival rate, mean reconcile cost, mean flush
cost, realized overlap. Under default-on the predictor does not grant
permission; its three readers are: **port priority** (among
hypothesis-carrying candidates, higher survival first), **hypothesis-source
selection** (contract hash vs store-buffer snapshot, when both exist), and
**churn detection** (the off-switch evidence). **Decision.**
**Alternative:** a history-indexed predictor (TAGE-shaped) — lost for v0:
no data yet, and a predictor richer than its training set memorizes it;
counters are inspectable and explainable in `Report.explain`. **Reverses
if:** measured bimodal survival within one shape (`README.md` OPEN); the
upgrade slot is isolated in `Speculate.Predictor`.

## Backstops

Two, both safety equipment, neither an objective:

- **The token ceiling.** A per-run ceiling on spend under undischarged
  hypotheses, generous by default. At the ceiling the scheduler admits only
  witnessed work until discharges catch up. Its purpose is runaway
  protection for admitted theories whose data is bigger than expected
  (`10-theory.md` § termination records why the ceiling is a backstop and
  not the mechanism); in normal operation it never binds, and a run where
  it binds is reported as an anomaly with the shape breakdown.
- **The confidence floor.** Chain confidence multiplies down a speculation
  chain; below the floor, reads suspend instead of hypothesizing. This
  bounds flush-cascade depth *in wall-clock terms* — a deep low-confidence
  subtree occupies port slots that witnessed work will need exactly when
  the cascade collapses — and is therefore a wall-clock protection, not a
  token economy. Generous default; per-run configurable.

## Drift routing: flush, reconcile, or wait

Drift is essential complexity — an uncontrollable upstream really can land
five genuinely different ways — so the branching is owed, and doc rule 8
dictates its form: **reified as data, in one place**. The hypothesis
refresher *parses* each landing into a `Drift.class` sum type (the parse
happens once; the class carries the diff evidence that produced it), and the
scheduler routes by a total match over that type — a policy table, never
conditionals threaded through the engine:

| Drift class | Signal | Route |
|---|---|---|
| Schema-identical (rename-only refactor upstream) | derived-schema hash equal | discharge silently; no consumer event |
| Additive (new optional field, widened enum) | diff is pure additions | reconcile: drift note at next yield; consumer usually no-ops |
| Breaking-narrow (field renamed/retyped, item signature changed) | diff touches consumed paths — the consumer's *observed witness* says which paths it read | reconcile: diagnostics + net delta; consumer patches its work |
| Breaking-broad (contract restructured; upstream decomposition changed) | diff touches a majority of consumed paths, or the producer's statement itself re-fired | flush the subtree; the planner may re-plan |
| Producer squashed | provenance | flush the subtree, always |

The consumed-paths refinement is why observed witnesses matter: a breaking
change to a field the consumer never read is *additive from that consumer's
perspective*, and routes as such. Drift class is judged per consumer, not
per contract.

**The engine ships signals; the scheduler owns the loop.** No retry,
reissue, or repair happens below the scheduler. Every route above is a
scheduler decision appended to the ledger with its reason (the diff class,
the counters consulted). A node is never surprised by its own re-execution;
a reader of the ledger can always answer "why did this run twice."

The table has three consumers, one per place drift can surface: the
**refresher** at a producer's landing (each pending hypothesis judged
against what landed), the **yield delivery** (an invalidation drained at a
consumer's suspension point becomes a typed note carrying the class and
the table's route), and the **rejection site** at retire (a moved witness
is classified per consumer before anything reissues). Every surfacing
appends the typed drift note; replay re-judges each recorded route against
the table. In the v0 synchronous engine a completed attempt cannot patch
mid-flight, so both reconcile rows route as reissue-with-the-diagnostics —
the note records the narrower intent; the mechanism converges when the
fiber substrate makes mid-flight patching real.

## Settlement

Every node settles exactly once, as one of:

- **`retired`** — committed; head tuples inserted; laws consulted at the
  commit (`50-commit.md`).
- **`faulted`** — the node's own failure (executor error, repair lane
  exhausted). The fault is the node's own throw, raw, never wrapped.
- **`squashed`** — killed from outside. Carries the cause chain, a sum
  naming exactly what killed it: a dead hypothesis; an upstream fault or
  upstream squash (whose); **reissue-loser** (a completed attempt
  abandoned so its body match can reissue against the state that beat it —
  conflict losers and moved-witness reconciles); **no-producer** (a
  suspended read whose operand can never be served, settled so the run
  quiesces); or operator abort. Reissue-losers and starved reads are never
  spelled as operator aborts — a reader of the settled map sees the real
  cause.

A fault squashes exactly the transitive dependents — provenance-walk
precision, falsifier-enforced (`80-validation.md`) — and siblings retire
undisturbed. The settled map, not an exception, is the answer the host
receives (`70-api.md`); the engine never converts a node failure into a
run-level rejection.

## Quiescence and completion

A run completes when no statement can fire (no live instances, no reads
left to serve) and every started node has settled. Retire laws are then
judged against final state (`50-commit.md`); law violations are reported on
the settled map as law verdicts, not as faults of any node — a quorum
shortfall names the law and the tuples, and the host decides whether that
is an error. **Decision.** **Alternative:** law violations fault the nodes
that "caused" them — lost because causation over set-valued laws is
ill-posed (which of the two missing verdicts is at fault?) and the
final-state judgment exists precisely to avoid per-node attribution of
global properties. **Reverses if:** never; a per-node judgment that seems
needed is a law that should have been a contract shape.

## OPEN items

- **Planner pre-issue.** Hypothesis sources in v0 are issued contracts and
  snooped store buffers. The planner pre-issuing *predicted* contracts for
  statements not yet fired is eager start one rung earlier and the natural
  next aggression. *Trigger: measured suspended-read time on deep chains
  (the ledger shows the opportunity's size directly — reads suspended with
  no hypothesis source, per shape).*
- **Port preemption.** v0 never preempts an admitted slot; a stop-cleanly
  note at the occupant's next yield (freeing the slot for witnessed work,
  requeueing the speculative occupant with its worktree intact) is the
  designed mechanism, unbuilt. *Trigger: measured witnessed-work queue
  time behind speculative occupants on a bounded port.*
- **Critical-path weighting** inside port priority classes — deferred with
  its slot named (§ ports and priority). *Trigger: recorded there.*
