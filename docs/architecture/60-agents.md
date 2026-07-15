# 60 — Agents

The execution units. An executor is what a spawn statement's `by` clause
names: an **agent template** (the common case), a **pure function** (host
OCaml, for mechanical transforms), or a **shell gate** (a build/test command
whose exit status and output become tuples). This doc owns the agent case;
the other two exist so the theory never invokes an LLM to do a compiler's
job. Readers: the `Agent` module; prompt-assembly; `20-contracts.md` (whose
derived artifacts are consumed here).

## Prompt assembly: derived, never authored

**A node's prompt is assembled from derived parts; a hand-authored per-node
prompt is a bug.** The parts, in order:

1. **The template preamble** — the agent template's role text (refuter,
   implementer, summarizer), the one hand-written artifact, owned by the
   theory author, versioned with the theory. It states stance and method,
   never shape.
2. **The contract section** — rendered from the catalog entry: the derived
   prose (doc comments), the wire schema as reference text, and the
   output-shape instruction. The decoder's schema and the prompt's reference
   text derive from the same declaration — one supply (`20-contracts.md`).
3. **The operand section** — the body tuples the node fired on, rendered by
   the codec's printer; for speculative nodes, the hypothesis tuples,
   *explicitly marked as speculative* with the confidence and the
   what-happens-on-drift contract (the agent is told it may receive drift
   notes at yield points and what to do with them).
4. **The footprint grant** — which paths are readable, which are writable
   (its worktree), which tools are granted (effect-capable tools appear only
   with declared-idempotent stamps for speculative nodes —
   `30-channels.md`).
5. **The settlement instruction** — the node's final message is its head
   tuples (structured output against the wire schema), not prose for a
   human. Reports for humans are tuples too (a `summary` relation), so the
   settlement instruction never wavers.

## The primary lane: freeform, then validate, then repair

**Agents generate freeform against a strong model; the contract constrains
at the boundary, never at the decoder.** The reply parses through the
derived codec; parse or schema failure enters the **repair loop**: the same
agent is re-invoked stateless-with-diagnostics — its own invalid output plus
the validator's specific complaints — with a bounded repair budget
(configured per template, small). Repair exhaustion faults the node; faults
route to the scheduler like any settlement (`40-scheduling.md`).

**Decision.** **Alternative:** grammar-constrained decoding on the primary
lane (force the output shape at the token sampler) — lost on the ruling
this design inherits and re-affirms: hard decode-time constraint runs on
constrained paths (provider-specific, weaker sampling, no reasoning
interleave) and buys shape at the cost of quality exactly where quality is
the product; freeform + mechanical validation + diagnostic repair gets the
same guarantee (nothing invalid passes the boundary) while letting the model
work at full strength. The repair loop is the same machinery reconcile uses
(`50-commit.md` § the repair lane), so the lane is paid for once.
**Reverses if:** measured repair-loop exhaustion rates on some (template,
model-pin) pair exceed the constrained lane's measured quality tax on the
same pair — per pair, never globally.

**The fallback lane.** Constrained decoding survives as the *refusal lane*:
when a model refuses or meta-comments instead of producing tuples
(recognized by the codec as a non-parse with refusal markers), the retry
routes to a constrained-decode call whose grammar is derived from the same
schema. Rare, mechanical, and it keeps the primary lane honest about what it
is: a quality choice, not a capability boundary.

## Tool grants and the effect gate

A node's tools are its footprint grant made operational: reads within
granted globs, writes within its worktree, the shell gates the template
declares. **The grant is a type indexed by speculation status, and the
forbidden combination has no constructor**: effect-capable tools enter a
grant only through a declared-idempotence witness on the template, and the
speculative grant type simply lacks the case for non-idempotent effects —
so "a speculative node ran a non-idempotent effect" is not a policy
violation the dispatcher catches, it is a grant nobody can build
(`30-channels.md` § event taxonomy owns the taxonomy; F12/F15 in
`80-validation.md` assert the unconstructibility). An agent requesting an
action outside its grant gets a typed refusal in-band (a tool error it can
read), never a silent no-op — agents route around obstacles they can see;
the refusal is the runtime *edge* of a boundary whose interior is
compile-time.

