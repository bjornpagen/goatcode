# 00 — Product & Philosophy

## Thesis

GOAT CODE is a coding harness built as a **speculative chase engine whose rule
firings invoke LLM agents**. A unit of work is declared, not scripted: the
operator (or a planner agent) presents a **theory** — relations plus dependency
statements — and the engine fires each statement the moment its body is
witnessed, or *earlier*, speculatively, when a predictor says the missing
inputs are cheap to guess and expensive to wait for. Every tool call any agent
makes is an event in an append-only ledger; all participants work **one shared
tree** — no branches, no worktrees — kept coherent by the ledger, not by
isolation; and speculative work retires in dependency order under commit-time
judgment of the theory's laws.

**The objective is wall-clock time, at all costs.** The scarce resource this
harness optimizes is the operator's — a working software engineer's — wall
clock. Tokens are the fuel burned to buy it: accounted, reported, backstopped,
and never the objective. Every scheduling policy derives from this sentence
(`30-scheduling.md` § the objective); a policy that would wait to save tokens
is wrong by constitution, not by tuning.

## The two co-equal bets

**Bet one — work is data.** The biggest lever in programming is the data
representation, not the control flow (Brooks's "representation is the essence
of programming"; Pike's "data dominates"; the lineage in prior art below).
Every rival harness is a script — orchestration as control flow, where each
new case lands as another branch, callback, or mode flag. GOAT CODE's answer
is structural: the theory reifies orchestration as relations and statements;
the engine is a small evaluator over it (the SICP ceiling: when control flow
gets hairy, represent it as data and interpret). Every mechanism downstream
is the same move re-applied — illegal states made unrepresentable instead of
guarded, boundaries that parse into refined types instead of validating,
policy reified as tables instead of scattered conditionals — and doc rule 8
(`README.md`) holds every future change to it. Greenspun's rule is the
warning label: an orchestration harness that refuses to build the theory
representation deliberately will grow an ad-hoc, bug-ridden version of it
inside its retry logic anyway.

**Bet two — share memory by communicating.** Pike's proverb — *"don't
communicate by sharing memory; share memory by communicating"* — is not
decoration here; it is the system's coherence constitution. GOAT CODE has
exactly two substrates:

- **The tree is shared memory** — the one working tree, the materialized
  state every participant reads and writes.
- **The ledger is communication** — events, invalidations, messages,
  witnesses, settlements.

The proverb states their relation: **the tree is never used as a
coordination channel.** Two agents poking the same bytes and inferring each
other's progress from them is exactly the race Pike warns against. All
coherence travels as evented facts on the ledger; the tree is a cache of the
ledger's live frontier (`20-medium.md` § validity is a ledger coordinate).
Rival harnesses buy safety by isolation — private worktrees, merge-at-the-end
— because they lack a coherence protocol. GOAT CODE ships one, which is why
it can share memory safely: workers converge continuously instead of merging
terminally, agreement costs zero (the free commit), and disagreement
surfaces at message latency instead of merge time, with an attribution trail
(the witness index) that neither locks nor merges provide.

The two bets are one bet stated twice: the ledger is the work-is-data move
applied to *time* — execution history reified as data, interpreted by
readers — and the coherence protocol is what that representation buys.

**The corollary bet — the agent-swarm level is unexploited silicon.**
Computer-science problems repeat at different levels. A pipeline of
subagents where each waits for its inputs is a dependent pointer chase.
Agent latency is one-to-five minutes — a DRAM miss at another scale — and
the lesson from the microarchitecture level transfers with its magnitudes
intact: restructuring for independent misses buys an order of magnitude more
than making any single unit faster. The mechanisms that harvest it in
silicon (rename, speculative issue, store-to-load forwarding, precise
retire, cache coherence) have exact, buildable analogs here.

## The two graphs

The design keeps two graphs, and confusing them is the classic error this
section exists to prevent:

**The derivation graph is a strict forward DAG, permanently.** What fires
what — body tuples consumed, head tuples produced, provenance, the squash
cascade — flows forward only. Feedback is a forward edge firing a new
generation; iteration is generations; a backward derivation edge is
unrepresentable (`10-theory.md` § feedback is forward). This is what makes
termination statically decidable (weak acyclicity at admission) and squash
precision provable. It never softens. **Reverses if: never.**

**The communication graph is the bus — wall-less by representation.** Any
participant — worker, supervisor, operator — reads any other's published
facts, on or off the declared dependency edges. Declared structure
(footprints, edges, subscriptions) is **advisory: a filter that tunes
delivery, never a wall that forbids flow** — and under the bus (§ the
medium is a bus) this is not a permission but a fact of the medium: there
is no addressed pipe for a wall to guard. What makes it safe is not
topology: every publication is an evented fact with provenance, every read
of one is a witnessed observation, so a squashed sender's publications are
dead provenance and their consumers are cascade-squashed or refused at
retire exactly as if they had read a dead file draft (`20-medium.md`
§ the bus). The machinery that makes the shared tree safe makes the
message layer safe, unchanged.

**Decision — walls fall at the communication layer.** The prior doctrine
("channels are unidirectional, permanently; message/mailbox is deleted
vocabulary") conflated the two graphs: unidirectionality was protecting
squash precision, and squash precision turns out to be a provenance-and-
witness property, not a topology property — the identical recognition that
deleted worktrees (a second coherence mechanism running beside the one the
ledger already implements; doc rule 8 says delete the duplicate).
**Alternative:** keep hard policy walls (flow only on declared edges) —
lost because a wall forbids the visibility the flat org exists to grant,
duplicates protection the witness machinery already provides, and turns
every undeclared-but-legitimate contact into either a rule violation or a
smuggled side channel. **The honest cost, recorded:** derivation is
statically terminating (weak acyclicity proves it); ad-hoc communication
that spawns work is not — it is backstop territory (the token ceiling,
generation bounds) catching a runaway the same way they catch an
admitted-but-too-big theory. A static guarantee is traded away off the
declared edges, and the backstop is the price — the same trade the flat org
made when it dropped worktree isolation. **Reverses (walls return) if:**
ledger evidence shows off-edge messaging producing coherence failures the
witness machinery cannot convict, or backstop-bound runaways dominated by
message-driven firings — the counters name the evidence
(`50-api.md` § the speculation counters).

## The medium is a bus

Pike's bet, taken to its fixed point: **the ledger is not one communication
channel among several — it is the only one.** The medium is an event bus:
publication is appending a fact to the one totally-ordered stream; delivery
is a subscription — a per-participant table of filters folded over that
stream; and everything these docs once needed as a distinct surface —
channels, edges, drift notes, supervisor notes, peer messages, escalations
— is one mechanism wearing different rows. **One bus, many folds**
(`20-medium.md` § the bus).

This is a coordinate change in the lineage's exact sense (the half-open
interval, homogeneous coordinates): in point-to-point coordinates, "who
may talk to whom" is policy — four delivery mechanisms, addressed
envelopes, walls to argue about. In bus coordinates those cases are not
handled; they are unrepresentable as distinct things. A message has no
addressee, only attributes a subscription can match; exclusion is not a
state the system can express, because no private pipe exists to be
excluded from.

**Agents have no privacy, and the design says so out loud.** Silicon
abandoned the snoopy bus for directories because of physical bandwidth;
organizations avoid broadcast because of confidentiality. Agents have
neither constraint: the bus carries small payload-free facts (payloads are
pulled — `20-medium.md` § invalidate, don't update), and no agent holds a
confidentiality interest against another. So GOAT CODE gets the synthesis
silicon couldn't have — **broadcast semantics with directory economics** —
plus a capability nothing had to be built for: any participant may
subscribe to any other's traffic, so watching a sibling's drift storms and
repair attempts (and adjusting) is observational learning at zero
machinery. The line that stays hard: **information is universal; authority
is typed.** Reading anything is free; causing anything — a mint, a commit,
a kill — remains a typed power with a named holder (`40-agents.md`
§ unforgeability).

**Facts and actuations are essentially different, and the bus carries only
facts.** This is Brooks's essential-complexity line, drawn once, on
purpose: a delivered fact informs a participant at its own pace; an
actuation — dispatch a node, wake a fiber, kill a turn — targets one thing
and takes effect regardless of the target's cooperation. Forcing
actuations onto the bus as "messages the receiver honors" would hide the
branching inside a convention (a kill an agent could ignore is not a
kill). So the bus has exactly one enactor: **the scheduler is the only
entity with hands.** A kill is never delivered — the fiber is discontinued
and the settlement fact is published for everyone's folds; nothing was
"sent" to the dying agent. Interrupt capability survives at full strength:
it is constitutional (wall clock outranks the tokens a killed turn wastes,
so a known-useless turn is cheapest dead), it is the supervisor's sharpest
steer (`40-agents.md` § the aggressive posture), and an LLM mid-token can
absorb nothing gentler — kill-and-reissue-with-guidance is what "redirect"
mechanically is. But it is an enactment, not a message mode. **Messages
inform; settlements actuate; the scheduler enacts.**

Every participant reads the bus through a **subscription discipline** —
Mute / Digest / Wake, a table as data, defaults compiled from the theory's
declared structure, amendable because structure is advisory
(`20-medium.md` § the subscription discipline).

## The machine analogy, and where it ends

The analogy is load-bearing, not decorative — each row is a mechanism this
design actually implements:

| Silicon | GOAT CODE |
|---|---|
| Decode into µops | Planner presents the theory |
| Register rename | Contract issuance; fresh-existential minting (`10-theory.md`) |
| Issue on operand readiness | Read-time operand binding under eager start (`30-scheduling.md`) |
| Speculative issue | Hypothesis tuples taken at blocking reads (`30-scheduling.md`) |
| Snoop/bypass network | The event bus: published invalidations + pulled net deltas (`20-medium.md`) |
| Shared cache + coherence directory | The one working tree + the witness index (`20-medium.md`) |
| Store buffer | Per-writer blob lineage in the object store; in-flight frontier tops (`20-medium.md`) |
| Memory disambiguation | Footprint-intersection conflict detection (`30-scheduling.md`) |
| ROB / in-order retire | Dependency-order retirement + final-state judgment (`30-scheduling.md`) |
| Mispredict flush | Subtree squash, abort by construction (`30-scheduling.md`) |
| Branch predictor | Contract-survival counters gating speculation (`30-scheduling.md`) |
| Performance counters | The ledger's speculation counters (`50-api.md`) |
| Performance-monitoring unit | The supervisor's subscription table over the ledger (`40-agents.md`) |
| Interrupt vs polled status | Wake vs Digest delivery levels (`20-medium.md`) |

Where the analogy ends, and the design diverges deliberately:

- **The wasted resource is tokens, not cycles — and the design spends them
  anyway.** Silicon speculates almost free; a squashed agent run has a real
  bill. The objective ruling resolves the tension: speculation is default-on
  because wall clock outranks spend, and the economics are *recorded* per
  task shape in the ledger — backstop ceilings and a churn-based off switch,
  never an expected-value permission gate (`30-scheduling.md`).
- **Waiting has a cheaper form than silicon's.** A stalled reservation
  station occupies hardware; a suspended fiber costs nothing. So GOAT CODE
  starts every node at t=0 (socket activation — pre-opened channels, s6/
  systemd lineage) and moves all waiting to read time: the agent's
  context-acquisition prefix overlaps unconditionally, and hypotheses are
  taken at the blocking read — as late, and therefore as well-informed, as
  the work allows (`30-scheduling.md` § eager start, § read-time binding).
- **Recovery has a middle mode silicon lacks.** Between "hypothesis held"
  (free) and "flush" (full price) sits **reconcile**: agents are unusually
  good at "here is what changed, patch your work," so contract *drift* routes
  a diagnostics-bearing net delta to the consumer instead of squashing. Most
  mispredictions are drift, not explosion; the middle mode is where the design
  earns its keep.
- **The value being predicted is an interface, not a bit pattern.** Value
  prediction failed in silicon because 64-bit values are noise. Interfaces are
  low-entropy: the planner can emit a speculative contract with real accuracy
  even though the implementation behind it is the whole point of the work.

## Workload census

The workloads the design is sized against, in priority order:

1. **Deep dependency chains with predictable interfaces.** Build-from-spec
   across N modules, staged migrations, codegen pipelines (schema → types →
   implementations → tests). This is the regime speculation exists for: long
   chains, high contract survival.
2. **Data-generated fanout with adversarial verification.** Find-N-things then
   verify-each-with-K-refuters: review sweeps, audit passes, migration-site
   discovery. Fanout width is unknown at plan time — the chase materializes it
   from tuples (`10-theory.md`). Speculation contributes little here;
   data-generated width is the draw.
3. **Mixed pipelines** — a deep spine with fanout ribs (implement → review →
   repair → verify per module). Both mechanisms compose.

## The default

**Speculation is on, everywhere, always — off is the exception that must be
earned by evidence.** Eager start is unconditional (it is not even
speculation: the prefix consumes no operands). Read-time hypotheses fire
wherever a source exists. The single off switch is per task shape and
requires the one measured regime where speculation *lengthens* wall clock —
reconcile churn displacing witnessed work on a contended port — with the
counter attached to the throw (`30-scheduling.md` § speculation is
default-on). Regime honesty still governs *claims* (README rule 6): the
docs state where speculation pays most (deep chains, predictable
interfaces) and least (wide-shallow graphs, already parallel) — but the
mechanism no longer waits for a regime judgment to act. Wide-shallow
theories lose nothing: their reads are witnessed, so there is nothing to
hypothesize and default-on is a no-op.

## Fix forward, only

Operator ruling, verbatim: *"only fix forward. no reverting. there's no
reverting in real life, there should be none in our architecture."* The
ruling is total: **revert is unrepresentable, everywhere** — no inverse
deltas, no undo logs, no rollback, and no revert smuggled under another
name. Corrections are new forward events at the next generation;
re-asserting known-good content is an ordinary forward store; recovery is
re-deriving the frontier from the ledger and converging the cache
(`20-medium.md` § squash without isolation). The crash story is the
ruling's own argument: a revert-based design has a crash mode no log can
classify (die mid-rollback and recovery must first decide which *direction*
it was moving); here that state is unconstructible because the direction
does not exist — every ledger append is monotone.

## Non-goals

- **Not a durable workflow engine.** v0 is one process; the ledger is
  replayable by design but resume is an OPEN item. Durability products
  (queues, workflow runtimes) sit around GOAT CODE, never inside it.
- **Not a general agent framework.** One shape: theory in, settled map out.
- **Not a chat platform.** Any participant may publish for any other
  (§ the medium is a bus), but every message is a typed, evented fact on
  the bus with provenance — an unrecorded conversation is unrepresentable,
  and so is a private one. What is excluded is not communication; it is
  communication that leaves no evidence.
- **Not a prompt library.** Prompts are derived artifacts (`10-theory.md`
  § contracts); a hand-authored per-node prompt is a bug.
- **Not model-agnostic middleware.** Two providers are wired — Anthropic
  (Claude Fable 5, the planner, the supervisor, and every judgment-heavy
  shape) and OpenAI (GPT-5.6 Terra, mechanical contract-filling shapes) —
  and the planner routes between them per template at theory-emission time
  (`40-agents.md` § model pins and provider routing). That is the ceiling:
  the pin record's `provider` field plus one runtime lane per provider is
  the entire abstraction; a general provider-middleware layer stays deleted
  vocabulary.

## Deleted vocabulary

Words that do not appear in these docs or the code, because each names a
concept the design replaces with something sharper:

- **"Workflow", "pipeline step", "stage"** (as nouns for work units) — the
  unit is a *node*: one firing of a dependency statement. Its inputs are body
  tuples, its outputs are head tuples; nothing else defines it.
- **"Orchestrator"** — there is a *scheduler* (mechanical, policy-bearing), a
  *planner* (an agent that emits a theory), and a *supervisor* (a standing
  session that watches and steers — `40-agents.md`). The word that blurs
  them is banned.
- **"Chat", "conversation"** (between agents) — a message is a typed,
  evented, provenance-carrying fact (`20-medium.md` § the bus); prose that
  lives only in someone's context window is unrepresentable. (*"Message"
  itself is reinstated vocabulary* — it was banned while messages meant
  unevented prose; the medium now defines them as first-class facts, and the
  ban moves to the unevented kind.)
- **"Envelope", "addressed delivery", "point-to-point"** (as communication
  mechanisms) — publication and subscription are the only routing. A
  message's intended reader is an attribute a subscription matches, never
  a wall around a pipe; the pipe itself is deleted vocabulary
  (`20-medium.md` § the bus).
- **"Retry"** (as an engine behavior) — the engine ships typed signals;
  *reissue* is a scheduler decision with a recorded reason.
- **"Sub-task"** — a node is not a fraction of anything; it is a rule firing
  with its own contract, witness, and settlement.
- **"Revert", "rollback", "restore"** — corrections are forward stores;
  recovery is frontier re-derivation; materializing the cache is checkout,
  not restore (§ fix forward).
- **"Worktree", "branch"** (as coordination objects) — one tree, one ref;
  isolation was a second coherence mechanism and is deleted
  (`20-medium.md`). The code has caught up: the vocabulary is deleted from
  the engine outright and a grep-gate falsifier keeps it out (FL1,
  `50-api.md`; `README.md` § design of record vs shipped engine, row 5).

## Prior art (inheritance, stated once)

- **`@superbuilders/issue`** (Bjorn Pagen): the execution vocabulary —
  issue-on-readiness, ports as structural hazards, precise settlement
  (`retired`/`faulted`/`squashed`), squash exactness, pull-only telemetry,
  the blocked/queue/run decomposition. GOAT CODE is that machine plus a
  speculative issue stage, with agents as execution units.
- **bumbledb** (Bjorn Pagen): the commit protocol — the staging law,
  generation-witnessed optimistic writes (witness-is-the-artifact,
  state-changing-generations-only), abort-by-construction deltas,
  provisional identity minting, the acceptance gate, commit-time final-state
  judgment, docs-as-normative discipline.
- **primer** (Alpha School): the contract representation — the declarative
  catalog from which schema, prompt prose, and validator all derive; mint/ref
  slot distinction; cardinality windows compiled into shape; the
  validate-and-repair loop; and the ruling that decode-time grammar
  constraint loses to freeform-plus-validator.
- **`ppx_deriving_jsonschema`** (Ahrefs) + **`ppx_yojson_conv`** (Jane
  Street): the mechanization of one-supply — a single OCaml type declaration
  derives the schema handed to the model API and the codec that parses the
  reply, agreeing by construction.
- **The representation lineage — Brooks (1975) → Pike (1989) → Raymond
  (1997) → Torvalds (2006), with Minsky's "make illegal states
  unrepresentable" and King's "parse, don't validate" as the type-level
  mechanisms**: the principle that work must be data and guards must become
  types. This is not decoration — it is *why the work unit is a theory*, and
  doc rule 8 is its enforcement (`README.md`).
- **The Go proverb (Pike 2015) and CSP (Hoare 1978)**: share memory by
  communicating. GOAT CODE's reading is architectural, not stylistic — the
  ledger is the communication substrate, the tree the shared memory it
  keeps coherent (§ the two co-equal bets).
- **Cache coherence, both families (snoopy bus and MESI-lineage
  directories)**: the flat org is their synthesis — one broadcast medium
  (the bus) whose delivery is directory-filtered (subscriptions,
  invalidations, pulled payloads), because agents lack both constraints
  that forced silicon and organizations to pick a side: physical bandwidth
  and privacy (§ the medium is a bus; `20-medium.md`).
- **The log as the message broker (Kreps, "The Log", 2013; Kafka)**: a
  single totally-ordered append-only log IS the bus, and consumers are
  cursors — folds with positions. The ledger-plus-subscriptions shape is
  this insight applied where the events are agent actions.
- **Linda tuplespaces (Gelernter) and blackboard architectures**:
  generative communication — facts published into a shared space with no
  addressee, consumed by pattern-match. The theory already fires
  statements by pattern; the bus makes the communication layer speak the
  derivation layer's own idiom.
- **Event sourcing**: append-only facts, corrections as new events, state
  as a fold — the ledger's discipline, now extended to the working tree
  itself (validity as a ledger coordinate).
- **s6 / systemd socket activation**: the supervisor opens every socket
  before any service starts; services start in any order and dependency
  resolves at first read. GOAT CODE's pre-opened channels, eager start, and
  read-time binding are this protocol with tuples for datagrams
  (`20-medium.md`, `30-scheduling.md`).
- **Tomasulo (1967), the CDC 6600 scoreboard, and the chase (Maier/Mendelzon/
  Sagiv 1979)**: the two formalisms this system observes to be the same
  algorithm at different levels — fire a rule when its body is satisfied —
  plus speculation, which is firing on a hypothesis.
- **ultracode** (contrast, and one inheritance): the standing frontier-model
  supervisor pattern — one strong model holds a whole run in its context,
  notices trouble, intervenes. Its *judgment* is inherited by the
  supervisor; its senses (self-reports) and hands (unrecorded prose) are
  replaced by ledger eyes and typed steers (`40-agents.md` § supervision).
  Its isolation-based coordination is the foil for bet two.
- **Anthropic's advisor tool** (contrast only): a worker-invoked stronger
  model consulted at moments the worker chooses — the pull architecture GOAT
  CODE bets against. The direction of advice here is push: the supervisor
  decides when to intervene, on ledger evidence, because a worker cannot
  call for help with a problem it cannot see (`40-agents.md` § push, not
  pull).

## Decision — implementation substrate: OxCaml

**Decision.** GOAT CODE is implemented in OCaml on the OxCaml toolchain.
Three properties are load-bearing: **modes** (`local`/`unique`) let the
compiler prove that speculative state cannot leak into committed state — the
retire invariant becomes a type error instead of a code-review item; **effects
handlers** give each in-flight node a suspendable fiber whose yield points are
exactly where queued deliveries land (`20-medium.md` § delivery); and the
Jane Street ppx stack plus `ppx_deriving_jsonschema` make the one-supply
contract law mechanical (`10-theory.md` § contracts).
**Alternative:** extending `issue` in TypeScript — lost because the two
safety properties that matter most (squash cannot leak, witnesses cannot be
fabricated) are ownership properties, and TypeScript has no ownership; the
engine would police them by discipline, which is how retire protocols rot.
**Alternative:** Rust — carries the ownership story but models suspended
agent fibers as hand-rolled state machines (async without effects), and the
contract-deriving ecosystem targeted here (`jsonschema` + `yojson_conv` from
one declaration) has no equally paired equivalent.
**Alternative:** Rust on bumbledb, with a Lean spec tree — the recorded
*successor*, not a loser: ownership gives the squash-safety property natively
(affine consumption is the mode discipline without the `+ox` toolchain),
serde + schemars is the one-supply law as a mature ecosystem, and the entire
tuple/ledger/witness/commit substrate — append-only provenance, generation-
witnessed optimistic commits, final-state judgment of declared statements,
the admission gate — is bumbledb's existing, falsifier-tested feature list
rather than a reimplementation. Deferred, not rejected, because it couples
GOAT CODE to a foundation that is itself pre-stability, and because the
right representation is only visible after the running version exposes the
pattern (the Brooks limit, applied to ourselves).
**Ruling: OxCaml is the experimental substrate; the port is planned, not
hypothetical.** The effects half of the bet has returned its evidence:
the fiber substrate runs the engine, and `docs/effects-evaluation.md` is
the language-test report the port decision consults — what effects
measurably bought (overlap without threads, squash with real finalizers,
no monadic coloring), the recorded price (every guarantee at that layer
is dynamic, held by falsifiers where the rest of the codebase gets
types), and the port shape (the semantics express in async Rust; the
direct style is what a port loses). The adoption ruling itself lives at
`30-scheduling.md` § read-time binding. Interim disciplines that keep the
port cheap: the ledger format and wire schemas stay language-neutral (JSON
on disk, never Marshal); investment goes to the layers that survive the
port conceptually (theory grammar, scheduler policy, drift routing, prompt
assembly), and the store layer (`ledger`/`witness`/`retire`) stays as thin
as v0 allows — it is the layer the port deletes.
**Reverses (the port triggers) if:** (a) the Greenspun trigger — the OCaml
store layer starts growing tuple queries, indexes, or incremental judgment,
i.e. an ad hoc, informally-specified implementation of half of bumbledb; or
(b) the design reaches quiescence (three months without a doc-rule-4
amendment to the protocol docs) AND bumbledb reaches its own stability
milestone — whichever comes first. Also reverses early if OxCaml's mode
system proves too unstable to pin (a toolchain fact, recorded per switch).
The ppx census already returned its verdict (`ppx_deriving_jsonschema`
does not build against the ox Parsetree; codecs via `ppx_yojson_conv`
work), and v0 carries the wound: hand-written wire schemas are a second
supply, tolerated only with a lint that diffs them against the type
declarations, and only until the port or a deriver port closes it.

## Success criteria

1. **Wall-clock**: on the deep-chain census workload, the default-on engine
   beats the same theory with speculation disabled by ≥1.5× end-to-end.
   Measured on fresh tasks, never a repeated benchmark task
   (`50-api.md` § honest measurement). This is the criterion; the
   rest are honesty about its price.
2. **Precision**: zero squash leaks (committed state influenced by a squashed
   node) across the falsifier suite and all live runs — absolute, and the
   only criterion that outranks wall clock.
3. **Economics, reported**: squashed-token overhead is measured and published
   per run with the per-shape breakdown — a report card, never a gate. The
   token ceiling binding during normal operation is an anomaly with a named
   cause, not a cost-control success. The supervisor's standing bill reports
   on the same line (`40-agents.md` § the bill).
4. **The correction record**: every regression of a doc'd number is a ledger
   event with a named cause. A harness that measures agents must survive its
   own measurement discipline.
