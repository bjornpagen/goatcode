# Executor Campaign — Work Plan (NON-NORMATIVE, delete when done)

This is a resumption tracker, not an architecture doc. The architecture docs
(`docs/architecture/`) are present-tense and normative; this file records
in-flight work and is deleted when the campaign lands. If this file and the
architecture docs disagree, the architecture docs win.

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

B2. **No Store/Effect events (BLOCKING, mostly fixed by Phase A).** Verify
    after A that `Witness_index.writes` is non-empty, `conflict_judgment`
    can fire, the disjoint law can find offenders, F12's runtime half is
    live. `Ledger.Delta_ref` needs a public constructor
    (`retire.ml:450` finding). `Worktree.net_delta` currently returns `[]`
    — make it real.

B3. **Channel delivery unwired (BLOCKING).** Engine never constructs an rx,
    never calls `Channel.invalidate`/`pull_invalidations`/`pull_tuples`;
    retirement never publishes committed head tuples (only seeds at
    chase.ml:931-932); every executor gets `~on_yield:(fun () -> [])`. Wire
    the delivery half: retire publishes, consumers pull, drift notes reach
    yields. (chase.ml:390.)

B4. **Seed payloads dropped (BLOCKING).** `seed_entry` sets `payload = None`,
    so agents never see seed data, `where` filters can't match seed fields,
    content hashes degrade to hashing the id, and `goat plan` never shows
    the planner the spec text. Also: seeds never enter `Committed.tuples`,
    so `judge_count` over a seeded relation is vacuously satisfied
    (retire.ml:801). Fix seed to carry payload and enter committed state.
    (chase.ml:933, retire.ml:801.)

B5. **Speculation is dead code.** Hypothesis arm of `read_operand`
    unreachable; confidence hardcoded 1.0; no store-buffer snooping;
    `Hypothesis_discharged` never emitted (so any hypothesis permanently
    blocks retirement → squashed as Dead_hypothesis even on exact-predicted
    landing); the hypothesis refresher has no implementation; `fire()`
    records `hypotheses = []`. Build the refresher: on producer landing,
    compare against hypothesis (identical → discharge silently; drift →
    Drift_note; squash → subtree squash). (chase.ml:243/518/800.)

B6. **Drift routing table has no consumer.** Every `Witness_moved` rejection
    is routed serialize-reissue (full flush) without classifying the drift;
    the policy table exists as data but nothing reads it. Wire the
    classifier → route (schema-identical/additive/breaking-narrow/
    breaking-broad/squashed). (chase.ml:843.)

B7. **Generation-zero / content-hash witness hole.** Fresh-address commits
    land at `Generation.zero` — the same generation `Witness.holds` assigns
    to never-committed state — and `holds` compares generations only,
    ignoring the content hash the triple carries. So a consumer that
    witnessed pre-commit state (snooped draft, or absence) at g0 retires
    cleanly even when the producer lands different content. Fix: `holds`
    must compare content hash, or fresh commits must not land at g0.
    (retire.ml:222, witness.ml:84.)

B8. **judge_disjoint is a tautology.** `Committed.advance` gives every write
    a fresh generation per address, so two distinct nodes can never share an
    (address, generation) pair — the Disjoint_writes law always returns
    satisfied, even in the clobber scenario. Fix generation assignment so
    same-generation concurrent writes to one address are detectable.
    (retire.ml:448/844.)

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

B12. **`Tuple_cell` Obj.t erasure is unsound through the public API
     (MAJOR).** Channel lookup is keyed by relation NAME only; `Relation.v`
     is a free public constructor; nothing ties a registry to the admitted
     theory. So a tx at the wrong payload type is constructible → publish/
     pull_tuples is an unchecked cast (segfault/heap corruption). The
     justifying comment ("OCaml offers no way…") is FALSE — a `Type.Id`/GADT
     witness on `Relation.t` makes the wrong-type read unconstructible per
     doc rule 8. Fix with a type witness, don't ship the Obj cast.
     (channel.ml:99/101.)

B13. **Cardinality windows enforced as count, not shape.** `invoke_lane`
     hands the agent the bare single-tuple schema for Tuples windows, then
     count-checks — instead of the array-with-minItems/maxItems contract the
     docs mandate ("the bound is shape… illegal payload unwritable at the
     decode boundary"). An agent that complies with the schema it was shown
     fails the parse. Fix: derive the array-window schema and hand THAT.
     (chase.ml:375.)

B14. **Provenance not total for Tuples-window heads.** `fire()` records
     `Fired{minted=[]}` for Window.Tuples; the existentials minted later in
     `parse_heads` are never evented, so the ledger has no record of which
     firing produced those tuples (breaks squash, dep-order, replay).
     (chase.ml:704.)

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
     implemented surface (70-api.md:36); effect-grant lane unreachable /
     declared-idempotence why never evented (agent.mli:41 — should mostly
     resolve via Phase A).

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
