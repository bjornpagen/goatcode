# 10 — Theory & Contracts

The work representation, whole: the **theory** (relations plus dependency
statements — orchestration reified as data) and the **contract catalog**
(the one supply from which every artifact an agent sees or a validator
checks derives). The scheduler is a chase over the theory
(`30-scheduling.md`); the DSL the host writes is a presentation of the
theory and nothing else (`50-api.md`). Readers of this doc: anyone writing
a theory; the `Theory` module that admits one; the `Contract` module that
derives from catalog entries; `40-agents.md` (which consumes the derived
prompt artifacts).

This doc is the representational bet in its primary application
(`00-product.md`): the theory **is** orchestration control flow reified as
data. Fanout is not a loop — it is a spawn statement the chase interprets.
Review-and-repair is not a callback cycle — it is a relation and a
generation. A branch that would live in a rival harness's scheduler code
lives here as a statement in an inspectable value, which is what makes the
engine a small evaluator instead of a large program.

## Relations

A relation declares a named tuple shape. Its payload type is a contract
catalog entry (§ contracts, below); its fields are slots, and every slot is
exactly one of:

- **mint** — this relation is where values of this identity are born. A mint
  slot is filled by the engine with a fresh id at firing time (provisional
  until retire — `30-scheduling.md` § provisional identity), never by an
  agent and never by the host. One relation mints an identity; everywhere
  else it is a ref. (Rename semantics: a mint is a write port.)
- **ref** — a foreign identity, checked by an inclusion statement (below). A
  ref is an operand: a node that reads a tuple through a ref slot acquires a
  witness obligation on the referent (`30-scheduling.md`). A ref may sit
  anywhere in the payload shape — inside arrays and nested records, not only
  at the top level — and the slot set is total over every ref position
  (nested ones are named by their dotted payload path), so the edge,
  footprint subscription, and witness obligation a ref implies are never
  lost to nesting.
- **value** — plain payload data, shaped by the contract.

Example relations for an antagonistic-review theory, in the notation used
throughout these docs (concrete OCaml surface in `50-api.md`):

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
function, or a shell gate — `40-agents.md`). A shell gate's command line
is data, judged at admission like every other declared value: argv[0]
resolving to git is a typed admission error naming the statement — git is
the harness's commit substrate, and a git gate is unwritable
(`40-agents.md` § the git ban). One firing = one **node**. The
chase fires the statement once per body match — fanout width is
data-generated, never plan-static. Head mint slots are filled with fresh
existentials at firing time; this is the rename.

**2. Cardinality windows.** *Between n and m head tuples per body match.*

```
spawn review: for f in finding exists 3..5 v in verdict ...
```

The window compiles into the firing plan (the node's contract asks for a
tuple array with `minItems`/`maxItems` — § lowering, below) or into the
firing count (three refuter nodes, one tuple each — the theory author picks
which by writing `3 nodes` vs `3..5 tuples`); either way the bound is shape,
not a runtime check. Enforcement plan: the decode boundary — the
window-lowered schema is one value serving both directions: it is what the
invocation hands the model **and** what the reply parses against
(§ failure surface), so an out-of-window reply is a parse failure routed to
the repair lane, and an agent complying with the schema it was shown parses
by construction. There is no count check downstream of the parse; a second
check would mean the boundary returned the wrong type.

**3. Inclusions (ref integrity).** Implicit in every `ref` slot: a committed
tuple's refs resolve to committed tuples. Enforcement plan: refs are typed
ids minted by the engine, so a dangling ref is constructible only by an agent
inventing an id — the codec rejects unknown ids at the channel boundary, and
retire re-judges against final state (`30-scheduling.md`).

**4. Retire laws (EGD-class).** *Predicates over the final state that gate
retirement*, judged once, at commit, against the merged final state — never
per-event, never deferred-with-modes:

```
law quorum:    for f in finding: count(v in verdict where v.finding = f.id) >= 3
law verdicted: for f in finding: f retires confirmed iff count(refuted) < 2
law disjoint:  no two nodes commit writes to one path from one base state
```

Enforcement plan: each law compiles to a query over the final tuple set plus
the footprint index (`20-medium.md`); `disjoint` is the EGD whose violation
is the conflict signal (`30-scheduling.md`). A law the compiler cannot turn
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
  operand takes the hypothesis by default (`30-scheduling.md` § eager
  start, § speculation is default-on). A hypothesis-fired node's head tuples
  carry the hypothesis in their provenance; they can fire further
  statements, and the whole derivation subtree squashes together if the
  hypothesis dies.
