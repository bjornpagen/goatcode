# 30 — Channels and Events

The movement layer: how facts, progress, and drift travel between nodes.
Readers: the `Channel`, `Ledger`, and `Witness` modules; `40-scheduling.md`
(which consumes readiness); `50-commit.md` (which consumes witnesses and
footprints).

## The unidirectional law

**Channels are unidirectional, permanently. A channel is a relation; flow is
from the statement that mints into it to the statements whose bodies read it.
The only bidirectional party in the system is the scheduler.**

**Decision.** **Alternative:** bidirectional channels (consumers can message
producers — ask questions, request revisions) — lost three times over:
(1) squash precision dies — a squashed speculative consumer that had already
influenced its producer has leaked into surviving state, and "abort by
construction" (`50-commit.md`) becomes abort-by-compensation; (2) the
formalism dies — a TGD derives head from body, nothing flows backward through
a rule, so backchannels would exit the theory the work is declared in;
(3) the graph acquires cycles and the admission check (`10-theory.md`
§ termination) loses its object. Everything a backchannel would carry is
representable forward: a question, a revision request, a refutation is a
*new fact* in a *new relation* that fires a *new node* — iteration is
generations, feedback is a forward edge (`10-theory.md` § feedback is
forward). **Reverses if:** never. This is load-bearing for the retire
protocol's provability; a workload that seems to need a backchannel needs a
relation it hasn't declared yet.

## Pre-opened channels (socket activation)

**Every channel exists at admission, before any node runs.** Inheritance
stated once: s6/systemd socket activation — the supervisor opens all sockets
first, so services start in any order and dependency resolves at first read,
with the kernel buffering in between. Here the theory's relations are all
"opened" (allocated, typed, subscribable) the moment admission passes, which
is what makes eager start legal (`40-scheduling.md` § eager start): a
consumer node can begin before its producers have produced — before they
have even *started* — because the channel it will eventually read is already
a real object it can hold, subscribe to, and suspend on.

**Readiness is a property of a read, never of a node.** A node holds its
channels from birth; each individual read either proceeds (witnessed),
returns a hypothesis (speculation, decided at the read —
`40-scheduling.md` § read-time binding), or suspends the fiber until the
channel's first invalidation for that address. The suspended state is the
buffered-socket state: free to hold, woken by delivery. Nothing in this
layer knows or cares whether the producer has started; producer lifecycle
is the scheduler's affair, connection topology is fixed at admission.
Reader: the fiber runtime's read operation, and `40-scheduling.md`, which
owns what happens at each read outcome.

## The ledger

**Every tool call every agent makes is an event, appended to one append-only
ledger.** An event records: the node id and its firing provenance, the
generation of the node's execution, the tool, the **footprint** (the
addresses touched — file paths, relation ids, machine resources), the
direction (load / store / effect), and a ref to the payload (net delta for
stores; payloads live in the worktree or blob store, never inline). The
ledger is the system's architectural state made durable — the fired graph,
every witness, every settlement is reconstructible from it.

**One log, four named readers** (the anti-transcription rule, satisfied):

1. **Resume/replay** — the ledger is the journal a future resume path replays
   (OPEN in `README.md`); today it is what the replay-determinism falsifier
   checks against (`80-validation.md`).
2. **Telemetry** — blocked/queue/run decomposition per node, critical path,
   speculation counters, all computed from event timestamps, all pull-only
   (`80-validation.md`). No logger rides the dispatch path; telemetry is a
   query over the ledger.
3. **The predictor** — contract-survival and reconcile-cost history per task
   shape is a ledger query (`40-scheduling.md`).
4. **The witness index** — read-set and write-set extraction per node
   (below), consumed by conflict detection at retire (`50-commit.md`).

## Event taxonomy

Every tool call classifies as exactly one of:

- **Load** — a read: file read, grep, tuple read through a ref slot, worktree
  inspection. Loads are logged (they build the witness) and **never
  forwarded** — no one downstream needs to know you read something; the
  ledger needs to know for conflict detection.
- **Store** — a write against the node's own worktree: file edit, file
  create/delete. Stores coalesce in the worktree as **net deltas** (twelve
  edits to one file forward as one delta; an edit that restores the original
  cancels to nothing). The worktree is the store buffer: uncommitted,
  squashable by dropping, snoopable by speculative consumers (below).
- **Effect** — an action against shared machine state outside any worktree:
  a network call, a package install, a global cache write. Effects acquire
  the machine-resource lock for their footprint (mkdir-atomic, holder-named)
  and are the one event class that is *not* squashable by construction — so
  a speculative node's tool surface **cannot contain** a non-idempotent
  effect tool: the grant type is indexed by speculation status and has no
  constructor for that combination (`60-agents.md` § tool grants) — the
  forbidden grant is unrepresentable, not refused at dispatch. This
  asymmetry is the honest price of speculation, stated once.

