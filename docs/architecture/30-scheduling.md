# 30 — Scheduling & Commit

The chase engine and its commit protocol: when nodes start (immediately),
where they wait (at reads, not at issue), who decides what happens when a
bet goes wrong, and how speculative state becomes committed state — or
nothing. Readers: the `Chase`, `Speculate`, `Retire`, and `Witness`
modules; `50-api.md` (the counters these policies train on and the
falsifiers that police every law here).

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
(`20-medium.md` § channels). A statement instance starts the moment it
exists — never the moment its operands are ready:**

- **Known instances start at t=0.** A statement whose body match is already
  seeded, and every instance derivable from committed tuples, dispatches
  immediately, subject only to ports.
- **Data-generated instances start at materialization or hypothesis,
  whichever is earlier.** When `sweep` streams findings into its in-flight
  stores, `review` instances start against the snooped, uncommitted tuples
  (`20-medium.md` § store-to-load forwarding) — before `sweep` retires.
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
  generation) enters the observed witness (`20-medium.md` § mechanized
  witnesses).
- **Uncommitted, hypothesizable** — the tuple sits in a producer's
  in-flight stores (parsed but unretired), or a contract is issued for it:
  the read returns a **hypothesis tuple**, recorded in provenance with its
  source and content hash, and the snooped content *also* enters the
  observed witness at the producer's uncommitted coordinate — the
  hypothesis is the lifecycle the refresher settles; the witness triple is
  the proof the commit point judges. This is speculation proper, and it
  begins *here*, not at issue.
- **Missing, no source** — nothing to hypothesize from (or the shape's off
  switch is thrown, or chain confidence is below the floor): the fiber
  suspends. A suspended fiber costs nothing (no tokens flow; the agent
  turn is parked at a yield) and resumes on the operand's first
  invalidation.

**The fiber is real, not a figure of speech.** Every dispatched node runs
as a fiber on the engine's single-domain cooperative scheduler (`Fiber`,
OCaml 5 effects): the read itself parks mid-flight — continuation held,
keyed by the awaited address — and a landing wakes exactly the fibers
parked on the addresses it committed, never a requeue of the whole parked
population. A woken read holds its admitted slot (the wake key is a
committed address, so it is witnessed work by construction). Provider
calls suspend on the `Http_post` instruction, so N model turns overlap on
one domain with zero preemption and no threads. Squash discontinues the
fiber: its stack unwinds, `Fun.protect` finalizers run before the squash
returns, and a squashed node cannot execute another instruction — squash
is scheduler state, never a convention the node honors. It is also the
interrupt mode's mechanism (`20-medium.md` § delivery): a kill-now is a
discontinue, whoever ordered it. Scheduling stays deterministic and
replay-coherent: FIFO ready queue, spawn and wake order fixed by the
trace, completion order owned by the transport (curl-multi live; scripted
in falsifiers FM1–FM4).

**Decision — the substrate is OCaml 5 effects, owned outright.** What is
adopted: a single-domain Deep-handler scheduler (`Fiber`) over a
three-instruction typed vocabulary (`Read`/`Yield`/`Http_post`), with
park/wake keyed by address, squash as discontinue with `Fun.protect`
finalizers, and curl-multi as the async HTTP lane — every dispatched node
a direct-style fiber.
**Alternative:** the blocking engine (whole-instance parking, re-read all
operands per attempt, requeue the entire parked list on any retirement) —
lost because it can hold N provider calls open only by burning N threads
or serializing, and because it is provably the defunctionalized form of
this scheduler (the mount reproduced the blocking trace with zero expect
diffs), i.e. the same machine with the resume points hand-maintained.
**Alternative:** Lwt or Eio — lost to monadic coloring (every function
between the tool loop and a suspension point recolors) and to importing a
general-purpose runtime where the deterministic, ledger-ordered scheduler
*is* the product; stdlib `Effect` also kept the no-new-dependencies rule.
The cost is recorded honestly: every effects guarantee here is dynamic
(untyped performs, runtime `Unhandled`, runtime one-shot enforcement,
escapable discontinue), so this one layer is held by falsifiers
(FB1–FB7) where the rest of the codebase gets types — the full evidence
file is `docs/effects-evaluation.md`.
**Reverses if:** OxCaml's typed effects mature (the growth path: the
vocabulary moves from discipline-as-documentation into signatures, and
FB6's runtime containment becomes a compile error), or the recorded
Rust-port trigger fires (`00-product.md` § substrate decision) — the
evaluation file records what ports (the semantics: park/wake/squash/
overlap all express in async Rust, `Drop` even improves squash) and what
is lost (direct style; Rust buys back the coloring), bounding that cost
to this layer plus the executor loop's signatures.

