# 10 — Theory

The work representation. A unit of orchestrated work is a **theory**: a set of
**relations** (typed tuple schemas; these become channels) and a set of
**dependency statements** over them (these become node templates). The
scheduler is a chase over this theory (`40-scheduling.md`); the DSL the host
writes is a presentation of the theory and nothing else (`70-api.md`). Reader
of this doc: anyone writing a theory, and the `Theory` module that admits one.

This doc is the representational bet in its primary application
(`00-product.md`): the theory **is** orchestration control flow reified as
data. Fanout is not a loop — it is a spawn statement the chase interprets.
Review-and-repair is not a callback cycle — it is a relation and a
generation. A branch that would live in a rival harness's scheduler code
lives here as a statement in an inspectable value, which is what makes the
engine a small evaluator instead of a large program.

## Relations

A relation declares a named tuple shape. Its payload type is a contract
catalog entry (`20-contracts.md`); its fields are slots, and every slot is
exactly one of:

- **mint** — this relation is where values of this identity are born. A mint
  slot is filled by the engine with a fresh id at firing time (provisional
  until retire — `50-commit.md` § provisional identity), never by an agent
  and never by the host. One relation mints an identity; everywhere else it
  is a ref. (Rename semantics: a mint is a write port.)
- **ref** — a foreign identity, checked by an inclusion statement (below). A
  ref is an operand: a node that reads a tuple through a ref slot acquires a
  witness obligation on the referent (`50-commit.md`).
- **value** — plain payload data, shaped by the contract.

Example relations for an antagonistic-review theory, in the notation used
throughout these docs (concrete OCaml surface in `70-api.md`):

```
relation finding   { id: mint, file: value, claim: value, severity: value }
relation verdict   { id: mint, finding: ref finding, refuted: value, why: value }
relation confirmed { id: mint, finding: ref finding }
```

## The statement grammar

Four statement forms exist. Each entered the grammar with an enforcement plan
(the acceptance gate, below); no other forms exist until they bring one.

**1. Spawn statements (TGDs).** *For every body match, there exist head
tuples, produced by an executor.*

```
spawn review:
  for f in finding
  exists v in verdict where v.finding = f.id
  by agent(refuter) with contract verdict
```

The body is a conjunctive pattern over relations (single-relation bodies in
v0 — see the OPEN item); the head names the relation(s) whose tuples the
firing must produce; `by` names the executor (an agent template, a pure
function, or a shell gate — `60-agents.md`). One firing = one **node**. The
chase fires the statement once per body match — fanout width is
data-generated, never plan-static. Head mint slots are filled with fresh
existentials at firing time; this is the rename.

**2. Cardinality windows.** *Between n and m head tuples per body match.*

```
spawn review: for f in finding exists 3..5 v in verdict ...
```

The window compiles into the firing plan (the node's contract asks for a
tuple array with `minItems`/`maxItems` — `20-contracts.md`) or into the
firing count (three refuter nodes, one tuple each — the theory author picks
which by writing `3 nodes` vs `3..5 tuples`); either way the bound is shape,
not a runtime check. Enforcement plan: the channel-boundary parse
(`20-contracts.md` § failure surface), count check at retire.

**3. Inclusions (ref integrity).** Implicit in every `ref` slot: a committed
tuple's refs resolve to committed tuples. Enforcement plan: refs are typed
ids minted by the engine, so a dangling ref is constructible only by an agent
inventing an id — the codec rejects unknown ids at the channel boundary, and
retire re-judges against final state (`50-commit.md`).

**4. Retire laws (EGD-class).** *Predicates over the final state that gate
retirement*, judged once, at commit, against the merged final state — never
per-event, never deferred-with-modes:

```
law quorum:    for f in finding: count(v in verdict where v.finding = f.id) >= 3
law verdicted: for f in finding: f retires confirmed iff count(refuted) < 2
law disjoint:  no two nodes commit writes to one path from one base state
```

Enforcement plan: each law compiles to a query over the final tuple set plus
the footprint index (`30-channels.md`); `disjoint` is the EGD whose violation
is the merge-conflict signal (`50-commit.md`). A law the compiler cannot turn
into such a query is rejected at admission.

## Chase semantics

The engine is the standard chase, restated in one paragraph so this doc is
self-contained: maintain the set of committed and pending tuples; a spawn
statement whose body pattern matches tuples not yet consumed by a firing of
that statement **fires**, minting head existentials and dispatching the node;
the node's retirement inserts the head tuples; repeat until no statement can
fire (quiescence), then judge the retire laws against the final state. Two
GOAT CODE refinements:

- **The firing rule is the staging law.** A statement's nodes start eagerly
  and bind operands at read time; a read of a missing-but-hypothesizable
  operand takes the hypothesis by default (`40-scheduling.md` § eager
  start, § speculation is default-on). A hypothesis-fired node's head tuples carry the
  hypothesis in their provenance; they can fire further statements, and the
  whole derivation subtree squashes together if the hypothesis dies.
- **Provenance is total.** Every tuple records the firing that produced it and
  the tuples that firing consumed. Squash completeness (delete exactly the
  derivation subtree of a dead hypothesis) is a provenance walk, and the
  ledger stores it for free because firings are events (`30-channels.md`).
  Reader: the squash routine, the reconcile router, and `80-validation.md`'s
  replay checker.

## Termination: weak acyclicity at admission

