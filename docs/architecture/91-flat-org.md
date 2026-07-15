# 91 — The Flat Org: One Tree, No Branches, No Worktrees

Status: **the flat-org redesign, in flight.** Until the migration lands,
`30-channels.md`, `40-scheduling.md`, `50-commit.md`, and `60-agents.md`
describe the shipped worktree machine and this doc is the design of record
for its successor; each migration step amends the owning doc in the same
change (doc rule 4) and strikes the corresponding HANDOFF row below. The
cross-cutting supervisor surface (`90-supervisor.md`) is in flight on a
sibling branch; where this doc touches its territory (leveled interruption,
the anti-firehose law) it cites the shared ruling, never the file.

Two operator rulings govern, verbatim:

> "the workers should be able to sort of sense what's going around them,
> and we hard reject worktrees. the culmination: same repo, no branches,
> no worktrees, full context, working together, speculative execution."

> "only fix forward. no reverting. there's no reverting in real life,
> there should be none in our architecture. i question the requirement of
> reverting at all."

The second ruling is total: **revert is unrepresentable, everywhere in the
architecture** — no inverse deltas, no undo logs, no rollback, and no
revert smuggled under another name. A "restore" operation is revert;
re-asserting known-good content as an ordinary forward store at the next
generation is not. Where any prior wording implied undo (squash's cleanup,
crash recovery, a gate's failed verdict), this doc resolves it fix-forward
and says so at the site.

## The reframe: the ledger is the coherence protocol

Today's machine gives each node a private store buffer (a git worktree)
and makes snooping an explicit read-only mount. The flat org collapses
this to **one shared store buffer — the working tree itself** — and the
concurrency control moves from isolation to detection-and-repair, which is
already the machine's speculation philosophy: the worst case for a bad
hypothesis is wasted tokens, never corruption. The analogy sharpens rather
than breaks — the tree becomes the shared cache and the ledger becomes the
coherence directory:

| Coherence protocol | Flat org |
|---|---|
| The directory | The witness index (`Ledger.Witness_index`) |
| Bus write traffic | Store events with delta refs |
| Invalidations | Invalidations (`Channel.invalidate`), unchanged |
| Snoop responses | Drift notes at yield, footprint-filtered |
| A snoop hit on a dirty line | A read of a neighbor's uncommitted store — a `Store_buffer` hypothesis with the landed refresher |
| Write-back | Retirement: the committed coordinate advances |

Every mechanism in that table is landed machinery. Every store is evented
with a delta ref; every load is witnessed with a content hash; a read of a
neighbor's uncommitted write is a store-buffer hypothesis whose refresher
discharges or drifts it at the producer's landing; squash cascades through
total provenance; the base-coordinate disjoint law convicts same-base
clobbers; and the fiber mount means **one domain** — every tool write
serializes at yield granularity, so intra-process byte races do not exist.
The flat org is not new machinery; it is the recognition that the worktree
was a *second* coherence mechanism running beside the one the ledger
already implements, and doc rule 8 says delete the duplicate.

"Workers sensing what's around them" is therefore **not context-stuffing**.
It is three existing channels, now ambient: (a) snoop reads of the shared
tree — every read of in-flight state is a tracked hypothesis, no mount to
arrange; (b) drift notes at yield, footprint-filtered (landed, B3/B6);
(c) the operand and channel machinery. Full visibility, leveled
interruption — the same anti-firehose law as the supervisor design (90-supervisor.md):
notifications are invalidations, payloads are pulled, and nothing
interrupts a turn mid-flight.

## State and materialization: validity is a ledger coordinate

The design's spine, from which every section below derives:

**Validity is a ledger coordinate, never a filesystem fact. The working
tree is a materialization — a cache — of the ledger's live frontier; bytes
whose producing store event is dead have no live coordinate and are
garbage nothing can witness into committed state.**

The frontier is a derived view over landed vocabulary, and it replaces
`Retire.Worktree` outright:

```ocaml
(* lib/retire.mli — Worktree is deleted; the frontier replaces it.
   Readers: the read resolver (hypothesis sourcing), the retire step
   (commit construction), boot and crash recovery (materialize), and the
   hygiene sweep (garbage identification). *)
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
                disjoint law judges (50-commit.md § retirement order). *)
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
(`Settled (Squashed cause)`, landed) is the one appended fact, and every
store coordinate under that node is provenance-dead *by derivation*. No
per-event kill marks, no tombstone events — representation before control
flow: the settlement the ledger already appends carries the whole
judgment.

**The half-open interval.** Committed versus in-flight is a coordinate on
an address's event sequence, never a place: everything at or below the
committed coordinate (`Committed.state`, landed — generation, content,
writer) is committed; live store events above it are in-flight; retirement
moves the boundary. `Witness.Committed_state.t` and `Committed.state`
survive unchanged in type; what dies is the pretense that the boundary was
a directory.

**The blob store is git's object database.** Every store tool writes its
content into `.git/objects` at store time (`git hash-object -w`
equivalent); `Ledger.Delta_ref` carries the blob oid. This closes the
blob-ref-scheme OPEN item in `30-channels.md`: the ref is a content
address, the store is the one git already maintains, and every historical
byte remains materializable forever without any branch existing to name
it. Readers of the oid: the retire step (below), `Frontier.materialize`,
and consumers pulling deltas through invalidations.

## Squash without isolation, fix-forward only

The hard problem. The worktree made squash a directory drop; the shared
tree has no directory to drop. The answer is that squash was never a
filesystem operation — the filesystem half was always hygiene — and under
the fix-forward ruling it decomposes into exactly three appends-and-derivations:

1. **The settlement.** `Settled (Squashed cause)` lands for every node in
   the provenance-closed subtree (`Retire.squash_set`, landed). Every
   store coordinate under those nodes is now provenance-dead, by the
   derivation above. Nothing touches the tree.
2. **The cascade.** Landed machinery: consumers holding hypotheses on the
   dead producer route `Producer_squashed` → flush-the-subtree, always
   (the drift table's one unconditional row). Consumers whose reads
   escaped hypothesis tracking are caught by the backstop: the witness is
   content-judged (B7), and a triple whose content resolves only to a dead
   coordinate cannot describe committed state — `Witness.holds` refuses,
   and the rejection routes forward through the drift table like any moved
   witness. One deliberate consequence stands: a consumer that read bytes
   which happen to equal committed content retires soundly even if their
   writer later squashed — soundness is content, not lineage (law 1), and
   the provenance cascade fires first in every case the hypothesis tracker
   saw.
3. **The forward repair.** The squashed statement's body match reissues
   (landed: reissue is a scheduler decision with a recorded reason). The
   reissued producer's stores land on the same paths as ordinary forward
   stores — **overwrite-on-reissue** — and its retirement advances the
   generation. A consumer holding a dead witness cannot retire (step 2)
   and is routed forward by the drift table to the reissued producer's
   landing. Nothing ever moves a coordinate backward.

**What about dead bytes the repair never overwrites?** A squashed node's
write to a committed path leaves dead bytes on disk while the frontier's
top for that path is the untouched committed coordinate; a squashed node's
fresh file has a frontier top of `Absent`. Both are **hygiene, never
correctness**: nothing can witness them into committed state (step 2's
backstop), so their lifetime is an aesthetic and disk-space concern.
**Decision — overwrite-on-reissue primary, lazy convergence backstop.**
The common case cleans itself: the reissue writes the same paths. The
backstop is `Frontier.materialize` run as the hygiene sweep — at
quiescence, at boot, after a crash — which converges every address to its
live top (writing committed content over dead bytes, deleting files whose
top is `Absent`). **Alternative:** eager per-squash cleanup (materialize
the squashed node's write set inside the squash path) — lost because it
puts filesystem I/O on the settlement path (F4, dispatch purity) to serve
no correctness need, and because mid-run the very next event may be the
reissue's overwrite of the same path. **Reverses if:** a measured
falsifier shows an agent's read of dead bytes burning material tokens
between squash and reissue (the ledger names the window) — the recorded
upgrade is materializing just the squashed write set at the squashed
node's port, off the dispatch path.

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
decide *which direction* it was moving. Here that state is
unconstructible because the direction doesn't exist: every ledger append
is monotone, the tree is a cache, and crash recovery is exactly boot —
re-derive the frontier from the ledger (`Frontier.of_ledger`), converge
the tree (`materialize`), reissue in-flight producers forward (their
settlements never landed, so their coordinates never went live; their
disk residue is the same garbage class squash leaves, swept by the same
mechanism). One recovery path, no special cases, and it is the resume
path the durability OPEN item already owed.

**The falsifiers** (the roster in § falsifier plan):

- (i) no provenance-dead bytes are ever witnessed into committed state;
- (ii) every consumer of dead state is cascade-squashed or routed forward
  — none retires against it;
- (iii) at quiescence the committed frontier contains only witnessed-live
  content;
- (iv) generations never retreat anywhere in the run — a global
  monotonicity fold over the ledger, judged across arbitrary squash and
  crash injections. Monotonicity is judged over the ledger because the
  tree carries no authority to retreat.

## Retirement and "no branches"

**Decision — collapse fully: one git ref, and the ledger is the commit
log.** The committed branch as a coordination object dies. One ref remains
— git's name for the retirement history, nothing more — and the working
tree on that ref is the shared store buffer *and* the committed tree,
distinguished by coordinate, not place. Retirement for one node becomes:

1. **Discharge and witness** — unchanged (hypotheses discharged,
   content-judged witness holds against `Committed.state`).
2. **Conflict judgment** — unchanged (base-coordinate disjoint, landed).
3. **The landing** — no merge exists, because there is nothing to move:
   the bytes are already in the tree. The step is a ledger state
   transition — the committed coordinate advances per law 2 (byte-null
   deltas advance nothing; the free commit stays silent) — plus a
   **pathspec-limited commit built from the ledger's blobs, never from
   the tree**: the commit's tree entries for the node's write set come
   from the store events' oids (`Delta_ref`), so a neighbor's later
   in-flight bytes on the same path cannot tear the commit. Message =
   node provenance, as today. The disjoint law is what makes write sets
   per-commit coherent: overlapping writers serialized or
   merge-declared before either retires.
4. **Seal** — unchanged.

**Alternative:** keep a separate committed branch and treat the working
tree as pure staging — lost because it is the worktree by another name: a
second place whose divergence from the first must be synchronized,
exactly the machinery this redesign deletes; the committed *state* is
already fully represented as ledger coordinates plus git objects.
**Reverses if:** multi-process execution arrives (two schedulers cannot
share one working tree; the recorded shape there is one tree per
scheduler and the cross-machine ledger OPEN item, not a return of
per-node isolation).

Generation advancement and `Committed.state` survive as **ledger state**
— address → (generation, content, writer) — and history stays
materializable: any retirement's tree is reachable through the one ref's
commit chain, which is how `Frontier.materialize` sources committed
content without any second branch existing. Reading that history is not
reverting (§ above).

## Gates on a shared tree

A build or test run observes the whole tree — including neighbors'
in-flight edits. The worktree bought gate isolation; the flat org replaces
it with gate *honesty*:

**A gate run witnesses its full observed footprint, and becomes a
store-buffer hypothesis on every in-flight writer whose stores it may have
read.** At gate start, the engine snapshots the frontier over the gate's
grant: every address whose top is `In_flight` yields a `Store_buffer`
hypothesis on that writer (source and content hash, landed vocabulary) and
a witness triple at the uncommitted coordinate. v0's footprint grain is
the gate's whole grant — conservative: a gate is charged with having read
every in-flight address it *could* see (the OPEN item below records the
file-level tracing upgrade).

**Decision — gates run optimistically and discharge like any hypothesis;
no quiesce point.** A gate verdict is **speculative evidence** while its
hypotheses are pending: the verdict tuple carries them in provenance like
any head tuple, so downstream consumers inherit them and the whole
subtree squashes or reconciles if an observed writer lands differently or
dies. It becomes **admissible evidence** exactly when it retires — which
requires every hypothesis discharged, so final-state law judgment (which
consumes only committed tuples) sees only gate verdicts whose observed
world landed as observed. **Alternative:** demand a quiesce point (barrier
the gate until every in-flight writer in its grant settles) — lost because
it reinvents issue-on-readiness at the gate, serializing exactly the
overlap the engine exists to win, and because the free-commit economics
(F7) make the optimistic gate's common case free: an implementer whose
draft the gate built against usually lands that draft. **Reverses if:**
measured gate churn — gate reissue rate under in-flight drift, per shape —
exceeds the barrier's serialization cost on the same shape (ledger
decides; the churn counter vocabulary already exists).

**The machine lock's new scope.** The mkdir-atomic, holder-named effect
lock serializes gates *per build-artifact resource* (`Address.Resource` —
the `_build` dir, a package cache), declared on the gate the way every
effect footprint is declared; source-tree reads take no lock (they are
witnessed, and witnesses conflict-detect better than locks serialize). In
v0 `run_command` blocks the one domain, so a gate's observation window is
atomic against every intra-process writer for free — the fiber mount's
gift. The recorded upgrade (OPEN below) is a `Subprocess` instruction
beside `Http_post`, buying gate overlap and paying with a witness that
spans the window: frontier snapshots at start and end, any store event
inside the window within the gate's grant making the verdict speculative
on that writer too. Fix-forward note: a failing gate verdict is a fact
(a tuple), never an instruction to restore anything — repair of a broken
tree is the producing statement's reissue writing forward, routed by the
same table as every drift.

## Torn reads: atomicity at the file grain

A reader must never witness a half-store. **Every file store is
tmp+rename**: the store tool writes the full content to a same-directory
temporary, then `rename(2)` — atomic on POSIX — replaces the target. This
lives in **the tool loop's store path** (the `write_file` /
`str_replace_edit` tool values in `Agent`'s grant-derived table), in the
same tool call that writes the blob to the object store and returns the
Store event for the loop to append — one site, three obligations, ordered:
blob first (the oid must exist before any event names it), rename second,
event append third. Within the process the fiber mount already serializes
tool writes at yield granularity; tmp+rename is for the readers the domain
does not schedule — gate subprocesses, external tools, the operator's own
editor — and it is what makes the gate's "observation window" a sequence
of whole files rather than a byte race.

## Grants and sensing

Grants and footprints **survive — they are what makes witnesses tractable
and conflicts attributable.** "Full context" is not an unbounded read of
everything; it is ambient read visibility *within the grant*, plus
drift-note subscription by footprint overlap (landed, edge-compiled).
What changes:

**`snoop_mounts` dies as a concept.** Everything in-grant is snoopable:
a read whose address tops `In_flight` is *automatically* a tracked
`Store_buffer` hypothesis — the resolver consults the frontier, not a
mount table. **Decision.** **Alternative:** keep explicit snoop mounts as
an opt-in sensing surface — lost because the mount was a materialization
detail of private trees (a path prefix to reach a neighbor's directory),
and with one tree it degenerates into a second, redundant supply of
read-visibility policy beside `read_globs`; the hypothesis tracker, not
the mount, was always what made snooping honest. **Reverses if:** never as
a mount table; a workload needing *finer* sensing tiers than read_globs
express is asking for a grant grammar extension, recorded here.

**The write grant is now the load-bearing boundary.** Without a private
root, writes land in the shared tree at granted paths:

```ocaml
(* lib/agent.mli — Grant.t under the flat org. worktree_root and
   snoop_mounts are deleted; write_globs is the boundary that replaces
   the private root. Readers: Toolset.of_grant (the capability table),
   Grant.describe (the prompt's footprint section), the disjoint law's
   attribution story. *)
type 'status t = {
  read_globs : string list;   (** Ambient visibility: readable, snoopable. *)
  write_globs : string list;  (** Where this node's stores may land. *)
  shell_gates : string list list;
  effects : 'status Effect_tool.t list;
}
```

**What enforces it:** the same construction that enforces grants today —
capability is the table. `Toolset.of_grant` derives the store tools over
`write_globs`; a path outside them fails the `Relpath` parse at the
argument boundary and returns the typed in-band `Grant.Refusal`
(absolute paths and `..` hops already unconstructible). There is no
run-time check to forget because an ungranted write has no tool entry to
dispatch to. Write grants should be disjoint-or-merge-declared across
concurrently-live statements as a matter of theory hygiene — but the
declaration is a filter, never a wall: overlapping grants are legal, and
the base-coordinate disjoint law is what convicts an actual clobber.

**What the escape surfacing owes.** Two escape classes, two mechanisms:
a *tool* write cannot escape (no table entry); an *effect* escape —
`run_command` writing outside its declared resource footprint — is
invisible to store events, so the flat org owes the **unexplained-bytes
sweep**: at quiescence (and at every hygiene materialization), diff the
tree against the frontier; bytes no live store event explains are
attributed to the effect events whose ledger window covers them and
surfaced exactly like footprint escapes today — logged, reported at
retire, a witness the declaration must grow to cover. The declaration
tunes delivery and attribution; correctness never depended on it.

## What worktrees bought, paid honestly

Insight 16's discipline: do not force essentially different cases into
one representation — so either private-vs-shared staging was accidental
structure, or some residue is essential and must be kept as exactly that
much. The audit, per purchase:

- **Crash isolation.** A crashed run's half-written garbage was confined
  to droppable directories. *Paid by:* the frontier — recovery re-derives
  state from the ledger and converges the tree; dirty bytes after a crash
  are the same garbage class as after a squash, swept by the same
  mechanism. *Consciously accepted:* between crash and boot-hygiene the
  tree is dirty; nothing reads it in that window because nothing runs.
- **Free squash.** `worktree remove` was O(directory). *Paid by:* squash
  is now O(settlement) — an append plus derivation, strictly cheaper; the
  filesystem half was always hygiene and is now honestly scheduled as
  hygiene (overwrite-on-reissue, lazy convergence).
- **Parallel gates.** N worktrees could build simultaneously. **Given up
  in v0, consciously** — one tree serializes builds per build-artifact
  resource (and v0's blocking `run_command` serializes harder). This is
  the flat org's one real regression and it is priced: the counter is
  gate queue time on the build resource, and the recorded mitigations are
  the `Subprocess` instruction (overlap the gate with non-gate work) and
  the observation that one warm incremental tree can beat N cold
  worktrees — an unearned claim until a ledger measures it (README
  rule 6).
- **Git-native merge.** Retirement applied a worktree's net delta to the
  committed branch. *Paid by:* nothing needs to pay — with one tree there
  is nothing to move at retire; the commit is built from ledger blobs.
  What is actually given up is git's *textual merge* machinery for
  concurrent same-file edits, which the design never used: conflicts
  serialize or route to registered merge functions, judged by the
  disjoint law, and that machinery is representation-level, not
  git-level.
- **The essential residue.** One case is essential: two live writers with
  genuinely different content for one path — a tree can materialize only
  one. The residue kept is **per-writer content lineage in the object
  store**: every store's blob is content-addressed and event-named, so
  both writers' bytes exist and are addressable even while the tree tops
  one of them; the loser's next read or yield senses the winner (drift
  note, base-coordinate conviction) and routes forward. Private staging
  survives as exactly this much — blobs, not namespaces. The
  directory-shaped remainder was accidental: a place to put lineage
  before the ledger carried it.

## The culmination

Same repo. No branches — one ref, and the ledger is the commit log. No
worktrees — one working tree, the shared store buffer, materializing the
ledger's live frontier. Workers start at t=0, read ambiently within their
grants, and *sense* each other through witnessed state: a read of a
neighbor's in-flight draft is a tracked hypothesis, a neighbor's landing
is an invalidation, a divergence is a drift note at the next yield with
its route already decided. The supervisor sits above with the same
anti-firehose law — full visibility, leveled interruption. Speculation is
the concurrency model: every overlap the machine wins is a bet the ledger
can settle, and every conflict it admits is one the ledger can attribute
(base coordinates name both writers) and the drift table can route
(discharge, reconcile, flush — all forward).

Why this beats isolation: isolation buys safety by forbidding visibility,
so ultracode-class harnesses pay for it twice — once in merge debt at the
end (divergence compounds in private), once in duplicated context
acquisition (each worker re-reads the world its neighbors already
learned). The flat org's workers converge continuously instead of
merging terminally; the free-commit case makes agreement cost zero, and
disagreement surfaces at drift-note latency instead of merge time.
Why it beats locking: locks serialize the *possibility* of conflict;
detection-and-forward-repair serializes only *actual* conflicts, after
the fact, with evidence — strictly more parallel wherever conflicts are
rarer than accesses, which is the measured regime the whole speculation
bet already rides on. And both alternatives lack the thing the ledger
makes native: an attribution trail. A lock queue doesn't say why; a merge
conflict doesn't say who read what. The witness index says both.

The deepest version of the claim: the working tree now obeys the law the
ledger has lived by since day one — **append-only, corrections as new
events, compensation never undo**. Event sourcing all the way down. There
is no second state discipline left in the system to keep coherent with
the first; ultracode needs isolation because it lacks a coherence
protocol, and this machine ships one.

## Falsifier plan

New roster entries (FL — flat org), each trying to kill a law above;
rigged executors throughout, no model calls:

- **FL1 — squash-revert counterfactual.** A producer stores over
  committed content, then squashes. Assert: the committed coordinate
  never moved (no event lowers or rewrites it); no event class in the
  ledger can express a retreat (the negative-compile half: no
  constructor takes a generation backward); the repair is a forward
  event; a rigged consumer that read the dead bytes is refused at retire
  and routed forward, never retired. The counterfactual arm: assert the
  suite contains no code path that could have restored the old bytes as
  anything but `Frontier.materialize`'s cache fill — grep-gate style, no
  restore verb in lib/.
- **FL2 — no dead witness commits (obligation i + ii).** Every consumer
  of provenance-dead state either cascade-squashes (hypothesis tracked)
  or is refused by the content-judged witness (untracked read); build
  the graph where any leak changes a committed tuple, assert none does
  (F3's shape, re-aimed).
- **FL3 — live frontier at quiescence (obligation iii).** After runs
  with injected squashes and reissues: every committed address's content
  equals a witnessed-live store's blob; the hygiene sweep finds only
  bytes attributable to dead events or declared effects.
- **FL4 — global generation monotonicity (obligation iv).** A fold over
  the whole ledger, per address, across arbitrary squash and crash
  injection points: committed generations strictly increase; run twice
  with a mid-run kill and re-boot (`Frontier.of_ledger` +
  `materialize` + forward reissue) and assert the same.
- **FL5 — live clobber conviction.** Two in-flight writers store to one
  path from one base in the shared tree. Assert: the disjoint law
  convicts the pair at retire (base equality, landed); the loser is a
  `Reissue_loser`, reissued against the winner's landing; the earlier
  writer receives the drift note at its next yield (sensing, not
  surprise); committed content is single-writer coherent.
- **FL6 — gate-hypothesis discharge.** A gate runs while a producer's
  draft is in flight. Arm A: the producer lands identically — the gate's
  hypothesis discharges silently, the verdict retires with zero
  reconcile events (the gate-shaped F7). Arm B: the producer lands
  differently — the verdict is squashed or reissued per the table,
  and no law consults the stale verdict at final state.
- **FL7 — torn-read impossibility.** A rigged gate subprocess reads the
  target path in a tight loop while stores land through the tool path;
  assert every observed read is a whole former-or-latter content, never
  an interleaving (tmp+rename's contract, exercised from outside the
  domain).

F5 (abort by construction) is re-aimed rather than deleted: its
kill-at-arbitrary-yield injection now asserts frontier re-derivation
instead of worktree-drop cleanliness. F12/F15 stand unchanged.

## Migration path (ordered; suite green at every step)

1. **Blobs into git's object store** (`agent.ml`, `http`-adjacent
   plumbing none): store tools write content-addressed blobs at store
   time; `Delta_ref` carries the oid; tmp+rename lands in the same
   change (the store path is being rewritten anyway). FL7.
2. **Retire from the ledger, not the tree** (`retire.ml`): `step`'s
   merge builds the pathspec-limited commit from store-event oids;
   `Worktree.net_delta`'s consumers move to the event stream. The
   worktree still exists but is no longer read at retire — the tear
   window closes before the walls come down.
3. **The frontier** (`retire.ml`): `Frontier` over ledger + committed
   state; `Committed.state` unchanged; `materialize` implemented as
   boot/hygiene. FL3, FL4's fold.
4. **Collapse the tree** (`agent.ml`, `chase.ml`): `Grant.t` loses
   `worktree_root`/`snoop_mounts`, gains `write_globs`; `Source.resolve`
   reads the shared tree and consults the frontier — an `In_flight` top
   returns the store-buffer hypothesis (chase's `policy_read` already
   speaks this vocabulary for tuples; files join it). Nodes dispatch
   with no `Worktree.create`. FL2, FL5.
5. **Delete `Worktree`** (`retire.mli`/`retire.ml`, `chase.ml`): the
   module dies; `Fun.protect` finalizers that dropped worktrees become
   nothing (squash is the settlement append); `queued_worktrees` and
   `drop_speculative_state`'s filesystem half are deleted; `run.mli`
   `config.worktree_root` dies. FL1 and the grep-gate (no
   worktree/restore vocabulary in lib/).
6. **Gates** (`chase.ml`, `agent.ml`): gate dispatch snapshots the
   frontier over the grant into hypotheses + witness triples; the effect
   lock re-scopes to declared build resources. FL6.
7. **Hygiene and recovery** (`run.ml`): `materialize` at open (boot =
   crash recovery); the unexplained-bytes sweep at quiescence; F5
   re-aimed.

Each step amends its owning doc in the same change (HANDOFF below).

## OPEN items

- **File-grain gate footprints.** v0 charges a gate with its whole
  grant; file-level read tracing (fs event snooping, compiler dep files)
  would shrink gate hypotheses to files actually read. *Trigger:
  measured gate reissues attributed to in-flight writers of files the
  gate provably never consumed (dep-file evidence).*
- **Gate overlap: the `Subprocess` instruction.** v0's blocking
  `run_command` serializes the domain during gates (and buys atomic
  observation). *Trigger: measured domain-block time under gates
  becoming a visible critical-path term.*
- **Write-grant overlap lint at admission.** Concurrently-live
  statements with overlapping `write_globs` are legal (the disjoint law
  is the judge) but usually a theory smell; an admission-time warning is
  cheap. *Trigger: the first real pipeline where a clobber conviction
  traces to a grant overlap the author didn't intend.*
- **Hygiene cadence.** Lazy convergence runs at boot and quiescence;
  whether long runs want a mid-run sweep (port-idle moments) is
  unmeasured. *Trigger: FL-suite or live evidence of agents reading dead
  bytes in the squash-to-reissue window (the FL falsifier's counter).*
- **Multi-process.** One tree assumes one scheduler process; the
  cross-machine story (one tree per scheduler, ledger-mediated) inherits
  the cross-machine ledger OPEN item. *Trigger: unchanged from
  `README.md`.*
- **Per-hunk generations** (inherited from `50-commit.md`, sharper here:
  a shared tree raises same-file traffic). *Trigger: unchanged —
  measured serialize-routes on disjoint-region conflicts.*

## HANDOFF — amendments owed when migration steps land (doc rule 4)

Each row lands with its migration step, in the same change, and is struck
here:

- **`30-channels.md`**: § event taxonomy — Store's "a write against the
  node's own worktree" becomes "a write against the shared tree at
  granted paths"; § store-to-load forwarding — snoop mounts deleted,
  ambient in-grant snooping with automatic hypothesis tracking; § OPEN
  items — blob ref scheme CLOSED (git blob oid, step 1).
- **`50-commit.md`**: § abort by construction — "drop the worktree"
  becomes the settlement-append + derived-deadness story; § retirement
  order step 3 — the merge becomes the ledger-blob commit; § durability
  boundary — rewritten: one ref, ledger as commit log, frontier
  materialization; Decision blocks re-recorded per this doc's § retirement.
- **`40-scheduling.md`**: § ports — the "N resident worktrees on one
  disk" bottleneck example dies, the build-resource lock example
  replaces it; § drift routing — gate verdicts named as a fourth
  consumer surface of the table.
- **`60-agents.md`**: § tool grants — `write_globs` as the boundary,
  snoop mounts deleted, the escape sweep named; § prompt assembly part
  4 — the footprint grant section renders read/write globs, not a
  worktree root.
- **`00-product.md`**: the machine-analogy table's store-buffer row —
  "the node's worktree" becomes "the shared tree + per-writer blob
  lineage"; § thesis's "speculative state lives in git worktrees"
  sentence.
- **`README.md`** (repo root): the abort-by-construction bullet's
  worktree wording; **`docs/architecture/README.md`**: Closed-by-ruling
  entries quoting worktrees; a new Closed-by-ruling entry for
  fix-forward ("revert is unrepresentable — corrections are forward
  stores; recovery is frontier re-derivation").
- **`80-validation.md`**: FL1–FL7 join the roster; F5's re-aim recorded.
- **`lib/run.mli`**: `config.worktree_root` deleted;
  `committed_branch` doc re-worded to "the one ref" (step 5).
- **`lib/retire.mli`**: `Worktree` deleted, `Frontier` added (steps 3/5);
  **`lib/agent.mli`**: `Grant.t` fields (step 4); **`lib/witness.mli`**:
  unchanged in shape — its content-judged `holds` is what makes the flat
  org sound, and the doc comment gains one sentence saying so.
- **Fix-forward audit**: any wording anywhere that implies undo (a
  "restore", a rollback, a revert) is amended fix-forward in the step
  that touches its file; the FL1 grep-gate enforces it in lib/.
