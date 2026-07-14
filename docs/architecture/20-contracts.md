# 20 — Contracts

The contract layer. Every relation's payload is governed by a **catalog
entry**: one OCaml type declaration that is the single supply from which every
other artifact derives. Readers of this doc: theory authors (who write catalog
entries), the `Contract` module (which derives from them), and `60-agents.md`
(which consumes the derived prompt artifacts).

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
   invoker (`60-agents.md`).
2. **The codec** — `finding_of_yojson` / `yojson_of_finding`, the parser that
   turns the agent's reply into the typed tuple and the printer that renders
   tuples into downstream prompts. Schema and codec agree by construction
   because they derive from the same declaration; the round-trip is the
   channel boundary's admission check (`30-channels.md`). Reader: the channel
   boundary.
3. **The prompt prose** — the doc comments, harvested (`~ocaml_doc`) into the
   schema's `description` fields and into the contract section of the node's
   prompt. The planner writes one artifact; the model reads the type's own
   documentation. Reader: prompt assembly (`60-agents.md`).
4. **The drift diff** — since the schema is a deterministic function of the
   declaration, "did the contract change" is a mechanical diff of two derived
   schemas, and *how* it changed is the diff's content — which is exactly the
   payload of a reconcile message (`50-commit.md` § drift). Reader: the
   reconcile router.

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
  queries at retire (`10-theory.md` § the acceptance gate, `50-commit.md`).
  Putting a cross-tuple law in a schema would be enforcing it against the
  wrong scope and pretending the boundary judged it.

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
consumer's read of the contract is witnessed against (`50-commit.md`). Two
consequences:

- **Semantic no-ops are free.** A refactor of the type declaration that
  derives a byte-identical schema advances nothing; speculators against it
  never hear about it. (Doc-comment changes DO change the derived schema —
  descriptions are part of what the model reads — and therefore do advance
  the generation. That is correct: a reworded contract is a different prompt.)
- **There is no compatibility algebra.** No semver, no "backwards-compatible
  addition" judgments. Any schema change is drift; the reconcile router
  decides cheap-patch vs flush from the diff's shape (`50-commit.md`), which
  is a policy judgment about *work salvage*, not a type-theory judgment about
  compatibility.

## Failure surface

The codec boundary is a trust boundary, and **it parses, never validates** —
King's distinction, load-bearing here: the boundary returns a typed tuple
(the refined type carrying the proof) or a repair-lane event, never a
"checked" blob. Downstream of the boundary no code re-checks shape,
enum membership, or ref resolution, because the tuple's type is the record
of the check. An agent reply that fails the parse is not an error the
engine handles — it is a **repair-lane event** (`60-agents.md`): the reply
text and the parser's diagnostics go back to the same agent as a stateless
repair call. The channel never admits an unparseable tuple; the theory never
sees a partially-valid payload; no panic is reachable from wire data
(adversarially swept — `80-validation.md`).

**Ref slots are phantom-typed.** A ref is `finding Id.t`, not a bare id with
a checked annotation: the id type carries its relation as a phantom
parameter, minted only by the engine for that relation, so a verdict
referencing a `change` where a `finding` belongs is a **compile error in
host code and a parse failure at the wire boundary** — never a runtime
admission check in between. Cross-relation ref confusion is unrepresentable
in every typed region of the system; the only place it can even be
*attempted* is agent output, where the boundary parse catches it with a
diagnostic naming the expected relation. Reader: the codec (which owns the
one attemptable surface) and `70-api.md` (whose declaration example shows
the phantom).

## OPEN items

- **Printer fidelity for `module_contract`.** The `.mli` renderer is a plain
  printer in v0; whether rendered interfaces should be round-tripped through
  the OCaml parser as a lint (catching malformed `type_expr` strings at
  contract-issue time instead of at the consumer's compile) is open.
  *Trigger: the first speculative consumer that burns a run on a malformed
  speculative mli.*
- **Contract libraries.** Recurring catalog entries (finding, verdict,
  revision_request) want a shared home once the second theory repeats them.
  *Trigger: same as theory composition (`10-theory.md`).*
- **Non-JSON payloads.** Large artifacts (diffs, file trees) ride as refs
  into the worktree/ledger, not as inline JSON — decided — but the exact ref
  scheme (content hash vs path+generation) is open. *Trigger: the store-buffer
  snooping implementation (`30-channels.md`), which is the first reader that
  must resolve one.*
