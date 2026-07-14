# 00 — Product

## Thesis

GOAT CODE is a coding harness built as a **speculative chase engine whose rule
firings invoke LLM agents**. A unit of work is declared, not scripted: the
operator (or a planner agent) presents a **theory** — relations plus dependency
statements — and the engine fires each statement the moment its body is
witnessed, or *earlier*, speculatively, when a predictor says the missing
inputs are cheap to guess and expensive to wait for. Every tool call any agent
makes is an event in an append-only ledger; downstream agents learn of upstream
progress through unidirectional invalidation channels; speculative state lives
in git worktrees and retires in dependency order under commit-time judgment of
the theory's laws.

**The objective is wall-clock time, at all costs.** The scarce resource this
harness optimizes is the operator's — a working software engineer's — wall
clock. Tokens are the fuel burned to buy it: accounted, reported, backstopped,
and never the objective. Every scheduling policy derives from this sentence
(`40-scheduling.md` § the objective); a policy that would wait to save tokens
is wrong by constitution, not by tuning.

## The representational bet

Beneath the wall-clock objective sits the design's deepest commitment: **the
biggest lever in programming is the data representation, not the control
flow** (Brooks's "representation is the essence of programming"; Pike's
"data dominates"; the lineage in prior art below). Every rival harness is a
script — orchestration as control flow, where each new case lands as another
branch, callback, or mode flag. GOAT CODE's answer is structural: **work is
data.** The theory reifies orchestration as relations and statements; the
engine is a small evaluator over it (the SICP ceiling: when control flow
gets hairy, represent it as data and interpret). Every mechanism downstream
is the same move re-applied — illegal states made unrepresentable instead of
guarded, boundaries that parse into refined types instead of validating,
policy reified as tables instead of scattered conditionals — and doc rule 8
(`README.md`) holds every future change to it. Greenspun's rule is the
warning label: an orchestration harness that refuses to build the theory
representation deliberately will grow an ad-hoc, bug-ridden version of it
inside its retry logic anyway.

The second bet: **computer-science problems repeat at
different levels, and the agent-swarm level is currently unexploited.** A
pipeline of subagents where each waits for its inputs is a dependent pointer
chase. Agent latency is one-to-five minutes — a DRAM miss at another scale —
and the lesson from the microarchitecture level transfers with its magnitudes
intact: restructuring for independent misses buys an order of magnitude more
than making any single unit faster. Sequential agent pipelines are leaving a
DRAM-miss-shaped factor on the table, and the mechanisms that harvest it in
silicon (rename, speculative issue, store-to-load forwarding, precise retire)
have exact, buildable analogs here.

## The machine analogy, and where it ends

The analogy is load-bearing, not decorative — each row is a mechanism this
design actually implements:

| Silicon | GOAT CODE |
|---|---|
| Decode into µops | Planner presents the theory |
| Register rename | Contract issuance; fresh-existential minting (`10-theory.md`) |
| Issue on operand readiness | Read-time operand binding under eager start (`40-scheduling.md`) |
| Speculative issue | Hypothesis tuples taken at blocking reads (`40-scheduling.md`) |
| Bypass network | Invalidation channels + pulled net deltas (`30-channels.md`) |
| Store buffer | The node's worktree; pre-retire delta snooping (`30-channels.md`) |
| Memory disambiguation | Footprint-intersection conflict detection (`50-commit.md`) |
| ROB / in-order retire | Dependency-order worktree merge + final-state judgment (`50-commit.md`) |
| Mispredict flush | Subtree squash, abort by construction (`50-commit.md`) |
| Branch predictor | Contract-survival counters gating speculation (`40-scheduling.md`) |
| Performance counters | The ledger's speculation counters (`80-validation.md`) |

Where the analogy ends, and the design diverges deliberately:

- **The wasted resource is tokens, not cycles — and the design spends them
  anyway.** Silicon speculates almost free; a squashed agent run has a real
  bill. The objective ruling resolves the tension: speculation is default-on
  because wall clock outranks spend, and the economics are *recorded* per
  task shape in the ledger — backstop ceilings and a churn-based off switch,
  never an expected-value permission gate (`40-scheduling.md`).
- **Waiting has a cheaper form than silicon's.** A stalled reservation
  station occupies hardware; a suspended fiber costs nothing. So GOAT CODE
  starts every node at t=0 (socket activation — pre-opened channels, s6/
  systemd lineage) and moves all waiting to read time: the agent's
  context-acquisition prefix overlaps unconditionally, and hypotheses are
  taken at the blocking read — as late, and therefore as well-informed, as
  the work allows (`40-scheduling.md` § eager start, § read-time binding).
