# 20 — The Medium

The movement layer: the two substrates everything travels through — the
**ledger** (communication) and the **one shared tree** (memory) — and the
laws that keep them coherent. Facts, progress, drift, and messages all move
here. Readers: the `Channel`, `Ledger`, `Witness`, and `Retire.Frontier`
modules; `30-scheduling.md` (which consumes readiness, hypotheses, and
witnesses); `40-agents.md` (which consumes delivery and grants).

## The two substrates

Pike's proverb is this layer's constitution (`00-product.md` § the two
co-equal bets): **share memory by communicating, never communicate by
sharing memory.** The tree is never a coordination channel — no participant
infers another's progress from bytes; all coherence travels as evented
facts on the ledger, and the tree is a **cache** of the ledger's live
frontier. The analogy is exact, and every row is landed or normative
machinery:

| Coherence protocol | GOAT CODE |
|---|---|
| The shared cache | The one working tree |
| The directory | The witness index (`Ledger.Witness_index`) |
| Bus write traffic | Store events with delta refs |
| Invalidations | Invalidations (`Channel.invalidate`) |
| Snoop responses | Drift notes at yield, footprint-filtered |
| A snoop hit on a dirty line | A read of a neighbor's uncommitted store — a `Store_buffer` hypothesis with the landed refresher |
| Write-back | Retirement: the committed coordinate advances |

The flat org is not new machinery; it is the recognition that per-node
isolation (private worktrees) was a *second* coherence mechanism running
beside the one the ledger already implements, and doc rule 8 says delete
the duplicate. Same repo, no branches, no worktrees: workers read
ambiently within their grants, sense each other through witnessed state,
and converge continuously instead of merging terminally.

## The ledger

**Every tool call every agent makes is an event, appended to one append-only
ledger.** An event records: the node id and its firing provenance, the
generation of the node's execution, the tool, the **footprint** (the
addresses touched — file paths, relation ids, machine resources), the
direction (load / store / effect), and a ref to the payload (net delta for
stores; payloads live in the object store, never inline). The ledger is the
system's architectural state made durable — the fired graph, every witness,
every settlement, every message and steer is reconstructible from it.

**One log, five named readers** (the anti-transcription rule, satisfied):

1. **Resume/replay** — the ledger is the journal a future resume path replays
   (OPEN in `README.md`); today it is what the replay-determinism falsifier
   checks against (`50-api.md`).
2. **Telemetry** — blocked/queue/run decomposition per node, critical path,
   speculation counters, all computed from event timestamps, all pull-only
   (`50-api.md`). No logger rides the dispatch path; telemetry is a
   query over the ledger.
3. **The predictor** — contract-survival and reconcile-cost history per task
   shape is a ledger query (`30-scheduling.md`).
4. **The witness index** — read-set and write-set extraction per node
   (below), consumed by conflict detection at retire (`30-scheduling.md`).
5. **Supervision** — the supervisor's subscription-filtered escalation query
   and drill-down surface, pull-only (`40-agents.md` § the fifth reader).

## Event taxonomy

Every tool call classifies as exactly one of:

- **Load** — a read: file read, grep, tuple read through a ref slot, a
  message pull. Loads are logged (they build the witness) and **never
  forwarded** — no one downstream needs to know you read something; the
  ledger needs to know for conflict detection.
- **Store** — a write against the shared tree at the node's granted paths:
  file edit, file create/delete. Stores coalesce as **net deltas** (twelve
  edits to one file forward as one delta; an edit that restores the original
  cancels to nothing), and every store's full content is written to the
  object store at store time (§ the blob store). In-flight stores are the
  store buffer: uncommitted coordinates, squashable by settlement, snoopable
  by anyone whose grant covers the address (§ store-to-load forwarding).
- **Effect** — an action against shared machine state outside the granted
  write surface: a network call, a package install, a global cache write.
  Effects acquire the machine-resource lock for their footprint
  (mkdir-atomic, holder-named) and are the one event class that is *not*
  squashable by construction — so a speculative node's tool surface
  **cannot contain** a non-idempotent effect tool: the grant type is indexed
  by speculation status and has no constructor for that combination
  (`40-agents.md` § tool grants) — the forbidden grant is unrepresentable,
  not refused at dispatch. This asymmetry is the honest price of
  speculation, stated once.