**Read-time hypotheses dominate issue-time hypotheses, by construction.**
The hypothesis is taken as late as the work allows — after the eager prefix,
often minutes into the producer's own run — so it is taken against richer
in-flight state and a more settled contract than any issue-time guess could
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
(§ retirement, below).

## Speculation is default-on

**Decision.** **Every read of a hypothesizable missing operand takes the
hypothesis, everywhere, unless a per-shape off switch is thrown.** The off
switch exists for exactly one regime — the only one where speculation
*lengthens* wall clock: measured reconcile churn (survival ≈ 0, drift class
predominantly breaking-broad, port contended) where speculative occupancy
displaces witnessed work and the flush-reissue cycle serializes anyway. The
churn counter (`50-api.md`) is the evidence; the switch is per
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
forces it (a model provider's concurrency ceiling, a build-artifact
resource like the `_build` directory behind its effect lock). "Prudence"
is not a bottleneck. Unboundedness is written (`Port.open_`), never
implied.

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
Supervision is a pure fold over that same append and adds nothing to the
path (`40-agents.md` § the cadence law).

## The predictor

**v0 is survival counters per task shape** — (statement id, executor id),
per model pin: hypothesis survival rate, mean reconcile cost, mean flush
cost, realized overlap. Under default-on the predictor does not grant
permission; its three readers are: **port priority** (among
hypothesis-carrying candidates, higher survival first), **hypothesis-source
selection** (contract hash vs in-flight-store snapshot, when both exist),
and **churn detection** (the off-switch evidence). **Decision.**
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
  it binds is reported as an anomaly with the shape breakdown. Under the
  no-walls ruling it also backstops message-driven work, which has no
  static termination story (`00-product.md` § the two graphs).
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

The table has four consumers, one per place drift can surface: the
**refresher** at a producer's landing (each pending hypothesis judged
against what landed), the **yield delivery** (an invalidation drained at a
consumer's suspension point becomes a typed note carrying the class and
the table's route), the **rejection site** at retire (a moved witness is
classified per consumer before anything reissues), and **gate verdicts**
(a gate's frontier-snapshot hypotheses judged like any other —
§ gates on the shared tree). Every surfacing appends the typed drift note;
replay re-judges each recorded route against the table. In v0 both
reconcile rows route as reissue-with-the-diagnostics — a completed attempt
cannot patch, and an in-flight fiber receives the note at its next yield
but has no patch protocol yet; the note records the narrower intent, and
the substrate carries the suspension points mid-flight patching needs (the
remaining work is the patch contract, not the scheduler).

## Settlement

Every node settles exactly once, as one of:

- **`retired`** — committed; head tuples inserted; laws consulted at the
  commit (§ retirement).
- **`faulted`** — the node's own failure (executor error, repair lane
  exhausted). The fault is the node's own throw, raw, never wrapped.
- **`squashed`** — killed from outside. Carries the cause chain, a sum
  naming exactly what killed it: a dead hypothesis; an upstream fault or
  upstream squash (whose); **reissue-loser** (a completed attempt
  abandoned so its body match can reissue against the state that beat it —
  conflict losers and moved-witness reconciles); **no-producer** (a
  suspended read whose operand can never be served, settled so the run
  quiesces); **supervisor abort** (`Supervisor_abort { reason }` — the
  supervisor's kill, traceable to the `Steered` event that ordered it,
  never spelled as an operator abort — `40-agents.md` § the steering
  vocabulary); or operator abort. Reissue-losers and starved reads are
  never spelled as operator aborts — a reader of the settled map sees the
  real cause, whoever acted.

