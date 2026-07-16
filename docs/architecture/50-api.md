# 50 — API & Validation

The host surface — how an operator (or the planner) presents a theory, runs
it, and reads what happened — and how the design's laws stay true: named
falsifiers that try to kill them, replay determinism against the ledger,
and measurement discipline for the one claim everything rides on. Readers:
theory authors; `bin/goat`; the test suite; anyone about to quote a GOAT
CODE number. The falsifier suite drives everything through this surface —
there is no privileged internal entry.

## Declaring a theory

A theory is OCaml source: catalog types with derivers, plus a declaration
value assembled from the library's constructors. No macro layer, no external
DSL file, no YAML. The worked review theory (`10-theory.md`), concretely:

```ocaml
open Goatcode

(** A single reviewer finding: one defect claim, anchored to a file. *)
type finding = {
  change : Change.t Id.t;  (** Phantom-typed ref: only the engine mints
                               [Change.t Id.t]s, so a wrong-relation ref is
                               a compile error here and a parse failure at
                               the wire ([10-theory.md] § failure surface). *)
  file : string;   (** Repo-relative path the claim anchors to. *)
  claim : string;  (** One-sentence statement of the defect. *)
}
[@@deriving jsonschema ~variant_as_string, yojson]

(** One refuter's verdict on one finding. *)
type verdict = {
  finding : Finding.t Id.t;
  refuted : bool;  (** True when the refuter killed the claim. *)
  why : string;    (** The refutation or survival argument, one paragraph. *)
}
[@@deriving jsonschema ~variant_as_string, yojson]

(* One catalog entry per relation packages the declaration's derived
   artifacts once: the deriver's schema output and the ppx codec pair. *)
let entry name schema of_json to_json =
  Contract.v ~name ~schema ~codec:(Contract.Codec.v ~of_json ~to_json)

let finder =
  Theory.Executor.Agent_template
    { name = "finder"; pin = Pins.finder; preamble = Prompts.finder;
      read_globs = [ "src/**" ] }

let refuter =
  Theory.Executor.Agent_template
    { name = "refuter"; pin = Pins.refuter; preamble = Prompts.refuter;
      read_globs = [ "src/**" ] }

let theory =
  Theory.declare
    ~relations:
      [
        Theory.Relation.Packed
          (Theory.Relation.v ~name:"change"
             (entry "change" change_jsonschema change_of_yojson
                yojson_of_change));
        Theory.Relation.Packed
          (Theory.Relation.v ~name:"finding"
             (entry "finding" finding_jsonschema finding_of_yojson
                yojson_of_finding));
        Theory.Relation.Packed
          (Theory.Relation.v ~name:"verdict"
             (entry "verdict" verdict_jsonschema verdict_of_yojson
                yojson_of_verdict));
      ]
    ~statements:
      [
        Theory.Spawn.v ~name:"sweep" ~for_:"change"
          ~exists:("finding", Theory.Window.upto 32)
          ~by:finder ();
        Theory.Spawn.v ~name:"review" ~for_:"finding"
          ~exists:("verdict", Theory.Window.nodes 3)
          ~by:refuter ();
      ]
    ~laws:
      [
        Theory.Law.Count
          { name = "quorum"; over = "verdict"; group_by = "finding";
            bound = Theory.Law.Exactly 3 };
      ]
```

`Theory.declare` runs **admission** immediately, and admission is a parse:
it returns `(Theory.admitted, Admission.error list) result`. Weak
acyclicity, the acceptance gate (every law compiled to its judge), the
schema parse into `Wire_schema.t` (`10-theory.md` § the LLM-safe
subset), and ref-slot resolution all happen here, once —
**`Theory.admitted` has no other constructor, and it is the only theory
type the rest of the API mentions**, so an unadmitted theory cannot reach
the engine by any code path (`10-theory.md` § termination). Admission
errors are values, each carrying the offending statement and, for cycles,
the cycle path — shaped for the planner's repair lane as much as for
humans (`40-agents.md` § the planner).

Surface style is deliberately plain: named constructors, no operator
soup, no builder chaining. **Decision.** **Alternative:** a ppx that reads
a custom `theory%` syntax block — lost for v0 because the constructor
surface is inspectable, greppable, and reachable by the planner (which
emits it as data through the meta-catalog, never as source text anyway); a
surface ppx is sugar with a real maintenance bill under a moving `+ox`
toolchain. **Reverses if:** hand-written theories accumulate enough
boilerplate that authorship error rates show up in admission telemetry.