**The blob store is git's object database.** Every store tool writes its
content into `.git/objects` at store time (`git hash-object -w`
equivalent); `Ledger.Delta_ref` carries the blob oid. The ref is a content
address, the store is the one git already maintains, and every historical
byte remains materializable forever without any branch existing to name it.
Readers of the oid: the retire step (`30-scheduling.md` § the landing),
`Frontier.materialize`, and consumers pulling deltas through invalidations.
(This closes the old blob-ref-scheme OPEN item.)

**Torn reads are unrepresentable at the file grain.** Every file store is
tmp+rename: the store tool writes the full content to a same-directory
temporary, then `rename(2)` — atomic on POSIX — replaces the target. This
lives in the tool loop's store path, in the same tool call that writes the
blob and returns the Store event — one site, three obligations, ordered:
blob first (the oid must exist before any event names it), rename second,
event append third. Within the process the fiber mount already serializes
tool writes at yield granularity; tmp+rename is for the readers the domain
does not schedule — gate subprocesses, external tools, the operator's own
editor.

**Mechanized witnesses.** Because every load is an event with a footprint,
**a node's read-set is captured by observation, not by self-report**. The
node's generation witness (`30-scheduling.md`) is assembled by the harness
from its own event stream: the set of (address, generation, content-hash)
triples it actually read. An agent cannot fabricate a witness, cannot
forget a dependency it consulted, and cannot claim staleness-immunity it
doesn't have. Conflict detection at retire is then a set intersection over
logged footprints — my read-set × your write-set at a newer generation —
memory disambiguation, mechanized. Reader: `30-scheduling.md`'s conflict
judge; this is also why the witness needs no trust boundary of its own.

