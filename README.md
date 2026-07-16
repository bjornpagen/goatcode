# GOAT CODE

A coding harness built as a **speculative chase engine whose rule firings
invoke LLM agents** — Tomasulo's algorithm and the database chase observed
to be the same algorithm at different levels, plus speculation, run at the
level where the execution units cost tokens and take tens of seconds.

There is no orchestration script and no agent-to-agent chat. You declare
work as a **theory** — relations (typed tuple schemas that become
channels), spawn statements (for every body match, head tuples exist,
produced by an executor), and retire laws (countable predicates judged
once, at quiescence, against final state) — and a small evaluator chases
it. Agents are execution units behind contracts: each node runs against
the one shared tree, talks to a model API directly through a harness-owned
tool loop, emits one typed tuple, and is retired by the engine as one
commit — built from the ledger's content-addressed blobs — on a committed
branch. Everything a node does — every load, store, effect,
model turn, hypothesis, and scheduler decision — is an event in an
append-only ledger you can read back, and the ledger's coherence is
machine-audited.

```ocaml
(* Work is data. Three parallel implementers, a count-gated integrator,
   a test gate — the full program is these declarations (abridged from
   examples/calc_live.ml, which runs live). *)
let statements = [
  (* data-generated fanout: one statement, one firing per module_spec seed *)
  Theory.Spawn.v ~name:"implement_module" ~for_:"module_spec"
    ~exists:("module", Theory.Window.nodes 1)
    ~by:module_implementer ();

  (* fan-in through the where-grammar: fires when three modules exist —
     including parsed-but-unretired ones, which the firing then consumes
     as store-buffer hypotheses *)
  Theory.Spawn.v ~name:"integrate" ~for_:"spec"
    ~where:(Theory.Filter.Count
              { over = "module"; link = "spec"; where_equals = [];
                cmp = Theory.Filter.Ge; bound = 3 })
    ~exists:("integration", Theory.Window.nodes 1)
    ~by:integrator ();

  (* exit status is data: a failing test run is a tuple, not a fault *)
  Theory.Spawn.v ~name:"run_all_tests" ~for_:"integration"
    ~exists:("final_run", Theory.Window.nodes 1)
    ~by:gate ();
]

let laws = [
  Theory.Law.Disjoint_writes { name = "disjoint" };
  Theory.Law.Count { name = "three_modules_per_spec"; over = "module";
                     group_by = "spec"; bound = Theory.Law.Exactly 3 };
]

match Run.exec ~theory ~seed ~config with
| Ok settled -> (* the settled map IS the answer: settlements, tuples,
                   law verdicts, and the ledger for the readers *)
| Error misuse -> (* host misuse only — node failure is never a run failure *)
```

What the ledger says one such node did, verbatim from a live run
(`goat explain`):

```
node node#3
fired because: statement integrate fired; consumed [spec:spec#0,
  module:module#2, module:module#0, module:module#1]; counters consulted
  [counted:module=3]; hypotheses constructed [hypothesis#0
  (source=store-buffer:node#1, confidence=0.93)]
witness (observed reads only):
  file:evaluator.py @ g0 (be64a435) ... tuple:module/module#1 @ g0 (a8be31cf)
settlement: retired
```

The integrator fired 140ms before its third producer retired, consumed the
in-flight tuple as a priced hypothesis, read the module sources off the
committed checkout, and the hypothesis discharged for free when the landing
matched the snapshot. Had it drifted, the integrator would have been
squashed and reissued — abort by construction, not compensation.

## The objective

**Wall-clock time, at all costs.** The scarce resource is the operator's
calendar; tokens are fuel — accounted, backstopped, reported, never the
objective. Consequences, each a ruling in the architecture docs:

- **Work is a theory, not a script.** The deepest commitment is the
  Brooks–Pike–Raymond–Torvalds principle that the representation, not the
  control flow, is where complexity lives: orchestration is reified as data
  (relations as channels; spawn rules with data-generated fanout;
  cardinality windows; retire laws judged once against final state) and the
  scheduler is a small evaluator — a chase — over it. Everywhere else the
  same move repeats: boundaries parse into refined types, forbidden states
  are unconstructible rather than guarded, unavoidable branching is a
  table.
- **Every channel is pre-opened at admission** (s6/systemd
  socket-activation lineage): every node starts at t=0, and readiness is a
  property of a *read*, never of a node. Waiting happens at reads;
  suspended fibers are free.
- **Speculation is default-on.** A read of a missing operand takes a
  hypothesis wherever a source exists (a producer's parsed store buffer, an
  issued contract) — taken at read time, as late and as well-informed as
  the work allows. Hypothesis-taking is a *capability of the executor
  class*: an agent binds one (the payload rides its prompt, marked, with
  the drift contract); a shell gate has no carrier, so its read parks —
  arrived at by capability, not by a config switch.
