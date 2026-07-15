# Executor Campaign — Work Plan (NON-NORMATIVE, delete when done)

This is a resumption tracker, not an architecture doc. The architecture docs
(`docs/architecture/`) are present-tense and normative; this file records
in-flight work and is deleted when the campaign lands. If this file and the
architecture docs disagree, the architecture docs win.

## WAVE 3 FIXES — the verified finding list, worked in order (2026-07-15)

The fixer pass over the panel's verified findings. All three criticals,
all seven live-path majors, and the minors landed; suite green; dry-path
CLI verified from a terminal.

- **C1 — self-witness poisoning (agent.ml).** A tool read served from
  the node's OWN draft stamped the committed generation with the draft's
  content hash — a triple `Witness.holds` could never accept → spurious
  `Witness_moved` → reissues → `Reissue_loser` squash for correct work.
  Fixed representationally: `Source.resolve` records WHERE a read is
  served from (`Source.place` = Draft | Committed | Snooped; a worktree
  file is Draft only when the buffer CHANGED it — `git status` against
  the checkout base), and `load_observation` claims by place: committed
  bytes witness the real committed pair, snooped reads stay at
  generation zero (B7), a draft read claims NOTHING. Falsifier
  (test_delivery.ml, red pre-fix: 2 attempts): edit a committed file,
  read the draft back, retire on the first attempt; F6's
  sibling-landing staleness verified still red-capable. Ruling recorded
  in 30-channels.md § mechanized witnesses.
- **C2 — glob_list poison triples.** Observed triples hashed the PATH
  STRING as content. Now the listing witnesses, for each Landed path,
  the committed (generation, content) pair straight from the lookup;
  in-flight-only paths contribute no triple (existence-of-uncommitted is
  not a witnessable claim in v0 — the listing-shaped witness belongs to
  the flat-org grant rework). The wave-3 "recorded not fixed" note below
  is CLOSED. Falsifier red pre-fix against the exact poison.
- **C3 — goat plan's vacuous emitted run.** The emitted theory ran with
  `seed:[]` — nothing could fire, success printed anyway. plan now stops
  at admission: roster + bind-validation of the emission's pins + the
  run-it-yourself guidance; exit code = the bootstrap map. The
  plan-to-run seed surface is deliberately undesigned — 70-api.md OPEN
  item with trigger (first operator to take an emission to a real run).
- **M1 — transient provider errors.** 429/5xx and curl timeouts retry
  bounded inside the lane (3 attempts, exponential backoff) before any
  `Executor_error`; exhaustion names the attempt count; no Ledger event
  (transport, not work). Rigged-post falsifiers count attempts.
- **M2 — max_tokens truncation.** `stop_reason: "max_tokens"` is a typed
  truncation outcome faulting IMMEDIATELY with raise-the-pin guidance —
  never the repair loop (falsifier red pre-fix: the repair re-post
  exhausted the scripted transport). OpenAI `incomplete`/
  `max_output_tokens` carries the same guidance.
- **M3 — schema lowering in the provider encoders only.**
  `format:"ref:<relation>"` strips into the description (model still
  sees the target relation); minItems/maxItems stay (Anthropic documents
  array bounds; OpenAI rides strict:false where the schema is guidance —
  live smoke verifies both wire facts). One shared `lower_api_schema`;
  prompt rendering unchanged; codec still judges refs/windows.
- **M4 — OpenAI strict:false on text.format** (tools already were);
  the strict-mode lowering (optional → required+nullable) recorded as
  the growth path at the encoder and in 60-agents.
- **M5 — ledger reuse collision.** `goat plan`/`run` refuse an existing
  ledger path with the path named (fix-forward; never truncated). CLI
  layer only.
- **M6 — examples/run.toml self-containment.** Everything under
  `./.goat/`; repo at `.goat/demo-repo` (quickstart git-inits it — goat
  never runs git for the operator); worktree_root INSIDE that repo.
  DEVIATION from the finding's letter, deliberate: the degradation
  warning lives at the CLI bind (both failure shapes — no repository,
  and the WRONG repository, judged by comparing git toplevels), not
  inside `Retire.Worktree.create` — bare-buffer mode is a designed
  engine mode the unit suites run whole engines on, and F4 asserts a
  silent stderr around engine steps; the create comment records both.
- **M7 — planner admission-repair, implemented (minimal honest form).**
  A rejected emission returns to the planner ONCE,
  stateless-with-diagnostics (original spec + invalid emission verbatim
  + `Theory.Admission.to_string` complaints) as a second planning run at
  `<ledger_path>.plan.repair`; a second rejection is the typed failure.
  Run-granular rather than a `Repair_attempt` in the settled turn:
  admission is judged after the bootstrap run settles, and a CLI-side
  re-entry into the turn's repair loop would be a second invocation
  lane — the divergent copy the executor rebuild deleted. All three
  claim sites amended to say exactly this.
- **N1 — effect-lock staleness.** The holder file records the pid; a
  dead-pid lock is removed and retaken with one warning line (falsifier
  red pre-fix: 30s spin into a spurious busy fault). Only positive
  evidence of death breaks a lock.
- **N2 — falsifier renumber.** 90-supervisor.md's reserved F16/F17
  collided with the taken roster (footprint escapes, the git ban);
  reservations renumbered F18/F19 with the collision noted in place.

**Recorded, NOT fixed — next-campaign items (N3):**

- **Reissue priority misclassification** — `lib/chase.ml:1254`: a
  reissued instance re-enters as `Priority.Resumed_witnessed` purely by
  membership in `t.reissues`, even when its operands would still bind
  speculatively — it jumps the witnessed class and bypasses the ceiling
  gate's intent for reissues that are not in fact witnessed.
- **Decorative port bounds** — `lib/chase.ml:841`: `Port.Bounded`'s
  limit is judged once at binding admission (`limit >= 1`) and never
  enforced as a concurrency ceiling at dispatch; a bounded port admits
  unbounded overlap. Falsifier owed with the fix.
- **Shared rx cursor** — `lib/chase.ml:171`: `rxs` is keyed by
  STATEMENT, so every instance of one statement shares one consumer-edge
  rx; one instance's `pull_invalidations` drain consumes invalidations
  owed to its siblings (masked today by mostly-single-instance suites).
- **Fallback-lane doc overclaim** — AMENDED this pass (60-agents § the
  fallback lane): the `?fallback` routing is built and falsified; the
  constrained-decode executor is recorded OPEN/unbuilt (v0 binds
  `fallback = None` in bin/main.ml) with its trigger.
- **Anthropic refusal-resilience betas** — still OPEN (Provider wire
  facts below): `betas: ["server-side-fallback-2026-06-01"]` +
  `fallbacks` opt-in undecided; decide at live smoke.

## WAVE 3 — enforcement rulings + verified-gap closure (2026-07-14)

Landed in one pass (this commit):