## Running

```ocaml
val Run.exec :
  theory:Theory.admitted ->
  seed:Tuple.t list ->            (* the initial facts, e.g. one change tuple *)
  config:Run.config ->            (* repo root, ledger path, port table,
                                     backstops: token ceiling + confidence
                                     floor, per-shape speculation off switches *)
  (Run.settled, Run.misuse) result
  (* Direct style on the cooperative fiber substrate (30-scheduling.md
     § read-time binding): exec drives the scheduler to quiescence in
     this process, on one domain — no monadic wrapper on the surface. *)
```

One entry point. Seed tuples are facts, not work product: each one enters
committed state at run open, at the primordial generation, with its payload
carried into the body-match feed — so where-filters match seed fields,
agents read seed data in their operand sections, and law judgment counts
seeded referents in its universe (a quorum law over a seeded relation is
never vacuously satisfied). `config` carries every number the docs say the
operator owns: the port table (provider ceilings), the two backstops
(`30-scheduling.md` § backstops), any per-shape off switches, paths. The
off switch is representation-enforced: `Switch.throw` takes the churn
evidence as an argument (`Churn.measurement`, a ledger-derived value) — a
bare switch is not rejected by the config loader, it is unconstructible
(doc rule 8; the counter is named below). Nothing in config changes
semantics — a run with speculation disabled retires the same tuples with
the same law verdicts, only slower; the falsifier suite asserts exactly
this equivalence (F9).

## The settled map

The answer is a value, never an exception:

```ocaml
type Run.settled = {
  nodes : Node.settlement Node.Map.t;   (* retired / faulted / squashed, cause chains, timings *)
  tuples : Tuple.committed Relation.Map.t;
  laws : Law.verdict list;              (* judged at quiescence, final state *)
  ledger : Ledger.handle;               (* the run's ledger, for the five readers *)
}
```

Each settlement carries the timing decomposition — `blocked` (operand
wait), `queued` (port wait), `run` — plus the speculation stamps
(hypotheses fired on, discharge times, drift notes received). A run-level
rejection exists only for host misuse (unadmitted theory, config paths that
don't exist), never for node failure or law violation: **the map is the
answer** (`30-scheduling.md` § settlement).

## Reading a run

Pull surfaces, all ledger queries, none of them on any hot path:

- **`Report.summarize settled`** — wall clock, total work, realized
  parallelism, the critical path (the chain that *was* the wall clock,
  walked backward through latest-settling operands), per-port queue
  rankings, and the speculation account: tokens spent under undischarged
  hypotheses, tokens squashed, latency bought (measured overlap, not
  theoretical) — plus, on supervised runs, the supervision line (the
  session's usage beside the speculation account — `40-agents.md` § the
  bill). This report is where the success criteria (`00-product.md`) are
  read, so its fields are the criteria's fields.
- **`Report.scoreboard run`** — live occupancy while running: per-port
  active/pending, in-flight hypotheses with confidence products, ledger
  append rate. Pull-only; polling it does not touch the dispatch path.
- **`Report.explain settled node_id`** — one node's story assembled from
  the ledger: why it fired when it did (the counters consulted, the
  hypothesis constructed), every drift note it received and the route
  taken, who steered it and why, its witness at retire, its settlement.
  The answer to "why did this run twice" is this function's output, and
  the scheduler's ruling that every decision lands in the ledger with
  reasons exists so this function can exist.

## The CLI

`bin/goat` wraps the library for the terminal:

```
goat run <theory.exe> --seed seed.json --config run.toml
goat plan "<spec>" --config run.toml
goat report <ledger>            # summarize
goat explain <ledger> <node>    # one node's story
goat replay <ledger>            # ledger-coherence audit (§ replay determinism)
goat version
```

(`goat steer` — the operator's entry to the supervisor's steer intake —
lands with the `Supervisor` module, `40-agents.md` § the module.)

Theories compile to executables that link the library and call `Run.exec` —
the CLI's `run` is a convenience runner around exactly that, holding no
semantics of its own. The planner path (`goat plan "<spec>"`) seeds a
one-statement bootstrap theory whose single node is the planner template
emitting a theory through the meta-catalog, runs admission on the
emission (a rejected emission returns to the planner **once**,
stateless-with-diagnostics — the original spec, the invalid emission
verbatim, and the admission complaints — as a second planning run
journaled at `<ledger_path>.plan.repair`; a second rejection is the
typed failure), and — on success — prints the emitted theory's statement
roster, validates that its executor pins bind under the same config
(providers known, keys present), and hands the operator the
run-it-yourself guidance (`goat run <theory.exe> --seed <seed.json>
--config <run.toml>`). **`plan` does not run the emitted theory**: its
seed relations are the operator's to supply (the bootstrap spec tuple
was consumed by the planner), and the plan-to-run seed surface is
undesigned — a run with an empty seed would fire nothing and print
success vacuously (OPEN item below). The planning run journals at
`<ledger_path>.plan`; `<ledger_path>` itself stays free for the emitted
theory's own run (node identity is per run, so one file holding two runs
would make `goat replay` report false divergences).

