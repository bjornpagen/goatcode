# 50 — Commit

Retirement: how speculative state becomes committed state, and how everything
else becomes nothing. Readers: the `Retire` and `Witness` modules;
`40-scheduling.md` (whose hypotheses this doc discharges); `80-validation.md`
(whose falsifiers police every law here).

## Abort by construction

**A node's entire mutable output lives in its own git worktree and its ledger
events. Squash is: drop the worktree, mark the events squashed. Nothing else
exists to clean up — "failed work leaves nothing" is true by construction,
never by rollback.** No compensating action is representable in the engine;
an executor that needs one is asking for an effect grant, which is the
declared, idempotence-gated exception (`30-channels.md` § event taxonomy),
not a hole in this law.

The OxCaml enforcement: speculative results are `unique`-moded values —
consumed exactly once, by retire or by squash. Committed state is reachable
only through the retire path; a code path that would let a speculative
value flow into committed structures without discharging its hypotheses does
not typecheck. This is "make illegal states unrepresentable" applied to the
retire protocol itself — the leak the success criteria call absolute
(`00-product.md`) is not policed by review or caught by a runtime guard;
it is a state the mode system refuses to construct. The compile-time probe
falsifiers assert exactly this refusal (`80-validation.md` F15).

## Provisional identity

Mint slots are filled at firing time with ids minted **provisionally against
the committed counter as of the node's snapshot**. Provisional ids are real
ids — downstream speculative nodes ref them, tuples carry them — but they
bind (become committed identity) only at the minting node's retirement, in
dependency order, so committed id space is dense and replay-deterministic.
A squashed node's provisional ids die with it; nothing renumbers. Reader:
the codec boundary (which rejects agent-invented ids by checking mint
provenance — `20-contracts.md` § failure surface).

## The generation-witness protocol

Every committed address (file path, relation tuple-set, contract) carries a
**generation**, and the protocol has four laws:

1. **The witness is the artifact, never an asserted number.** A node's
   witness is the set of (address, generation, content-hash) triples
   assembled from its *observed* load events (`30-channels.md` § mechanized
   witnesses). Nothing in the system ever trusts a claimed version; evidence
   is collected, not reported. (Parse-don't-validate, applied to trust: a
   version number is a validator's residue — a claim whose proof was thrown
   away; the observed triple set is the proof itself, carried to the commit
   point.)
2. **Only semantic change advances a generation.** At retirement, a store's
   net delta is compared against the address's committed content: byte-null
   deltas advance nothing (cancellation already dropped them in the store
   buffer); for contract addresses the comparison is the derived-schema hash
   (`20-contracts.md` § versioning), so refactors that re-derive identically
   are generation-silent. Consequence, the design's economic keystone: **an
   upstream node that lands exactly what speculators predicted retires them
   for free** — their witnesses still hold, no invalidation fires, no
   reconcile runs. Correct speculation costs zero.
3. **Commit iff the witness holds.** A node retires only if every witnessed
   triple still describes the committed state — and the judged thing is the
   artifact (law 1): the address's committed content is the content the
   triple carries. Generation equality is that comparison's shadow under
   law 2, never the check itself, because a fresh address's first landing
   and a pre-commit read (a snooped draft, an uncommitted tuple) share the
   first generation and only their content tells them apart. Absence is a
   real case of the committed lookup, never a sentinel generation: a triple
   witnessed at the primordial generation holds against never-committed
   state, so a consumer that witnessed a differing draft is rejected the
   moment the producer's landing exists at all. A moved witness is the
   typed signal `Generation_moved { address; witnessed; current;
   delta_ref }` shipped to the scheduler — the engine performs no retry, no
   merge heroics, no silent re-read (the scheduler's routing table owns
   what happens next — `40-scheduling.md` § drift routing).
4. **Soundness, never freshness.** A held witness proves the node's outputs
   were derived from the state they claim — it does not prove no better
   input existed. Freshness is the scheduler's economics (reissue if the
   ledger says the upgrade is worth it), never a commit-blocking judgment.
   Stated once, here, so no future law confuses the two.

## Retirement order and the merge

**Nodes retire in dependency order — a node's producers retire before it
does — and retirement is the only writer of committed state.** The retire
step for one node:

1. **Discharge check**: all hypotheses discharged (`40-scheduling.md`), all
   witnesses hold (law 3 above).
2. **Conflict judgment**: the node's write-set (observed store footprints)
   intersects no sibling's committed write-set within the current
   generation — the `disjoint` EGD (`10-theory.md`). A violation is the
   typed conflict signal, to the scheduler, with both footprints; routes are
   serialize (reissue loser against winner's state) or merge (only when a
   declared merge function exists for the address class — a dune-file
   appender, a lockfile regenerator; merge functions are registered per
   address class at theory accept, never improvised). Every committed write
   is recorded in **base coordinates**: the content the writer's witness
   proves it derived from, a blind write's absent base a real case. The
   final-state `Disjoint_writes` judgment is then pair equality over that
   index — two committed writes to one address from one base are the
   clobber by construction, and serialized writers cannot collide because
   the later one's base is the earlier one's landing. The base index is
   the law's backstop behind this per-retire judgment, which sees only
   observed store footprints.