- **The git ban (operator ruling, verbatim: "ban all git commands from
  any of the workers").** Two boundaries, one law. Tool lane:
  `run_command` refuses any command whose token stream names git in
  command position (argv0; after `&&`/`||`/`;`/`|`/`&`, subshell/
  substitution opens, backticks; assignments and wrappers transparent;
  one quote layer stripped; basenames compared) with the typed
  `Grant.Refusal` ("git is the harness's commit substrate; workers never
  touch it") and no `Effect` event; the ban is named in the tool's own
  description. Admission lane: `Theory.Admission.Git_gate` — a shell
  gate whose argv[0] resolves to git is rejected with the statement
  named. RECORDED HONESTLY in `60-agents.md` § the git ban: the v0
  screen is a tripwire, not a security boundary (`sh -c`, `$PATH` games,
  and git-calling scripts pass it); PATH/sandbox control is the growth
  path. Falsifiers F17 on both lanes (test_boundary.ml — the refusal
  read in-band through a probe provider, Effect-event absence, and the
  precision control `echo git is banned` running; test_admission.ml —
  bare and by-path gates rejected, a build gate admitted). Roster + doc
  sections: `80-validation.md` F17, `60-agents.md`, `10-theory.md`
  § statement grammar.
- **CLI exit codes.** The contract is written in `bin/main.ml`'s module
  comment, the usage text, and `70-api.md` § the CLI: 0 success, 1 any
  typed error path, 2 usage. Audit result: every error path already
  exited non-zero EXCEPT the final settled map — `goat plan` printed
  faulted nodes/violated laws and exited 0. Fixed: `exit_of_settled`
  (any faulted node or violated law → 1; squashes alone are
  speculation's normal business). Verified from a terminal: missing API
  key → 1, missing config key → 1, missing ledger → 1, usage → 2,
  version → 0.
- **`shell_gate` eventing (wave-2 OPEN item, closed).** The gate runs
  behind the mkdir-atomic holder-named machine lock and appends
  `Ledger.Event.Effect { tool = "shell_gate"; resource = <declared
  command line>; idempotent = true }` — idempotence is the declaration's
  (a gate is a reissuable build/test command, which is why gates are
  grantable under either speculation index). Falsifier in
  test_boundary.ml. A git gate never reaches this runtime (admission).
- **Tool-load generations (wave-2 OPEN item, closed).**
  `Agent.Invocation` carries `committed : Ledger.Address.t ->
  Witness.Committed_state.t`; the chase threads
  `Retire.Committed.state` through `invoke_lane`, `Toolset.of_grant`
  takes it, and `load_triple` stamps the REAL committed generation for
  committed addresses (in-flight/absent stay zero; content still carries
  the judgment, per B7). Direct callers supply `fun _ -> Absent`.
  Falsifier in test_delivery.ml ("tool loads witness the real committed
  generation…" — printed witness generation g1, pre-fix g0).
- **F6 end-to-end.** test_delivery.ml "F6 end-to-end: an observed tool
  read gates retirement" — a rigged node's `read_file` load enters the
  observed witness through the real tool loop and gates retirement
  through the real machinery (sibling lands over the file →
  `Witness_moved` → breaking-broad flush → bounded reissue retires at
  the landed generation). The claim/hide unit directions stay in
  test_witness.ml.
- **Replay gap (judge-panel finding).** `80-validation.md` § replay
  determinism and `run.mli` now claim exactly what `Run.replay`
  delivers: a ledger-completeness coherence audit (clock, settlement,
  retire order, drift routes re-derived); firing order and speculation
  choices are recorded but NOT re-derived (their inputs include the
  admitted theory, which the ledger does not carry). Full re-execution
  is a new `80-validation.md` OPEN item with its trigger (a divergence
  dispute the audit cannot adjudicate, or the ledger gaining the
  admitted theory's wire rendering). `goat replay`'s success line and
  the usage/README wording now say "coherence audit", not "every
  decision reproduced".
- **Grant hard-codes (judge-panel finding).** No wiring built —
  `Theory.Executor.Agent_template` carries no effect-tool declaration
  surface, so effect grants await that surface; recorded honestly in
  `60-agents.md` § tool grants ("the v0 grant surface, recorded
  honestly") and at `chase.ml`'s `grant_of`: `effects = []` (F12's
  runtime half held by the type index + direct-drive falsifiers) and
  `snoop_mounts = []` (dies in the flat-org migration, `91-flat-org.md`;
  in-engine snooping rides the body-match feed).

Small finding, recorded not fixed at the time: `glob_list`'s observed
triples hashed the path string. CLOSED by the wave-3 fixer pass (C2,
above): the listing witnesses committed (generation, content) pairs from
the lookup; in-flight-only paths contribute no triple.

## WAVE 2 COMPLETE (2026-07-14)

Every B-finding is closed; the engine runs on the fiber substrate; the
CLI is terminal-ready up to live keys. A cold session resumes from this
section alone. Landed, by commit (subjects, newest last):

- `1530549` Commit layer: content-judged witnesses (B7), base-coordinate
  disjoint law (B8), real net deltas (B2's `net_delta` half).
- `a01bdd3` Event log: typed Decision/Drift vocabularies, typed
  `Pin_bump`/`Switch_thrown` (B11 reader half).
- `a1ff882` Admission: generation strata (B9), total slot sets (B10),
  admission parse audit.
- `3bc9791` Channels: `Type.Id` payload witnesses, `Obj` deleted (B12).
- `d088d0c` `lib/fiber`: the OCaml 5 effects substrate (vocabulary,
  Deep-handler scheduler, curl-multi lane, FB1–FB7),
  plus `docs/effects-evaluation.md`.
- `7702e26` Boundary rewiring: codec-judged heads (B1), committed seeds
  with payloads (B4), shape-lowered windows (B13), total mint provenance
  (B14).
- `e1f4ff0` Delivery + speculation: publish-on-retire, store-buffer
  hypotheses + refresher, drift table consumed at all three sites,
  lifecycle emission, typed squash causes (B3/B5/B6/B11 emission half/
  most of B15).
- `24073ef`/`26b1277` Effects integration: the chase and both provider
  lanes mounted on `Fiber` (FM1–FM4); zero expect diffs on the
  pre-existing suite.
- (this commit) The B15 remainder + CLI readiness: footprint escapes
  surfaced (`Channel.covers`, `Ledger.Event.Footprint_escape` appended at
  retire, the `footprint_cover` verdict on the settled map,
  `Report.explain`'s escape list, falsifier F16 in `test_delivery.ml` —
  loads only, per `30-channels.md` § footprint filtering: a store is the
  node's own work product and write overlaps are the disjoint law's
  domain); typed bind-time CLI errors (config file/line/key named,
  unknown provider named, missing API-key variable named BEFORE any node
  runs — the dry `goat plan` path verified); `examples/run.toml`
  (documented keys, sane defaults, planner pin
  `claude-fable-5`/anthropic); `goat plan` journals the planning turn at
  `<ledger_path>.plan` and the emitted run at `<ledger_path>` (one run
  per ledger — replay stays honest) and prints the emitted statement
  roster + both ledger locations; README Quickstart + Status; the
  effects-adoption Decision block in `40-scheduling.md`;
  `00-product.md` § substrate decision names the evaluation file;
  `70-api.md` § the CLI matches the implemented surface.

OPEN after wave 2, with owners:

- **Live smoke (Phase C) — operator + wave 3.** Needs real
  `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`; the README Quickstart is the
  script. First-ever live model contact: expect wire-shape surprises the
  rigged lanes cannot show. Anthropic `output_config.format` together
  with tool use is untested live; the `server-side-fallback` betas
  opt-in is still an open decision (details in "Provider wire facts").
- **`shell_gate` Effect eventing — CLOSED (wave 3, above).** The gate
  runs behind the machine lock and appends the `Effect` event.
  `pure_fn` needs nothing (pure over operands — no loads/stores exist).
- **Tool-load generations — CLOSED (wave 3, above).** The committed-state
  lookup threads chase → invocation → toolset; tool loads witness real
  generations for committed addresses.
- **Recorded-shape mechanisms, deliberately unexercised:** the
  `Issued_contract` hypothesis arm and retire's dangling-ref
  serialize-reissue lane are reachable only when dispatch overlaps
  producers; `No_producer` is emitted at `resolve_parked` but not
  constructible end-to-end in the current engine. Mid-flight patching
  (reconcile without reissue) stays the recorded convergence in
  `40-scheduling.md` § drift routing.
- **The ppx wound.** Hand-written wire schemas remain the recorded
  second supply (`ppx_deriving_jsonschema` does not build on `+ox`);
  tolerated per the substrate ruling until a deriver port or the Rust
  port.
- **Benchmark corpus** for the ≥1.5× headline claim (`80-validation.md`
  OPEN) — after live smoke.

Build/test: `opam exec --switch=5.2.0+ox -- dune build` /
`dune runtest --force`. Full suite green at wave-2 close (F1–F16,
FB1–FB7, FM1–FM4; rigged executors only).

## Where we are

**PHASE A LANDED** (commit "Executors: direct provider APIs +
harness-owned tool loop", 2026-07-14). What shipped:

- `lib/http` on ocurl (`Http.post_json`, transport errors typed, non-2xx
  is data); `curl` in `lib/dune`, `ocurl` in `dune-project`.
- `agent.ml`/`agent.mli` rebuilt: `Agent.Provider` (one stateless model
  turn; Anthropic Messages / OpenAI Responses / Rigged behind one
  signature) + the shared agent layer (`Agent.agent ~provider`) owning the
  tool loop, grant enforcement, Load/Store/Effect eventing, refusal
  recognition. `Executor.run` now takes `~ledger ~node`; `Executor.reply`
  gained `refusal`.
- Harness tools: `read_file`, `write_file`, `str_replace_edit`,
  `glob_list`, `grep`, `run_command` (granted only via an effect tool of
  that name; behind the mkdir-atomic holder-named machine lock at
  `$TMPDIR/goatcode-effect.lock`). Reads resolve worktree → read_globs
  (against process CWD) → snoop mounts; writes worktree-only; out-of-grant
  → typed in-band refusal.
- `claude_cli` DELETED; grep-gate clean. `bin/main.ml` dispatches
  `Pin.provider` at bind time (`provider_runtime`; unknown provider = a
  config error before any node runs). Planner pin default model is now
  `claude-fable-5`.
- chase's divergent repair-lane copy KILLED: `invoke_lane` now calls
  `Agent.invoke_parsed` (one repair-loop implementation; chase still
  supplies its own `parse_heads` — that migration is B1).
- `Ledger.Delta_ref.v` is public (the B2 constructor ask — done).
- `Rigged` steps are scripted provider turns; new `Call_tool` step drives
  the tool loop offline. New falsifier in `test_boundary.ml` ("tool loop:
  stores and loads are evented…"). Full `dune runtest --force` green.
- `60-agents.md` gained "§ The executor transport" (the no-CLI ruling +
  mechanized-witness rationale).
- OpenAI Responses wire shapes VERIFIED against the openai-openapi spec
  (flat `function` tools; `function_call`/`function_call_output` with
  `call_id`, `arguments` as JSON string; `text.format` json_schema;
  `output_text`/`refusal` content items; `input_tokens`/`output_tokens`).
  The earlier "wire uncertainty" note is resolved on paper; live smoke
  (Phase C) still pending.

**REFACTOR LANDED** (second 2026-07-14 commit): the executor layer
re-expressed representation-first after an audit against the Vercel AI
SDK's agent abstractions (decision recorded in 60-agents.md § the
executor transport). What changed: tools are values in a grant-derived
table (`Toolset.of_grant` — capability is the table; the giant
string-match dispatcher and every per-branch grant re-check are gone);
tool paths parse once into `Relpath.t` (bounds proof carried by the
type); read resolution is one `Source.resolve` (worktree → read_globs →
snoop, with `Missing`/`Outside_grant` typed); `Provider.outcome` is a sum
with non-empty-by-construction `Calls` and a real `Suspend` constructor
(the two degenerate-state guards deleted); `Executor.outcome` is
`Text | Refusal` (flag gone); `Agent.Stop` bounds the loop (pin option
`max_steps`, default 32; exhaustion = `Context_exhausted`); tool events
travel as data in `Tool.outcome` and the loop appends them. Suite green,
zero expect diffs — behavior-preserving.

Known Phase-A residue, deliberate:
- Tool Load events carry `Generation.zero` in their witness triples (the
  content hash is real); threading committed-state generation lookups
  through the executor is the B2/B7 rewiring.
- `pure_fn`/`shell_gate` emit no Load/Store/Effect events yet (B2/B15).
- Anthropic `output_config.format` + tool use together is untested live;
  `betas: server-side-fallback` opt-in still OPEN.

Working tree: clean except `.claude/` (untracked, ignore).

## Environment facts (verified this session)

- Switch: `5.2.0+ox`. Always build/test with
  `opam exec --switch=5.2.0+ox -- dune build` / `dune test`.
- `ocurl 0.9.2` **is installed** on the switch (in-process libcurl bindings).
  Not yet added to `lib/dune` or `dune-project`.
- `ppx_deriving_jsonschema` does NOT build on `+ox` (labeled-tuple Parsetree
  mismatch). Wire schemas are hand-written — the recorded wound, tolerated
  per the substrate ruling until a deriver port or the Rust port.
- `ppx_yojson_conv` works on `+ox` (codecs are fine).
- Live provider lanes will need `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` in
  the environment. Not needed for `dune test` (rigged executors only).

## Decisions locked this session (already in the normative docs)

1. **No CLI shell-outs, ever. Direct provider API calls only.** (User ruling.)
   This is also an architectural necessity, not just taste: a CLI session's
   tool calls are invisible to `Ledger`, so `30-channels.md`'s mechanized-
   witness law is unimplementable through a shell-out. Direct calls with the
   harness owning the tool loop is the only design where every load/store is
   an evented, observable footprint.
2. **Two providers, planner-routed.** Anthropic Claude Fable 5 (planner + all
   judgment-heavy shapes) and OpenAI GPT-5.6 Terra (mechanical contract-
   filling shapes). Routing is a theory-emission decision, never a per-call
   auto-router. Written into `60-agents.md` § model pins and provider
   routing; provider-abstraction OPEN item closed; `00-product.md` non-goal
   updated.
3. **Substrate ruling.** OxCaml is the experimental substrate; Rust-on-
   bumbledb + Lean spec tree is the recorded successor with two port
   triggers (Greenspun: store layer grows bumbledb features; or quiescence +
   bumbledb stability). In `00-product.md` § substrate decision, `README.md`
   Closed-by-ruling.

## Provider wire facts (for the direct-API lanes)

**Anthropic Messages API** — `POST https://api.anthropic.com/v1/messages`
- Headers: `x-api-key: $ANTHROPIC_API_KEY`, `anthropic-version: 2023-06-01`,
  `content-type: application/json`.
- Model: `claude-fable-5` (from Pin). Fable 5 rules (from the claude-api
  skill, authoritative):
  - OMIT the `thinking` parameter entirely (explicit `disabled` → 400).
  - NEVER send `temperature`/`top_p`/`top_k` (→ 400).
  - `output_config.effort`: `low|medium|high|xhigh|max` (default high; use
    `xhigh` for coding/agentic, `high` min for judgment work).
  - Handle `stop_reason: "refusal"` as a typed outcome (HTTP 200, empty or
    partial content) — routes to repair/fault, never parsed as payload.
    Check `stop_reason` BEFORE reading `content`.
  - Structured output: `output_config: {format: {type: "json_schema",
    schema: <our Wire_schema JSON>}}`.
  - Tools: `input_schema` tool declarations; parallel `tool_use` blocks are
    ALL answered in ONE user message of `tool_result` blocks.
  - `max_tokens`: from pin options, default 16000 (stream if >~16k — 128k
    ceiling requires streaming to dodge HTTP timeout).
  - Consider `betas: ["server-side-fallback-2026-06-01"]` +
    `fallbacks: [{"model": "claude-opus-4-8"}]` for refusal resilience
    (opt-in; recommended for Fable 5). OPEN: decide if v0 wants it.

**OpenAI Responses API** — `POST https://api.openai.com/v1/responses`
- Headers: `Authorization: Bearer $OPENAI_API_KEY`, `content-type: application/json`.
- Model: `gpt-5.6-terra` (1.05M context, 128k out, $2.50/$15 per 1M).
  Supports streaming, function calling, structured outputs.
- Structured output: `text.format` json_schema strict.
- Tools: function declarations; loop is `function_call` →
  `function_call_output` items.
- WIRE UNCERTAINTY: exact Responses request/response field paths were not
  verified against live docs this session. Keep the OpenAI encoder/decoder
  in one small module with wire shapes documented in comments; do NOT invent
  silently — verify against
  `https://platform.openai.com/docs/api-reference/responses` (or WebFetch)
  before trusting the field names.

## Effects ruling (operator, 2026-07-14)

**Go full OCaml 5 effects.** Overrides run.mli's "blocking in v0" posture
and the earlier stop-short reasoning; part of the motive is testing the
language itself before the substrate decision (OxCaml vs Rust — effects
are the one feature with no Rust analogue, so this port IS evidence for
the substrate ruling). Verified on the switch: perform/continue work, and
`discontinue` runs `Fun.protect` finalizers — squash-by-discontinue with
worktree cleanup is real. `Curl.Multi` is available for HTTP-as-an-effect.

Sequencing (ownership-driven, not timidity): a substrate agent builds
`lib/fiber` NOW in parallel with wave 1 (effect vocabulary as typed data,
Deep-handler scheduler, park/resume/squash, curl-multi HTTP effect,
falsifiers, and `docs/effects-evaluation.md` — the language-test report);
the wave-2 tail mounts chase dispatch + the agent loop on it after the
B-findings rewiring lands, so the port wraps the wired engine, not the
skeleton. The evaluation doc is a first-class deliverable: what effects
bought, every sharp edge (untyped effects, one-shot continuations,
Unhandled, OxCaml quirks), and what it implies for the Rust port trigger.

STATUS: INTEGRATION LANDED (effects-integration pass, 2026-07-14). The
chase runs every node as a fiber: `dispatch_node` spawns; the body binds
operands at its own `Fiber.read`s (the whole-instance parked list, its
requeue-everything on any retirement, and the resume re-read are
deleted); the substrate's read policy (`policy_read`) answers witnessed/
hypothesis or parks exactly the fiber on exactly the missing address;
`retire_success` wakes exactly the fibers parked on the addresses the
landing committed (`Fiber.wake` per committed head). Squash goes through
`Fiber.squash`/discontinue everywhere (`purge` carries the settlement's
cause to every live fiber of a dead node; `resolve_parked` discontinues
the starved read): worktree custody rides the body's `Fun.protect`, so a
mid-flight squash drops the store buffer before the squash returns and
the node cannot run further. Provider lanes take the transport as a
parameter (`Agent.Provider.post`: `blocking_post` default;
`Fiber.http_post` inside the engine — `bin/main.ml` passes it), so N
provider turns overlap on one domain; `Chase.create` gained
`?transport` (lazy curl-multi default; scripted in tests) and a trailing
`()`. The executor's yields perform `Fiber.Yield` in-engine (one
delivery representation — the chase's per-consumer closure — mounted at
spawn; `Executor.run`'s callback signature unchanged for direct
callers); a stop-cleanly disposition is now a discontinue, not a
convention. `run.mli`'s "Blocking in v0" comment amended per the
evaluation doc's recorded handoff; 40-scheduling § read-time binding and
60-agents (§ executor transport, § drift notes at yield) amended.
Falsifiers in test/test_mount.ml: FM1 (engine-level overlap under the
real Anthropic Messages encoder over a rigged-slow transport; completion
order, not submit order, decides turn order; replay coherent), FM2
(mid-flight squash end-to-end: hypothesis taken, squashed while the POST
is in flight, `Fun.protect` worktree drop observed on disk, abandoned
completion dropped, zero turns billed), FM3 (wake precision: one
suspension and one resumption per consumer, each on ITS producer's
landing), FM4 (stop-cleanly is a discontinue: a breaking-broad note at a
yield — the moved file provably read, in the same tool batch that
drafted it — ends the fiber at the yield; no further submit reaches the
transport, the worktree drops, the body match reissues bounded). The
pre-existing suite reproduced with ZERO expect diffs —
F1/F2/F4/F5 step counts and traces identical, which is the measured
confirmation that the blocking engine was the defunctionalized form of
this scheduler. Remaining on this front: nothing owed; mid-flight
patching (reconcile without reissue) stays the recorded convergence in
40-scheduling § drift routing.

## The plan — three phases

### Phase A — executor rebuild (executor layer only) — DONE, see "Where we are"

Owns: `lib/agent.mli`/`agent.ml`, new `lib/http`, `bin/main.ml` dispatch,
rigged-executor adaptation, `60-agents.md` doc-rule-4 amendment.

1. `lib/http.mli` + `http.ml` on ocurl. Signature roughly:
   `val post_json : headers:(string*string) list -> url:string ->
   body:string -> timeout_s:float -> (int * string, error) result`
   (status, body; typed transport error). No subprocesses. Add `ocurl` to
   `lib/dune` libraries and `dune-project` depends.
2. Refactor `agent.ml` into two layers:
   - **Provider layer** = ONE model turn: request (system, messages incl.
     tool results, tool decls, wire schema) → response (assistant content:
     text / tool calls, stop reason, usage). Three lanes behind one
     signature: Anthropic Messages, OpenAI Responses, Rigged (scripted
     provider turns — the existing `Rigged` steps become scripted turns so
     falsifiers still run offline).
   - **Agent layer** (shared across lanes — this is what kills the "chase.ml
     carries a divergent repair-lane copy" finding): the tool-execution
     loop, ledger event emission, grant enforcement, the repair lane
     (stateless-with-diagnostics, budget = initial + N repairs exactly as
     `agent.mli` documents), refusal recognition.
3. Harness-owned tool surface — the point of the rebuild: `read_file`,
   `write_file`, `str_replace_edit`, `glob_list`, `grep`, `run_command`.
   - Reads within grant `read_globs` + worktree; writes ONLY in worktree;
     out-of-grant → typed in-band tool error (`is_error` result), never
     silent no-op.
   - EVERY execution appends the matching `Ledger` event with footprint:
     Load (read/glob/grep), Store (write/edit, worktree net-delta ref),
     Effect (run_command, behind the mkdir-atomic holder-named machine lock;
     present in a speculative grant ONLY via the declared-idempotence
     witness — the grant types already encode this, respect them).
4. **Delete `claude_cli` entirely.** grep-gate: no subprocess / `Unix.exec`
   / `Sys.command` path to a model binary may remain. `bin/main.ml`
   dispatches runtime from `Pin.provider` ("anthropic"/"openai"/else →
   config error at bind time). Preserve `pure_fn` and `shell_gate` (those
   are for compiler-job executors, not LLM shell-outs — different thing,
   keep them).
5. Keep build + tests green. Adapt F-suites to the Provider/Agent factoring;
   where a test asserted the OLD divergent repair-lane behavior, fix it to
   the documented semantics (`agent.mli` is normative). Don't delete
   coverage.
6. Doc rule 4: amend `60-agents.md` where it names the claude-CLI executor →
   direct-API ruling + the mechanized-witness rationale. One paragraph.
7. Commit: "Executors: direct provider APIs + harness-owned tool loop".

INTERFACE NOTE: `Executor.reply = { text; usage }` currently returns only
text — that is the root of the whole witness wound. The tool loop moves
INSIDE the Agent layer, so the executor no longer returns bare text; the
Agent layer drives Provider turns and emits events. `Executor.t` and
`invoke` in `agent.mli` will change shape — that's expected and deliberate.

### Phase B — engine rewiring (the remaining findings)

The findings below are NOT executor problems; they are engine-integration
gaps. Several can't be tested correctly until Phase A's real tool events
exist, which is why B follows A. Group and fix in this order:

B1. **Codec boundary not called (BLOCKING).** `chase.ml` `parse_heads`
    checks only JSON well-formedness + cardinality; never validates against
    the admitted Wire_schema, never uses the relation's `Contract.Codec`,
    never resolves ref slots against mint provenance. Fix: route head
    parsing through `Contract.Codec.parse ~registry`, and make that codec's
    ref resolution real (it currently ignores `~registry` —
    `contract.ml:804`, `let _ = registry`). Retire must also re-judge refs
    against final state. (Findings at chase.ml:291/301, contract.ml:804.)
    Kills F10/F11 violations.
    STATUS: DONE (boundary-rewiring pass, 2026-07-14). `Contract.Codec`
    threads the registry into the decode for real (the `let _ = registry`
    deviation is deleted); new `Codec.by_schema` is the schema-driven
    boundary — shape, enum membership, array windows, and ref resolution
    against mint provenance in one walk of the admitted `Wire_schema.t`.
    `invoke_lane` parses head replies through `Codec.parse by_schema
    ~registry:t.registry`; the old `parse_heads`/`is_refusal` raw-JSON lane
    is deleted. Retire re-judges refs against final state: `try_retire`
    re-resolves every ref slot (dotted nested paths included) before
    `Retire.step` and routes a dangling ref to serialize-reissue —
    unreachable in the synchronous v0 engine (recorded-shape mechanism for
    when dispatch overlaps producers). Falsifiers in test_heads.ml ("B1:
    shape, enum membership, and ref resolution…" — invented refs,
    out-of-enum values, and stray fields all crossed and committed
    pre-fix).

B2. **No Store/Effect events (BLOCKING, mostly fixed by Phase A).** Verify
    after A that `Witness_index.writes` is non-empty, `conflict_judgment`
    can fire, the disjoint law can find offenders, F12's runtime half is
    live. `Ledger.Delta_ref` needs a public constructor
    (`retire.ml:450` finding). `Worktree.net_delta` currently returns `[]`
    — make it real.
    STATUS: `net_delta` DONE (commit-layer pass, 2026-07-14): pairs
    `changed_paths` with `Delta_ref.v` of the worktree-relative locator;
    deltas now flow through `Committed.advance` into
    `generation_moved.delta_ref`. The `pure_fn`/`shell_gate` eventing half
    remains (B15).

B3. **Channel delivery unwired (BLOCKING).** Engine never constructs an rx,
    never calls `Channel.invalidate`/`pull_invalidations`/`pull_tuples`;
    retirement never publishes committed head tuples (only seeds at
    chase.ml:931-932); every executor gets `~on_yield:(fun () -> [])`. Wire
    the delivery half: retire publishes, consumers pull, drift notes reach
    yields. (chase.ml:390.)
    STATUS: DONE (delivery/speculation pass, 2026-07-14). The chase opens
    the scheduler's channel ends at `create` (one packed tx per relation,
    one packed rx per consumer edge). `retire_success` publishes committed
    heads on the typed logs (new `Theory.Relation.payload_of_json` — the
    codec-proven payload re-enters through the relation's own codec, ids
    resolved against mint provenance) and fans each `Invalidation_sent` as
    a `Channel.invalidate` over every channel (edge footprints filter;
    subs on other relations legitimately subscribe to file globs and
    ref-target relations). Every dispatch gets a REAL `on_yield`
    (`on_yield_of`) closed over the instance's edge rx: it drains
    `pull_invalidations` at the fiber's suspension points, pulls landed
    tuples (`pull_tuples`) for the classification, appends the typed
    `Drift_note`, and returns notes whose dispositions derive from the
    route (`Speculate.Drift.disposition_of`). Falsifier: test_delivery.ml
    "delivery: the invalidation and the typed drift note reach the
    consumer's yield" (parked chain; buffered-socket delivery before the
    consumer ran). 50-commit.md § retirement order amended.

B4. **Seed payloads dropped (BLOCKING).** `seed_entry` sets `payload = None`,
    so agents never see seed data, `where` filters can't match seed fields,
    content hashes degrade to hashing the id, and `goat plan` never shows
    the planner the spec text. Also: seeds never enter `Committed.tuples`,
    so `judge_count` over a seeded relation is vacuously satisfied
    (retire.ml:801). Fix seed to carry payload and enter committed state.
    (chase.ml:933, retire.ml:801.)
    STATUS: DONE (boundary-rewiring pass, 2026-07-14). `tuple_entry.payload`
    is non-optional (the None sentinel is gone); seeds render through the
    relation's own codec (`Theory.Tuple.payload_json`), publish typed on
    the channel layer as before, and enter committed state at run open via
    the new `Retire.Committed.seed` (primordial generation, recorded
    content, NO write-log entry — no node wrote a seed; the id binds at
    once). Where-filters match seed fields, operand sections carry seed
    payloads, content hashes are real, and `judge_count`'s universe
    includes seeded referents. 70-api.md § running amended. Falsifiers in
    test_heads.ml ("B4: a seed's payload reaches the executor…", "B4:
    judge_count over a seeded relation…" — both failed pre-fix). Seed
    tuples now appear in `Run.settled.tuples`/committed prints; affected
    expectations promoted (test_engine, test_drift F9, test_admission,
    test_squash — whose F5 invariant checker now takes the seed keys as
    the declared no-provenance exemption).

B5. **Speculation is dead code.** Hypothesis arm of `read_operand`
    unreachable; confidence hardcoded 1.0; no store-buffer snooping;
    `Hypothesis_discharged` never emitted (so any hypothesis permanently
    blocks retirement → squashed as Dead_hypothesis even on exact-predicted
    landing); the hypothesis refresher has no implementation; `fire()`
    records `hypotheses = []`. Build the refresher: on producer landing,
    compare against hypothesis (identical → discharge silently; drift →
    Drift_note; squash → subtree squash). (chase.ml:243/518/800.)
    STATUS: DONE (delivery/speculation pass, 2026-07-14). Heads enter the
    body-match feed at their producer's COMPLETION as snoopable
    store-buffer entries (materialization — data-generated instances now
    start before the producer retires, per 40-scheduling § eager start),
    carrying producer, inherited hypotheses, chain confidence, and strata.
    `read_operand` takes a `Store_buffer` hypothesis on every uncommitted
    operand (default-on; the off switch and the confidence floor route to
    suspension instead), and the snooped read ALSO enters the observed
    witness ("chase.snoop" Load at the uncommitted generation — the
    content-judged triple is what makes F7 free). Chain confidence is the
    entry's chain product times `Speculate.Backstops.link_confidence`
    (0.93, the declared constant the floor's calibration assumes;
    per-shape measured links are the recorded upgrade — the predictor's
    raw survival is contaminated by in-flight lifecycles and must not be
    the link factor). The lifecycle is the sum-typed machine
    `Speculate.Lifecycle` (Taken → Discharged | Drifted{cls} | Squashed)
    with ONE landing judgment; the chase's refresher runs it at
    `retire_success`: identical landings discharge silently
    (`Hypothesis_discharged`, per consumer node); drifted landings note
    and route by the table; producer squash flows through the existing
    provenance walk (store-buffer sources are squash edges). `fire()` now
    records inherited hypotheses in provenance. Falsifiers:
    test_delivery.ml F7 (end-to-end free commit: no invalidation, no
    note, no reissue) and the landing-judgment unit block; F9's on/off
    equivalence now runs with 2 real hypotheses on the on side.
    40-scheduling § read-time binding amended (snoop = hypothesis +
    witness triple). The `Issued_contract` arm remains recorded-shape
    (reachable only when dispatch overlaps firing).

B6. **Drift routing table has no consumer.** Every `Witness_moved` rejection
    is routed serialize-reissue (full flush) without classifying the drift;
    the policy table exists as data but nothing reads it. Wire the
    classifier → route (schema-identical/additive/breaking-narrow/
    breaking-broad/squashed). (chase.ml:843.)
    STATUS: DONE (delivery/speculation pass, 2026-07-14). One classifier
    (`classify_move` in chase.ml) parses a moved address into the table's
    domain per consumer: a moved tuple operand diffs snooped-vs-landed
    payloads (`Speculate.Drift.payload_diff` — content drift in the same
    Diff vocabulary as schema drift, so `classify` judges both); a moved
    file is judged against everything the consumer's witness proves it
    read (majority → broad → flush; minority → narrow → reconcile); an
    address outside its reads is additive. Three consumption sites, one
    table: the refresher (landing), the yield delivery (invalidation →
    note), and the `Witness_moved` rejection at retire — each appends the
    typed `Drift_note` whose route replay re-judges against the table.
    v0 reconcile = reissue-with-diagnostics (no mid-flight patching yet);
    flush rows flush the subtree before the bounded refire.
    40-scheduling § drift routing amended (the three consumers named).
    Falsifiers: test_delivery.ml "drift table at the rejection site"
    (breaking-broad flush and breaking-narrow reissue, end to end,
    replay-coherent) plus the existing F8 unit roster.

B7. **Generation-zero / content-hash witness hole.** Fresh-address commits
    land at `Generation.zero` — the same generation `Witness.holds` assigns
    to never-committed state — and `holds` compares generations only,
    ignoring the content hash the triple carries. So a consumer that
    witnessed pre-commit state (snooped draft, or absence) at g0 retires
    cleanly even when the producer lands different content. Fix: `holds`
    must compare content hash, or fresh commits must not land at g0.
    (retire.ml:222, witness.ml:84.)
    STATUS: DONE (commit-layer pass, 2026-07-14): committed lookup is now
    the sum `Witness.Committed_state` (Absent | Landed{gen; content} |
    Deleted{gen}; absence a real case), `Retire.Committed` records landed
    content, and `holds` judges the content hash (law 3 amended in
    50-commit.md). Falsifiers in test_witness.ml ("law 3: ..."), file- and
    tuple-shaped. NOTE for B1/B15: agent tool loads still record
    `Generation.zero` in triples — harmless now (content is judged), but
    the generation lookup threading is still owed.

B8. **judge_disjoint is a tautology.** `Committed.advance` gives every write
    a fresh generation per address, so two distinct nodes can never share an
    (address, generation) pair — the Disjoint_writes law always returns
    satisfied, even in the clobber scenario. Fix generation assignment so
    same-generation concurrent writes to one address are detectable.
    (retire.ml:448/844.)
    STATUS: DONE (commit-layer pass, 2026-07-14): the write log is in base
    coordinates — each committed write carries the content its writer's
    witness proves it derived from (blind write = the absence case), so a
    clobber is pair equality and serialized writers cannot collide. Law
    statements sharpened in 50-commit.md § retirement order and
    10-theory.md (`law disjoint`). Falsifier: test_disjoint.ml (blind
    clobber violated; serialized rewrite satisfied).

B9. **feedback-is-forward inadmissible.** DONE (2026-07-14, admission-layer
    commit): generation strata implemented as data the cycle check consumes.
    `Theory.Relation.stratified ~generations` (and a `generations` field in
    the meta-catalog relation wire shape) declares the loop relation's
    bounded counter; every dep edge of a statement heading into a bounded
    relation is an `Advance` edge, excluded from the cycle graph (in
    unrolled (position, generation) coordinates it can never close a
    cycle); the chase carries per-derivation strata on `tuple_entry` and
    refuses the firing past the bound (quiescence, not a fault) — that
    runtime guard is what keeps F13's "admitted theories quiesce" true.
    `10-theory.md` § termination and § feedback-is-forward amended.
    Falsifiers in test_admission.ml: the canonical loop rejected bare,
    admitted with a stratum, quiesces on approval, and stops at the bound
    under an always-demanding reviewer.

B10. **Nested ref slots dropped.** DONE (2026-07-14, same commit):
     `slots_of_schema` now returns a total slot set — top-level fields as
     before, plus a Ref slot for every nested `Ref_id` named by its dotted
     payload path ("findings.[]", "detail.primary"); edges and channel
     footprint subscriptions pick them up (the falsifier consumes
     `Channel.footprint`, giving the B15 orphan its first caller). The v0
     filter/law grammar still resolves link/group_by against top-level
     slots only. Bonus admission audit fixes in the same commit: a payload
     field named `id` (mint-slot shadow), windows no firing plan satisfies
     (`0 nodes`, inverted/negative tuple ranges), and generation bounds
     below one are now typed admission errors.

B11. **Telemetry/predictor event starvation.** No code appends the lifecycle
     Decision actions (queued/admitted/suspended/resumed) or `Pin_bump`, so
     blocked/queued timings are always 0, port queues/scoreboard always
     empty, a binding token ceiling is silent, `Predictor.survival` always
     None, and `Speculate.Churn.measure` (needs queued_s > 0 and samples > 0)
     can never produce a Switch. Also `Report.shapes_of` double-prefixes
     executor ids ("fn:agent:refuter") so per-shape counters never match
     Pin_bump strings. Emit the events; fix the id reconstruction.
     (ledger.ml:380, report.ml:54/329.)
     READER HALF LANDED (event-log agent, 2026-07-14): the Decision action
     vocabulary is a sum (`Ledger.Decision`: Queued/Admitted carrying the
     port, Dispatched, Suspended, Resumed, Serialize_reissue,
     Flush_subtree, Abort_suspended, Ceiling_bound), `Drift_note` carries
     typed `Ledger.Drift.cls`/`route` (Speculate.Drift's tag/Route now ARE
     these types), and `Pin_bump`/`Switch_thrown` carry typed
     `Theory.Statement.id`/`Executor.id` — the shapes_of double-prefix is
     unrepresentable and the string-normalizing replay parser is deleted.
     Readers (Telemetry.timing, Predictor_history, Report, Run.replay's
     drift audit) verified against hand-built streams in
     `test/test_report.ml`. REMAINING for the chase phase: EMIT the
     lifecycle constructors (Queued/Admitted/Dispatched/Suspended/Resumed),
     Ceiling_bound at the binding admission, and each shape's initial
     `Pin_bump` at run open.
     EMISSION HALF DONE (delivery/speculation pass, 2026-07-14): the chase
     appends `Queued{port}` at fire, `Admitted{port}` at port admission,
     `Dispatched` when operands bind, `Suspended` at the park,
     `Resumed` + `Queued` at the resume (a resumed instance re-enters as
     `Resumed_witnessed` ONLY when every operand now reads committed —
     the B15 ceiling-gate fix); `Ceiling_bound` is announced once per
     binding episode, run-level, with token_ceiling/run_tokens/
     undischarged counters; `create` appends each shape's initial
     `Pin_bump`. Telemetry's phase machine, port queues, and the
     predictor history now measure real spans (F9's churn evidence and
     the delivery falsifier's suspended→resumed walk exercise them).
     Falsifier: test_delivery.ml "the token ceiling binds" (deflection,
     announcement with numbers, admission after discharge).
     test_report.ml's reader pins unchanged and green.

B12. **`Tuple_cell` Obj.t erasure is unsound through the public API
     (MAJOR).** Channel lookup is keyed by relation NAME only; `Relation.v`
     is a free public constructor; nothing ties a registry to the admitted
     theory. So a tx at the wrong payload type is constructible → publish/
     pull_tuples is an unchecked cast (segfault/heap corruption). The
     justifying comment ("OCaml offers no way…") is FALSE — a `Type.Id`/GADT
     witness on `Relation.t` makes the wrong-type read unconstructible per
     doc rule 8. Fix with a type witness, don't ship the Obj cast.
     (channel.ml:99/101.)
     LANDED (channel agent, 2026-07-14): `Theory.Relation.t` carries a
     `Type.Id` payload witness minted at declaration
     (`Theory.Relation.witness`); each channel's log is packed with the
     admitted relation's witness at `open_all`, and `Channel.tx`/`rx`
     recover the payload type via `Type.Id.provably_equal` against the
     presented relation — `Tuple_cell`/`Obj` deleted, no cast remains in
     lib/. A same-named re-declaration is refused at the lookup
     (runtime falsifier in test_boundary.ml); the cross-type publish is a
     negative compile (probe_f15_wrong_payload_publish.ml). Docs:
     30-channels.md § pre-opened channels, 80-validation.md F15 roster.

B13. **Cardinality windows enforced as count, not shape.** `invoke_lane`
     hands the agent the bare single-tuple schema for Tuples windows, then
     count-checks — instead of the array-with-minItems/maxItems contract the
     docs mandate ("the bound is shape… illegal payload unwritable at the
     decode boundary"). An agent that complies with the schema it was shown
     fails the parse. Fix: derive the array-window schema and hand THAT.
     (chase.ml:375.)
     STATUS: DONE (boundary-rewiring pass, 2026-07-14). `invoke_lane`
     lowers the window into the head schema (`window_schema`: a Tuples
     window becomes the array root with the window as minItems/maxItems)
     and the SAME value is handed to the invocation (prompt + structured
     output) and parsed against (`Codec.by_schema`) — the bound is
     unwritable at the decode boundary; the count check is deleted. Nodes
     windows keep the bare tuple schema. `goat plan`'s bootstrap statement
     moved from `exactly 1` to `nodes 1` (one theory per spec is a firing
     count; the one-element-array coordinate was an artifact).
     10-theory.md § statement grammar enforcement plan amended. Falsifiers
     in test_heads.ml ("B13: a tuples window is handed as the array
     schema…" — captured a bare object schema pre-fix; "B13: a reply
     outside the window dies at the decode boundary").

B14. **Provenance not total for Tuples-window heads.** `fire()` records
     `Fired{minted=[]}` for Window.Tuples; the existentials minted later in
     `parse_heads` are never evented, so the ledger has no record of which
     firing produced those tuples (breaks squash, dep-order, replay).
     (chase.ml:704.)
     STATUS: DONE (boundary-rewiring pass, 2026-07-14). One route to a
     head-relation id: `record_firing` mints AND appends the `Fired`
     event carrying the mint, so an uneventedly-minted head id is not
     writable. Nodes windows mint through it at fire time; tuple windows
     mint through it at the boundary parse when the data-generated width
     exists (their fire-time record carries `minted=[]` and remains the
     issue-order trace F1/F2 judge; `instance` carries its provenance so
     the late record appends under the same firing). All Fired readers
     (squash walk, dependency order, replay, report) already fold over
     every firing record per node. Falsifier: the B14 half of the window
     test in test_heads.ml ("every committed head traces to its firing" —
     false pre-fix).

B15. **Minor cleanups (do last, batch):** port admission runs the survival
     comparator on non-hypothesis eager starts, breaking FIFO-within-class
     (chase.ml:473); engine reads of uncommitted tuples return Witnessed but
     aren't logged as Load (F6 gap, chase.ml:530); `retire_success` promotes
     every parked instance to Resumed_witnessed regardless of witnessed
     status, bypassing the token-ceiling gate (chase.ml:750); squash cause
     chains mislabel reissue-losers and starved reads as Operator_abort —
     the sum type is missing the reissue/no-producer cases (chase.ml:766/767);
     dead-hypothesis squash drops only the rejected node's worktree, orphaning
     dependents' on-disk state (chase.ml:818); footprint escapes never
     detected/surfaced — `Channel.footprint` has zero callers
     (channel.ml:268); `70-api.md` declaration example doesn't match the
     implemented surface (70-api.md:36) — DONE in the boundary-rewiring
     pass (rewritten to the real constructors: `Theory.Relation.v ~name`,
     `Contract.v`, `Spawn.v … ()`, `Law.Count`); effect-grant lane unreachable /
     declared-idempotence why never evented (agent.mli:41 — should mostly
     resolve via Phase A).
     STATUS (delivery/speculation pass, 2026-07-14): mostly done.
     - FIFO-within-class: the survival comparator now runs only when BOTH
       candidates are hypothesis-carrying (an uncommitted operand at
       queue time); witnessed eager starts keep FIFO. DONE.
     - F6 gap: uncommitted operand reads are hypotheses AND logged as
       "chase.snoop" Loads at the uncommitted generation (see B5). DONE.
     - `retire_success` promotion: resumed instances re-enter as
       `Resumed_witnessed` only with fully-committed operands; anything
       still speculative rides `Eager_or_speculative` and the ceiling
       gate holds. DONE (exercised by the ceiling falsifier).
     - Squash causes: `Ledger.Squash_cause` gained `Reissue_loser` and
       `No_producer`; `abandon` takes an explicit cause (conflict losers
       and moved-witness reconciles are reissue-losers; the refresher's
       flush uses `Dead_hypothesis`; `resolve_parked` uses
       `No_producer`); dependents of an abandoned attempt squash as
       `Upstream_squash` with their worktrees dropped and their pending
       hypotheses/feed entries cleaned (`drop_speculative_state`).
       40-scheduling § settlement amended. Falsifier: test_delivery.ml
       "squash causes: a conflict loser is a reissue-loser". NOTE:
       `No_producer` is emitted at `resolve_parked` but is not
       constructible end-to-end in the synchronous engine (every parked
       read's producer either lands or squashes it first) — the stall
       resolver is the recorded backstop.
     - Dead-hypothesis squash: the whole doomed subtree's worktrees drop
       (`queued_worktrees` at every squash path), not just the rejected
       node's. DONE.
     - Footprint escapes (`Channel.footprint`'s runtime half): DONE
       (wave-2 finisher pass, 2026-07-14). `Channel.covers` is the
       exposed cover judgment (the same one delivery uses); the chase
       judges every observed Load against the edge's compiled filter at
       `retire_success` and appends `Ledger.Event.Footprint_escape`
       (one per escaped address, tool named); `Chase.judge` folds the
       events into a violated `footprint_cover` verdict on the settled
       map (only a violation lands — no declared law exists to report
       satisfied); `Report.explain`'s story carries the per-node escape
       list. Loads only, per 30-channels.md § footprint filtering (a
       store is the node's own work product; write overlaps are the
       disjoint law's domain). Falsifier F16 in test_delivery.ml
       ("footprint escape: an uncovered load surfaces at retire…" —
       escapee retires, covered sibling surfaces nothing). The
       constructible v0 escape is a worktree read outside `read_globs`
       (the worktree is a committed-tree checkout, so any committed file
       is readable through it regardless of the declaration).

### Phase C — tests + live smoke

- New falsifiers for the now-real tool-event laws (Load/Store/Effect emitted
  with correct footprints; witness assembled from observed events;
  conflict/disjoint can fire).
- Full `dune test` green.
- Live smoke test of BOTH provider lanes against real APIs (needs the two
  API keys). This is the first time the design meets a real model — expect
  to learn things the rigged executors couldn't show.
- Then the benchmark corpus question (`80-validation.md` OPEN) for the ≥1.5×
  headline claim — separate, later.

## Failure this session (why we're resuming)

A `fork` subagent launched for Phase A explored for ~650k tokens and returned
a PLAN narrated as if it had delegated to a further fork — but executed
nothing. No `lib/` code changed. Lesson for the resume: for the executor
rebuild, either drive it inline or launch a NON-fork agent with an
execute-only mandate and verify disk state (`git status`, `ls lib/http.*`,
`grep claude_cli`) before trusting any completion report.
