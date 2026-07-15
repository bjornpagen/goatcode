(** The contract layer: one supply, everything derived.

    Every relation's payload is governed by a catalog entry: one OCaml type
    declaration (with [@@deriving jsonschema, yojson]) that is the single
    supply from which every other artifact derives — the wire schema handed
    to the model API, the codec that parses replies, the prompt prose
    (harvested doc comments), and the drift diff. A hand-carried second copy
    of any derived artifact is a bug wherever it appears
    (docs/architecture/20-contracts.md § the one-supply law).

    Naming rule, inherited as law: the prompt-reader wins the naming, the
    decoder wins the shape. Field names, enum spellings, and doc comments are
    chosen for the model that reads them; encodings, nullability, and
    structural strictness are chosen for the codec that parses them. *)

(** Content identity for derived schemas. The schema hash is the contract's
    generation-witness input: a refactor of the type declaration that
    derives a byte-identical schema advances nothing, and speculators
    against it never hear about it. Doc-comment changes DO change the
    derived schema — descriptions are part of what the model reads — and
    therefore do advance the generation
    (docs/architecture/20-contracts.md § versioning and generations). *)
module Schema_hash : sig
  type t

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val to_hex : t -> string
  val pp : Format.formatter -> t -> unit
end

(** A path into a payload shape (field names, [$defs] hops, array-items
    steps): the coordinate system of schema diffs, parse complaints, and the
    consumed-paths drift refinement
    (docs/architecture/40-scheduling.md § drift routing). *)
module Path : sig
  type t = string list
  (** Root-to-leaf steps; [[]] is the payload root. *)

  val to_string : t -> string
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
end

(** The LLM-safe schema subset, as a type rather than a lint.

    [Wire_schema.t] can only express what structured-output validators
    reliably honor: variants as string enums, records closed
    ([additionalProperties: false] by construction — there is no open-record
    constructor), recursion via [$defs]/[$ref] only, no [prefixItems]
    tricks. At theory-accept time the deriver's Yojson output is parsed into
    this type, once; an escape is a parse failure at admission with the
    offending path named, and everything downstream (the API caller, the
    prompt renderer, the drift differ) consumes [Wire_schema.t], in which
    the unsafe schema is unrepresentable rather than detected
    (docs/architecture/20-contracts.md § lowering). *)
