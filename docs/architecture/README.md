# GOAT CODE Architecture

These documents are the normative design. They are living documents, updated
in place — there are no work packets or compliance gates. Git history is the
changelog; the documents describe **the design of record, in the present
tense**. Where the shipped engine has not yet caught up to a ruling, the gap
is recorded once, in this file's migration ledger (§ design of record vs
shipped engine) — never as hedging inside the docs themselves.

There is no formal specification tree yet (see OPEN items); until one exists,
these docs are the only normative home of GOAT CODE's semantics. Where a
mechanism is inherited from a prior artifact — the `issue` scheduler, bumbledb's
commit protocol, primer's contract catalog — the doc names the inheritance once
and then owns the mechanism outright: GOAT CODE's docs never defer to another
repo for their own semantics.

## Rules for these docs

1. **Every decision records its strongest alternative, why it lost, and what
   evidence would reverse it** — one paragraph. If we can't articulate the
   alternative, the decision isn't made yet. (An overturned "reverses if:
   never" is not forbidden — it is re-litigated as a new decision block that
   names what the old ruling was actually protecting and why the protection
   holds without it. Two such reversals are on the books: § closed by
   ruling.)
2. **Every mechanism must name its reader** — a channel, stamp, counter, or
   predictor with no named consumer is deleted. (The anti-transcription rule.)
3. **Undecided things are marked `OPEN` with a closure trigger** (the event or
   milestone that forces the decision) and listed in the owning doc. An OPEN
   item is a real state; the failure mode is code deciding it silently.
4. **When implementation contradicts a doc**, either the doc is amended in
   the same change, or the gap is a row in the migration ledger below. A
   contradiction recorded nowhere means the repo is broken.
