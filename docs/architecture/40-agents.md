# 40 — Agents & Supervision

The judgment hierarchy: the **execution units** (agents, pure functions,
shell gates — what a spawn statement's `by` clause names), the **planner**
(the agent that emits theories), and the **supervisor** (the standing
session that watches a run and steers it). Three roles, one runtime (the
same tool loop, grant boundary, and eventing path), three different
relationships to the theory. Readers: the `Agent` module; prompt assembly;
the `Supervisor` module (doc-resident until its trigger — § the module);
`10-theory.md` (whose derived artifacts are consumed here).

# Execution units

An executor is an **agent template** (the common case), a **pure function**
(host OCaml, for mechanical transforms), or a **shell gate** (a build/test
command whose exit status and output become tuples). This part owns the
agent case; the other two exist so the theory never invokes an LLM to do a
compiler's job.

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
   text derive from the same declaration — one supply (`10-theory.md`).
3. **The operand section** — the body tuples the node fired on, rendered by
   the codec's printer; for speculative nodes, the hypothesis tuples,
   *explicitly marked as speculative* with the confidence and the
   what-happens-on-drift contract (the agent is told it may receive drift
   notes at yield points and what to do with them).
4. **The footprint grant** — which paths are readable (and therefore
   snoopable — `20-medium.md` § ambient sensing), which are writable
   (`write_globs`), which tools are granted (effect-capable tools appear
   only with declared-idempotent stamps for speculative nodes).
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
route to the scheduler like any settlement (`30-scheduling.md`).

**Decision.** **Alternative:** grammar-constrained decoding on the primary
lane (force the output shape at the token sampler) — lost on the ruling
this design inherits and re-affirms: hard decode-time constraint runs on
constrained paths (provider-specific, weaker sampling, no reasoning
interleave) and buys shape at the cost of quality exactly where quality is
the product; freeform + mechanical validation + diagnostic repair gets the
same guarantee (nothing invalid passes the boundary) while letting the model
work at full strength. The repair loop is the same machinery reconcile uses
(`30-scheduling.md` § the repair lane), so the lane is paid for once.
**Reverses if:** measured repair-loop exhaustion rates on some (template,
model-pin) pair exceed the constrained lane's measured quality tax on the
same pair — per pair, never globally.

**The fallback lane.** Constrained decoding survives as the *refusal lane*:
when a model refuses or meta-comments instead of producing tuples
(recognized by the codec as a non-parse with refusal markers, or typed by
the provider), the retry routes — once, without burning repair budget —
to the invocation's `?fallback` executor (`Agent.invoke`'s routing, built
and falsified). The constrained-decode executor itself — a grammar
derived from the same schema — is OPEN, unbuilt: v0 binds no fallback
(`bin/main.ml` sets `fallback = None`), so a refusal today re-enters the
repair loop like any non-parse. *Trigger: live-smoke refusal rates on any
(template, pin) pair, or the first repair exhaustion whose attempts are
all refusals.* When built it keeps the primary lane honest about what it
is: a quality choice, not a capability boundary.

## Tool grants and the effect gate

A node's tools are its footprint grant made operational. Under the flat org
the grant is:

```ocaml
(* lib/agent.mli — Grant.t. write_globs is the load-bearing boundary that
   replaced the private worktree root. Readers: Toolset.of_grant (the
   capability table), Grant.describe (the prompt's footprint section), the
   disjoint law's attribution story. *)
type 'status t = {
  read_globs : string list;   (** Ambient visibility: readable, snoopable. *)
  write_globs : string list;  (** Where this node's stores may land. *)
  shell_gates : string list list;
  effects : 'status Effect_tool.t list;
}
```

**Capability is the table.** `Toolset.of_grant` derives the tool values
from the grant; an ungranted action has no entry to dispatch to, so there
is no runtime permission check to forget. A store path outside
`write_globs` fails the `Relpath` parse at the argument boundary and
returns the typed in-band `Grant.Refusal` (absolute paths and `..` hops
already unconstructible). An agent requesting an action outside its grant
gets a typed refusal it can read, never a silent no-op — agents route
around obstacles they can see; the refusal is the runtime *edge* of a
boundary whose interior is compile-time.

**The grant is a type indexed by speculation status, and the forbidden
combination has no constructor**: effect-capable tools enter a grant only
through a declared-idempotence witness on the template, and the
speculative grant type simply lacks the case for non-idempotent effects —
so "a speculative node ran a non-idempotent effect" is not a policy
violation the dispatcher catches, it is a grant nobody can build
(`20-medium.md` § event taxonomy owns the taxonomy; F12/F15 in
`50-api.md` assert the unconstructibility).

A shell gate runs under the same event discipline as any effect: behind
the mkdir-atomic, holder-named machine lock scoped to its declared
build-artifact resource (`30-scheduling.md` § gates), with an `Effect`
event carrying the declared command line as the resource — a gate is never
an unobserved effect lane. Its idempotence is the declaration's: a gate is
a build/test command the engine may freely reissue, which is why gates are
grantable under either speculation index.

**Write grants are hygiene, not walls.** Concurrently-live statements
should declare disjoint-or-merge-declared `write_globs` as a matter of
theory hygiene — but the declaration is a filter, never a wall
(`20-medium.md` § footprint filtering): overlapping grants are legal, and
the base-coordinate disjoint law is what convicts an actual clobber. The
effect-escape surfacing (the unexplained-bytes sweep) is owned at
`20-medium.md` § the escape surfaces.