**`run.toml` is the CLI's config subset**, parsed once and entirely at
bind time — `examples/run.toml` documents every key. Top level:
`repo`, `committed_branch`, `ledger_path` (required strings —
`committed_branch` names the one ref retirement advances, its commits
built from ledger blobs, never a coordination channel; the retired
`worktree_root` key is refused by name with the migration pointer, never
silently ignored); `port` (default executor port, default
`"agents"`); `token_ceiling`, `confidence_floor` (the backstops);
`repair_attempts` (default 3); `planner_provider`/`planner_model` (the
plan pin, default `anthropic`/`claude-fable-5`). `[[ports]]` tables
declare bounded ports — `name` alone opens one; a `limit` parses only
together with its documented `bottleneck` (`Chase.Port.bounded`).
Deliberately absent: speculation off switches (unconstructible from
config text — a throw requires ledger-derived churn evidence, § running
above) and merge functions (v0 ships the registry empty,
`30-scheduling.md`).

**Every CLI failure on this surface is a typed, named complaint, never a
stack trace**: a missing or malformed config names the file, line, and
key; an unknown provider in a pin names the provider and the accepted
set; a pin routing to a provider whose API key variable
(`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`) is unset names the variable — all
judged at bind time, before any node runs, so a dry `goat plan` with no
key exits on the typed key error without a single model call. A ledger
path that already exists is refused up front by `plan` and `run` with the
path named — a ledger is one run's replayable journal (node identity is
per run; a second run appended to the same file would make `goat replay`
report false divergences), so the operator picks a fresh path and the
existing journal is never truncated (fix-forward). The refusal is the
CLI's: library callers and tests manage their own paths. Exit codes are a
contract: 0 is success (for `plan`, the bootstrap run quiesced with no
faulted node and no violated law — squashes alone are speculation's
normal business — and the emission passed admission); 1 is any typed
error path, including a final settled map carrying a faulted node or
violated law; 2 is an argv parse failure. `goat run` returns the theory
executable's own exit code — the same contract, owed by the linked
binary.

---

# Validation

## The falsifier discipline

**Every law in these docs has a named test that tries to kill it, not an
example that happens to pass.** Rigged executors (deterministic fakes with
scripted outputs, delays, faults, and invalid-output injections) make the
whole roster runnable in CI without a model call. Live-model runs are
validation of the *templates*, never of the engine laws — the split keeps
the falsifiers fast and the engine's correctness independent of any
provider's behavior. The roster, each entry naming the law and its owning
doc:

- **F1 — max-of-legs.** A diamond theory's wall clock is the slowest leg,
  never the sum: the dependency structure IS the schedule
  (`30-scheduling.md` § eager start, § read-time binding).
- **F2 — no head-of-line blocking.** A slow node on an open port never delays
  an unrelated ready node.
- **F3 — squash precision.** A fault or dead hypothesis squashes exactly the
  provenance-closed subtree; siblings retire undisturbed; the falsifier
  builds a graph where any over- or under-squash changes a committed tuple
  and asserts none does (`30-scheduling.md`).
- **F4 — dispatch purity.** No I/O, logging, or await on the
  settlement-to-issue path beyond the ledger append; enforced by
  instrumentation in test builds (`30-scheduling.md`).
- **F5 — abort by construction.** Kill a run at arbitrary points (fault
  injection at every yield class); committed state contains only
  fully-retired nodes' effects. Under the flat org this falsifier is
  re-aimed: the injection asserts frontier re-derivation (boot = crash
  recovery, `20-medium.md`) instead of worktree-drop cleanliness.
- **F6 — witness honesty.** A node whose executor is rigged to *claim* a
  dependency it never read, or to hide one it did read, gets the witness the
  ledger observed, both times (`20-medium.md` § mechanized witnesses).