3. **The merge**: the worktree's net delta applies to the committed tree;
   generations advance per law 2; head tuples insert; provisional ids bind.
4. **Ledger seal**: the settlement event, with timings, closes the node.

Squash is the dual, and **squash precision is absolute**: exactly the
provenance-closed subtree of the dead hypothesis or faulted node squashes —
computed from tuple provenance (`10-theory.md` § provenance is total),
enforced by falsifier (`80-validation.md` F3), guaranteed leak-free by the
success criterion that outranks performance (`00-product.md`).

**Decision — dependency-order retire.** **Alternative:** commit-as-you-go
(each node merges the moment it finishes, optimistically) — lost because it
lets a speculative node's output become visible to committed readers before
its hypotheses discharge, which is precisely the speculative-leak class the
whole protocol exists to kill; the wall-clock cost of ordering is near zero
(retire is cheap; execution dominates) and speculation already overlaps the
waiting. **Reverses if:** never for hypothesis-carrying nodes; a measured
retire-queue backlog on non-speculative wide fanouts could earn ready-node
early retire for the hypothesis-free subset (the ledger would show retire
latency as a visible critical-path term — it does not today).

## Final-state judgment

**Retire laws are judged once, when the run quiesces, against the merged
final state — no per-event checking, no deferral modes, no triggers.** The
judgment consumes the committed tuple set and the footprint index; verdicts
land on the settled map as law verdicts (`40-scheduling.md` § quiescence).
Mid-run, laws are invisible to executing nodes — a node never blocks on a
law, only on operands and ports. **Decision.** **Alternative:** incremental
law checking (judge quorums as verdicts stream in, fail fast) — lost because
mid-run state is not final state: a quorum "violation" at t may be three
in-flight refuters from satisfaction, so incremental verdicts are either
wrong or hedged, and hedged verdicts train operators to ignore them. The
scheduler already uses law *bodies* as readiness filters where the theory
says so (`publish` in the worked example fires on a count) — that is
scheduling, not judgment, and the final judgment still runs. **Reverses
if:** a censused theory needs a mid-run abort on a law that is
monotone-violated (once broken, unfixable by further tuples — e.g. a
`disjoint` breach); monotone laws are the recorded candidate class for
early judgment, and the judge already knows which laws are monotone.

## The repair lane at the boundary

Retirement rejections that route to reconcile carry **diagnostics shaped for
the executor**: the schema diff or witness mismatch, the consumer's own
prior output, and the specific paths its observed witness says it consumed.
The reconcile invocation is stateless-with-diagnostics (`60-agents.md` § the
repair loop) — the same mechanism as codec-boundary repair, one lane, two
entry points. Reader: `60-agents.md`, which owns the invocation shape.

## Durability boundary

v0 commits into a real git repository: the committed tree is a branch,
retirements are commits (one per node, dependency-ordered, message = node
provenance), worktrees are git worktrees. Git is the storage engine, not a
metaphor: squash is `worktree remove`, the committed branch's history is an
audit surface (though the ledger, not git log, is normative). The engine
holds the only writer lock on the committed branch; agents never run git
against it. **Decision.** **Alternative:** a bespoke content store (bumbledb
LMDB-style) — lost for v0 because the artifacts are code trees whose
consumers (compilers, test runners, humans) speak filesystem+git natively,
and reusing git's worktree machinery buys snooping mounts and delta
machinery for free. **Reverses if:** ledger-measured merge/checkout cost
becomes a visible critical-path term, or multi-machine (`README.md` OPEN)
forces a content-addressed store anyway.

## OPEN items

- **Merge-function registry seed set.** Which address classes ship with
  declared merges in v0 (dune files? lockfiles? nothing?). Starting posture:
  empty — every conflict serializes — until a real pipeline shows a
  serialization hot spot with an obviously-safe merge. *Trigger: that
  measurement.*
- **Generation granularity for files.** Per-path in v0. Per-hunk generations
  would let two nodes edit disjoint regions of one file without conflict;
  cost is a hunk-stable diff anchor. *Trigger: measured serialize-routes on
  same-file-disjoint-region conflicts exceeding an annoyance threshold.*
- **Law verdict → git annotation.** Whether law verdicts should also land as
  commit trailers / notes on the committed branch for human archaeology.
  *Trigger: the first post-mortem that had to correlate ledger and git by
  hand.*