**Theories must be weakly acyclic; admission judges it statically — and
admission is a parser, not a validator.** The chase over arbitrary TGDs need
not terminate (a mint slot feeding a body that spawns tuples feeding the same
mint is an infinite factory). Admission builds the standard dependency graph
over relation positions (edges for value propagation, special edges for mint
positions) and rejects cycles through mint edges. The check is a page of
graph code, runs at theory-accept time, and **returns a refined type**:
`Theory.admitted` is a distinct type with no public constructor — the only
way to obtain one is to pass admission, and it is the only type `Run.exec`
accepts (`70-api.md`). No code downstream of admission re-checks acyclicity,
gate coverage, or schema lint results, because possession of the value *is*
the proof — parse, don't validate, applied to the theory itself. An
unadmitted theory reaching the engine is not an error path; it is
unrepresentable.
**Decision.** **Alternative:** run unrestricted theories and rely on the
token-ceiling backstop to stop runaways — lost because it converts a static,
explainable admission error ("this statement can spawn itself forever,
here's the cycle") into a runtime bill with a confusing shape; the backstop
remains for *admitted* theories whose data is bigger than expected, which
is a different failure with a different message (`40-scheduling.md`
§ backstops).
**Reverses if:** a censused workload genuinely needs a recursive spawn shape
(iterate-until-fixed-point repair); the recorded path is stratified
iteration — a bounded `generation` counter on the loop relation, which
restores weak acyclicity per stratum — not unrestricted chase.

## Feedback is forward

There are no backward edges and no cycles in the fired graph, ever. "The
reviewer sends work back" is representable and common — as a *new fact*:

```
relation revision_request { id: mint, target: ref module_impl, diagnostics: value }
spawn repair: for r in revision_request exists m2 in module_impl ...
```

The repair firing is a **new node with a new generation** of the module
implementation; the theory stays acyclic (the admission check sees the
`generation` stratum). What looks like iteration is generations; what looks
like a backchannel is a forward relation. This ruling is what keeps squash
precision provable (`30-channels.md` § the unidirectional law) — and it is
a coordinate change in the lineage's exact sense (Dijkstra's half-open
interval, homogeneous coordinates): in the (node, backchannel) coordinate
system, feedback is a special case demanding cycle detection, deadlock
policy, and squash exceptions; in the (relation, generation) coordinate
system those cases are not handled, they are unrepresentable.

## The acceptance gate

**A statement form enters the grammar only when it carries a cheap
enforcement plan** — a named, mechanical judge: the channel-boundary parse,
a compiled query at retire, a footprint-index check. The
gate exists because an unjudgeable clause cannot discharge a speculation
hypothesis, so it cannot gate anything: it is prose wearing law's clothing,
and it rots into folklore exactly the way regime-free performance claims do.
Consequences, recorded as rulings:

- **No "the code should be idiomatic" laws.** Judgeable proxies exist
  (compiles, tests pass, lint clean, a named reviewer-agent's verdict tuple)
  and are what the theory can say. The reviewer's *judgment* is a tuple; the
  law quantifies over tuples.
- **No implication judgments.** The engine judges satisfaction of stated laws
  against final state, never consequence among statements. If two laws are
  redundant, they are both judged; redundancy is the author's affair.
- **No soft laws.** A law either gates retirement or is deleted. "Warnings"
  are tuples a reporting node emits, not law verdicts.

## Worked example: the review theory, whole

```
relation change    { id: mint, diff_ref: value }
relation finding   { id: mint, change: ref change, file: value, claim: value }
relation verdict   { id: mint, finding: ref finding, refuted: value, why: value }
relation confirmed { id: mint, finding: ref finding, summary: value }

spawn sweep:   for c in change
               exists 0..32 f in finding
               by agent(finder) with contract finding

spawn review:  for f in finding
               exists 3 nodes v in verdict
               by agent(refuter) with contract verdict

spawn publish: for f in finding
               where count(v in verdict where v.finding = f.id and v.refuted) < 2
               exists s in confirmed
               by agent(summarizer) with contract confirmed

law quorum:    for f in finding: count(v where v.finding = f.id) = 3
```

Reading: `sweep` fans out to a data-generated number of findings; `review` is
the antagonistic panel, three refuters per finding, width known only after
`sweep` retires — but `review` nodes start against `sweep`'s store buffer as
findings stream out, before `sweep` retires (`30-channels.md` § store-to-load
forwarding; eager start and read-time binding, `40-scheduling.md`).
`publish` demonstrates a filtered body: it fires per finding, starts eagerly,
and at its read of the verdict count either finds it witnessed or takes the
hypothesis on the popular outcome — speculation is the default posture
(`40-scheduling.md` § speculation is default-on). Every mechanism the rest
of these docs specify is visible in
these four statements; the example is the census workload #2 and the
falsifier suite's canonical theory (`80-validation.md`).

## OPEN items

- **Multi-relation bodies** (joins in spawn bodies: "for every (impl, its
  spec) pair..."). v0 bodies are single-relation plus `where` filters over
  refs one hop away, which covers the census. *Trigger: a censused theory
  that cannot be written without a true join body; the mechanism is standard
  (the chase does joins natively) — what's open is only the surface grammar
  and the admission-check extension.*
- **Aggregation in law bodies beyond `count`** (sum, max, user folds).
  *Trigger: first law that needs one; each arrives with its enforcement
  plan or not at all.*
- **Theory composition** (importing a review sub-theory into a build
  pipeline with relation renaming). *Trigger: the second real pipeline that
  hand-copies the review theory.*