- **F7 — free-commit.** An upstream that lands byte-identically to the
  hypothesis advances no generation, fires no invalidation, and its
  speculators retire with zero reconcile events (`30-scheduling.md`
  § the generation-witness protocol, law 2 — the economic keystone gets
  its own falsifier).
- **F8 — drift routing table.** Each drift class in `30-scheduling.md`'s
  table, constructed deliberately, routes as the table says — including the
  per-consumer refinement (a breaking change to an unread field routes
  additive for that consumer).
- **F9 — speculation is semantics-free.** The same theory and seed, run with
  speculation on and off, commits the same tuples (mod fresh-id renaming —
  the replay canonicalizer handles it) and the same law verdicts. The
  falsifier runs the review theory both ways with rigged executors and
  diffs.
- **F10 — repair-lane boundedness.** A permanently-invalid rigged executor
  faults after exactly the configured repair budget; nothing invalid ever
  crosses the codec boundary (`40-agents.md`, `10-theory.md` § failure
  surface).
- **F11 — derivation unidirectionality.** No API surface, tool grant, or
  channel operation lets a node write to any relation its statement doesn't
  mint into; the adversarial sweep drives planner-shaped garbage at
  admission and wire-shaped garbage at the codec, asserting no panic and no
  write (`20-medium.md` § the derivation law, `10-theory.md`).
- **F12 — effect gating.** A speculative node's tool surface contains no
  non-idempotent effect tool, under every template configuration the suite
  can generate (`20-medium.md` § event taxonomy).
- **F13 — admission soundness.** Every theory the weak-acyclicity check
  admits quiesces on rigged executors with bounded fanout data; every
  rejected theory carries a real cycle path (checked by hand-verified
  fixtures) (`10-theory.md` § termination).
- **F14 — provisional identity.** Squashed nodes' minted ids never appear in
  committed tuples; committed id space is dense and replay-stable
  (`30-scheduling.md` § provisional identity).
- **F15 — compile-time probes.** Every state these docs declare
  *unrepresentable* has a negative compilation test: a probe file of
  programs that must NOT typecheck — a speculative `unique` value flowing
  into committed structures (`30-scheduling.md`), a non-idempotent effect
  tool in a speculative grant (`40-agents.md`), a wrong-relation phantom
  ref (`10-theory.md`), `Run.exec` on an unadmitted theory, a bare
  `Switch.throw`, a wrongly-typed payload published through a
  correctly-named relation (`20-medium.md` § channels) — each asserted to
  fail with the expected error class. The supervisor probes P1–P4
  (`40-agents.md` § unforgeability) join this roster with the module. Doc
  rule 8's claims are checkable claims, and this is their checker: an
  "unrepresentable" that compiles is a doc bug or a type bug, and either
  way the suite goes red.
- **F16 — footprint escapes.** An observed load outside a consumer edge's
  compiled delivery filter surfaces at retire as the typed
  `Footprint_escape` event, a violated `footprint_cover` verdict on the
  settled map naming the node and address, and the escape list in
  `Report.explain`'s story; a covered read surfaces nothing, and the
  escapee still retires — the declaration is a filter, never a wall
  (`20-medium.md` § footprint filtering).
- **F17 — the git ban.** Both boundaries of the ruling: a worker's
  `run_command` naming git in command position — argv0, after separators,
  through one layer of quoting — gets the typed in-band refusal and
  appends no `Effect` event, while a precise non-command mention passes;
  and a theory declaring a shell gate whose argv[0] resolves to git is
  rejected at admission with the offending statement named
  (`40-agents.md` § the git ban).
- **F18 — witnessed steering** (reserved; lands with the `Supervisor`
  module). A rigged session drives every `Steer` constructor; each
  application's machinery events are preceded by its `Steered` event;
  replay reproduces every application with supervisor turns substituted
  from the ledger (`40-agents.md`).
- **F19 — supervision never delays dispatch** (reserved; lands with the
  `Supervisor` module). An arbitrarily slow rigged supervisor turn changes
  no unrelated node's dispatch timing; F4's instrumentation extended over
  the feed fold (`40-agents.md` § the cadence law).
- **F20 — delivery is a fold** (reserved; lands with the message event
  class and the worker subscription surface). Every materialized delivery
  — a worker's note drain, a supervisor escalation, an eavesdropper's
  match — is re-derived from the recorded subscription table folded over
  the recorded stream, and nothing was delivered that the fold does not
  re-derive: no unrecorded delivery, no envelope-shaped side lane
  (`20-medium.md` § the subscription discipline).