module Wire_schema : sig
  type prim = Str | Int | Num | Bool

  (** One schema node. The [doc] on each node is the harvested doc comment,
      rendered into the schema's [description] fields and the prompt's
      contract section — prose the model actually reads. *)
  type node =
    | Prim of { prim : prim; doc : string }
    | Str_enum of { cases : string list; doc : string }
        (** A closed variant, [~variant_as_string]. *)
    | Record of { fields : field list; doc : string }
        (** Closed by construction: no constructor argument can reopen it. *)
    | Array of {
        items : node;
        min_items : int option;
        max_items : int option;
        doc : string;
      }
        (** Within-payload cardinality: a [3..5]-window head asked for as
            one array compiles to [minItems]/[maxItems]
            (docs/architecture/10-theory.md § cardinality windows). *)
    | Nullable of node  (** Optionality, shaped for the decoder. *)
    | Ref_id of { relation : string; doc : string }
        (** A ref slot: a typed id string that must resolve through
            {!Id.Registry.resolve} for [relation]. Ref slots are discovered
            here at admission — the theory never re-declares them, one
            supply (docs/architecture/20-contracts.md § phantom refs). *)
    | Def_ref of string  (** [$ref] into {!t.defs}; the only recursion. *)

  and field = { name : string; required : bool; schema : node }

  type t = { defs : (string * node) list; root : node }

  type escape = { path : Path.t; construct : string; hint : string }
  (** A schema construct outside the safe subset: where it is, what it was,
      and what to write instead — shaped for the planner's repair lane as
      much as for humans. *)

  val parse : Yojson.Safe.t -> (t, escape) result
  (** The admission parse of the deriver's output. The acceptance grammar is
      versioned per model-provider pin; the recorded reversal is widening
      [t], never removing the parse. *)

  val to_json : t -> Yojson.Safe.t
  (** Render for the model API's structured-output request. *)

  val hash : t -> Schema_hash.t
  (** Deterministic content hash; the generation-witness input for contract
      addresses (docs/architecture/50-commit.md § law 2). *)
end

(** Contract drift as a mechanical schema diff. Since the schema is a
    deterministic function of the declaration, "did the contract change" is
    a hash comparison and {e how} it changed is the diff's content — exactly
    the payload of a reconcile message. There is no compatibility algebra:
    no semver, no "backwards-compatible" judgments; the reconcile router
    decides cheap-patch vs flush from the diff's shape — a work-salvage
    judgment, never a type-theory one
    (docs/architecture/20-contracts.md § the drift diff, § versioning). *)
module Diff : sig
  type change =
    | Added of Path.t  (** New optional field / widened enum. *)
    | Removed of Path.t
    | Retyped of { path : Path.t; was : string; now : string }
    | Doc_changed of Path.t
        (** A reworded contract is a different prompt; it advances the
            generation like any structural change. *)

  type t = change list
  (** Empty iff the two schemas hash equal. Inspectable data, per doc
      rule 8: the drift classifier is a total match over this. *)

  val between : Wire_schema.t -> Wire_schema.t -> t
  val is_empty : t -> bool

  val additive_only : t -> bool
  (** True when every change is {!constructor:Added} — the [Additive] drift
      class's signal (docs/architecture/40-scheduling.md § drift routing). *)

  val touched_paths : t -> Path.t list
  (** The paths this diff touches; intersected with a consumer's observed
      reads to judge drift class per consumer, not per contract. *)
end

(** Diagnostics produced when an agent reply fails the boundary parse. The
    reply text and these diagnostics go back to the same agent as a
    stateless repair call; the channel never admits an unparseable tuple and
    no panic is reachable from wire data
    (docs/architecture/20-contracts.md § failure surface;
    docs/architecture/60-agents.md § the primary lane). *)
module Repair : sig
  type complaint = { path : Path.t; expected : string; got : string }

  type diagnostics = {
    raw_reply : string;  (** The invalid output, returned to its author. *)
    complaints : complaint list;
    refusal : bool;
        (** A non-parse with refusal markers (the model refused or
            meta-commented instead of producing tuples): routes to the
            constrained-decode fallback lane, not the repair loop
            (docs/architecture/60-agents.md § the fallback lane). *)
  }
end

(** The codec: the trust boundary that parses, never validates. It returns a
    typed tuple (the refined type carrying the proof) or repair diagnostics
    — never a "checked" blob. Downstream of the boundary no code re-checks
    shape, enum membership, or ref resolution, because the tuple's type is
    the record of the check. The ppx-raised decode exceptions are caught
    here, once, and converted to diagnostics
    (docs/architecture/20-contracts.md § failure surface). *)
module Codec : sig
  type 'a t

  val v :
    of_json:(Yojson.Safe.t -> 'a) -> to_json:('a -> Yojson.Safe.t) -> 'a t
  (** Wrap the ppx-derived pair ([payload_of_yojson], [yojson_of_payload]).
      Schema and codec agree by construction because both derive from the
      same declaration. A typed [of_json] that reads ref slots resolves
      them by closing over its run's registry ({!Id.Registry.resolve} is
      the only wire-string-to-id conversion). *)

  val by_schema : Wire_schema.t -> Yojson.Safe.t t
  (** The schema-driven boundary for schema-typed payloads (the engine's
      head lane, dynamic relations): shape, enum membership, array windows
      ([minItems]/[maxItems]), and ref resolution against mint provenance
      are all one walk of the admitted schema — the same value the model
      was handed, one supply. The parsed value is the codec-proven payload;
      an escape at any path (an invented ref id included) is a repair
      complaint naming that path
      (docs/architecture/20-contracts.md § failure surface). *)

  val parse :
    'a t -> registry:Id.Registry.t -> string -> ('a, Repair.diagnostics) result
  (** Parse a raw agent reply: JSON extraction, shape decode, and ref
      resolution against mint provenance ([registry]), one boundary
      crossing. *)

  val parse_json :
    'a t ->
    registry:Id.Registry.t ->
    Yojson.Safe.t ->
    ('a, Repair.diagnostics) result
  (** The same boundary for already-parsed JSON; seed tuples ride through
      here too (docs/architecture/70-api.md § seed tooling). *)

  val print : 'a t -> 'a -> Yojson.Safe.t

  val render : 'a t -> 'a -> string
  (** The printer that renders tuples into downstream prompts (the operand
      section — docs/architecture/60-agents.md § prompt assembly). *)
end

type 'a t
(** A catalog entry: the contract governing one relation's payload type
    ['a]. Carries the raw deriver output (parsed into {!Wire_schema.t} at
    admission — admission owns the parse and keeps the refined type) and the
    codec, nothing else. There is no version field: contract identity is
    positional (the relation it governs) and change is detected via
    {!Wire_schema.hash}, never declared. *)

val v : name:string -> schema:Yojson.Safe.t -> codec:'a Codec.t -> 'a t
(** [v ~name ~schema ~codec] packages one declaration's derived artifacts.
    [schema] is the raw deriver output ([payload_jsonschema]);
    [Theory.declare] parses it into the safe subset and rejects escapes
    with the offending path named. *)

val name : 'a t -> string
val raw_schema : 'a t -> Yojson.Safe.t
val codec : 'a t -> 'a Codec.t

(** Code-interface contracts: the meta-type. Contracts describe data; the
    interface of a module some agent will write is not data — so the
    catalog does not pretend it is. A code contract is a value of
    {!Module_contract.t} describing the interface; the [.mli] text is a
    derived artifact, rendered by {!Module_contract.render_mli}, handed to
    both the implementer (as the interface to satisfy) and the speculative
    consumer (as the interface to compile against). The hypothesis in
    "speculate on the interface" is a [Module_contract.t] tuple; interface
    drift is a diff of two such values; the enforcement plan for
    [invariants] is the module's test gate — named machinery, keeping the
    acceptance gate honest
    (docs/architecture/20-contracts.md § code-interface contracts). *)
module Module_contract : sig
  type sig_item = {
    name : string;  (** The value's name as it appears in the mli. *)
    type_expr : string;  (** Its type, OCaml concrete syntax. *)
    doc : string;  (** The doc comment the mli will carry. *)
  }

  type t = {
    module_name : string;
    items : sig_item list;
    invariants : string list;
        (** Prose obligations judged by the module's test gate. *)
  }

  val render_mli : t -> string
  (** The plain printer (round-trip fidelity linting is OPEN —
      docs/architecture/20-contracts.md § OPEN items). *)
end

val module_contract : Module_contract.t t
(** The catalog entry for module contracts themselves, so an implementer
    statement's head can be a [module_contract] tuple like any other. *)