A shell gate runs under the same event discipline as any effect: behind
the mkdir-atomic, holder-named machine lock, with an `Effect` event
carrying the declared command line as the resource — a gate is never an
unobserved effect lane. Its idempotence is the declaration's: a gate is a
build/test command the engine may freely reissue, which is why gates are
grantable under either speculation index.

**The v0 grant surface, recorded honestly.** The chase derives a node's
grant from its template: `read_globs` from the declaration, the worktree
root from dispatch, the declared command line for shell-gate executors.
Two fields are hard-coded empty. `effects` is empty because no template
surface declares effect tools yet — `run_command` is unreachable through
a theory, so F12's runtime half is held by the grant's type index plus
direct-drive falsifiers; effect grants await the template-declaration
surface. `snoop_mounts` is empty and gets no wiring: it dies in the
flat-org migration (`91-flat-org.md` § grants and sensing — everything
in-grant is snoopable and the resolver consults the frontier, not a mount
table), and in-engine snooping already rides the body-match feed. Neither
absence is a capability the docs claim and the engine lacks; both are
recorded here so nobody builds soon-dead wiring.

## The git ban

**Workers never run git.** (Operator ruling: "ban all git commands from
any of the workers.") Git is the harness's commit substrate —
`Retire.Committed` holds the only writer lock on the committed branch,
worktrees are the engine's store buffers, squash is a worktree drop — so
a worker running git is three violations in one act: an unwitnessed
effect (its loads and stores bypass the evented tool loop, breaking the
mechanized-witness law), revert machinery (abort is by construction,
never compensation), and branch machinery (the commit topology is the
engine's own representation). One law, two boundaries:

- **The tool boundary.** `run_command` refuses any command whose token
  stream names git in command position — argv0; after `&&`/`||`/`;`/`|`/
  `&`, subshell and substitution opens, and backticks; leading
  assignments and wrapper commands transparent; one layer of quoting
  stripped; basenames compared — with the typed in-band refusal ("git is
  the harness's commit substrate; workers never touch it") and no
  `Effect` event. The ban is named in the tool's own description, so an
  agent sees the wall before it walks into it.
- **The admission boundary.** Shell-gate command lines are data in the
  theory, so a gate whose argv[0] resolves to git is a typed admission
  error naming the offending statement (`Theory.Admission.Git_gate`) — a
  git gate is unwritable, not refused at dispatch.

**Honesty note:** the v0 token screen is a tripwire, not a security
boundary — `sh -c "git ..."`, `$PATH` games, and a script that itself
calls git all pass it. The recorded growth path is environmental: PATH
control and a sandbox that denies the git binary to worker subprocesses.
The screen exists so an agent cannot drift into git by habit, and so the
falsifiers (F17 in `80-validation.md`) have a boundary to kill.

## The executor transport

**Both lanes are direct API calls from the harness process — never a CLI
shell-out.** (Ruling.) This is an architectural necessity, not taste: the
harness owns the tool loop, so every load, store, and effect an agent
performs is executed by the harness and appended to the ledger with its
footprint. A CLI session runs its own tools invisibly, which makes the
mechanized-witness law (`30-channels.md` § mechanized witnesses)
unimplementable through one — memory disambiguation, conflict detection,
and the disjoint-writes law all read the witness index those events build.
Recorded when the executor layer moved from a `claude`-CLI shell-out to
direct Messages/Responses calls; the rigged lane sits behind the same tool
loop, so falsifiers exercise the one boundary the live lanes use.

**The transport is a parameter of the constructed lane, never a global
flag.** Each provider value carries its POST (`Agent.Provider.post`): the
blocking lane (`blocking_post`, over `Http.post_json`) stands for callers
outside any fiber scheduler; inside the engine — where every node is a
fiber — the lanes post through `Fiber.http_post`, and the POST becomes the
suspension the scheduler overlaps: N provider turns simultaneously in
flight on one domain (falsifier FM1 proves the overlap through the engine
with the real Messages encoder over a rigged transport). The rigged lane
performs nothing — scripted turns construct no request.

**Transport noise is absorbed inside the lane; provider outcomes are
typed.** A transient transport failure — HTTP 429/5xx or a curl timeout —
retries bounded inside the provider lane with exponential backoff (three
attempts): transport, not work, so no ledger event is owed and the repair
budget is untouched; an exhausted envelope faults with the attempt count
named in the message. A truncated reply (Anthropic
`stop_reason: "max_tokens"`, OpenAI `incomplete`/`max_output_tokens`) is a
typed truncation outcome that faults IMMEDIATELY with
raise-the-pin-option guidance — an identical retry truncates identically,
so truncation never enters the repair loop. And the structured-output
format each lane sends is the admitted schema LOWERED to the provider's
documented json_schema subset (ref formats fold into descriptions; array
windows stay; OpenAI's format rides `strict: false` — admitted schemas
carry optional fields, which strict mode forbids; the strict-mode
lowering, optional to required-plus-nullable, is the recorded growth
path): one supply, two renderings — the prompt keeps the full schema and
the codec still judges refs and windows at the decode boundary.
Falsifiers in `test_boundary.ml` (rigged posts counting attempts).

**Decision.** The layer's shapes were audited against the Vercel AI SDK's
agent abstractions (`ToolLoopAgent`, `tool()`, `stopWhen`, the
`LanguageModel` provider spec, middleware, mock models) — the closest
widely-deployed design for this exact layer. Adopted, re-expressed
representationally (README rule 8): tools are first-class values in a
table derived from the grant, so capability *is* the table and an
ungranted action has no entry to dispatch to; loop bounds are data
(`Agent.Stop`, a per-pin step ceiling by default, exhaustion faulting as
`Context_exhausted`); the offline lane is a scripted provider behind the
same interface (their mock-model pattern, which validates the falsifier
discipline). **Alternatives lost:** per-step model/tool switching
(`prepareStep`) — conflicts with § model pins: routing is a theory
decision, and per-call switching corrupts per-pin predictor history; a
composable middleware stack (`wrapLanguageModel`) — the pin record plus
two named lanes is the entire abstraction, permanently (see the OPEN-item
resolution below); execute-less "done-tool" termination — settlement is
structured output against the wire schema, never a sentinel tool call.
**Reverses if:** a third provider lane forces shared request-transform
logic (the middleware trigger), or live smoke shows
structured-output-plus-tools needs a forced-tool settlement lane.

## Drift notes at yield

Between tool calls, a speculative node may receive **drift notes** —
compact renderings of invalidations that passed its footprint filter
(`30-channels.md` § check-on-yield): the address, the diff class, the schema
diff or delta summary. The note ends with the routing the scheduler already
decided (continue / patch-then-continue / stop-cleanly), so the agent never
guesses its own fate. A stop-cleanly note is the humane form of squash for
an agent mid-turn: finish no further work, emit nothing; the worktree drop
does the rest.

Delivery has one representation — the node's `unit -> Drift.note list`
closure, built by the chase over the consumer's channel end — and two
mounts. Inside the engine the executor's yield performs the fiber's
`Yield` instruction and the handler runs that closure; a stop-cleanly
disposition there is not a convention the executor honors but a
discontinue it cannot escape (the fiber settles with the note; nothing
further runs; finalizers drop the worktree). Where tests drive an
executor directly, `Executor.run`'s `on_yield` callback takes the same
closure and the loop's stop-cleanly discipline stands as written above.

## Model pins and provider routing

**Every template pins its model; pins move deliberately, never implicitly.**
A pin is (provider, model id, sampling config, prompt-affecting options),
recorded in the theory. A pin bump is a first-class ledger event and resets
the shape's predictor counters (survival history is per pin — a new model is
a new speculation regime; regime honesty, `README.md` rule 6).

**Two providers are wired, and routing between them is the planner's
decision, made per template at theory-emission time.** The planner template
itself pins the strongest available model (Claude Fable 5). For worker
templates the planner chooses by the intelligence the shape requires:

- **`anthropic` / Fable 5** — shapes where judgment is the product: design,
  integration and adjudication, repair, adversarial review, anything
  navigating ambiguity or a long horizon.
- **`openai` / GPT-5.6 Terra** — shapes that are mechanical against a tight
  contract: structured extraction, summarization into a fixed schema,
  formatting, low-ambiguity finders — work where the contract does the
  thinking and the model fills the shape, at roughly a quarter of the
  input cost.

**Routing is a theory decision, never a per-call auto-router.** The chosen
pin is data in the emitted theory — auditable at admission, stable for the
run, and accountable to the predictor: counters are keyed per (shape, pin),
so a mis-routed shape surfaces as measured survival and repair-rate deltas,
and the correction is a recorded pin bump on the next theory, not a silent
runtime switch. The planner's meta-catalog carries the routing guidance as
part of the template contract, so the planner justifies each pin the way it
justifies any other emitted value. **Decision.** **Alternative:** a runtime
auto-router (classify each firing's difficulty, pick the model per call) —
lost because it makes the executor identity unpredictable within a shape,
which corrupts the predictor's per-pin history, defeats regime honesty
(which model produced this outcome?), and moves a judgment the planner is
best placed to make into a heuristic nobody audits. **Reverses if:**
measured per-shape difficulty variance is so bimodal that one pin per shape
visibly wastes money or intelligence — the recorded path is then splitting
the *statement* into two shapes at planning time, not routing at runtime. **Decision.** **Alternative:** auto-upgrade to the
provider's latest — lost because the predictor's history silently stops
describing the executor generating the outcomes, corrupting port priority
and the churn detector's evidence — the harness would be measuring one
machine and scheduling another. **Reverses if:** never for silent upgrades; a
*supervised* upgrade lane (shadow-run the new pin on completed shapes,
compare, then bump) is the recorded growth path.

## The planner

The planner is an agent template like any other, distinguished only by its
contract: its head tuples are a **theory** (relations, statements,
templates, pins — the meta-catalog is just more catalog). The operator can
also write theories by hand (`70-api.md`); the planner exists so "here's a
spec, build it" is one invocation. Planner outputs pass the same admission
judgment as hand-written theories (weak acyclicity, acceptance gate, schema
lint) — **the planner earns no trust the operator doesn't have.** A rejected
theory returns to the planner with admission diagnostics in the
repair-lane shape — stateless-with-diagnostics: its original operand,
its own invalid emission, the complaints — bounded to ONE re-invocation,
run as a second planning run (run-granular rather than a
`Repair_attempt` inside the first turn, because admission is judged
after the bootstrap run settles: the head boundary proves shape, never
theory semantics); a second rejection is the typed failure
(`bin/main.ml`, `70-api.md` § the CLI). Reader: admission
(`10-theory.md`), which sees no difference; the falsifier suite, which
fuzzes admission with planner-shaped garbage (`80-validation.md`).

## OPEN items

- **Template library.** Refuter, implementer, summarizer, finder templates
  will repeat across theories verbatim. Same trigger as theory composition
  (`10-theory.md`): the second real pipeline that hand-copies them.
- **Context budget management for long nodes.** A node whose agent
  approaches its context ceiling mid-work has no story yet beyond faulting.
  Candidate: a declared checkpoint contract (the node emits partial head
  tuples and a continuation tuple; the chase fires a successor). *Trigger:
  the first fault attributed to context exhaustion in a real pipeline.*
- **Provider abstraction** — CLOSED: the trigger fired (OpenAI is the second
  provider). The resolution is § model pins and provider routing above: two
  named lanes behind the pin record, planner-owned routing, and still no
  general middleware layer — the pin's `provider` field plus one runtime per
  lane is the entire abstraction, permanently.