- **Contracts are one supply.** A relation's schema derives the prose the
  model reads, the (non-strict) structured-output format, and the codec
  that judges the reply — drift is a schema diff, and correct speculation
  commits for free. The same discipline runs the planner: a theory is
  itself wire data through a meta-catalog, and planner emissions face
  exactly the admission judgment hand-written theories face.
- **Abort by construction.** Speculative state lives in the append-only
  ledger; squash is a settlement append — the subtree's events become
  provenance-dead by derivation, its tree bytes are hygiene for the
  frontier's materialize — no rollback, no compensation. Witnesses are
  observed from tool events, never self-reported. Retirement is
  dependency-ordered; squash precision is absolute.
- **Two graphs, one bus.** Derivation is a strict forward DAG — feedback
  is a forward edge firing a new generation, and a backward derivation
  edge is unrepresentable. Communication is an event bus: publication and
  subscription are the only routing, a message has no addressee (agents
  have no privacy — only attributes a subscription matches), and every
  publication is a witnessed, provenance-carrying fact the same squash
  machinery judges. The bus carries facts; the scheduler is the only
  enactor — a kill is a discontinue plus a published settlement, never a
  delivered message.

## The agent harness

Direct provider API calls, never a CLI shell-out: the harness owns the tool
loop, so every action an agent takes is executed here and evented with its
footprint — the only design under which the mechanized-witness law can
hold. Two lanes behind one signature (Anthropic Messages, OpenAI Responses)
plus a scripted lane the whole falsifier suite runs on.

The tool surface is a table derived from the node's grant — an ungranted
tool has no entry to dispatch to, so there is no runtime permission check
to forget:

| tool | class | notes |
|---|---|---|
| `read_file` | load | resolves through the frontier over the one shared tree; a read of an in-flight top witnesses at the producer's uncommitted generation |
| `glob_list`, `grep` | load | same three-place resolution; a match whose committed state is Landed enters the observed witness at the committed (generation, content) — in-flight and never-committed matches contribute no triple (existence-of-uncommitted is not a witnessable claim in v0) |
| `write_file`, `str_replace_edit` | store | land in the shared tree within granted write globs, bytes content-addressed into git's object database first — retirement commits from those blobs |
| `run_command` | effect | exists only when the template declares it: an idempotence argument makes it grantable under speculation; without one it reaches only hypothesis-free dispatches — the forbidden combination has no constructor, and a node made speculative mid-turn hits the runtime edge (the non-idempotent tool refuses in-band). Execution takes the gate's honesty snapshot: every in-flight top becomes a tracked hypothesis. Machine-locked; git in command position is a typed refusal (the harness owns the commit substrate) |

Prompts are assembled, never authored per node: template preamble (the one
hand-written artifact — stance and method, never shape), contract section
(derived prose + schema), operands (codec-rendered tuples; hypotheses
explicitly marked with confidence and the drift contract), footprint grant,
settlement instruction. Replies cross a codec boundary with a bounded
repair loop (the same agent re-invoked stateless-with-diagnostics); typed
provider refusals route to a fallback lane instead of burning repair
budget. The Anthropic lane runs the standard two-breakpoint prompt-caching
shape, so a tool loop's resent history is read from cache.

## The CLI

```
goat plan <spec> --config run.toml   # planner emits a theory; admission judges it
goat run <theory.exe> --seed ... --config ...   # convenience runner (theories are executables)
goat report <ledger>                 # wall clock, realized parallelism, speculation account
goat explain <ledger> <node>         # one node's story: firing, decisions, witness, settlement
goat replay <ledger>                 # ledger-coherence audit: re-derive every re-derivable judgment
```

### Quickstart

Build (the switch is linked to this directory):

```sh
opam exec --switch=5.2.0+ox -- dune build
opam exec --switch=5.2.0+ox -- dune runtest   # the falsifier suite, no model calls
```

Export a key, create the demo repository (goat never runs git for you), and
plan a toy spec:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
cp examples/run.toml run.toml       # self-contained: everything under ./.goat/
mkdir -p .goat/demo-repo
git -C .goat/demo-repo init -q
git -C .goat/demo-repo commit --allow-empty -m "goat demo root"

./_build/default/bin/main.exe plan \
  "Write docs/haiku.md: one haiku about speculative execution. \
   Then have a second agent review it and write docs/haiku-review.md." \
  --config run.toml