**The v0 grant surface, recorded honestly.** The chase derives a node's
grant from its template: `read_globs` from the declaration, the declared
command line for shell-gate executors. `effects` is hard-coded empty
because no template surface declares effect tools yet — `run_command` is
unreachable through a theory, so F12's runtime half is held by the grant's
type index plus direct-drive falsifiers; effect grants await the
template-declaration surface. The shipped engine still dispatches with a
worktree root where the design of record has `write_globs` — that gap
lives in the migration ledger (`README.md` § design of record vs shipped
engine), never as soon-dead wiring built here.

## The git ban

**Workers never run git.** (Operator ruling: "ban all git commands from
any of the workers.") Git is the harness's commit substrate —
the engine is the only writer of the committed coordinate, the object
database is the blob store, retirement builds the commits — so
a worker running git is three violations in one act: an unwitnessed
effect (its loads and stores bypass the evented tool loop, breaking the
mechanized-witness law), revert machinery (fix-forward is total; abort is
by construction, never compensation), and branch machinery (the commit
topology is the engine's own representation). One law, two boundaries:

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
falsifiers (F17 in `50-api.md`) have a boundary to kill.

## The executor transport

**Both lanes are direct API calls from the harness process — never a CLI
shell-out.** (Ruling.) This is an architectural necessity, not taste: the
harness owns the tool loop, so every load, store, and effect an agent
performs is executed by the harness and appended to the ledger with its
footprint. A CLI session runs its own tools invisibly, which makes the
mechanized-witness law (`20-medium.md` § mechanized witnesses)
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
two named lanes is the entire abstraction, permanently; execute-less
"done-tool" termination — settlement is structured output against the wire
schema, never a sentinel tool call. **Reverses if:** a third provider lane
forces shared request-transform logic (the middleware trigger), or live
smoke shows structured-output-plus-tools needs a forced-tool settlement
lane.

## Notes at yield

Between tool calls, a node drains what its subscription materialized
(`20-medium.md` § the subscription discipline) as one **note sum**:

```
Drift of Speculate.Drift.note
| Supervisory of { text; delta; disposition : [ `Continue | `Patch_then_continue ] }
| Message of { from; about; payload_ref }   (* doc-resident with the message class *)
```

All three are bus publications distinguished by attributes; the sum is
what one table materialized for one participant, not three delivery
mechanisms. A drift note is a compact rendering of an invalidation that
matched the node's default (footprint-compiled) rows: the address, the
diff class, the schema diff or delta summary, ending with the routing the
scheduler already decided (continue / patch-then-continue) — the agent
never guesses its own fate. A supervisory note is the supervisor's `Note`
steer (§ the steering vocabulary) — a publication bearing the node's id.
A message is a peer's publication that matched a row. Kills never arrive
as notes: a kill is the enactor's discontinue, not a delivery
(`20-medium.md` § delivery) — the fiber settles with its typed cause,
finalizers run, nothing further executes.

Delivery has one representation — the node's note-drain closure, built by
the chase over the consumer's channel end — and two mounts: inside the
engine the executor's yield performs the fiber's `Yield` instruction and
the handler runs that closure; where tests drive an executor directly,
`Executor.run`'s `on_yield` callback takes the same closure.

**Decision — supervisory notes and messages ride the yield lane as new
note cases, not fake drift classes.** Fibers have exactly one listening
point — the yield — so everything queued *must* arrive there; the question
is its type. **Alternative:** mint a `Supervisory` case inside
`Drift.cls` — lost because drift classes are *parsed from diff evidence*
and routed by the drift table; a supervisor's or peer's prose has no diff
and no table row, so the case would make the parse partial and the class a
lie. **Alternative:** a second delivery queue to fibers — lost because it
re-derives check-on-yield beside itself and gives fibers a second
listening point the docs rule they don't have. **Reverses if:** never for
the single listening point; the note-sum shape itself reverses if the
fiber substrate ever types yields per statement shape (then the note sum
is per-contract data).

## Model pins and provider routing

**Every template pins its model; pins move deliberately, never implicitly.**
A pin is (provider, model id, sampling config, prompt-affecting options),
recorded in the theory. A pin bump is a first-class ledger event and resets
the shape's predictor counters (survival history is per pin — a new model is
a new speculation regime; regime honesty, `README.md` rule 6).

**Two providers are wired, and routing between them is the planner's
decision, made per template at theory-emission time.** The planner template
itself pins the strongest available model (Claude Fable 5), and so does the
supervisor (judgment is the product at both). For worker templates the
planner chooses by the intelligence the shape requires:

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
and the correction is a recorded pin bump. The planner's meta-catalog
carries the routing guidance as part of the template contract, so the
planner justifies each pin the way it justifies any other emitted value.
**Decision.** **Alternative:** a runtime auto-router (classify each
firing's difficulty, pick the model per call) — lost because it makes the
executor identity unpredictable within a shape, which corrupts the
predictor's per-pin history, defeats regime honesty (which model produced
this outcome?), and moves a judgment the planner is best placed to make
into a heuristic nobody audits. **Reverses if:** measured per-shape
difficulty variance is so bimodal that one pin per shape visibly wastes
money or intelligence — the recorded path is then splitting the
*statement* into two shapes at planning time, not routing at runtime.
**Decision.** **Alternative:** auto-upgrade to the provider's latest —
lost because the predictor's history silently stops describing the
executor generating the outcomes, corrupting port priority and the churn
detector's evidence — the harness would be measuring one machine and
scheduling another. **Reverses if:** never for silent upgrades; a
*supervised* upgrade lane (shadow-run the new pin on completed shapes,
compare, then bump) is the recorded growth path.

**Decision — pin bumps apply mid-run, through the supervisor.** The
correction lane for a mis-routed shape was "a pin bump on the next
theory"; a mid-run provider incident — a refusal storm, a latency
collapse, a model behaving out of character on one shape — is exactly the
interrupt case supervision exists for, and waiting for the next theory
forfeits the wall-clock objective on this one. The bump is per-shape,
evented with reasons, and predictor-resetting, so everything the
auto-router ban protects (per-pin history, regime honesty, auditability)
survives. **Alternative:** defer all bumps to the next theory — lost as
above. **Reverses if:** ledger evidence shows mid-run bumps churning
predictor history faster than it converges (bumps per shape per run > 1
as a norm) — then the lane narrows to provider-incident causes only.

## The planner

The planner is an agent template like any other, distinguished only by its
contract: its head tuples are a **theory** (relations, statements,
templates, pins — the meta-catalog is just more catalog). The operator can
also write theories by hand (`50-api.md`); the planner exists so "here's a
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
(`bin/main.ml`, `50-api.md` § the CLI). Reader: admission
(`10-theory.md`), which sees no difference; the falsifier suite, which
fuzzes admission with planner-shaped garbage (`50-api.md`).

---

# Supervision

The supervisory plane: a frontier model that watches a running engine
through the ledger and steers it through a typed, evented vocabulary. In
the machine analogy this is the performance-monitoring unit, the
exception/interrupt architecture, and (bounded) microcode patching —
occupied by a model instead of firmware. The **supervisor** is a standing
supervision session over one run. It is not the *planner* (an agent that
emits a theory) and not the *scheduler* (mechanical, policy-bearing): it
plans nothing and schedules nothing; it watches settlements and steers
with an operator's powers, never a god's.

## Motivation: ultracode's judgment, witnessed and audited

Inheritance stated once: **ultracode** — the standing frontier-model
supervisor pattern, where one strong model holds a whole run in its context,
notices trouble, and intervenes. Its judgment is the inheritance; its senses
and hands are replaced, because both are unsound in exactly the way this
design exists to kill:

- **Ultracode's eyes are self-reports.** It knows what workers *say* they
  did. The exploit class is recorded evidence, not folklore: a supervising
  agent in this project's own history returned a plan narrated as executed
  work — no code had changed, and nothing in the harness could tell
  (docs/executor-campaign.md § failure this session). Mechanized witnesses
  closed that hole for *workers* (`20-medium.md`: read-sets by observation,
  never self-report). The supervisor closes it for supervision itself:
  **its eyes are ledger events** — settlements, drift notes, law verdicts,
  counters — which are observations the harness appended, not claims any
  agent made. A worker cannot lie to the supervisor about work, because the
  supervisor never asks the worker; it asks the ledger.
- **Ultracode's hands are prose.** It steers by talking, and its
  interventions live nowhere but its own context — unrecorded, unreplayable,
  unauditable, and lost at context exhaustion. The supervisor steers through
  a **typed sum** (§ the steering vocabulary), every actuation a ledger
  event before it applies: **the witnessed supervisor** — its interventions
  exactly as audited as any agent's tool calls, replay re-judging each one.

What this design does *not* fix, stated so nobody buys it as more than it
is: **worker judgment quality.** A supervisor cannot make a refuter sharper
or an implementer more careful; adversarial verification stays where the
theory put it — refuter statements and retire laws (`10-theory.md`). And it
carries a **standing token bill**: a model that watches a run costs tokens
the run's work does not. The subscription table (§ the fifth reader) is
what bounds that bill, and the bill is reported like every other
(`00-product.md` § success criteria; § the bill, below).

## Push, not pull

**Decision — advice flows down, on the supervisor's initiative, never up
on the worker's request.** The contrast case is Anthropic's advisor tool
(Claude Code): a worker-side server tool that consults a typically
stronger model at moments the *worker* chooses — before committing to an
approach, when stuck on a recurring error, before declaring a task
complete — receiving the worker's full conversation and returning
guidance. Same insight (a stronger model at key moments), inverted
direction — and the direction is the whole bet:

- **Pull inherits the self-report problem.** A worker that must recognize
  it needs help cannot call for help with a problem it cannot see — and
  the recorded exploit class (work narrated, not done) is precisely a
  worker whose self-assessment is wrong. Pull-based advice trusts the
  distressed party to diagnose its own distress.
- **Push reads evidence, not confessions.** The supervisor's wake
  conditions are ledger events — faults, law violations, drift storms,
  ceiling binds, stalls — observations the harness appended, visible
  whether or not the worker knows anything is wrong.
- **Pull is also unaudited at the decision point.** The moments a worker
  *didn't* consult leave no trace; the supervisor's attention policy is a
  subscription table — data, amendable, replayed.

**Alternative:** adopt an advisor-style escalation tool on the worker's
tool surface (a pull hatch beside the push plane) — lost for v0 because it
splits the judgment surface (two advice channels, two attention policies,
one of them self-report-gated), and because everything a stuck worker
would ask is already surfaced cheaper: a repair lane for invalid output, a
drift note for a moved world, a fault for a dead end (the supervisor sees
all three). **Reverses if:** live pipelines show a measured class of
worker distress that never surfaces as any ledger event the subscription
table can name — evidence that the worker knows something the ledger
doesn't — then the bus already carries the fix with no new lane at all: a
worker *publishes* distress (an attributed fact like any other,
`20-medium.md` § the bus) and the supervisor's table subscribes to the
attribute — still push at the decision point (the supervisor's row, not
the worker's call, decides that it surfaces), still never a synchronous
advice call.

## The fifth reader

**The supervisor reads the ledger through a named reader — `Supervision`,
joining Replay, Telemetry, Predictor_history, and the Witness index**
(`20-medium.md` § the ledger). It is not a firehose. What the supervisor
is *pushed* is governed by a **subscription table as data** — not a
supervision-special mechanism but the system's one delivery discipline
(`20-medium.md` § the subscription discipline) instantiated at the
supervision plane: rows of event class × threshold → escalation level,
inspectable, amendable mid-run (the amendment is itself a steer, evented),
and replayable (the current table is a fold of the default plus the
recorded amendments; last row per class wins).

```ocaml
module Subscription : sig
  (** What a row escalates to. [Mute] exists so an amendment can silence a
      default row — amendments are append-only events; the table is their
      fold. *)
  module Level : sig
    type t =
      | Mute  (** Ledger-only: available to pull, never delivered. *)
      | Digest  (** Coalesced into the next supervisor turn's digest. *)
      | Wake  (** Queue a supervisor turn now (§ the cadence law). *)
  end

  (** The supervision-relevant condition classes: mostly event kinds at
      settlement granularity, plus one clock-derived class (stall). *)
  module Class : sig
    type t =
      | Settled of [ `Any | `Retired | `Faulted | `Squashed ]
      | Law_verdict of [ `Any | `Violated ]
      | Drift of Ledger.Drift.cls
      | Ceiling_bound  (** The token backstop bound — always an anomaly. *)
      | Switch_thrown
      | Pin_bump
      | Repair_attempts  (** Threshold-counted: the repair-storm probe. *)
      | Correction
      | Quiescence_stall
          (** No settlement or dispatch progress while unsettled nodes
              exist — the one clock-derived class (§ the cadence law). *)
      | Steered  (** Prior actuations — the successor's boot class. *)
  end

  module Threshold : sig
    type t =
      | Every
      | Count of { at_least : int; within_s : float }
      | Stall of { longer_than_s : float }
          (** Meaningful only for [Quiescence_stall]. *)
  end

  type row = { cls : Class.t; threshold : Threshold.t; level : Level.t }

  type t
  (** The folded table: one effective row per class; unlisted classes are
      [Mute] (the table is total by default, never by enumeration). *)

  val default : t
  val amend : t -> row -> t
  (** Applied only by the steer intake — the amendment event precedes the
      new table (§ the steering vocabulary). *)

  val level : t -> Class.t -> Threshold.t * Level.t
end
```

**The default subscription**, as data:

| Class | Threshold | Level |
|---|---|---|
| ``Settled `Faulted`` | every | Wake |
| ``Settled `Squashed`` | every | Digest |
| ``Settled `Retired`` | every | Digest |
| ``Law_verdict `Violated`` | every | Wake |
| `Drift Breaking_broad` | ≥ 3 within 600 s | Wake |
| `Ceiling_bound` | every | Wake |
| `Switch_thrown` | every | Digest |
| `Correction` | every | Wake |
| `Quiescence_stall` | > 300 s | Wake |

Everything else stays in the ledger for on-demand drill-down — **pull,
never push**. The reader surface: `Supervision.escalations : Ledger.t ->
table:Subscription.t -> since:Ledger.Timestamp.t -> escalation list` — a
pure fold over the event stream, so replay re-derives every escalation
from the same table; escalations carry the level and the matching events,
coalesced. The digest rendering is **coalesced, never per-event prose** —
counts with exemplar refs, deltas behind `Delta_ref` pulls: the
invalidate-don't-update posture applied to the supervisor's own context
window.

**Decision — a subscription table, not a firehose and not a fixed feed.**
**Alternative:** stream every ledger event into the supervisor's context
(the ultracode posture: the supervisor sees everything) — lost because the
context window is the session's scarce resource and the bill is standing;
a firehose either exhausts the session mid-run or trains it to skim, and a
supervisor that skims is worse than a counter. **Alternative:** a fixed,
code-owned escalation policy (no table, just "faults wake the supervisor")
— lost on doc rule 8: escalation policy is exactly the branching that must
be reified as data, and a mid-run-amendable table is what lets the
supervisor *narrow* its own attention when a run turns noisy (the
amendment evented, so the narrowing is auditable too). **Reverses if:**
measured session token bills show the table's flexibility unused across
real pipelines (every run rides the default) — then the default hardens
into the code and the amendment steer is deleted with its constructor.

### Go to the bottleneck

**The machine computes where the supervisor should stand.** Attention
allocation is not a vibe: `Report.summary` carries `critical_path` (the
node chain that determined wall clock), `port_queues` (seconds queued per
reservation station), `realized_parallelism`, and the per-shape
speculation counters. The standing playbook is a query, not an
impression: read the scoreboard, find the constraint as a value, retarget
the subscription to that port/shape/node (a `Subscribe` steer, evented),
drill its ledger traffic on demand, steer through the vocabulary below.
The steers stay law-bound where human floor-walking is not: widening a
port demands the named bottleneck `Port.bounded` already requires, and
killing a flailing shape's speculation demands churn evidence — "a bad
feeling" is not a legal steer; "survival 0.31 over 14 samples" is. Amdahl
aligns the incentive exactly: attending the critical path is the only
attention that buys wall clock, wall clock is the machine's one
objective, and a supervisor loitering anywhere else is measurably wasting
its own ledgered bill.

### The aggressive posture

**The supervisor errs toward intervention.** (Operator ruling: the
supervisor pays attention and steers aggressively, including the
interrupt.) The payoff is asymmetric by constitution: a steer costs tokens
— reported, leashed — while under-intervention costs wall clock, the
objective: a flailing shape left to churn, a known-useless turn left to
drain a port slot, a mis-routed pin left to burn a run. The module's own
implementation trigger is the measured form of under-supervision ("nobody
was watching"), so passivity is the recorded failure mode, not the safe
default. The same evidence discipline that legalizes a steer ("survival
0.31 over 14 samples") is what makes aggression safe: an aggressive
supervisor is one that acts on evidence *early*, never one that acts
without it.

**The interrupt is the sharpest tool in the vocabulary, and the supervisor
is expected to use it.** `Abort` kills a turn mid-flight through the
enactor (the discontinue — `20-medium.md` § delivery), and killing
known-useless work immediately is constitutionally cheaper than any
politeness; `Abort` with a redirect note is the steer-*now* form (kill,
reissue with guidance — the only mid-turn steering an LLM can mechanically
receive, § the steering vocabulary). What keeps aggression from becoming
thrash is recorded where the powers are: every steer is evented with its
evidence (F18), the cadence law keeps every intervention off the dispatch
path, and steer-versus-outcome is auditable per session — a supervisor
whose kills cost more than they saved is visible in its own ledgered bill
(§ the bill), and "who supervises the supervisor" already has its three
answers (§ beside the machine).

## The cadence law

**The supervisor lives at settlement granularity and is never on the
dispatch path.** F4 is inviolable: between a settlement and the dispatch of
its dependents the engine performs no I/O beyond the ledger append — and
the subscription judgment is a pure fold over that already-owed append, so
supervision adds nothing to the path. A `Wake` **queues** a supervisor turn;
it never blocks anything on one. The turn runs beside the engine,
overlapping work exactly as any provider call overlaps on the fiber
substrate, and its steers apply at the engine's existing application
points — a note at the target's next yield, a kill through the squash
path, a tune at the next judgment that reads the tuned value. No dispatch
ever waits on a model's answer, because the wall-clock objective dies the
day model latency enters dispatch (`30-scheduling.md` § the objective).
The falsifier is F19: a rigged supervisor with an arbitrarily slow
scripted turn changes no unrelated node's dispatch timing — the F2
discipline, applied to the supervisor.

`Quiescence_stall` is the one clock-derived class: a stalled run appends
nothing, so no fold over appends can notice it. The stall probe is a host
timer owned by the session; its wake is recorded by the turn it starts
(the turn's events carry ledger timestamps), so replay's story is the same
as for any executor — supervisor turns are substituted from the ledger, and
the wake's timing rides the recorded events. The heartbeat's exact
representation is OPEN (below).

## The typed steering vocabulary

**A steer is a constructor of a sum, never free prose — and almost every
constructor is a thin handle on machinery the engine already has.** That
collapse is the design's spine: the supervisor needed almost no new
actuators because the engine's control surface was already reified as data
and typed signals; the vocabulary names what exists.

```ocaml
(** Mid-run-tunable numbers. Every constructor's application point is a
    read the engine already performs per judgment, which is what makes the
    whole sum mid-run-safe by construction: nothing here changes semantics
    (falsifier F9's equivalence covers backstops and switches; ports and
    pins change scheduling, never tuples or verdicts). *)
module Tune : sig
  type t =
    | Token_ceiling of int
    | Confidence_floor of float
    | Port_limit of { port : string; limit : int; bottleneck : string }
        (** Re-bound a declared port. [bottleneck] is required by
            construction, exactly as at [Chase.Port.bounded]: a bound
            without a documented reason is unwritable, whoever writes it.
            Raising is trivially safe; lowering binds at the next
            admission — v0 never preempts an admitted slot. *)
end

(** The steering vocabulary. Each constructor names its machinery; none
    mints, witnesses, or commits anything (§ unforgeability). *)
module Steer : sig
  type t =
    | Note of {
        node : Ledger.node Id.t;
        text : string;
        delta : Ledger.Delta_ref.t option;
        disposition : [ `Continue | `Patch_then_continue ];
      }
        (** Steer a running node: a bus publication bearing the node's id,
            materialized by its default subscription and drained at its
            next yield — the fiber's only listening point (§ notes at
            yield). [node] is an attribute, never an envelope: any
            subscriber to the same attribute reads it too. A note that
            kills is [Abort], one act per constructor: kills are
            enactments, never dispositions (20-medium.md § delivery). *)
    | Abort of { node : Ledger.node Id.t; redirect : string option }
        (** Kill, now: the enactor's discontinue through the existing
            squash path, with the typed cause
            [Ledger.Squash_cause.Supervisor_abort { reason }] (the reason
            copied from this steer's event). The supervisor's interrupt —
            its sharpest steer (§ the aggressive posture). [redirect],
            when present, is guidance for the reissue: it rides the
            reissued node's diagnostics in the repair-lane shape
            (30-scheduling.md § the repair lane), because
            kill-and-reissue-with-guidance is the only mid-turn steering
            an LLM can mechanically receive. The act is still one act —
            the kill; reissue remains the scheduler's recorded decision,
            and squash precision is the engine's, untouched: the
            provenance-closed subtree, nothing renumbered. *)
    | Bump_pin of {
        statement : Theory.Statement.id;
        executor : Theory.Executor.id;
        pin : Theory.Pin.t;
      }
        (** Reroute: the first-class pin bump, mid-run, per shape
            (§ model pins). Appends the existing [Pin_bump] event, resets
            the shape's predictor counters. Never per call: the
            auto-router ban stands. *)
    | Throw_switch of Speculate.Switch.t
        (** Speculation off, per shape. The value itself is the evidence
            law: [Speculate.Switch.throw] requires a [Churn.measurement],
            which has no public constructor and comes only from a ledger —
            the supervisor is bound exactly as the operator and the
            scheduler are, by construction. *)
    | Amend_theory of Theory.Meta.t
        (** Restructure: a theory amendment {e through admission} —
            [Theory.Meta.admit], the same gate the planner passes, with
            the same accumulated [Admission.error list] on rejection. No
            bypass exists to construct: the steer carries wire-shaped
            [Meta.t], never [Theory.admitted]. v0's application point is
            the run boundary (§ OPEN: mid-run splice). *)
    | Tune of Tune.t
    | Subscribe of Subscription.row
        (** Amend the supervisor's own feed — attention is steerable too,
            and the amendment is audited like everything else. *)
    | Observe of { subject : string; text : string }
        (** An actuation whose entire effect is its event: the recorded
            observation. This is the succession checkpoint
            (§ statelessness) — what a supervisor wants its successor to
            know is in the ledger or it does not exist. *)

  (** The intake's answer: typed, in-band, never an exception — the
      supervisor routes around obstacles it can see, the same posture as
      [Agent.Grant.Refusal]. *)
  type outcome =
    | Applied
    | Rejected of reject

  and reject =
    | Unknown_node of Ledger.node Id.t
    | Already_settled of Ledger.node Id.t
    | Inadmissible of Theory.Admission.error list
    | Unknown_port of string
end
```

**Every steer is a ledger event before it is anything else.** The intake
appends `Steered` (the compact form of the constructor, the reason, and
the counters consulted — the same explainability contract as scheduler
`Decision` events), then executes through the named machinery, which
appends *its* existing events: an applied `Bump_pin` is a `Steered` event
followed by the `Pin_bump` event the machinery already emits; an applied
`Abort` is `Steered` followed by `Settled (Squashed (Supervisor_abort _))`.
Readers of `Steered`, named: replay (which re-judges every application),
`Report.explain` (a steered node's story shows who steered it and why),
the operator, and the successor session's boot query. An application the
event does not precede is not writable: the intake owns both the append
and the call, and falsifier F18 asserts the order.

**Decision — a dedicated squash cause, `Supervisor_abort of { reason :
string }`.** The settled map's rule is that a reader sees the real cause —
the same ruling that forbade spelling reissue-losers as operator aborts
(`30-scheduling.md` § settlement). A supervisor kill spelled
`Operator_abort` lies about who acted and severs the audit trail from the
`Steered` event that ordered it. **Alternative:** reuse `Operator_abort`
(the supervisor "is" an operator) — lost on exactly that rule: the
operator is sovereign and unaccountable; the supervisor is accountable by
design, and its cause must be traceable to its evented reason.
**Alternative:** generalize to `Abort of { by : [ `Operator | `Supervisor
]; reason : string }` — lost because it churns every existing match to
carry a distinction one new constructor carries alone. **Reverses if:** a
third killer class appears (a policy daemon, a second supervision plane) —
then the by-field coordinate wins and the constructors collapse into it.

## Unforgeability by construction

**The supervisor gets an operator's powers, never a god's.** The forbidden
powers, enumerated, each with the representation that makes it
unconstructible and the F15 negative-compilation probe that pins it:

1. **It cannot forge a witness.** Witness triples enter the ledger only
   through harness-executed loads (`20-medium.md` § mechanized
   witnesses), and the session's surface exposes no `Ledger.append` — its
   ledger handle is the reader surface. *Probe P1: appending a
   hand-built `Event.kind.Load` through any value reachable from
   `Supervisor.session` must not typecheck.*
2. **It cannot mint or commit a tuple.** No `Id.Minter.t`, no committed
   writer, and no channel end is reachable from the session; the `Steer`
   sum has no tuple-bearing constructor. *Probe P2: obtaining
   `'a Channel.tx` or calling the committed seed from the session
   surface must not typecheck (no accessor exists to write it with).*
3. **It cannot bypass admission.** `Amend_theory` carries `Theory.Meta.t`
   — wire data — and admitted statements exist only through
   `Theory.declare`/`Theory.Meta.admit`. *Probe P3: an `Amend_theory`
   steer carrying `Theory.admitted` or raw `Theory.Spawn.t` values must
   not typecheck.*
4. **It cannot throw an evidence-free switch.** Inherited, not new:
   `Speculate.Switch.throw` requires a `Churn.measurement`, which only a
   ledger can produce. *Probe: the existing bare-`Switch.throw` F15 probe
   already pins this; the steer adds no second path.*
5. **It cannot loosen its own leash.** `Tune` has no constructor for the
   session's own stop bounds — the leash is `attach`'s operator-supplied
   argument (§ beside the machine). *Probe P4: a `Tune` value naming the
   session budget must not typecheck (no constructor).*
6. **It cannot steer unrecorded.** The intake appends `Steered` before
   applying; the application functions are not exposed apart from it.
   This one is runtime-ordered rather than type-shaped, so its pin is a
   falsifier, not a probe: *F18 asserts every applied steer's machinery
   events are preceded by its `Steered` event, and replay re-judges each
   application.*
7. **It cannot touch the dispatch path.** No synchronous surface exists
   between settlement and dispatch that consults a session (§ the cadence
   law). *Pinned by F4's existing instrumentation plus F19.*

The pattern is the house pattern: the boundary's interior is compile-time
(no constructor, no accessor), its runtime edge is a typed in-band
rejection (`Steer.outcome`), and the residue that types cannot carry
(event ordering, dispatch purity) is named falsifier work.

## Statelessness via the ledger

**A supervisor session holds no state a fresh session cannot rebuild from
the ledger.** This is not a discipline; it is the falsified completeness
law doing new work: replay determinism already asserts that every input to
every decision is ledger-recorded (`50-api.md` § replay determinism), so a
successor reading the ledger reads everything its predecessor knew that
mattered. Context exhaustion is therefore handled by **session
succession**, never by summaries held in anyone's head: when a session's
leash trips (`Agent.Stop`, `Fault.Context_exhausted` — the same bound any
agent has), the host detaches it and attaches a successor. The succession
is evented (`Supervisor_session` names its predecessor), and the
predecessor's parting `Observe` steers are the only handoff — in the
ledger, structured, audited, or nonexistent.

**The boot query**, in order — bounded, never a full replay (the session's
context is the scarce resource; the boot reads digests and drills down by
pull):

1. **The run's frame:** the admitted theory and config (recovered from the
   ledger, as replay recovers them), the port table, backstops, thrown
   switches.
2. **The subscription table:** `Subscription.default` folded with the
   recorded `Subscribe` steers.
3. **The run's present tense:** settlements so far (the settled-map fold),
   unsettled nodes with their lifecycle phase (queued / dispatched /
   suspended, from `Decision` markers), undischarged hypotheses, ceiling
   state.
4. **The shape counters:** `Speculate.Counters.of_ledger` per active shape
   — survival, reconcile cost, churn — the PMU's registers.
5. **The supervision record:** prior `Steered` events with their outcomes
   (open interventions a successor must not contradict blindly), and the
   predecessor's `Observe` events — the diary.
6. **The pending feed:** `Supervision.escalations` since the predecessor's
   last drained cursor — what woke, or would have woken, the session.

**Decision — no new checkpoint representation.** The boot query is served
entirely by existing surfaces plus the fifth reader; the only addition is
`Observe` (an event, not a store) and the succession event.
**Alternative:** a periodic supervisor checkpoint blob (a serialized
"understanding of the run" the successor deserializes) — lost because it
is a summary held in a head with extra steps: unaudited judgment
compressed into an unreplayable artifact, exactly the ultracode failure
re-imported, and a second supply of what the ledger already holds.
**Reverses if:** measured boot cost (tokens per succession, a ledger
query) dominates the session bill on long runs — the recorded upgrade is a
*derived* digest cache (a pure function of the ledger, recomputable and
therefore not a second supply), never an authored checkpoint.

## Beside the machine

The deepest representational question: is the supervisor **inside** the
theory — an agent-template node with a standing grant — or **beside** it,
a host-level surface?

The case for inside is the machine's own dogfood: a node gets token
accounting, mechanized witnessing, and settlement discipline for free, and
"the planner is an agent template like any other" argues the supervisor
should be too. The case collapses on the representation: a node is *one
firing of a dependency statement* — body tuples in, head tuples out, one
settlement, counted by quiescence. The supervisor fires on no body match,
mints no head tuples, and **never settles while the run lives**; a
standing node poisons quiescence ("every started node has settled") unless
quiescence grows an exemption representation, and an exemption for exactly
one privileged node is a guard wearing a type's clothing — doc rule 8 read
against itself. Worse, a supervisor-in-theory makes the supervisor's own
events fireable facts: its steers would be tuples, its subscriptions
edges, and the theory acquires a reader of every relation whose writes
feed back into scheduling — a cycle in the one graph the whole design
keeps acyclic (`00-product.md` § the two graphs: the supervisor lives on
the communication graph, and pulling it into the derivation graph would
make its steering derivation).

**Decision — beside the theory, inside the audit.** The supervisor is a
host-level standing session attached to a `Run.handle`, and its runtime is
the same `Agent.agent` layer over a provider lane as every worker — one
tool loop, one grant boundary, one eventing path — with a supervision
grant whose toolset is the ledger-query surface plus the one steer tool.
So it is **a node in every audited respect and a node in no theory
respect**: its queries are harness-executed, Load-classed events under its
session id; its turns bill `Agent_turn` events; its writes are the typed
intake — but no statement fires it, no port queues it, no settlement is
owed by it, and quiescence never hears of it. The machine analogy seals
the ruling: the PMU is not an execution unit, an interrupt handler is not
a µop, and a supervisory plane threaded through the instruction stream
would be self-referential in silicon too.
**Alternative (inside, recorded):** an agent-template node with a standing
grant and a quiescence exemption — lost as above (the exemption, the
cycle, the settled map polluted by a node that is not work).
**Reverses if:** human-in-the-loop nodes (`README.md` OPEN) force a
standing-node representation into the theory anyway — a human approver is
also a long-lived non-settling participant, and if that work builds the
exemption representation honestly, the supervisor collapses onto it and
the host surface is deleted; or if supervision itself needs adversarial
review *as a theory* (refuter panels over steers), which requires steers
to be tuples — the recorded growth path below gets there without the
move, so this trigger is the weaker one.

**Who supervises the supervisor.** Three answers, all existing machinery:
the **ledger** (every steer, query, and turn is evented; replay re-judges
the applications; `Report.explain` on a steered node names the steerer and
its reason); the **operator** (the session is host-owned: the leash is the
operator's argument at `attach`, `detach` is unconditional, and the same
steer intake serves the operator's own interventions — so a manual abort
is exactly as recorded as a supervisor's, closing the unrecorded-manual-
intervention hole from the same class); and, as the recorded growth path,
**the machine itself**: a run's `Steered` events are seedable facts, so an
adversarial review of a run's supervision is census workload #2 over its
own ledger — representable today, built when a supervisor's judgment first
costs a run something a refuter would have caught.

**The session surface** (doc-resident with the module, § below):

```ocaml
type session

val attach :
  run:Run.handle ->
  table:Subscription.t ->
  provider:Agent.Provider.t ->
  leash:Agent.Stop.t list ->
  session
(** Start supervision: mints the session's node-realm id, appends
    [Supervisor_session], and stands the agent loop up over the
    supervision grant. [leash] is the operator's bound on the session
    (steps and tokens); it is an argument here {e because} no [Tune]
    constructor can reach it. The template's pin follows the planner's
    rule: judgment is the product, so the strongest available model. *)

val detach : session -> unit
(** Unconditional; appends the closing [Supervisor_session] event. The
    run is unaffected: supervision is observation plus steers, never a
    dependency of any dispatch. *)

val steer : session -> Steer.t -> Steer.outcome
(** The one intake: appends [Steered], then applies through the named
    machinery. The model reaches this as its [steer] tool; host code and
    the operator's CLI ([goat steer]) call the same function — one
    steering surface, everyone on it audited alike. *)
```

## The bill

The standing cost, owned honestly: a supervised run pays (a) the session's
turns — bounded by the leash and by the subscription table (a `Wake` is
the only thing that starts a turn early; `Digest` batches; `Mute` is
free), (b) the boot cost per succession (bounded by the boot query's
digest discipline), and (c) nothing on any dispatch path. The bill is
reported, never gated: the session's usage aggregates under its session id
and lands in `Report.summarize` as a supervision line beside the
speculation account — tokens are fuel, and the operator reads what
watching cost exactly as they read what speculation cost.

## The module

**The `Supervisor` module is doc-resident: this doc's signatures are its
`.mli` until the implementation trigger, and no lib module lands before it
has a consumer** (the anti-transcription rule — an unconsumed supervision
layer is transcription of this doc into dead code). The module's
implementation trigger: **the first live pipeline whose ledger shows a
Wake-class condition (a fault, a `Ceiling_bound`, a churn switch) that the
operator learned of only from the settled map** — the measured form of
"nobody was watching." At the trigger, the module lands as `lib/supervisor`
with exactly these signatures (`Subscription`, `Supervision` as ledger
reader 5, `Tune`, `Steer`, the session surface), plus the owed lib
amendments in the same change (`README.md` § design of record vs shipped
engine), per doc rule 4.

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
  provider). The resolution is § model pins and provider routing: two
  named lanes behind the pin record, planner-owned routing, and still no
  general middleware layer — the pin's `provider` field plus one runtime per
  lane is the entire abstraction, permanently.
- **Mid-run theory splice.** v0 applies `Amend_theory` at the run
  boundary: admit, then reseed a successor run from the settled map. A
  true splice (new statements joining a live chase, channels opened
  mid-run) is designed nowhere. *Trigger: a supervised run where the
  ledger's `suspended_reads` counter shows reads a spliced statement would
  have served, at a cost exceeding the reseed's — the counter names the
  opportunity directly.*
- **The stall heartbeat's representation.** A host timer whose wake is
  recorded by the turn it starts is the v0 story; whether the expiry
  itself needs an evented representation (so a stall *nobody acted on* is
  visible) is undecided. *Trigger: the first post-mortem that asks "did
  the heartbeat fire?" and cannot answer from the ledger.*
- **Digest budget.** How much context one escalation digest may spend, and
  the coalescing policy past it (drop exemplars first? summarize counts
  per shape?). *Trigger: measured session bills dominated by digest volume
  (a ledger query over the session's `Agent_turn` usage).*
- **Proactive succession.** v0 successions fire on the leash
  (`Context_exhausted` faults the session; the host attaches a successor).
  Succeeding *before* exhaustion — at a quiet settlement, so no incident
  straddles a handoff — is unbuilt. *Trigger: the first session that
  faults mid-incident.*
- **Steer contention.** Two occupants of the intake (operator and
  supervisor) can steer the same target oppositely; v0 is last-write-wins
  with both recorded, and the operator's remedy is `detach`. *Trigger: the
  first contradictory steer pair in a real ledger.*