A fault squashes exactly the transitive dependents — provenance-walk
precision, falsifier-enforced (`50-api.md`) — and siblings retire
undisturbed. The settled map, not an exception, is the answer the host
receives (`50-api.md`); the engine never converts a node failure into a
run-level rejection.

## Quiescence and completion

A run completes when no statement can fire (no live instances, no reads
left to serve) and every started node has settled. Retire laws are then
judged against final state (§ final-state judgment); law violations are
reported on the settled map as law verdicts, not as faults of any node — a
quorum shortfall names the law and the tuples, and the host decides whether
that is an error. **Decision.** **Alternative:** law violations fault the
nodes that "caused" them — lost because causation over set-valued laws is
ill-posed (which of the two missing verdicts is at fault?) and the
final-state judgment exists precisely to avoid per-node attribution of
global properties. **Reverses if:** never; a per-node judgment that seems
needed is a law that should have been a contract shape.

---

# Commit

How speculative state becomes committed state, and how everything else
becomes nothing — on one shared tree, fix-forward only.

## Abort by construction

**A node's entire mutable output is its ledger events: stores with
content-addressed blobs, at coordinates that are live only while the node
is unsettled or retired. Squash is one settlement append; every store
coordinate under the squashed subtree is provenance-dead by derivation —
"failed work leaves nothing" is true by coordinate, never by rollback**
(`20-medium.md` § squash without isolation owns the full decomposition:
settlement, cascade, forward repair, hygiene). No compensating action is
representable in the engine; an executor that needs one is asking for an
effect grant, which is the declared, idempotence-gated exception
(`20-medium.md` § event taxonomy), not a hole in this law.

The OxCaml enforcement: speculative results are `unique`-moded values —
consumed exactly once, by retire or by squash. Committed state is reachable
only through the retire path; a code path that would let a speculative
value flow into committed structures without discharging its hypotheses does
not typecheck. This is "make illegal states unrepresentable" applied to the
retire protocol itself — the leak the success criteria call absolute
(`00-product.md`) is not policed by review or caught by a runtime guard;
it is a state the mode system refuses to construct. The compile-time probe
falsifiers assert exactly this refusal (`50-api.md` F15).

## Provisional identity

Mint slots are filled at firing time with ids minted **provisionally against
the committed counter as of the node's snapshot**. Provisional ids are real
ids — downstream speculative nodes ref them, tuples carry them — but they
bind (become committed identity) only at the minting node's retirement, in
dependency order, so committed id space is dense and replay-deterministic.
A squashed node's provisional ids die with it; nothing renumbers. Reader:
the codec boundary (which rejects agent-invented ids by checking mint
provenance — `10-theory.md` § failure surface).

## The generation-witness protocol

Every committed address (file path, relation tuple-set, contract) carries a
**generation**, and the protocol has four laws:

1. **The witness is the artifact, never an asserted number.** A node's
   witness is the set of (address, generation, content-hash) triples
   assembled from its *observed* load events (`20-medium.md` § mechanized
   witnesses). Nothing in the system ever trusts a claimed version; evidence
   is collected, not reported. (Parse-don't-validate, applied to trust: a
   version number is a validator's residue — a claim whose proof was thrown
   away; the observed triple set is the proof itself, carried to the commit
   point.)
2. **Only semantic change advances a generation.** At retirement, a store's
   net delta is compared against the address's committed content: byte-null
   deltas advance nothing (cancellation already dropped them from the net
   delta); for contract addresses the comparison is the derived-schema hash
   (`10-theory.md` § versioning), so refactors that re-derive identically
   are generation-silent. Consequence, the design's economic keystone: **an
   upstream node that lands exactly what speculators predicted retires them
   for free** — their witnesses still hold, no invalidation fires, no
   reconcile runs. Correct speculation costs zero.