**The flat-org roster (FL — lands with the migration steps,
`README.md` § design of record vs shipped engine):**

- **FL1 — squash-revert counterfactual.** A producer stores over committed
  content, then squashes. Assert: the committed coordinate never moved (no
  event lowers or rewrites it); no event class in the ledger can express a
  retreat (the negative-compile half: no constructor takes a generation
  backward); the repair is a forward event; a rigged consumer that read
  the dead bytes is refused at retire and routed forward, never retired.
  The counterfactual arm: assert the suite contains no code path that
  could have restored the old bytes as anything but
  `Frontier.materialize`'s cache fill — grep-gate style, no restore verb
  in lib/.
- **FL2 — no dead witness commits.** Every consumer of provenance-dead
  state either cascade-squashes (hypothesis tracked) or is refused by the
  content-judged witness (untracked read); build the graph where any leak
  changes a committed tuple, assert none does (F3's shape, re-aimed).
- **FL3 — live frontier at quiescence.** After runs with injected squashes
  and reissues: every committed address's content equals a witnessed-live
  store's blob; the hygiene sweep finds only bytes attributable to dead
  events or declared effects.
- **FL4 — global generation monotonicity.** A fold over the whole ledger,
  per address, across arbitrary squash and crash injection points:
  committed generations strictly increase; run twice with a mid-run kill
  and re-boot (`Frontier.of_ledger` + `materialize` + forward reissue) and
  assert the same. Monotonicity is judged over the ledger because the tree
  carries no authority to retreat.
- **FL5 — live clobber conviction.** Two in-flight writers store to one
  path from one base in the shared tree. Assert: the disjoint law convicts
  the pair at retire (base equality); the loser is a `Reissue_loser`,
  reissued against the winner's landing; the earlier writer receives the
  drift note at its next yield (sensing, not surprise); committed content
  is single-writer coherent.
- **FL6 — gate-hypothesis discharge.** A gate runs while a producer's
  draft is in flight. Arm A: the producer lands identically — the gate's
  hypothesis discharges silently, the verdict retires with zero reconcile
  events (the gate-shaped F7). Arm B: the producer lands differently — the
  verdict is squashed or reissued per the table, and no law consults the
  stale verdict at final state; the writer-killed variant beside it pins
  the provenance cascade. The effect-side arm re-aims both at the
  tree-observing subprocess the gate law also binds: an agent's granted
  `run_command` takes the same snapshot at execution
  (`30-scheduling.md` § gates on the shared tree).
- **FL7 — torn-read impossibility.** A rigged gate subprocess reads the
  target path in a tight loop while stores land through the tool path;
  assert every observed read is a whole former-or-latter content, never an
  interleaving (tmp+rename's contract, exercised from outside the domain).

The fiber-substrate falsifiers (FB1–FB7: park/wake delivery, squash
inescapability, discontinue finalizers, overlap, wake-twice, rogue-effect
containment, the curl-multi loopback) and the mount falsifiers (FM1–FM4:
overlap through the real Messages encoder, mid-flight squash with
finalizers, wake-exactly-the-address) hold the one layer whose guarantees
are dynamic — the evidence file is `docs/effects-evaluation.md`.

## Replay determinism

`goat replay <ledger>` audits a run's recorded trace for **ledger
completeness**: every judgment the trace makes re-derivable is re-derived
from recorded events alone and asserted against what the ledger recorded —
the clock (timestamps enter decisions only through the ledger, so append
order is non-decreasing), settlement (every fired node settles exactly
once), retire order (dependency order recomputed from firing provenance),
and drift routing (each recorded note's route re-derived from the policy
table applied to its recorded class). A decision that consulted unrecorded
state surfaces as a divergence between the recorded rendering and the
re-derived one. This is the mechanism behind the no-hidden-state posture
(`20-medium.md` § the ledger), and the reason `Date.now()`-class
nondeterminism is banned from the scheduler. It is also what supervision's
statelessness law leans on (`40-agents.md` § statelessness), and what the
bus makes universal: every delivery in the system — worker drains,
supervisor escalations, any subscription's matches — is a pure fold of a
recorded table over the recorded stream, re-derived the same way (F20).

**What the checker does not do**, stated so the doc and the code cannot
drift apart: firing order and speculation choices are recorded but *not*
re-derived — their inputs include the admitted theory value and the run's
backstop/switch configuration, which the ledger does not carry. Full
re-execution (same theory, same seed, executor outputs substituted from
recorded events, every scheduler decision reproduced exactly) is the OPEN
item below, with its trigger.

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
  full even when a squashed node's work contained salvageable pieces; if
  salvage lanes are ever built, they earn their accounting when they exist.

## The speculation counters

The ledger-derived counter set, each with its named reader:

| Counter | Definition | Reader |
|---|---|---|
| survival(shape, pin) | hypotheses discharged unchanged / fired | port priority + hypothesis-source selection (`30-scheduling.md`) |
| reconcile_cost(shape) | mean tokens per drift-routed reconcile | the token-overhead report |
| flush_cost(shape) | mean tokens squashed per subtree flush | the token-overhead report |
| churn(shape) | wall-clock lengthening attributable to reconcile/flush serialization on contended ports | the per-shape off switch — the ONLY evidence that throws it (`30-scheduling.md`) |
| overlap(shape) | wall-clock actually overlapped per surviving hypothesis | `Report.summarize`; the default-on ruling's standing evidence |
| suspended_reads(shape) | read-suspension time with no hypothesis source | the planner pre-issue OPEN trigger (`30-scheduling.md`) |
| stale_window | invalidation append → consumer yield latency | the queued-delivery latency evidence (`20-medium.md`) |
| interrupt_cost(shape) | kill → redispatch → context re-acquisition cost per interrupt | the interrupt-mode reversal trigger (`20-medium.md` § delivery) |
| publication_volume(participant) | bus publications / tokens spent on message-driven work | the bus ruling's reversal trigger (`20-medium.md` § the bus); reserved with the message class |
| footprint_escapes(edge) | loads outside the declared footprint | theory authors (`20-medium.md`) |
| repair_rate(template, pin) | boundary repairs per invocation | the GCD-lane reversal trigger (`40-agents.md`) |
| retire_latency | ready-to-merged per node | the early-retire reversal trigger (`30-scheduling.md`) |
| gate_churn(shape) | gate reissue rate under in-flight drift | the optimistic-gate reversal trigger (`30-scheduling.md` § gates) |
| supervision_bill(session) | tokens per supervision session, boot cost per succession | `Report.summarize`'s supervision line (`40-agents.md` § the bill) |

Every reversal trigger written in these docs that says "measured" names its
counter in this table or doesn't say "measured." The table is the docs'
promissory notes made auditable.

## OPEN items

- **Config defaulting.** Which config fields get defaults vs stay required.
- **The CLI has no falsifier.** § the CLI's laws — the retired
  `worktree_root` key refused by name, the typed bind-time complaints,
  the fresh-ledger refusal — are held by code review alone:
  `Config_file` is private to `bin/main.ml`, no dune rule invokes the
  `goat` binary, and the falsifier discipline's "a named test that tries
  to kill it" does not yet reach this surface. A regression to silently
  ignoring `worktree_root` would keep the suite green. *Trigger: the
  first CLI-surface regression, or the config parser's next refactor —
  whichever lands first extracts the parser where a falsifier can reach
  it.*
- **Streaming report surface.** `scoreboard` polls; a push surface (SSE or
  a TUI) is presentation-layer and waits for a consumer. *Trigger: the
  first operator who runs a >30-minute pipeline and asks for a progress
  bar.*
- **Seed tooling.** Seeds are JSON tuples validated through the same codec
  boundary; sugar for common seeds (a git diff as a `change` tuple) belongs
  in `bin/goat` once patterns repeat. *Trigger: the third hand-written
  seed file with the same shape.*
- **The plan-to-run seed surface.** `goat plan` stops at admission plus
  the run guidance; nothing yet designs how an emitted theory's seed
  relations get populated (the planner could emit example seeds through
  the meta-catalog, or `plan` could prompt for them, or the guidance
  stays the surface). Deliberately undesigned rather than run vacuously
  with an empty seed. *Trigger: the first operator who takes a `plan`
  emission all the way to a real run and reports the seed-authoring
  friction.*
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
- **Full re-execution replay.** The coherence audit (§ replay determinism)
  re-derives what the trace alone makes derivable; re-running the scheduler
  against recorded executor outputs additionally needs the admitted theory
  and the run's backstops/switches in the ledger — the meta-catalog wire
  rendering (`Theory.Meta`) already exists as the natural carrier.
  *Trigger: the first divergence dispute the coherence audit cannot
  adjudicate, or the ledger gaining the admitted theory's wire rendering
  for any other reason.*
