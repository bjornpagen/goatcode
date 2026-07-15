# 90 — Supervisor (project codename: puppeteer)

The supervisory plane: a frontier model that watches a running engine through
the ledger and steers it through a typed, evented vocabulary. In the machine
analogy this is the plane the first eight docs left unoccupied — the
performance-monitoring unit, the exception/interrupt architecture, and
(bounded) microcode patching — occupied by a model instead of firmware.
Readers of this doc: the operator; the `Supervisor` module (doc-resident
until its implementation trigger, § the module); `30-channels.md` (whose
ledger-reader list this doc extends); `80-validation.md` (whose falsifier
roster gains this doc's probes). Existing-file amendments this design
demands are recorded in § HANDOFF, deferred under doc rule 4 until the
concurrent engine work lands.

The word is new house vocabulary, defined once: the **supervisor** is a
standing supervision session over one run. It is not the *planner* (an
agent that emits a theory), not the *scheduler* (mechanical,
policy-bearing), and not an "orchestrator" (deleted vocabulary — the word
that blurs them stays banned). The supervisor plans nothing and schedules
nothing: it watches settlements and steers with an operator's powers,
never a god's.

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
  closed that hole for *workers* (`30-channels.md` § mechanized witnesses:
  read-sets by observation, never self-report). The supervisor closes it for
  supervision itself: **its eyes are ledger events** — settlements, drift
  notes, law verdicts, counters — which are observations the harness
  appended, not claims any agent made. A worker cannot lie to the supervisor
  about work, because the supervisor never asks the worker; it asks the
  ledger.
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

The analogy's rows, and where it ends:

| Silicon | GOAT CODE |
|---|---|
| Performance-monitoring unit | The subscription table over the ledger (§ the fifth reader) |
| Interrupt vs polled status | `Wake` vs `Digest` escalation levels |
| Exception vector table | Subscription rows: event class × threshold → level, as data |
| Microcode patch | A steer: typed, bounded, through existing machinery only |

Where it ends: silicon's microcode patches are unaudited and its PMU
counters are trusted hardware. Here the patcher is a model — so every patch
is an event, every power is typed, and the forbidden powers are
unconstructible (§ unforgeability), because a supervisor you cannot audit
is the exploit class this doc opened with.

## The fifth reader

**The supervisor reads the ledger through a named reader — `Supervision`,
joining Replay, Telemetry, Predictor_history, and the Witness index**
(`30-channels.md` § the ledger; the anti-transcription rule demands the
name, and the HANDOFF amends the four-reader list). It is not a firehose.
What the supervisor is *pushed* is governed by a **subscription table as
data**: rows of event class × threshold → escalation level — inspectable,
amendable mid-run (the amendment is itself a steer, evented like any
other), and replayable (the current table is a fold of the default plus
the recorded amendments; last row per class wins).

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

    val equal : t -> t -> bool
    val compare : t -> t -> int
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
  val rows : t -> row list
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
never push**. The reader surface:

```ocaml
(** Reader 5: supervision. Escalations since a cursor, judged by the
    subscription table — a pure fold over the event stream, so replay
    re-derives every escalation from the same table
    (docs/architecture/80-validation.md § replay determinism). *)
module Supervision : sig
  type escalation = {
    at : Ledger.Timestamp.t;
    cls : Subscription.Class.t;
    level : Subscription.Level.t;  (** [Digest] or [Wake]; [Mute] rows
                                       never construct one. *)
    events : Ledger.Event.t list;  (** The matching events, coalesced. *)
  }

  val escalations :
    Ledger.t ->
    table:Subscription.t ->
    since:Ledger.Timestamp.t ->
    escalation list
end
```

The digest rendering is **coalesced, never per-event prose** — counts with
exemplar refs, deltas behind `Delta_ref` pulls. This is the
invalidate-don't-update posture (`30-channels.md`) applied to the
supervisor's own context window: the scarcest resource in a standing
session is the session's context, and per-event play-by-play fills it
exactly the way update-flooding fills a bus.

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

## The cadence law

**The supervisor lives at settlement granularity and is never on the
dispatch path.** F4 is inviolable: between a settlement and the dispatch of
its dependents the engine performs no I/O beyond the ledger append — and
the subscription judgment is a pure fold over that already-owed append, so
supervision adds nothing to the path. A `Wake` **queues** a supervisor turn;
it never blocks anything on one. The turn runs beside the engine,
overlapping work exactly as any provider call overlaps on the fiber
substrate (`Fiber`), and its steers apply at the engine's existing
application points — a note at the target's next yield, a squash through
the squash path, a tune at the next judgment that reads the tuned value.
No dispatch ever waits on a model's answer, because the wall-clock
objective dies the day model latency enters dispatch
(`40-scheduling.md` § the objective). The falsifier is F17 (§ HANDOFF): a
rigged supervisor with an arbitrarily slow scripted turn changes no
unrelated node's dispatch timing — the F2 discipline, applied to the
supervisor.

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
    | Token_ceiling of int  (** [Speculate.Backstops.token_ceiling]. *)
    | Confidence_floor of float
        (** [Speculate.Backstops.confidence_floor]. *)
    | Port_limit of { port : string; limit : int; bottleneck : string }
        (** Re-bound a declared port. [bottleneck] is required by
            construction, exactly as at [Chase.Port.bounded]: a bound
            without a documented reason is unwritable, whoever writes it.
            Raising is trivially safe; lowering binds at the next
            admission — v0 never preempts an admitted slot
            (docs/architecture/40-scheduling.md § ports). *)
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
        (** Steer a running node: a supervisory note delivered at the
            node's next yield — the check-on-yield lane, the fiber's only
            listening point (docs/architecture/30-channels.md § delivery).
            [`Stop_cleanly] is deliberately absent: a note that kills is
            [Abort], one act per constructor. *)
    | Abort of { node : Ledger.node Id.t }
        (** Kill: the existing squash path, with the typed cause
            [Ledger.Squash_cause.Supervisor_abort { reason }] (the reason
            copied from this steer's event). Squash precision is the
            engine's, untouched: the provenance-closed subtree, worktrees
            dropped, nothing renumbered. *)
    | Bump_pin of {
        statement : Theory.Statement.id;
        executor : Theory.Executor.id;
        pin : Theory.Pin.t;
      }
        (** Reroute: the first-class pin bump. Applies per shape to future
            invocations (an override table the invocation read consults),
            appends the existing [Pin_bump] event, resets the shape's
            predictor counters — per pin, per regime honesty. Never per
            call: the auto-router ban stands
            (docs/architecture/60-agents.md § model pins). *)
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
            observation. This is the succession checkpoint (§ statelessness)
            — what a supervisor wants its successor to know is in the
            ledger or it does not exist. *)

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
and the call, and falsifier F16 asserts the order.

**Decision — a dedicated squash cause, `Supervisor_abort of { reason :
string }`.** The settled map's rule is that a reader sees the real cause —
the same ruling that forbade spelling reissue-losers as operator aborts
(`40-scheduling.md` § settlement). A supervisor kill spelled `Operator_abort`
lies about who acted and severs the audit trail from the `Steered` event
that ordered it. **Alternative:** reuse `Operator_abort` (the supervisor
"is" an operator) — lost on exactly that rule: the operator is sovereign
and unaccountable; the supervisor is accountable by design, and its cause
must be traceable to its evented reason. **Alternative:** generalize to
`Abort of { by : [ `Operator | `Supervisor ]; reason : string }` — lost
because it churns every existing match to carry a distinction one new
constructor carries alone. **Reverses if:** a third killer class appears
(a policy daemon, a second supervision plane) — then the by-field
coordinate wins and the constructors collapse into it.

**Decision — supervisory notes ride the yield lane as a new note case,
not a fake drift class.** Fibers have exactly one listening point —
check-on-yield — so the note *must* arrive there; the question is its
type. The delivered note type generalizes to a sum:
`Drift of Speculate.Drift.note | Supervisory of { text; delta;
disposition }` (HANDOFF: `speculate.mli`, `fiber.mli`'s `Yield`,
`agent.mli`'s `on_yield`). **Alternative:** mint a `Supervisory` case
inside `Drift.cls` — lost because drift classes are *parsed from diff
evidence* and routed by the F8 table; a supervisor's prose has no diff and
no table row, so the case would make the parse partial and the class a
lie. **Alternative:** a second delivery queue to fibers — lost because it
re-derives check-on-yield beside itself and gives fibers a second
listening point the docs just ruled they don't have. **Reverses if:**
never for the single listening point; the note-sum shape itself reverses
if the fiber substrate ever types yields per statement shape (then the
note sum is per-contract data).

**Decision — the supervisor's pin bump applies mid-run.** The recorded
correction lane for a mis-routed shape was "a pin bump on the next theory"
(`60-agents.md`). A mid-run provider incident — a refusal storm, a latency
collapse, a model behaving out of character on one shape — is exactly the
interrupt case supervision exists for, and waiting for the next theory
forfeits the wall-clock objective on this one. The bump is per-shape,
evented with reasons, and predictor-resetting, so everything the
auto-router ban protects (per-pin history, regime honesty, auditability)
survives. **Alternative:** defer all bumps to the next theory — lost as
above. **Reverses if:** ledger evidence shows mid-run bumps churning
predictor history faster than it converges (bumps per shape per run > 1
as a norm) — then the lane narrows to provider-incident causes only.

## Unforgeability by construction

**The supervisor gets an operator's powers, never a god's.** The forbidden
powers, enumerated, each with the representation that makes it
unconstructible and the F15 negative-compilation probe that pins it
(HANDOFF: `80-validation.md` F15 roster):

1. **It cannot forge a witness.** Witness triples enter the ledger only
   through harness-executed loads (`30-channels.md` § mechanized
   witnesses), and the session's surface exposes no `Ledger.append` — its
   ledger handle is the reader surface. *Probe P1: appending a
   hand-built `Event.kind.Load` through any value reachable from
   `Supervisor.session` must not typecheck.*
2. **It cannot mint or commit a tuple.** No `Id.Minter.t`, no
   `Retire.Committed.t`, and no channel end is reachable from the session;
   the `Steer` sum has no tuple-bearing constructor. *Probe P2: obtaining
   `'a Channel.tx` or calling `Retire.Committed.seed` from the session
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
   argument (§ the supervisor beside the machine). *Probe P4: a `Tune`
   value naming the session budget must not typecheck (no constructor).*
6. **It cannot steer unrecorded.** The intake appends `Steered` before
   applying; the application functions are not exposed apart from it.
   This one is runtime-ordered rather than type-shaped, so its pin is a
   falsifier, not a probe: *F16 asserts every applied steer's machinery
   events are preceded by its `Steered` event, and replay re-judges each
   application.*
7. **It cannot touch the dispatch path.** No synchronous surface exists
   between settlement and dispatch that consults a session (§ the cadence
   law). *Pinned by F4's existing instrumentation plus F17.*

The pattern is the house pattern: the boundary's interior is compile-time
(no constructor, no accessor), its runtime edge is a typed in-band
rejection (`Steer.outcome`), and the residue that types cannot carry
(event ordering, dispatch purity) is named falsifier work — doc rule 7
applied to the supervisor.

## Statelessness via the ledger

**A supervisor session holds no state a fresh session cannot rebuild from
the ledger.** This is not a discipline; it is the falsified completeness
law doing new work: replay determinism already asserts that every input to
every decision is ledger-recorded (`80-validation.md` § replay
determinism), so a successor reading the ledger reads everything its
predecessor knew that mattered. Context exhaustion is therefore handled by
**session succession**, never by summaries held in anyone's head: when a
session's leash trips (`Agent.Stop`, `Fault.Context_exhausted` — the same
bound any agent has), the host detaches it and attaches a successor. The
succession is evented (`Supervisor_session` names its predecessor), and
the predecessor's parting `Observe` steers are the only handoff — in the
ledger, structured, audited, or nonexistent.

**The boot query**, in order — bounded, never a full replay (the session's
context is the scarce resource; the boot reads digests and drills down by
pull):

1. **The run's frame:** the admitted theory and config (recovered from the
   ledger, as replay recovers them), the port table, backstops, thrown
   switches.
2. **The subscription table:** `Subscription.default` folded with the
   recorded `Subscribe` steers — the table is replayable because
   amendments are evented.
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
entirely by existing surfaces plus this doc's reader; the only addition is
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

## The supervisor beside the machine

The deepest representational question: is the supervisor **inside** the
theory — an agent-template node with a standing grant, its reads ledger
queries, its writes the steering vocabulary — or **beside** it, a
host-level surface like `Run.handle`?

The case for inside is the machine's own dogfood: a node gets token
accounting, mechanized witnessing, and settlement discipline for free, and
"the planner is an agent template like any other" (`60-agents.md`) argues
the supervisor should be too. The case collapses on the representation:
a node is *one firing of a dependency statement* — body tuples in, head
tuples out, one settlement, counted by quiescence. The supervisor fires on
no body match, mints no head tuples, and **never settles while the run
lives**; a standing node poisons quiescence ("every started node has
settled") unless quiescence grows an exemption representation, and an
exemption for exactly one privileged node is a guard wearing a type's
clothing — doc rule 8 read against itself. Worse, a supervisor-in-theory
makes the supervisor's own events fireable facts: its steers would be
tuples, its subscriptions edges, and the theory acquires a reader of every
relation whose writes feed back into scheduling — a cycle in the one graph
the whole design keeps acyclic, exempted only by the scheduler because
the scheduler is mechanical and the theory cannot see it.

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
speculation account (HANDOFF) — tokens are fuel, and the operator reads
what watching cost exactly as they read what speculation cost.

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
reader 5, `Tune`, `Steer`, the session surface), plus the HANDOFF
amendments in the same change, per doc rule 4.

## OPEN items

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

## HANDOFF — amendments to existing files (doc rule 4, deferred)

Recorded here instead of applied, because this doc lands in an isolated
worktree beside concurrent engine work; each item is one owed edit,
applied by whoever lands the implementation trigger's change (or sooner,
with the merge):