./_build/default/bin/main.exe report .goat/ledger.bin.plan
```

### Live examples

Each is a theory compiled against the library — the shape `goat run`
expects — with its setup incantation in its header comment. All three have
run green against live models; deliverables are verified on the committed
branch, never by exit codes alone.

| example | what it exercises |
|---|---|
| [`examples/haiku_live.ml`](examples/haiku_live.ml) | two agents chained through a ref slot; store-buffer speculation; a count law |
| [`examples/coding_live.ml`](examples/coding_live.ml) | a from-scratch coding task: an implementer that runs its own tests (`run_command`), then a shell gate re-verifying against the committed tree |
| [`examples/calc_live.ml`](examples/calc_live.ml) | the stress: three parallel implementers, a count-gated integrator consuming an in-flight tuple as a hypothesis, disjoint-writes law, full-suite gate |
| [`examples/dump_ledger.ml`](examples/dump_ledger.ml) | the raw event stream, one line per append — the ground truth the readers summarize |

## Validation

- **Falsifiers, not tests**: the suite (F1–F17, FL1–FL7, FB1–FB7,
  FM1–FM4) drives rigged provider lanes at engine laws and tries to kill
  them — repair-lane boundedness, effect gating under speculation, squash
  precision, the git ban, delivery filtering, and the flat-org roster
  (squash-revert counterfactual, dead-witness refusal, frontier
  liveness, generation monotonicity, clobber conviction, gate-hypothesis
  discharge, torn-read impossibility). No live model call anywhere in CI.
- **Negative compiles**: the forbidden states are unconstructible, and
  probes assert it — an unadmitted theory reaching the engine, a
  non-idempotent effect in a speculative grant, a wrongly-typed channel end.
- **Replay**: `goat replay` re-derives every judgment the trace makes
  re-derivable (the clock, settlements, retire order, drift routing) and
  asserts them against what the ledger recorded; a decision that consulted
  unrecorded state surfaces as a divergence.
- **Live claims stay earned.** Anything measured is cited from a specific
  ledger. Current honest numbers, from the calc pipeline's first green
  traces: 3 provider calls overlapped on one domain (1.7× realized
  parallelism), 0.14s of speculation overlap bought (small by structure —
  a store buffer becomes snoopable at parse, which lands at the end of a
  provider call; widening that window via issued-contract firing and
  streaming parses is the recorded growth path).

## Architecture

The design is documented before it is code, and the docs are normative:
when code and these docs disagree, one of them is wrong and the repo is
broken until they agree. Start at the
[architecture README](docs/architecture/README.md) for the doc rules
(decision records with reversal evidence, OPEN items with closure triggers,
the acceptance gate) and the reading order.

| doc | what it owns |
|---|---|
| [00 — Product & Philosophy](docs/architecture/00-product.md) | what goat code is and refuses to be: the two co-equal bets (work is data; share memory by communicating), the two graphs, the medium is a bus, fix-forward |
| [10 — Theory & Contracts](docs/architecture/10-theory.md) | the work representation: relations, spawn statements, laws, admission-as-parse, weak acyclicity; one supply — schema, codec, and prompt prose from one declaration |
| [20 — The Medium](docs/architecture/20-medium.md) | the bus and the cache: the ledger's five readers, mechanized witnesses, validity as a ledger coordinate, publication and subscription (no walls, no envelopes), delivery levels and the enactor |
| [30 — Scheduling & Commit](docs/architecture/30-scheduling.md) | the chase: eager start, read-time binding, ports, the predictor, backstops, drift routing; retirement, the witness protocol, squash, gates on the shared tree |
| [40 — Agents & Supervision](docs/architecture/40-agents.md) | executors, tool grants, prompt assembly, model pins, the planner, the git ban; the supervisor — push not pull, the typed steering vocabulary, session succession |
| [50 — API & Validation](docs/architecture/50-api.md) | declaring, running, and reading a run; the CLI; the falsifier roster, replay determinism, measurement rules |

## Repository layout

```
lib/            the engine: theory, contract, channel, chase, retire,
                speculate, agent, fiber, ledger, witness, report, run, http
bin/            the goat CLI (a thin wrapper: theories are executables)
test/           the falsifier suite + negative-compile probes (rigged lanes only)
examples/       run.toml (documented config) + the live theories + dump_ledger
docs/           the normative architecture
```

## Toolchain

OCaml on the OxCaml toolchain (modes prove squash safety; effects carry the
fibers — provider calls overlap on one domain with no async framework). See
`dune-project` for the package set; the switch is linked to this directory.

## Status

Research-grade and honest about it. The engine, both direct provider lanes,
default-on speculation, retirement, and the readers are implemented and
held by the falsifier suite; three live pipelines have run green
end-to-end, including a from-scratch coding task built by parallel agents
and verified by a test gate. The docs describe the **design of record** —
the flat org (one tree, no branches, no worktrees) — and the shipped
engine runs all of it: stores land as content-addressed blobs, retirement
commits from the ledger, nodes dispatch against the one shared tree with
the worktree machinery deleted, gates run behind per-resource effect
locks, boot is crash recovery (the frontier is re-derived and the tree
converged at every open), and quiescence runs the unexplained-bytes
sweep. The
[migration ledger](docs/architecture/README.md#design-of-record-vs-shipped-engine-the-migration-ledger)
records that gap as closed, rows kept as struck history.
Other open seams are recorded where they live: the plan-to-run seed
surface and the supervisor module (doc-resident until their triggers),
issued-contract firing to widen the speculation window, and the message
event class.

## License

[0BSD](LICENSE) — use it for anything; no attribution required.