3. **Commit iff the witness holds.** A node retires only if every witnessed
   triple still describes the committed state — and the judged thing is the
   artifact (law 1): the address's committed content is the content the
   triple carries. Generation equality is that comparison's shadow under
   law 2, never the check itself, because a fresh address's first landing
   and a pre-commit read (a snooped draft, an uncommitted tuple) share the
   first generation and only their content tells them apart. Absence is a
   real case of the committed lookup, never a sentinel generation: a triple
   witnessed at the primordial generation holds against never-committed
   state, so a consumer that witnessed a differing draft is rejected the
   moment the producer's landing exists at all. A moved witness is the
   typed signal `Generation_moved { address; witnessed; current;
   delta_ref }` shipped to the scheduler — the engine performs no retry, no
   merge heroics, no silent re-read (the scheduler's routing table owns
   what happens next — § drift routing).
4. **Soundness, never freshness.** A held witness proves the node's outputs
   were derived from the state they claim — it does not prove no better
   input existed. Freshness is the scheduler's economics (reissue if the
   ledger says the upgrade is worth it), never a commit-blocking judgment.
   Stated once, here, so no future law confuses the two.

## Retirement order and the landing

**Nodes retire in dependency order — a node's producers retire before it
does — and retirement is the only mover of the committed coordinate.** The
retire step for one node:

1. **Discharge check**: all hypotheses discharged, all witnesses hold
   (law 3 above).
2. **Conflict judgment**: the node's write-set (observed store footprints)
   intersects no sibling's committed write-set within the current
   generation — the `disjoint` EGD (`10-theory.md`). A violation is the
   typed conflict signal, to the scheduler, with both footprints; routes are
   serialize (reissue loser against winner's state) or merge (only when a
   declared merge function exists for the address class — a dune-file
   appender, a lockfile regenerator; merge functions are registered per
   address class at theory accept, never improvised). Every committed write
   is recorded in **base coordinates**: the content the writer's witness
   proves it derived from, a blind write's absent base a real case. The
   final-state `Disjoint_writes` judgment is then pair equality over that
   index — two committed writes to one address from one base are the
   clobber by construction, and serialized writers cannot collide because
   the later one's base is the earlier one's landing. The base index is
   the law's backstop behind this per-retire judgment, which sees only
   observed store footprints.
3. **The landing** — no merge exists, because there is nothing to move:
   the bytes are already in the tree. The step is a ledger state
   transition — the committed coordinate advances per law 2 (byte-null
   deltas advance nothing; the free commit stays silent) — plus a
   **pathspec-limited commit built from the ledger's blobs, never from
   the tree**: the commit's tree entries for the node's write set come
   from the store events' oids (`Delta_ref`), so a neighbor's later
   in-flight bytes on the same path cannot tear the commit. Message =
   node provenance. The disjoint law is what makes write sets per-commit
   coherent: overlapping writers serialized or merge-declared before
   either retires.
4. **Ledger seal**: the settlement event, with timings, closes the node.

Retirement is also the channel layer's one publisher: the committed head
tuples publish on their relations' typed logs, and every generation the
landing moved fans out as a payload-free invalidation, filtered by each
subscribed edge's declared footprint (`20-medium.md` § invalidate,
don't update). A landing that matched every speculator's snapshot moved
no generation and fans nothing — the free commit is silent by
construction.

Squash is the dual, and **squash precision is absolute**: exactly the
provenance-closed subtree of the dead hypothesis or faulted node squashes —
computed from tuple provenance (`10-theory.md` § provenance is total),
enforced by falsifier (`50-api.md` F3), guaranteed leak-free by the
success criterion that outranks performance (`00-product.md`).