**Mechanized witnesses.** Because every load is an event with a footprint,
**a node's read-set is captured by observation, not by self-report**. The
node's generation witness (`50-commit.md`) is assembled by the harness from
its own event stream: the set of (address, generation) pairs it actually
read. An agent cannot fabricate a witness, cannot forget a dependency it
consulted, and cannot claim staleness-immunity it doesn't have. Conflict
detection at retire is then a set intersection over logged footprints —
my read-set × your write-set at a newer generation — memory disambiguation,
mechanized. Reader: `50-commit.md`'s conflict judge; this is also why the
witness needs no trust boundary of its own.

## Invalidate, don't update

**A notification is an invalidation — small, typed, payload-free:**
`{ address; new_generation; producer_node; delta_ref }`. Consumers **pull**
the net delta through `delta_ref` if and when they decide it matters.

**Decision.** **Alternative:** update-based delivery (push the payload down
every subscribed channel) — lost because the scarcest resource in the system
is the consumer agent's context window, and update-flooding fills it with
other agents' play-by-play exactly the way update-based coherence floods a
bus; the moment two producers get chatty, every consumer pays. Invalidations
cost a few tokens, carry enough to decide relevance, and defer the payload
until the consumer is at a point where reconciling is cheap. Pull is also the
only shape consistent with pins-acknowledge-never-re-fix: drift is a signal
a consumer *acknowledges*, never a mutation performed *on* the consumer.
**Reverses if:** measured invalidation-then-pull round trips dominate
reconcile latency on real pipelines (ledger timestamps decide) — the recorded
upgrade is inlining deltas below a size threshold into the invalidation,
which changes the economics, not the semantics.

## Footprint filtering

Forwarding every event to every dependent is snooping without a filter. Each
edge carries a **footprint declaration** compiled from its contract: the ref
slots it reads plus a file-glob grant. An invalidation forwards down an edge
only when its address intersects the edge's declared footprint. Two
consequences:

- The theory author never writes routing; routing is derived from what the
  contract says the consumer depends on.
- A consumer touched by an address *outside* its declared footprint (its
  event stream shows a load the declaration didn't cover) is a **footprint
  escape** — logged, surfaced at retire, and treated as a witness the
  declaration must grow to cover. The declaration is a filter, never a wall:
  correctness comes from the observed witness, the declaration only tunes
  delivery. Reader: the retire conflict judge (which uses observed sets) and
  the theory author (who reads escape reports to fix declarations).

## Store-to-load forwarding

**Speculative consumers may snoop a producer's store buffer before it
retires.** A node's worktree deltas are readable (read-only mounts) by nodes
speculating downstream of it; the snooped read enters the consumer's witness
as (address, producer's *uncommitted* generation), which is exactly what
makes the speculation honest — if the producer's final committed delta
differs, the consumer's witness is stale and the reconcile path fires; if
the producer squashes, the consumer's hypothesis dies with it, and provenance
already links them.

This is the streaming-partial-outputs lever: the implementer's type
definitions land in its worktree minutes before the function bodies; a
consumer speculating against the interface contract reads them as they
stabilize, and by the time the producer retires, the consumer's hypothesis
is usually already conforming — making the free-commit case
(`50-commit.md` § state-changing generations) the common case. Reader:
`40-scheduling.md`'s hypothesis refresher.

## Delivery: check-on-yield

**Invalidations are delivered at the consumer's yield points** — between tool
calls, at its fiber's suspension — never as mid-flight interrupts. The
delivered form is a compact contract-drift note (the schema diff or delta
summary, rendered small); the agent decides pull-now vs finish-current-step.
**Decision.** **Alternative:** continuous snooping (interrupt the agent's
current call, restart its turn with fresh context) — lost for v0 because an
agent mid-tool-call cannot absorb an interrupt anyway (the call completes or
is wasted), turn-restarts cost a full context replay, and yield points arrive
every few seconds in practice. **Reverses if:** ledger measurement shows
stale-speculation windows (invalidation appended → consumer's next yield)
long enough that wasted work between them dominates reconcile cost — the
OPEN item in `README.md`, with the upgrade path (interrupt only on
*hypothesis-killing* invalidations, the one class worth a wasted call)
recorded here.

## OPEN items

- **Blob ref scheme** for large payloads (content hash vs path+generation) —
  owned here, triggered by the snooping implementation (`20-contracts.md`
  carries the cross-reference).
- **Invalidation coalescing window.** A producer emitting ten stores to one
  address in one turn should invalidate once. v0: coalesce per yield (the
  producer's own turn boundary). *Trigger: measured invalidation volume
  annoying consumers (token cost of drift notes in agent context, a ledger
  query).*
- **Cross-machine ledger.** Single-writer append-only file in v0. *Trigger:
  the multi-machine OPEN in `README.md`.*