- **Provenance is total.** Every tuple records the firing that produced it and
  the tuples that firing consumed. Squash completeness (delete exactly the
  derivation subtree of a dead hypothesis) is a provenance walk, and the
  ledger stores it for free because firings are events (`20-medium.md`).
  Reader: the squash routine, the reconcile router, and `50-api.md`'s
  replay checker.

## Termination: weak acyclicity at admission

**Theories must be weakly acyclic; admission judges it statically — and
admission is a parser, not a validator.** The chase over arbitrary TGDs need
not terminate (a mint slot feeding a body that spawns tuples feeding the same
mint is an infinite factory). Admission builds the standard dependency graph
over relation positions (edges for value propagation, special edges for mint
positions) and rejects cycles through mint edges. Stratified iteration is in
the grammar, not an exception to it: a relation may carry a bounded
`generation` counter (§ feedback is forward), and every dependency edge into
a bounded relation crosses to a new stratum of a finite ladder — the cycle
judgment runs over the stratum-preserving edges, so a bounded feedback loop
admits while the same loop without its bound is rejected with its cycle
path. The check is a page of
graph code, runs at theory-accept time, and **returns a refined type**:
`Theory.admitted` is a distinct type with no public constructor — the only
way to obtain one is to pass admission, and it is the only type `Run.exec`
accepts (`50-api.md`). No code downstream of admission re-checks acyclicity,
gate coverage, or schema lint results, because possession of the value *is*
the proof — parse, don't validate, applied to the theory itself. An
unadmitted theory reaching the engine is not an error path; it is
unrepresentable.
**Decision.** **Alternative:** run unrestricted theories and rely on the
token-ceiling backstop to stop runaways — lost because it converts a static,
explainable admission error ("this statement can spawn itself forever,
here's the cycle") into a runtime bill with a confusing shape; the backstop
remains for *admitted* theories whose data is bigger than expected, which
is a different failure with a different message (`30-scheduling.md`
§ backstops).
**Reverses if:** a censused workload needs a fixed-point iteration no
a-priori generation bound can honestly carry; the recorded path is an
operator-raised bound (a theory edit, judged at re-admission) — not
unrestricted chase.

## Feedback is forward

There are no backward edges and no cycles in the fired graph, ever. "The
reviewer sends work back" is representable and common — as a *new fact*:

```
relation module_impl      { id: mint, src: value } generations 3
relation revision_request { id: mint, target: ref module_impl, diagnostics: value }
spawn repair: for r in revision_request exists m2 in module_impl ...
```

The repair firing is a **new node with a new generation** of the module
implementation. The loop relation declares the bounded `generation` counter
(`Relation.stratified ~generations` in the OCaml surface, `generations` in
the meta-catalog): at most that many engine-minted generations of it may
exist along any one derivation chain, seeds counting as generation zero.
Admission consumes the bound as strata in the weak-acyclicity graph — every
dependency edge into a bounded relation places its head in a new stratum of
a finite ladder, so no such edge can lie on a cycle, and the cycle judgment
runs over the stratum-preserving remainder. The chase enforces the bound by
refusing the firing that would exceed it: the loop's terminal generation is
quiescence, never a fault. The same loop with no declared stratum is
rejected with its cycle path — unbounded "iterate until the reviewer is
happy" is exactly the infinite factory admission exists to refuse. What
looks like iteration is generations; what looks like a backchannel is a
forward relation. This ruling is what keeps derivation squash precision
provable — and it is a coordinate change in the lineage's exact sense
(Dijkstra's half-open interval, homogeneous coordinates): in the (node,
backchannel) coordinate system, feedback is a special case demanding cycle
detection, deadlock policy, and squash exceptions; in the (relation,
generation) coordinate system those cases are not handled, they are
unrepresentable.

**Scope, per the two-graphs ruling (`00-product.md`):** this law governs
**derivation** — what fires what, what provenance records, what squash
walks. It does not govern *communication*: a message from a consumer to a
producer is legal and evented (`20-medium.md` § no walls), but it derives
nothing — no statement fires on it, no tuple's provenance cites it as a
body match, and admission never sees it. A "backchannel" that needs to
*produce work* is still what it always was: a forward relation the theory
hasn't declared yet.

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
`sweep` retires — but `review` nodes start against `sweep`'s in-flight
stores as findings stream out, before `sweep` retires (`20-medium.md`
§ store-to-load forwarding; eager start and read-time binding,
`30-scheduling.md`). `publish` demonstrates a filtered body: it fires per
finding, starts eagerly, and at its read of the verdict count either finds
it witnessed or takes the hypothesis on the popular outcome — speculation is
the default posture (`30-scheduling.md` § speculation is default-on). Every
mechanism the rest of these docs specify is visible in these four
statements; the example is the census workload #2 and the falsifier suite's
canonical theory (`50-api.md`).

---

# Contracts

Every relation's payload is governed by a **catalog entry**: one OCaml type
declaration that is the single supply from which every other artifact
derives.

## The one-supply law

**The contract is an OCaml type; everything an agent sees or a validator
checks is derived from it, mechanically, at build time or theory-accept time.
A hand-carried second copy of any derived artifact is a bug wherever it
appears.**

From one declaration:

```ocaml
(** A single reviewer finding: one defect claim, anchored to a file. *)
type finding = {
  file : string;      (** Repo-relative path the claim anchors to. *)
  line : int option;  (** 1-indexed line, when the claim is line-anchored. *)
  claim : string;     (** One-sentence statement of the defect. *)
  severity : sev;     (** How bad, on the closed scale below. *)
}
and sev = Blocking | Major | Minor
[@@deriving jsonschema ~variant_as_string, yojson]
```

four artifacts derive:

1. **The wire schema** — `finding_jsonschema`, the JSON Schema handed to the
   model API as the forced tool/structured-output schema. Reader: the agent
   invoker (`40-agents.md`).
2. **The codec** — `finding_of_yojson` / `yojson_of_finding`, the parser that
   turns the agent's reply into the typed tuple and the printer that renders
   tuples into downstream prompts. Schema and codec agree by construction
   because they derive from the same declaration; the round-trip is the
   channel boundary's admission check (`20-medium.md`). Reader: the channel
   boundary.
3. **The prompt prose** — the doc comments, harvested (`~ocaml_doc`) into the
   schema's `description` fields and into the contract section of the node's
   prompt. The planner writes one artifact; the model reads the type's own
   documentation. Reader: prompt assembly (`40-agents.md`).
4. **The drift diff** — since the schema is a deterministic function of the
   declaration, "did the contract change" is a mechanical diff of two derived
   schemas, and *how* it changed is the diff's content — which is exactly the
   payload of a reconcile message (`30-scheduling.md` § drift routing).
   Reader: the reconcile router.

**Naming rule, inherited as law: the prompt-reader wins the naming, the
decoder wins the shape.** Field names, enum spellings, and doc comments are
chosen for the model that reads them; encodings, nullability, and structural
strictness are chosen for the codec that parses them. When the two pull
apart, that is the resolution.

## Lowering: what goes where

JSON Schema cannot carry the whole theory, and is not asked to. The split is
constitutional:

- **Per-message payload shape lowers to JSON Schema.** Record shapes, closed
  enums, ref slots as typed id strings, optionality, and *within-payload*
  cardinality (a `3..5`-window head asked for as one array compiles to
  `minItems: 3, maxItems: 5`). The illegal payload is unwritable at the
  decode boundary.
- **Cross-tuple laws never lower to schema.** Inclusions, quorums, EGDs —
  anything relating tuples across messages or nodes — are judged by compiled
  queries at retire (§ the acceptance gate, `30-scheduling.md`). Putting a
  cross-tuple law in a schema would be enforcing it against the wrong scope
  and pretending the boundary judged it.

**The LLM-safe subset is a type, not a lint.** `Wire_schema.t` is a schema
representation that can only express the subset structured-output validators
reliably honor: variants as string enums (`~variant_as_string`), no
`prefixItems` tricks, records closed (`additionalProperties: false`),
recursion via `$defs`/`$ref` only. At theory-accept time the deriver's
Yojson output is **parsed into `Wire_schema.t`, once** — an escape is a
parse failure at admission with the offending path named, and everything
downstream (the API caller, the prompt renderer, the drift differ) consumes
`Wire_schema.t`, in which the unsafe schema is unrepresentable rather than
detected. The parser's acceptance grammar is versioned per model provider
pin. **Decision.** **Alternative:** hand the deriver's full draft-2020-12
output to the API and trust the provider — lost because a silently ignored
constraint is a validator that lies: the payload arrives, parses, and
violates the shape the theory thinks was enforced. **Alternative:** a lint
that walks the Yojson and rejects escapes but passes the raw Yojson through
— lost by doc rule 8: the lint proves safety and throws the proof away,
so every downstream consumer must trust rather than know; the parse keeps
the proof in the type. **Reverses if:** provider validators converge on
full 2020-12 semantics (checked when a pin moves — the change is then
widening `Wire_schema.t`, not removing the parse).

## Code-interface contracts: the meta-type

Contracts describe **data**. The interface of a module some agent will write
is not data — so the catalog does not pretend it is. A code contract is a
**meta-type whose values describe interfaces**:

```ocaml
(** One value in a module's public interface. *)
type sig_item = {
  name : string;         (** The value's name as it appears in the mli. *)
  type_expr : string;    (** Its type, OCaml concrete syntax. *)
  doc : string;          (** The doc comment the mli will carry. *)
}

(** A speculative module interface: the contract an implementer fills
    and a consumer may start against before the implementation exists. *)
type module_contract = {
  module_name : string;
  items : sig_item list;
  invariants : string list;  (** Prose obligations judged by the module's test gate. *)
}
[@@deriving jsonschema, yojson]
```

The `.mli` text is then a **derived artifact too** — rendered from the
`module_contract` value by a printer, handed to both the implementer (as the
interface to satisfy) and the speculative consumer (as the interface to
compile against). The hypothesis in "speculate on the interface" is a
`module_contract` tuple; interface drift is a diff of two such values; and
the enforcement plan for `invariants` is named (the test gate), keeping the
acceptance gate honest. **Decision.** **Alternative:** treat the `.mli`
source text as the contract — lost because text can't be diffed
semantically (whitespace and comment changes would read as drift, defeating
state-changing-generations-only), can't lower to a wire schema for the
implementer's structured output, and can't carry per-item doc routing.
**Reverses if:** never for the wire side; a parsed-AST representation could
replace `type_expr : string` when the string form measurably produces
malformed types (the codec's parse-failure counter is the evidence).

## Versioning and generations

A catalog entry carries no version field. Contract identity is positional
(the relation it governs) and change is detected, not declared: the derived
schema's hash is the contract's **generation witness input** — the thing a
consumer's read of the contract is witnessed against (`30-scheduling.md`
§ the generation-witness protocol). Two consequences:

- **Semantic no-ops are free.** A refactor of the type declaration that
  derives a byte-identical schema advances nothing; speculators against it
  never hear about it. (Doc-comment changes DO change the derived schema —
  descriptions are part of what the model reads — and therefore do advance
  the generation. That is correct: a reworded contract is a different prompt.)
- **There is no compatibility algebra.** No semver, no "backwards-compatible
  addition" judgments. Any schema change is drift; the reconcile router
  decides cheap-patch vs flush from the diff's shape (`30-scheduling.md`),
  which is a policy judgment about *work salvage*, not a type-theory
  judgment about compatibility.

## Failure surface

The codec boundary is a trust boundary, and **it parses, never validates** —
King's distinction, load-bearing here: the boundary returns a typed tuple
(the refined type carrying the proof) or a repair-lane event, never a
"checked" blob. Downstream of the boundary no code re-checks shape,
enum membership, window bounds, or ref resolution, because the tuple's
type is the record of the check. An agent reply that fails the parse is not
an error the engine handles — it is a **repair-lane event**
(`40-agents.md`): the reply text and the parser's diagnostics go back to the
same agent as a stateless repair call. The channel never admits an
unparseable tuple; the theory never sees a partially-valid payload; no panic
is reachable from wire data (adversarially swept — `50-api.md`).

**Ref slots are phantom-typed.** A ref is `finding Id.t`, not a bare id with
a checked annotation: the id type carries its relation as a phantom
parameter, minted only by the engine for that relation, so a verdict
referencing a `change` where a `finding` belongs is a **compile error in
host code and a parse failure at the wire boundary** — never a runtime
admission check in between. Cross-relation ref confusion is unrepresentable
in every typed region of the system; the only place it can even be
*attempted* is agent output, where the boundary parse catches it with a
diagnostic naming the expected relation. Reader: the codec (which owns the
one attemptable surface) and `50-api.md` (whose declaration example shows
the phantom).

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
- **Printer fidelity for `module_contract`.** The `.mli` renderer is a plain
  printer in v0; whether rendered interfaces should be round-tripped through
  the OCaml parser as a lint (catching malformed `type_expr` strings at
  contract-issue time instead of at the consumer's compile) is open.
  *Trigger: the first speculative consumer that burns a run on a malformed
  speculative mli.*
- **Contract libraries.** Recurring catalog entries (finding, verdict,
  revision_request) want a shared home once the second theory repeats them.
  *Trigger: same as theory composition, above.*