**Decision — dependency-order retire.** **Alternative:** commit-as-you-go
(each node's coordinate advances the moment it finishes, optimistically) —
lost because it lets a speculative node's output become committed-readable
before its hypotheses discharge, which is precisely the speculative-leak
class the whole protocol exists to kill; the wall-clock cost of ordering is
near zero (retire is cheap; execution dominates) and speculation already
overlaps the waiting. **Reverses if:** never for hypothesis-carrying nodes;
a measured retire-queue backlog on non-speculative wide fanouts could earn
ready-node early retire for the hypothesis-free subset (the ledger would
show retire latency as a visible critical-path term — it does not today).

**Decision — one ref; the committed branch as a coordination object is
dead.** One git ref remains — git's name for the retirement history,
nothing more — and the working tree on that ref is the shared store buffer
*and* the committed tree, distinguished by coordinate, not place.
**Alternative:** keep a separate committed branch and treat the working
tree as pure staging — lost because it is the worktree by another name: a
second place whose divergence from the first must be synchronized, exactly
the machinery the flat org deletes; the committed *state* is already fully
represented as ledger coordinates plus git objects. **Reverses if:**
multi-process execution arrives (two schedulers cannot share one working
tree; the recorded shape there is one tree per scheduler and the
cross-machine ledger OPEN item, not a return of per-node isolation).

Generation advancement and `Committed.state` survive as **ledger state** —
address → (generation, content, writer) — and history stays
materializable: any retirement's tree is reachable through the one ref's
commit chain, which is how `Frontier.materialize` sources committed
content without any second branch existing. Reading that history is not
reverting (`20-medium.md` § materialization is not revert).

## Gates on the shared tree

A build or test run observes the whole tree — including neighbors'
in-flight edits. Per-node isolation bought gate isolation; the flat org
replaces it with gate *honesty*:

**A gate run witnesses its full observed footprint, and becomes a
store-buffer hypothesis on every in-flight writer whose stores it may have
read.** At gate start, the engine snapshots the frontier over the gate's
grant: every address whose top is `In_flight` yields a `Store_buffer`
hypothesis on that writer (source and content hash) and a witness triple
at the uncommitted coordinate. v0's footprint grain is the gate's whole
grant — conservative: a gate is charged with having read every in-flight
address it *could* see (the OPEN item below records the file-level tracing
upgrade).

**Decision — gates run optimistically and discharge like any hypothesis;
no quiesce point.** A gate verdict is **speculative evidence** while its
hypotheses are pending: the verdict tuple carries them in provenance like
any head tuple, so downstream consumers inherit them and the whole
subtree squashes or reconciles if an observed writer lands differently or
dies. It becomes **admissible evidence** exactly when it retires — which
requires every hypothesis discharged, so final-state law judgment (which
consumes only committed tuples) sees only gate verdicts whose observed
world landed as observed. **Alternative:** demand a quiesce point (barrier
the gate until every in-flight writer in its grant settles) — lost because
it reinvents issue-on-readiness at the gate, serializing exactly the
overlap the engine exists to win, and because the free-commit economics
make the optimistic gate's common case free: an implementer whose draft
the gate built against usually lands that draft. **Reverses if:**
measured gate churn — gate reissue rate under in-flight drift, per shape —
exceeds the barrier's serialization cost on the same shape (ledger
decides; the churn counter vocabulary already exists).

**The machine lock's scope.** The mkdir-atomic, holder-named effect lock
serializes gates *per build-artifact resource* (`Address.Resource` — the
`_build` dir, a package cache), declared on the gate the way every effect
footprint is declared; source-tree reads take no lock (they are witnessed,
and witnesses conflict-detect better than locks serialize). In v0
`run_command` blocks the one domain, so a gate's observation window is
atomic against every intra-process writer for free — the fiber mount's
gift. The recorded upgrade (OPEN below) is a `Subprocess` instruction
beside `Http_post`, buying gate overlap and paying with a witness that
spans the window: frontier snapshots at start and end, any store event
inside the window within the gate's grant making the verdict speculative
on that writer too. Fix-forward note: a failing gate verdict is a fact
(a tuple), never an instruction to restore anything — repair of a broken
tree is the producing statement's reissue writing forward, routed by the
same table as every drift.

## Final-state judgment

**Retire laws are judged once, when the run quiesces, against the final
committed state — no per-event checking, no deferral modes, no triggers.**
The judgment consumes the committed tuple set and the footprint index;
verdicts land on the settled map as law verdicts (§ quiescence). Mid-run,
laws are invisible to executing nodes — a node never blocks on a law, only
on operands and ports. **Decision.** **Alternative:** incremental law
checking (judge quorums as verdicts stream in, fail fast) — lost because
mid-run state is not final state: a quorum "violation" at t may be three
in-flight refuters from satisfaction, so incremental verdicts are either
wrong or hedged, and hedged verdicts train operators to ignore them. The
scheduler already uses law *bodies* as readiness filters where the theory
says so (`publish` in the worked example fires on a count) — that is
scheduling, not judgment, and the final judgment still runs. **Reverses
if:** a censused theory needs a mid-run abort on a law that is
monotone-violated (once broken, unfixable by further tuples — e.g. a
`disjoint` breach); monotone laws are the recorded candidate class for
early judgment, and the judge already knows which laws are monotone.