- **Recovery has a middle mode silicon lacks.** Between "hypothesis held"
  (free) and "flush" (full price) sits **reconcile**: agents are unusually
  good at "here is what changed, patch your work," so contract *drift* routes
  a diagnostics-bearing net delta down the channel instead of squashing. Most
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
counter attached to the throw (`40-scheduling.md` § speculation is
default-on). Regime honesty still governs *claims* (README rule 6): the
docs state where speculation pays most (deep chains, predictable
interfaces) and least (wide-shallow graphs, already parallel) — but the
mechanism no longer waits for a regime judgment to act. Wide-shallow
theories lose nothing: their reads are witnessed, so there is nothing to
hypothesize and default-on is a no-op.

## Non-goals

- **Not a durable workflow engine.** v0 is one process; the ledger is
  replayable by design but resume is an OPEN item. Durability products
  (queues, workflow runtimes) sit around GOAT CODE, never inside it.
- **Not a general agent framework.** One shape: theory in, settled map out.
  No open-ended chat loops, no agent-to-agent free conversation — channels
  carry typed tuples only.
- **Not a prompt library.** Prompts are derived artifacts (`20-contracts.md`);
  a hand-authored per-node prompt is a bug.
- **Not model-agnostic middleware.** The planner runs on the strongest
  available model and workers are pinned per pipeline (`60-agents.md`); a
  provider-abstraction layer is deleted vocabulary until a second provider is
  actually wired.

## Deleted vocabulary

Words that do not appear in these docs or the code, because each names a
concept the design replaces with something sharper:

- **"Workflow", "pipeline step", "stage"** (as nouns for work units) — the
  unit is a *node*: one firing of a dependency statement. Its inputs are body
  tuples, its outputs are head tuples; nothing else defines it.
- **"Orchestrator"** — there is a *scheduler* (mechanical, policy-bearing) and
  a *planner* (an agent that emits a theory). The word that blurs them is
  banned.
- **"Message", "mailbox"** — channels carry *tuples* and *invalidations*.
  Prose between agents is unrepresentable.
- **"Retry"** (as an engine behavior) — the engine ships typed signals;
  *reissue* is a scheduler decision with a recorded reason.
- **"Sub-task"** — a node is not a fraction of anything; it is a rule firing
  with its own contract, witness, and settlement.

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
  types. This is not decoration — it is *why the work unit is a theory*
  (dependency statements are the representation that makes orchestration
  control flow unnecessary), and doc rule 8 is its enforcement
  (`README.md`). Its limit is honored too: essential branching (drift
  routing, the repair lane — genuinely different cases from an
  uncontrollable source) is reified as tables and sum types, never
  disguised as one representation with config flags inside.
- **s6 / systemd socket activation**: the supervisor opens every socket
  before any service starts; services start in any order and dependency
  resolves at first read. GOAT CODE's pre-opened channels, eager start, and
  read-time binding are this protocol with tuples for datagrams
  (`30-channels.md`, `40-scheduling.md`).
- **Tomasulo (1967), the CDC 6600 scoreboard, and the chase (Maier/Mendelzon/
  Sagiv 1979)**: the two formalisms this system observes to be the same
  algorithm at different levels — fire a rule when its body is satisfied —
  plus speculation, which is firing on a hypothesis.

## Decision — implementation substrate: OxCaml

**Decision.** GOAT CODE is implemented in OCaml on the OxCaml toolchain.
Three properties are load-bearing: **modes** (`local`/`unique`) let the
compiler prove that speculative state cannot leak into committed state — the
retire invariant becomes a type error instead of a code-review item; **effects
handlers** give each in-flight node a suspendable fiber whose yield points are
exactly where invalidations are delivered (`30-channels.md` § check-on-yield);
and the Jane Street ppx stack plus `ppx_deriving_jsonschema` make the
one-supply contract law mechanical (`20-contracts.md`).
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
hypothetical.** Interim disciplines that keep the port cheap: the ledger
format and wire schemas stay language-neutral (JSON on disk, never
Marshal); investment goes to the layers that survive the port conceptually
(theory grammar, scheduler policy, drift routing, prompt assembly), and the
store layer (`ledger`/`witness`/`retire`) stays as thin as v0 allows —
it is the layer the port deletes.
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
   (`80-validation.md` § honest measurement). This is the criterion; the
   rest are honesty about its price.
2. **Precision**: zero squash leaks (committed state influenced by a squashed
   node) across the falsifier suite and all live runs — absolute, and the
   only criterion that outranks wall clock.
3. **Economics, reported**: squashed-token overhead is measured and published
   per run with the per-shape breakdown — a report card, never a gate. The
   token ceiling binding during normal operation is an anomaly with a named
   cause, not a cost-control success.
4. **The correction record**: every regression of a doc'd number is a ledger
   event with a named cause. A harness that measures agents must survive its
   own measurement discipline.