5. **No history.** These documents never narrate how the design got here or
   describe previous engines. A measured number may appear as rationale for a
   current mechanism ("measured"); a story may not. (The two evidence files —
   `docs/effects-evaluation.md`, `docs/executor-campaign.md` — are dated
   history, deliberately outside this rule and outside normativity.)
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
   boundary **parses into a refined type, never validates**; states the
   design forbids are **unrepresentable, not guarded**; and policy that must
   branch is **reified as data** — a table or sum type in one place,
   inspectable, never conditionals spread through the engine. (Brooks's
   "representation is the essence of programming," Pike's Rule 5, Minsky's
   illegal states, King's parse-don't-validate — the lineage is this
   design's deepest prior art, `00-product.md`.)

## The documents

| Doc | Contents |
|---|---|
| `00-product.md` | Product & Philosophy: thesis, the wall-clock objective, the two co-equal bets (work is data; share memory by communicating), the two graphs, the medium is a bus (facts vs actuations; agents have no privacy), the machine analogy, fix-forward, workload census, non-goals, deleted vocabulary, prior art, the substrate decision, success criteria |
| `10-theory.md` | Theory & Contracts: relations with mint/ref slots, the statement grammar, chase semantics, weak acyclicity, feedback-is-forward, the acceptance gate; the one-supply contract law, lowering, the LLM-safe subset, meta-contracts, drift as schema diff |
| `20-medium.md` | The Medium: the bus and the cache, the ledger and its five readers, event taxonomy, mechanized witnesses, validity as a ledger coordinate (the frontier), squash without isolation, channels as folds, publication and subscription (no walls, no envelopes), invalidate-don't-update, footprint filters as default subscriptions, ambient sensing, delivery levels and the enactor |
| `30-scheduling.md` | Scheduling & Commit: the chase engine, eager start, read-time binding on the fiber substrate, default-on speculation, ports, the predictor, backstops, drift routing, settlement; retirement, the generation-witness protocol, the landing from ledger blobs, gates on the shared tree, final-state judgment |
| `40-agents.md` | Agents & Supervision: executors, prompt assembly, the repair lane, tool grants, the git ban, the transport, notes at yield, model pins and provider routing, the planner; the supervisor — push not pull, the fifth reader, the steering vocabulary, unforgeability, session succession, beside the machine |
| `50-api.md` | API & Validation: declaring, running, and reading a run; the CLI; the settled map; the falsifier roster (F, FL, FB, FM), replay determinism, honest measurement, the counters table |

Former doc names, for readers arriving from code comments or old links:
`20-contracts.md` → `10-theory.md`; `30-channels.md` → `20-medium.md`;
`40-scheduling.md` and `50-commit.md` → `30-scheduling.md`; `60-agents.md`
and `90-supervisor.md` → `40-agents.md`; `70-api.md` and
`80-validation.md` → `50-api.md`; `91-flat-org.md` → distributed
(`00-product.md`, `20-medium.md`, `30-scheduling.md`) plus the migration
ledger below.

## Design of record vs shipped engine (the migration ledger)

The flat org — one tree, no branches, no worktrees, coherence by ledger —
is the **design of record** (operator ruling), and these docs describe it
normatively. The shipped engine still runs the worktree machine. The gap,
in full, each row struck when its change lands (suite green at every
step):

1. **Blobs into git's object store** — store tools write content-addressed
   blobs at store time; `Delta_ref` carries the oid; tmp+rename lands in
   the same change. Lands FL7.
2. **Retire from the ledger, not the tree** — the retire step builds the
   pathspec-limited commit from store-event oids; net-delta consumers move
   to the event stream.
3. **The frontier** — `Retire.Frontier` over ledger + committed state;
   `materialize` as boot/hygiene. Lands FL3, FL4.
4. **Collapse the tree** — `Agent.Grant.t` loses `worktree_root`/
   `snoop_mounts`, gains `write_globs`; the read resolver consults the
   frontier; nodes dispatch with no worktree. Lands FL2, FL5.
5. **Delete `Worktree`** — the module dies; squash finalizers become the
   settlement append; `run.mli` `config.worktree_root` dies. Lands FL1 and
   the grep-gate (no worktree/restore vocabulary in lib/).
6. **Gates** — gate dispatch snapshots the frontier over the grant into
   hypotheses + witness triples; the effect lock re-scopes to declared
   build resources. Lands FL6.
7. **Hygiene and recovery** — `materialize` at open (boot = crash
   recovery); the unexplained-bytes sweep at quiescence; F5 re-aimed.

Also owed, tracked here so nothing lands silently:

- **The `Supervisor` module** — doc-resident until its trigger
  (`40-agents.md` § the module). Lands with: `Ledger` gaining the
  `Supervision` reader, `Steered` and `Supervisor_session` event kinds,
  and the `Supervisor_abort` squash cause; `Speculate.Switch.throw`'s
  `thrown_by` widening to include `` `Supervisor ``; the yield-note type
  generalizing to the note sum (`fiber.mli`, `agent.mli`, `chase.ml`);
  `Run.handle` growing `attach`/`detach`/`steer` and the CLI `goat steer`;
  `Report.summary` gaining the supervision line; falsifiers F18/F19 and
  probes P1–P4.
- **The message event class** — doc-resident until its trigger
  (`20-medium.md` § the bus): attributes-only, no addressee field; the
  worker subscription surface (theory-compiled defaults plus amendments)
  and falsifier F20 land with it.
- **The code-comment sweep** — `lib/`, `bin/`, `test/`, and `examples/`
  carry ~450 references to the former doc filenames; they are swept to the
  new names in one mechanical change (no semantics).

## OPEN items (run-level; mechanism-level OPEN items live in their owning doc)

- **Formal specification of the retire state machine.** The
  speculation/retire protocol (hypotheses, witnesses, squash, generation
  advance) is a small state machine and the plan of record is to specify it
  formally and prove witness soundness and squash completeness, linking spec
  to implementation empirically (oracles, never verified extraction).
  *Trigger: the first retire-protocol bug that a falsifier misses, or the
  protocol surviving three months unchanged — whichever comes first.*
- **Durability and resume.** v0 is one process, in-memory graph; the ledger
  is replayable by design, and under the flat org boot IS crash recovery
  (`20-medium.md` § the crash story) — but no resume path is built.
  *Trigger: a real pipeline long enough that a crash costs more than a day
  of agent spend.*
- **Predictor structure.** v0 is per-task-shape survival counters; anything
  history-indexed (TAGE-shaped) waits for data. *Trigger: measured survival
  rates that are bimodal within one task shape — evidence that shape alone
  under-indexes.*
- **Multi-machine execution.** The theory and ledger are location-transparent
  by construction; the scheduler is not, and one tree assumes one scheduler
  process. *Trigger: a workload whose port ceilings (model API concurrency)
  exceed one machine's usefulness — unlikely soon, since the bottleneck is
  provider ceilings, not cores.*
- **Human-in-the-loop nodes.** A human is representable as an execution unit
  with a very long latency distribution and no repair lane; nothing is built.
  A standing human participant is also the recorded trigger that could pull
  the supervisor inside the theory (`40-agents.md` § beside the machine).
  *Trigger: the first pipeline that needs an approval gate.*
- **The `+ox` ppx compatibility census** — returned its verdict
  (`ppx_deriving_jsonschema` does not build against the ox Parsetree;
  codecs via `ppx_yojson_conv` work); the hand-written wire schemas remain
  a recorded wound (`00-product.md` § substrate decision).

## Closed by ruling

Each recorded with its rationale in the owning doc; listed here so nothing is
re-litigated by accident:

- **Work is data.** The unit of orchestration is a theory — control flow
  reified as relations and statements, run by a small evaluator — never a
  script (`00-product.md`, `10-theory.md`).
- **Share memory by communicating.** The tree is never a coordination
  channel; all coherence is evented on the ledger; the tree is a cache of
  the ledger's live frontier (`00-product.md` § the two co-equal bets,
  `20-medium.md`).
- **One tree, no branches, no worktrees.** Isolation was a second coherence
  mechanism beside the ledger's; deleted. One git ref; the ledger is the
  commit log; retirement builds commits from ledger blobs
  (`20-medium.md`, `30-scheduling.md` § the landing).
- **Fix forward, only.** Revert is unrepresentable — corrections are
  forward stores; recovery is frontier re-derivation; materialization is
  checkout, never restore (`00-product.md`, `20-medium.md`).
- **The two graphs.** Derivation is a strict forward DAG, permanently;
  communication is wall-less and witnessed — declared structure is a
  filter, never a wall. *(Supersedes "channels are unidirectional,
  permanently," whose derivation half survives verbatim and whose
  communication half was a duplicate coherence mechanism —
  `00-product.md` § the two graphs, `20-medium.md` § the bus.)*
- **The medium is a bus.** One totally-ordered stream; publication is
  appending, delivery is a subscription fold; channels, drift notes,
  supervisor notes, peer messages, and escalations are one mechanism
  wearing different rows. A message has no addressee — only attributes;
  agents have no privacy, so eavesdropping is legal observational
  learning. Information is universal; authority is typed. *(Supersedes
  "the two message modes" and completes the no-walls ruling: walls are not
  merely advisory, they are unrepresentable — no private pipe exists to
  guard — `00-product.md` § the medium is a bus, `20-medium.md` § the
  bus.)*
- **Facts and actuations are essentially different; the bus carries only
  facts, and the scheduler is the only enactor.** A kill is never
  delivered — the fiber is discontinued and the settlement publishes;
  modelling the kill as a message would make squash an escapable
  convention. Queued delivery is the only delivery; the interrupt survives
  at full strength as an enactment. *(Supersedes "never mid-flight
  interrupts," whose informational half survives: nothing informational
  crosses a turn boundary — `00-product.md`, `20-medium.md` § delivery.)*
- **Messages inform; settlements actuate; the scheduler enacts.** No
  message kills, fires, or commits anything; interrupt-class actuation
  belongs to the judgment hierarchy (`20-medium.md` § the bus).
- **The supervisor steers aggressively.** Err toward intervention, on
  evidence, early; the interrupt (`Abort`, optionally with a redirect note
  for the reissue) is its sharpest steer, and passivity is the recorded
  failure mode (`40-agents.md` § the aggressive posture).
- **Every boundary parses.** Admission returns `Theory.admitted`; the codec
  boundary returns typed tuples with phantom-typed ref ids; the schema lint
  parses derived schemas into `Wire_schema.t`. No downstream code re-checks
  what a boundary proved (`10-theory.md`, `50-api.md`).
- **Wall clock is the objective, at all costs.** Tokens are backstops and
  reports, never gates (`00-product.md`, `30-scheduling.md`).
- **Speculation is default-on, everywhere.** The only off switch is per task
  shape and requires measured reconcile churn (`30-scheduling.md`).
- **Channels are pre-opened at admission; readiness is a property of a read,
  never of a node** — socket activation, with eager start and read-time
  hypothesis binding as consequences (`20-medium.md`, `30-scheduling.md`).
- **Feedback is forward.** Iteration is generations; a backward derivation
  edge is unrepresentable; a "backchannel" that produces work is an
  undeclared forward relation (`10-theory.md`).
- **Notifications are invalidations, never payloads** — consumers pull net
  deltas at their own yield points (`20-medium.md`).
- **No decode-time grammar constraint on the primary lane.** Freeform strong
  model + derived contract as reference + mechanical validation with
  diagnostic repair; constrained decoding survives only as the refusal
  fallback lane (`40-agents.md`).
- **The contract is data; everything else is derived.** Schema, codec, prompt
  prose, and `.mli` text all derive from one catalog value (`10-theory.md`).
- **The witness is the artifact, never an asserted version number**
  (`30-scheduling.md`).
- **Only semantic change advances a generation** — an upstream landing exactly
  the predicted contract retires its speculators for free
  (`30-scheduling.md`).
- **Speculative state aborts by construction** — squash is a settlement
  append; provenance-dead coordinates are garbage nothing can witness into
  committed state; compensating actions are unrepresentable
  (`20-medium.md`, `30-scheduling.md`).
- **The engine ships typed drift signals; replay is scheduler policy** — no
  hidden retry loop below the scheduler (`30-scheduling.md`).
- **Laws are judged at retire, against final state, once** — no per-event
  checking, no deferral modes (`30-scheduling.md`).
- **Speculation targets contracts, never implementations** — the hypothesis is
  the interface tuple, not the artifact bytes (`30-scheduling.md`).
- **Theories must be weakly acyclic at accept time** — chase termination is a
  static admission judgment, not a runtime hope (`10-theory.md`).
- **Workers never run git** — the harness owns the commit substrate; two
  boundaries, tool and admission (`40-agents.md` § the git ban).
- **Executors are direct API calls, never a CLI shell-out** — the harness
  owns the tool loop or the mechanized-witness law is unimplementable
  (`40-agents.md` § the executor transport).
- **Supervision is push, not pull.** The supervisor decides when to
  intervene, on ledger evidence; a worker-invoked advice call inherits the
  self-report blind spot (`40-agents.md` § push, not pull).
- **The supervisor is beside the theory, inside the audit** — a host-level
  session, a node in every audited respect and a node in no theory respect
  (`40-agents.md` § beside the machine).
- **The supervisor gets an operator's powers, never a god's** — every
  forbidden power unconstructible, every steer evented before it applies
  (`40-agents.md` § unforgeability).
- **OxCaml is the experimental substrate; Rust-on-bumbledb (with a Lean spec
  tree) is the recorded successor.** Interim law: ledger and wire formats
  stay language-neutral; the store layer stays thin (`00-product.md`
  § substrate decision).