## The repair lane at the boundary

Retirement rejections that route to reconcile carry **diagnostics shaped for
the executor**: the schema diff or witness mismatch, the consumer's own
prior output, and the specific paths its observed witness says it consumed.
The reconcile invocation is stateless-with-diagnostics (`40-agents.md` § the
primary lane) — the same mechanism as codec-boundary repair, one lane, two
entry points. Reader: `40-agents.md`, which owns the invocation shape.

## Durability boundary

v0 commits into a real git repository: one ref, retirements as commits (one
per node, dependency-ordered, message = node provenance, tree entries from
ledger blobs), the object database as the blob store. Git is the storage
engine, not a metaphor — and the ledger, not git log, is normative. The
engine holds the only writer of the committed coordinate; agents never run
git at all (`40-agents.md` § the git ban). Crash recovery is boot:
re-derive the frontier, converge the tree, reissue in-flight producers
forward (`20-medium.md` § the crash story). **Decision.** **Alternative:**
a bespoke content store (bumbledb LMDB-style) — lost for v0 because the
artifacts are code trees whose consumers (compilers, test runners, humans)
speak filesystem+git natively, and reusing git's object database buys
content addressing and history materialization for free. **Reverses if:**
ledger-measured commit/materialize cost becomes a visible critical-path
term, or multi-machine (`README.md` OPEN) forces a content-addressed store
anyway.

## OPEN items

- **Planner pre-issue.** Hypothesis sources in v0 are issued contracts and
  snooped in-flight stores. The planner pre-issuing *predicted* contracts
  for statements not yet fired is eager start one rung earlier and the
  natural next aggression. *Trigger: measured suspended-read time on deep
  chains (the ledger shows the opportunity's size directly — reads
  suspended with no hypothesis source, per shape).*
- **Port preemption.** v0 never preempts an admitted slot; a stop-cleanly
  note at the occupant's next yield (freeing the slot for witnessed work,
  requeueing the speculative occupant with its stores intact) is the
  designed mechanism, unbuilt. *Trigger: measured witnessed-work queue
  time behind speculative occupants on a bounded port.*
- **Critical-path weighting** inside port priority classes — deferred with
  its slot named (§ ports and priority). *Trigger: recorded there.*
- **Merge-function registry seed set.** Which address classes ship with
  declared merges in v0 (dune files? lockfiles? nothing?). Starting posture:
  empty — every conflict serializes — until a real pipeline shows a
  serialization hot spot with an obviously-safe merge. *Trigger: that
  measurement.*
- **Generation granularity for files.** Per-path in v0. Per-hunk generations
  would let two nodes edit disjoint regions of one file without conflict;
  cost is a hunk-stable diff anchor. The shared tree raises same-file
  traffic, so this OPEN item is sharper than it was under isolation.
  *Trigger: measured serialize-routes on same-file-disjoint-region
  conflicts exceeding an annoyance threshold.*
- **File-grain gate footprints.** v0 charges a gate with its whole grant;
  file-level read tracing (fs event snooping, compiler dep files) would
  shrink gate hypotheses to files actually read. *Trigger: measured gate
  reissues attributed to in-flight writers of files the gate provably
  never consumed (dep-file evidence).*
- **Gate overlap: the `Subprocess` instruction.** v0's blocking
  `run_command` serializes the domain during gates (and buys atomic
  observation). *Trigger: measured domain-block time under gates becoming
  a visible critical-path term.*
- **Law verdict → git annotation.** Whether law verdicts should also land as
  commit trailers / notes on the one ref for human archaeology.
  *Trigger: the first post-mortem that had to correlate ledger and git by
  hand.*