What a load may *claim* is decided by **where the read was served from**
(the self-witness ruling): a read served from committed state witnesses the
real committed (generation, content); a read served from another node's
in-flight store is an in-flight observation (the producer's uncommitted
coordinate, content judged when that producer lands); a read served from
the node's **own draft** is store-to-load forwarding of its own in-flight
work and claims **nothing** — such a triple could never hold at the node's
own retire (its landing hasn't happened when the witness is judged), and a
vacuous one would shield the conflict judgment. The Load event is still
appended (the footprint is real); only the witness triple is withheld.
Likewise a `glob_list` observes the listing itself: a listed path whose
committed state is Landed witnesses the committed (generation, content)
pair straight from the lookup; a path that exists only in flight
contributes no triple — existence-of-uncommitted is not a witnessable
claim in v0.

## Validity is a ledger coordinate

The flat org's spine, from which squash, recovery, and sensing all derive:

**Validity is a ledger coordinate, never a filesystem fact. The working
tree is a materialization — a cache — of the ledger's live frontier; bytes
whose producing store event is dead have no live coordinate and are
garbage nothing can witness into committed state.**

The frontier is a derived view over landed vocabulary, and it replaces
per-node isolation outright:

```ocaml
(* lib/retire.mli — the frontier. Readers: the read resolver (hypothesis
   sourcing), the retire step (commit construction), boot and crash
   recovery (materialize), and the hygiene sweep (garbage identification). *)
module Frontier : sig
  type t

  (** The live top of one address. [In_flight] tops carry the writer —
      the read resolver turns a read of one into a [Store_buffer]
      hypothesis on exactly that node. *)
  type top =
    | Committed of Witness.Committed_state.t
    | In_flight of {
        writer : Ledger.node Id.t;
        content : Ledger.Content_hash.t;
        base : Ledger.Content_hash.t option;
            (** The writer's read point — the same base coordinate the
                disjoint law judges (30-scheduling.md § retirement). *)
      }

  val of_ledger : Ledger.t -> committed:Committed.t -> t

  val top : t -> Ledger.Address.t -> top

  val materialize : t -> repo:string -> unit
  (** Converge the tree to the frontier: write each address's live top.
      Idempotent; appends nothing; moves no coordinate. This is checkout,
      not restore — it runs at boot, after a crash, and as the hygiene
      sweep, never on any per-node path. *)
end
```

**Liveness is a derived judgment, not a second supply.** A store event is
live iff its node is unsettled or retired; a squash settlement
(`Settled (Squashed cause)`) is the one appended fact, and every store
coordinate under that node is provenance-dead *by derivation*. No per-event
kill marks, no tombstone events — representation before control flow: the
settlement the ledger already appends carries the whole judgment.

**The half-open interval.** Committed versus in-flight is a coordinate on
an address's event sequence, never a place: everything at or below the
committed coordinate (`Committed.state` — generation, content, writer) is
committed; live store events above it are in-flight; retirement moves the
boundary. Nothing about the boundary is a directory.

## Squash without isolation, fix-forward only

Squash was never a filesystem operation — the filesystem half was always
hygiene — and under the fix-forward ruling (`00-product.md`) it decomposes
into exactly three appends-and-derivations:

1. **The settlement.** `Settled (Squashed cause)` lands for every node in
   the provenance-closed subtree (`Retire.squash_set`). Every store
   coordinate under those nodes is now provenance-dead, by the derivation
   above. Nothing touches the tree.
2. **The cascade.** Consumers holding hypotheses on the dead producer route
   `Producer_squashed` → flush-the-subtree, always (the drift table's one
   unconditional row — `30-scheduling.md`). Consumers whose reads escaped
   hypothesis tracking are caught by the backstop: the witness is
   content-judged, and a triple whose content resolves only to a dead
   coordinate cannot describe committed state — `Witness.holds` refuses,
   and the rejection routes forward through the drift table like any moved
   witness. One deliberate consequence stands: a consumer that read bytes
   which happen to equal committed content retires soundly even if their
   writer later squashed — soundness is content, not lineage, and the
   provenance cascade fires first in every case the hypothesis tracker saw.
3. **The forward repair.** The squashed statement's body match reissues
   (reissue is a scheduler decision with a recorded reason). The reissued
   producer's stores land on the same paths as ordinary forward stores —
   **overwrite-on-reissue** — and its retirement advances the generation. A
   consumer holding a dead witness cannot retire (step 2) and is routed
   forward by the drift table to the reissued producer's landing. Nothing
   ever moves a coordinate backward.

**Dead bytes are hygiene, never correctness.** A squashed node's write to a
committed path leaves dead bytes on disk while the frontier's top for that
path is the untouched committed coordinate; a squashed node's fresh file
has a frontier top of `Absent`. Nothing can witness either into committed
state (step 2's backstop), so their lifetime is an aesthetic and disk-space
concern. **Decision — overwrite-on-reissue primary, lazy convergence
backstop.** The common case cleans itself: the reissue writes the same
paths. The backstop is `Frontier.materialize` run as the hygiene sweep — at
quiescence, at boot, after a crash — which converges every address to its
live top (writing committed content over dead bytes, deleting files whose
top is `Absent`). **Alternative:** eager per-squash cleanup (materialize
the squashed node's write set inside the squash path) — lost because it
puts filesystem I/O on the settlement path (dispatch purity, F4) to serve
no correctness need, and because mid-run the very next event may be the
reissue's overwrite of the same path. **Reverses if:** a measured falsifier
shows an agent's read of dead bytes burning material tokens between squash
and reissue (the ledger names the window) — the recorded upgrade is
materializing just the squashed write set at the squashed node's port, off
the dispatch path.

**Materialization is not revert.** `materialize` writes the frontier's
live top — content whose coordinate never moved. State is the ledger; the
tree has no history, only a current fill that either matches the frontier
or is garbage. Re-asserting *historical* content as the new truth — an
operator or agent deciding generation g's content should stand again — is
a different act: an ordinary forward store, a new event, generation
advances, invalidations fan. Reading history (git objects from any past
retirement) is not reverting; writing it back is a forward store. Both
paths exist; neither retreats a coordinate.

**The crash story is an argument for the ruling.** A revert-based design
has a crash mode no log can classify: die mid-rollback and the tree is
half-restored, neither the old state nor the new, and recovery must first
decide *which direction* it was moving. Here that state is unconstructible
because the direction doesn't exist: every ledger append is monotone, the
tree is a cache, and crash recovery is exactly boot — re-derive the
frontier from the ledger (`Frontier.of_ledger`), converge the tree
(`materialize`), reissue in-flight producers forward (their settlements
never landed, so their coordinates never went live; their disk residue is
the same garbage class squash leaves, swept by the same mechanism). One
recovery path, no special cases, and it is the resume path the durability
OPEN item already owed.

The falsifiers holding all of this are FL1–FL7 (`50-api.md`).

## Channels: pre-opened, typed by witness

A channel is a relation's tuple log. **Every channel exists at admission,
before any node runs.** Inheritance stated once: s6/systemd socket
activation — the supervisor opens all sockets first, so services start in
any order and dependency resolves at first read, with the kernel buffering
in between. Here the theory's relations are all "opened" (allocated, typed,
subscribable) the moment admission passes, which is what makes eager start
legal (`30-scheduling.md` § eager start): a consumer node can begin before
its producers have produced — before they have even *started* — because the
channel it will eventually read is already a real object it can hold,
subscribe to, and suspend on.

**"Typed" is by witness, not by cast.** The channel table is keyed by
relation name, but each channel's tuple log is packed with the payload
witness its relation minted at declaration (`Theory.Relation.witness`, a
`Type.Id`), and a channel end is granted only by presenting that very
declaration — the lookup recovers the payload type through
`Type.Id.provably_equal`, so a writer or reader end at the wrong payload
type is unconstructible and no cast exists in the channel layer. A
re-declaration that collides on the name refutes the judgment and is
refused at the lookup; the negative compile is falsifier F15
(`50-api.md`), the value-level refusal a runtime falsifier beside it.
Possession of the registry is possession of the proof it matches the
admitted theory: `Channel.open_all` takes `Theory.admitted` and nothing
else constructs one.

**Readiness is a property of a read, never of a node.** A node holds its
channels from birth; each individual read either proceeds (witnessed),
returns a hypothesis (speculation, decided at the read —
`30-scheduling.md` § read-time binding), or suspends the fiber until the
channel's first invalidation for that address. The suspended state is the
buffered-socket state: free to hold, woken by delivery. Nothing in this
layer knows or cares whether the producer has started; producer lifecycle
is the scheduler's affair.

**The derivation law, restated for channels.** Tuple flow through a
relation is derivation: from the statement that mints into it to the
statements whose bodies read it, forward only, no cycles — a node can
write only to relations its statement mints into (falsifier F11). What the
two-graphs ruling (`00-product.md`) changed is not this; it is that the
relation graph stopped being the *only* legal contact between
participants. Communication rides messages (§ below), and messages derive
nothing.

## Messages, and no walls

**Any participant may address any other — worker to worker, worker to
supervisor, on or off the declared dependency edges. Declared structure is
advisory: a filter that tunes delivery, never a wall that forbids flow.**
The operator ruling, verbatim: *"just like agents want to, they should be
able to cut through the crap and talk with anyone they like. there are no
hard policy walls."*

A **message** is an evented fact:
`{ from : participant; to : participant | broadcast; payload_ref; provenance }`
— appended to the ledger before it is anything else, payload in the object
store, sender provenance total. What makes wall-less messaging safe is the
medium, not topology (`00-product.md` § the two graphs):

- **Every message is witnessed on read.** A receiver's pull of a message is
  a Load event; the message enters its observed witness carrying the
  sender's provenance. If the sender was speculative and squashes, the
  message is dead provenance: receivers that consumed it are
  cascade-squashed (hypothesis tracked) or refused at retire
  (content-judged witness) — exactly the machinery that handles a dead file
  draft, unchanged.
- **Messages inform; they never derive.** No statement fires on a message;
  no tuple's provenance cites one as a body match; admission never sees
  them (`10-theory.md` § feedback is forward, scope note). A message that
  needs to *produce work* is a forward relation the theory hasn't declared
  yet.
- **Messages inform; settlements actuate.** No message kills, re-fires, or
  commits anything. Interrupt-class actuation (§ delivery) belongs to the
  judgment hierarchy — scheduler, supervisor, operator — because a kill
  spends shared wall clock.

Engine-authored drift notes, supervisor notes (`40-agents.md` § the
steering vocabulary, `Note`), and peer messages are **one kind**: they
share the delivery lane (the yield-time note sum), the subscription
discipline (§ below), and the eventing. The supervisor's `Note` steer is
simply the first message class built.

**Decision — no walls.** **Alternative:** flow only on declared edges
(the prior "unidirectional, permanently" ruling read as a communication
law) — lost because the protection it bought (squash precision) is a
provenance-and-witness property the medium already provides, making the
topology wall a duplicate coherence mechanism (doc rule 8: delete the
duplicate — the argument that killed worktrees, applied to routing); and
because walls forbid the ambient sensing the flat org exists to grant.
The derivation half of the old ruling is retained permanently
(`10-theory.md`). **The honest cost:** off-edge chatter has no static
termination story; the backstops own it (`30-scheduling.md`), and message
volume is a counter (`50-api.md`). **Reverses (walls return) if:** ledger
evidence shows off-edge messaging producing coherence failures the witness
machinery cannot convict, or message-driven token spend that the
subscription discipline cannot bound.

**Status: doc-resident until its trigger.** The message event class and
peer-to-peer sends are unbuilt; the delivered note sum and the supervisor's
`Note` are the designed carriers (`40-agents.md`). *Trigger: the first
censused workload where a worker's knowledge would change a sibling's
in-flight work and the drift machinery doesn't already carry it — or the
supervisor module landing, whichever comes first.*

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

## Footprint filtering, and the escape surfaces

Forwarding every event to every dependent is snooping without a filter. Each
edge carries a **footprint declaration** compiled from its contract: the ref
slots it reads plus a file-glob grant. An invalidation forwards down an edge
only when its address intersects the edge's declared footprint. Two
consequences:

- The theory author never writes routing; routing is derived from what the
  contract says the consumer depends on.
- **The declaration is a filter, never a wall** — the general principle the
  no-walls ruling elevated to doctrine. Correctness comes from the observed
  witness; the declaration only tunes delivery and attribution.

Two escape classes, two mechanisms:

- **A load outside the declared footprint** (the consumer's event stream
  shows a read the declaration didn't cover) is a **footprint escape** —
  surfaced at retire as a typed ledger event (`Footprint_escape`, one per
  escaped address, the tool named) and, at quiescence, a violated
  `footprint_cover` verdict on the settled map whose offenders name the
  node and address; the escape never blocks the retire. Readers: the
  `footprint_cover` verdict and `Report.explain`'s per-node escape list —
  what the theory author reads to grow the declaration (falsifier F16).
- **An effect writing outside its declared resource footprint** is
  invisible to store events, so the flat org owes the **unexplained-bytes
  sweep**: at quiescence (and at every hygiene materialization), diff the
  tree against the frontier; bytes no live store event explains are
  attributed to the effect events whose ledger window covers them and
  surfaced exactly like footprint escapes — logged, reported at retire, a
  witness the declaration must grow to cover.

## Store-to-load forwarding: ambient sensing

**Everything in-grant is snoopable, automatically.** A read whose address
tops `In_flight` at the frontier is a tracked `Store_buffer` hypothesis on
exactly that writer — the resolver consults the frontier, not a mount
table; there is no mount to arrange and no opt-in surface. The snooped read
enters the consumer's witness at the producer's uncommitted coordinate,
which is exactly what makes the speculation honest — if the producer's
final committed delta differs, the consumer's witness is stale and the
reconcile path fires; if the producer squashes, the consumer's hypothesis
dies with it, and provenance already links them.

"Workers sensing what's around them" is therefore **not context-stuffing**;
it is three channels, now ambient: (a) snoop reads of the shared tree —
every read of in-flight state is a tracked hypothesis; (b) drift notes and
messages at yield, footprint-filtered; (c) the operand and channel
machinery. Full visibility, leveled interruption (§ delivery).

**Decision — snoop mounts deleted.** **Alternative:** keep explicit snoop
mounts as an opt-in sensing surface — lost because the mount was a
materialization detail of private trees (a path prefix to reach a
neighbor's directory), and with one tree it degenerates into a second,
redundant supply of read-visibility policy beside `read_globs`; the
hypothesis tracker, not the mount, was always what made snooping honest.
**Reverses if:** never as a mount table; a workload needing *finer*
sensing tiers than read_globs express is asking for a grant grammar
extension (`40-agents.md`).

This is the streaming-partial-outputs lever: the implementer's type
definitions land in the tree minutes before the function bodies; a
consumer speculating against the interface contract reads them as they
stabilize, and by the time the producer retires, the consumer's hypothesis
is usually already conforming — making the free-commit case
(`30-scheduling.md` § the generation-witness protocol) the common case.
Reader: `30-scheduling.md`'s hypothesis refresher.

## Delivery: the two modes

The constitutional derivation is in `00-product.md` § the two message
modes; the mechanics:

**Queued (the default): check-on-yield.** Invalidations, drift notes, and
messages are delivered at the receiver's yield points — between tool calls,
at its fiber's suspension — coalesced, read together. The delivered form is
compact (a contract-drift note, a schema diff, a message digest); the agent
decides pull-now vs finish-current-step. The receiving fiber has exactly
one listening point, and everything queued arrives there as one note sum
(`40-agents.md` § notes at yield).

**Interrupt (the exception): kill-now.** An interrupt is delivered *now*,
mid-turn, by discontinuing the fiber — the squash path, already built: the
stack unwinds, finalizers run, the node settles with its typed cause, and
reissue (with the redirect in the new dispatch) is the scheduler's
recorded decision. An LLM cannot absorb a mid-token interrupt — the call
completes or is wasted — so there is no "pause and reconsider" middle
state: interrupt ≡ discontinue, abort by construction, applied to
attention. Wasting the in-flight turn's tokens is the point, and it is
constitutional: wall clock outranks spend, and a turn known to be useless
is cheapest dead. Who may interrupt: the scheduler (mechanically, via the
drift table and squash causes), the supervisor (an `Abort` steer, evented
with evidence), the operator (sovereign). A worker may not — it sends a
message and the judgment hierarchy decides (§ messages).

**Decision — interrupts are first-class, overturning check-on-yield-only.**
The prior ruling deferred mid-flight interruption ("an agent mid-tool-call
cannot absorb an interrupt anyway; turn-restarts cost a full context
replay") and recorded hypothesis-killing invalidations as the upgrade
class. The upgrade is hereby taken, on the recorded path: the one class
worth a wasted call is exactly the kill — a dead hypothesis, a
known-useless turn, a wall-clock emergency — and the fiber substrate
delivers it as discontinue with real finalizers, already falsified
(FB2/FM2). What check-on-yield protected survives intact: nothing
*informational* interrupts a turn; reconsideration is always queued.
**Alternative:** stay yield-only and let a known-dead turn run to
completion — lost by constitution: it waits to save tokens.
**Reverses if:** measured interrupt-reissue cycles (kill, redispatch,
re-acquire context) exceeding the cost of letting turns drain, per shape —
the ledger names the comparison; the concession would be raising the
interrupt threshold, never deleting the mode.

## The subscription discipline

**Every participant has a subscription table — rows of event class ×
threshold → level — and the levels are one closed scale:**

- **Mute** — ledger-only: available to pull, never delivered.
- **Digest** — coalesced into the receiver's next yield (a worker's note
  drain, the supervisor's next turn).
- **Wake** — act now: resume a suspended fiber to read it; queue a
  supervisor turn immediately; for a mid-turn worker, Wake cannot cross
  the turn boundary — only a kill can (§ delivery), so a Wake-leveled row
  for a running worker means "first thing at the next yield, and wake the
  fiber if suspended."

The table is data — inspectable, amendable mid-run (the amendment is
itself an evented act), replayable as a fold of the default plus recorded
amendments. The supervisor's table (`40-agents.md` § the fifth reader) is
this mechanism at the supervision plane; workers get the same shape with
template-declared rows, defaulting to Digest for drift notes and addressed
messages, Mute for everything else. This is the invalidate-don't-update
posture applied to every context window in the system: the scarcest
resource a standing participant has is its context, and per-event
play-by-play fills it exactly the way update-flooding fills a bus.

## OPEN items

- **The message event class** — doc-resident, trigger recorded (§ messages).
- **Invalidation coalescing window.** A producer emitting ten stores to one
  address in one turn should invalidate once. v0: coalesce per yield (the
  producer's own turn boundary). *Trigger: measured invalidation volume
  annoying consumers (token cost of drift notes in agent context, a ledger
  query).*
- **Worker subscription surface.** The supervisor's table is designed; the
  worker-side declaration (template-declared rows) has no surface yet.
  *Trigger: the message event class landing — the first sender needs a
  receiver discipline.*
- **Hygiene cadence.** Lazy convergence runs at boot and quiescence;
  whether long runs want a mid-run sweep (port-idle moments) is unmeasured.
  *Trigger: FL-suite or live evidence of agents reading dead bytes in the
  squash-to-reissue window.*
- **File-grain gate footprints** — owned with gates (`30-scheduling.md`
  § gates on the shared tree).
- **Cross-machine ledger.** Single-writer append-only file in v0. *Trigger:
  the multi-machine OPEN in `README.md`.*