1. **`docs/architecture/30-channels.md` § the ledger** — "One log, four
   named readers" becomes five; add reader 5: *"**Supervision** — the
   supervisor's subscription-filtered escalation query and drill-down
   surface, pull-only (`90-supervisor.md`)."*
2. **`lib/ledger.mli`** — the header's "four named readers" comment
   likewise; add the `Supervision` reader module (this doc's signature);
   `Squash_cause` gains `Supervisor_abort of { reason : string }`;
   `Event.kind` gains `Steered of { steer : (* compact form of Steer.t;
   payloads by Delta_ref *); reason : string; counters : (string * float)
   list }` and `Supervisor_session of { succeeding : node Id.t option }`.
3. **`lib/speculate.mli`** — `Switch.throw`'s `thrown_by` widens to
   ``[ `Operator | `Scheduler | `Supervisor ]``; the yield-note type
   generalizes to the sum ``Drift of Drift.note | Supervisory of { text :
   string; delta : Ledger.Delta_ref.t option; disposition : [ `Continue |
   `Patch_then_continue ] }`` (with `Drift.note` unchanged inside it).
4. **`lib/fiber.mli` / `lib/agent.mli`** — `Yield`'s answer type and every
   `on_yield` signature retype from `Speculate.Drift.note list` to the
   note sum of item 3; `chase.ml`'s `on_yield_of` merges supervisory notes
   into the same drain.
5. **`lib/run.mli` / `docs/architecture/70-api.md`** — the handle grows
   the supervision surface (`attach`/`detach`/`steer`, this doc's
   signatures); the CLI gains `goat steer <ledger> ...` (the operator's
   entry to the same intake); `Report.summary` gains a supervision usage
   line beside the speculation account (`lib/report.mli`).
6. **`docs/architecture/40-scheduling.md` § settlement** — the squash
   cause list gains the supervisor cause, with the same
   never-mislabeled rule extended: a supervisor kill is never spelled as an
   operator abort.
7. **`docs/architecture/60-agents.md`** — § drift notes at yield notes the
   supervisory case of the note sum; § model pins records the mid-run bump
   lane (per-shape, evented, predictor-resetting; the auto-router ban
   untouched).
8. **`docs/architecture/80-validation.md`** — F15's probe list gains P1–P4
   (§ unforgeability); the roster gains **F16 — witnessed steering** (a
   rigged session drives every `Steer` constructor; each application's
   machinery events are preceded by its `Steered` event; replay reproduces
   every application with supervisor turns substituted from the ledger) and
   **F17 — supervision never delays dispatch** (an arbitrarily slow rigged
   supervisor turn changes no unrelated node's dispatch timing; F4's
   instrumentation extended over the feed fold).
9. **`docs/architecture/README.md`** — the documents table gains the
   `90-supervisor.md` row: *"The supervisory plane: the fifth ledger
   reader and its subscription table, the typed steering vocabulary,
   unforgeability probes, session succession, the beside-the-machine
   ruling."*
