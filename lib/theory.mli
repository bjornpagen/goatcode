(** The work representation: relations plus dependency statements, admitted
    into a refined type.

    A unit of orchestrated work is a theory — orchestration control flow
    reified as data, run by a small evaluator ({!Chase}). Fanout is not a
    loop, it is a spawn statement the chase interprets; review-and-repair is
    not a callback cycle, it is a relation and a generation
    (docs/architecture/10-theory.md).

    Admission is a parse, not a validation: {!declare} returns
    [(admitted, Admission.error list) result], and {!type-admitted} has no
    other constructor — possession of the value {e is} the proof of weak
    acyclicity, acceptance-gate coverage, and schema safety. No code
    downstream re-checks any of it; an unadmitted theory reaching the engine
    is not an error path, it is unrepresentable
    (docs/architecture/10-theory.md § termination;
    docs/architecture/70-api.md § declaring a theory). *)

(** A relation: a named tuple shape whose payload is a contract catalog
    entry. Relations become channels at admission
    (docs/architecture/30-channels.md § pre-opened channels). The phantom
    ['a] is the payload type, which is also the {!Id} realm for the
    relation's mint slot — so a ref to this relation is written ['a Id.t]. *)
module Relation : sig
  type 'a t

  val v : name:string -> 'a Contract.t -> 'a t
  (** Declare a relation over a statically-typed payload. Slot structure
      (mint / ref / value) is discovered from the contract's derived schema
      at admission, never re-declared: the engine-filled mint id sits
      outside the payload, ref slots are the schema's [Ref_id] nodes,
      everything else is value (docs/architecture/10-theory.md § relations). *)

  val dynamic : name:string -> schema:Yojson.Safe.t -> Yojson.Safe.t t
  (** A relation whose payload type exists only as a schema — the planner
      lane: planner-emitted theories arrive as data through the
      meta-catalog, with no OCaml payload type to derive from. The payload
      is schema-checked JSON; everything else (admission, channels,
      codecs-by-schema) is identical
      (docs/architecture/60-agents.md § the planner). *)

  val stratified : generations:int -> 'a t -> 'a t
  (** Mark the relation as a feedback loop's stratum carrier: at most
      [generations] engine-minted generations of it may exist along any one
      derivation chain (seeds are generation zero). Admission consumes the
      bound as strata in the weak-acyclicity judgment — every edge into a
      bounded relation crosses to a new stratum, so a loop through it is a
      bounded spiral, not an infinite factory — and the chase refuses the
      firing that would exceed the bound
      (docs/architecture/10-theory.md § feedback is forward). A bound below
      one is an admission error. *)

  val name : 'a t -> string

  val witness : 'a t -> 'a Type.Id.t
  (** The relation's payload witness, minted once at declaration. The
      channel registry stores it alongside the log it opens for this
      relation, and {!Channel.tx}/{!Channel.rx} recover the payload type by
      [Type.Id.provably_equal] against the presented relation — so a
      channel end at the wrong payload type is unconstructible even through
      the name-keyed table: only this declaration's own value refines
      (docs/architecture/30-channels.md § pre-opened channels). *)

  val payload_of_json :
    'a t ->
    registry:Id.Registry.t ->
    Yojson.Safe.t ->
    ('a, Contract.Repair.diagnostics) result
  (** Re-enter a wire payload through the relation's own codec — the typed
      decode the engine's retire path uses to publish a committed head
      tuple on the relation's channel: the payload was codec-proven at the
      boundary parse against this relation's admitted schema, so the typed
      log receives a value of the very type the channel was opened for
      (docs/architecture/50-commit.md § retirement order;
      docs/architecture/30-channels.md § pre-opened channels). *)

  type packed = Packed : 'a t -> packed
  (** Existential wrapper for heterogeneous relation lists. *)
end

(** Slot classification, as parsed from the contract at admission. Exactly
    one mint slot exists per relation (the engine-filled id); a mint is a
    write port in the rename analogy
    (docs/architecture/10-theory.md § relations).

    The slot set is total over everything admission admits: a ref nested
    below the payload's top level (inside arrays or sub-records) carries
    the same edge, footprint subscription, and witness obligation as a
    top-level one, so it gets a slot of its own, named by its dotted
    payload path (array items step spelled [[]]). *)
module Slot : sig
  type kind =
    | Mint  (** Born here; filled by the engine at firing time. *)
    | Ref of string
        (** A foreign identity; the payload position is a [target Id.t].
            The inclusion statement is implicit and its enforcement plan is
            the codec's registry check plus retire re-judgment. *)
    | Value  (** Plain payload data, shaped by the contract. *)

  type t = { field : string; kind : kind }
  (** [field] is a top-level payload field name, or the dotted payload path
      of a nested ref slot. *)
end

(** Cardinality windows: between [n] and [m] head tuples per body match.
    The bound is shape, never a runtime check — it compiles into the node's
    wire schema ([minItems]/[maxItems]) or into the firing count; the theory
    author picks which (docs/architecture/10-theory.md § statement grammar). *)
module Window : sig
  type t =
    | Tuples of { min : int; max : int }
        (** One node produces a tuple array of this width; lowers to
            [minItems]/[maxItems] in the head contract. *)
    | Nodes of int
        (** [n] independent firings, one tuple each — the antagonistic-panel
            shape ([3 nodes v in verdict]). *)

  val exactly : int -> t
  val between : min:int -> max:int -> t
  val upto : int -> t
  val nodes : int -> t
end

(** A model pin: (provider, model id, sampling config, prompt-affecting
    options), recorded in the theory. Pins move deliberately, never
    implicitly; a pin bump is a first-class ledger event and resets the
    shape's predictor counters — survival history is per pin
    (docs/architecture/60-agents.md § model pins). *)
module Pin : sig
  type t = {
    provider : string;
    model : string;
    sampling : (string * float) list;
    options : (string * string) list;
  }

  val key : t -> string
  (** Stable identity for predictor counters and ledger events. *)

  val equal : t -> t -> bool
end

(** What a spawn statement's [by] clause names. The declaration lives here
    (data, in the theory); the runtime behind each case is bound in the run
    config ({!Agent} owns invocation). Pure functions and shell gates exist
    so the theory never invokes an LLM to do a compiler's job
    (docs/architecture/60-agents.md). *)
module Executor : sig
  (** An effect tool the template grants its nodes, priced at
      declaration: [Idempotent] carries the recorded idempotence
      argument (a re-runnable build/test command, a content-keyed cache
      write) and is grantable under either speculation status;
      [Non_idempotent] reaches only hypothesis-free dispatches — the
      grant's status index polices the rest
      (docs/architecture/60-agents.md § tool grants; {!Agent.Grant}). *)
  module Effect : sig
    type t =
      | Idempotent of { tool : string; why : string }
      | Non_idempotent of { tool : string }
  end

  type t =
    | Agent_template of {
        name : string;
        pin : Pin.t;
        preamble : string;
            (** The role text (refuter, implementer, summarizer): the one
                hand-written artifact, owned by the theory author. It states
                stance and method, never shape — shape derives from the
                contract (docs/architecture/60-agents.md § prompt assembly). *)
        read_globs : string list;
            (** The read half of the file footprint grant — ambient
                visibility over the shared tree (readable, snoopable);
                ref-slot reads are derived from the contract. *)
        write_globs : string list;
            (** The write half: where the template's nodes' stores may
                land in the shared tree. A store outside it is a typed
                {!Agent.Grant.Refusal} at the tool boundary. Hygiene, not
                a wall: overlapping grants are legal, and the disjoint
                law convicts an actual clobber
                (docs/architecture/40-agents.md § tool grants). *)
        effects : Effect.t list;
            (** Effect tools the template's nodes may run ([run_command]
                is the one v0 runtime): declarations here become grant
                entries at dispatch — idempotent ones under either
                speculation status, non-idempotent ones only when the
                node carries no hypotheses. *)
      }
    | Pure_fn of { name : string }
        (** Host OCaml, for mechanical transforms; bound by name at run. *)
    | Shell_gate of {
        name : string;
        command : string list;
        resource : string;
            (** The declared build-artifact resource the gate's effect
                lock scopes to (the [_build] dir, a package cache) —
                declared on the gate the way every effect footprint is
                declared; gates on distinct resources overlap, and
                source-tree reads take no lock
                (docs/architecture/30-scheduling.md § gates on the
                shared tree). *)
      }
        (** A build/test command whose exit status and output become
            tuples. *)

  type id
  (** Executor identity, half of a speculation shape key
      ((statement, executor) per pin —
      docs/architecture/40-scheduling.md § the predictor). *)

  val id : t -> id
  val id_to_string : id -> string
  val id_equal : id -> id -> bool
  val id_compare : id -> id -> int

  val pin : t -> Pin.t option
  (** [Some] only for agent templates. *)
end

(** Body filters: the v0 [where] grammar — single-relation bodies plus
    filters over refs one hop away, which covers the census; true join
    bodies are OPEN (docs/architecture/10-theory.md § OPEN items). *)
module Filter : sig
  type cmp = Lt | Le | Eq | Ge | Gt

  type t =
    | Count of {
        over : string;  (** The counted relation ([verdict]). *)
        link : string;
            (** The ref field of [over] pointing at the body tuple
                ([finding]). *)
        where_equals : (string * Yojson.Safe.t) list;
            (** Extra value-field equalities on counted tuples
                ([v.refuted = true]). *)
        cmp : cmp;
        bound : int;
      }
        (** [count(x in over where x.link = body.id and where_equals) cmp
            bound] — the [publish] shape in the worked example. Used by the
            scheduler as a readiness filter; the final law judgment still
            runs (docs/architecture/50-commit.md § final-state judgment). *)
end

(** Statement identity within one admitted theory. *)
module Statement : sig
  type id

  val to_string : id -> string
  val equal : id -> id -> bool
  val compare : id -> id -> int
end

(** Spawn statements (TGDs): for every body match, there exist head tuples,
    produced by an executor. One firing = one node; fanout width is
    data-generated, never plan-static. Head mint slots are filled with fresh
    existentials at firing time — the rename
    (docs/architecture/10-theory.md § statement grammar). *)
module Spawn : sig
  type t = {
    name : string;
    for_ : string;  (** The body relation (single-relation bodies in v0). *)
    where : Filter.t option;
    exists : string * Window.t;  (** Head relation and its window. *)
    by : Executor.t;
  }

  val v :
    name:string ->
    for_:string ->
    ?where:Filter.t ->
    exists:string * Window.t ->
    by:Executor.t ->
    unit ->
    t
end

(** Retire laws (EGD-class): predicates over the final state that gate
    retirement, judged once, at quiescence, against the merged final state —
    never per-event, never deferred-with-modes. Each constructor carries its
    enforcement plan by construction: a law is one of these compiled-query
    shapes or it does not exist (the acceptance gate — no idiomatic-code
    laws, no implication judgments, no soft laws;
    docs/architecture/10-theory.md § the acceptance gate). *)
module Law : sig
  type bound = At_least of int | At_most of int | Exactly of int

  type t =
    | Count of {
        name : string;
        over : string;  (** The counted relation. *)
        group_by : string;
            (** The ref field of [over] grouping counts per referent. *)
        bound : bound;
      }
        (** Compiles to a query over the final tuple set ([quorum]). *)
    | Disjoint_writes of { name : string }
        (** No two nodes commit writes to the same path in one generation:
            the EGD whose violation is the merge-conflict signal, judged
            against the footprint index
            (docs/architecture/50-commit.md § retirement order). *)

  val name : t -> string

  type verdict = {
    law : string;
    satisfied : bool;
    offenders : string list;
        (** The tuples or paths that witness a violation — a quorum
            shortfall names the law and the tuples; the host decides whether
            that is an error (docs/architecture/40-scheduling.md
            § quiescence). *)
  }
  (** Law verdicts land on the settled map, never as faults of any node:
      causation over set-valued laws is ill-posed by ruling. *)
end

(** A typed fact, pre-run: what seeds are made of. Seed payloads written in
    OCaml are typed at construction; JSON seeds enter through the same codec
    boundary as agent replies (docs/architecture/70-api.md § running,
    § seed tooling). *)
module Tuple : sig
  type t = Packed : 'a Relation.t * 'a -> t

  val v : 'a Relation.t -> 'a -> t
  val relation_name : t -> string

  val payload_json : t -> Yojson.Safe.t
  (** The payload's wire rendering through the relation's own codec — what
      the engine feeds the body-match feed and committed state with at run
      open. Typed at construction, so the rendering is codec-proven by
      construction (docs/architecture/70-api.md § running). *)
end

(** A consumer edge: one statement reading one relation, with the raw
    material of its footprint declaration (compiled from the contract: the
    ref slots it reads plus the executor's file-glob grant). The theory
    author never writes routing; routing is derived from what the contract
    says the consumer depends on
    (docs/architecture/30-channels.md § footprint filtering). *)
module Edge : sig
  type t = {
    statement : Statement.id;
    reads : string;  (** The body relation. *)
    ref_fields : string list;
        (** Ref slots of [reads] the consumer dereferences. *)
    read_globs : string list;  (** The executor's file-glob grant. *)
    counts : string list;
        (** Relations the statement's where-filter counts over. A count
            is a read — the firing consumes the counted tuples — so the
            filter's relation joins the edge exactly like a ref target:
            it widens the delivery filter (counted landings reach the
            consumer as drift notes) and the footprint-escape judgment
            (a counted-tuple read is declared, not an escape). *)
  }
end

(** Admission errors: values, each carrying the offending statement and,
    for cycles, the cycle path — shaped for the planner's repair lane as
    much as for humans (docs/architecture/70-api.md § declaring a theory).
    The planner earns no trust the operator doesn't have: planner-emitted
    theories pass exactly this judgment. *)
module Admission : sig
  type error =
    | Cycle of { path : (string * string) list }
        (** A weak-acyclicity violation: the (relation, field) positions of
            a cycle through mint edges — "this statement can spawn itself
            forever, here's the cycle"
            (docs/architecture/10-theory.md § termination). *)
    | Schema_escape of {
        relation : string;
        escape : Contract.Wire_schema.escape;
      }
        (** The contract's derived schema left the LLM-safe subset. *)
    | Unknown_relation of { statement : string; relation : string }
    | Unknown_ref_target of {
        relation : string;
        field : string;
        target : string;
      }
        (** A [Ref_id] naming a relation the theory doesn't declare. *)
    | Duplicate_relation of { name : string }
    | Duplicate_statement of { name : string }
    | Reserved_field of { relation : string; field : string }
        (** A payload field that collides with the engine-filled mint slot:
            the engine owns [id], and a contract declaring its own would
            shadow the mint at every consumer. *)
    | Invalid_window of { statement : string; reason : string }
        (** A cardinality window no firing plan can satisfy ([0 nodes], a
            negative or inverted tuple range) — shape nonsense rejected
            where it is written, never a per-node fault at the boundary. *)
    | Git_gate of { statement : string; command : string }
        (** A shell gate whose argv[0] resolves to git. Git is the
            harness's commit substrate — [Retire.Committed] holds the only
            writer lock on the committed branch — and a worker running git
            is an unwitnessed effect plus revert and branch machinery;
            gate command lines are data in the theory, so the ban is an
            admission judgment, not a dispatch-time refusal (operator
            ruling; docs/architecture/60-agents.md § the git ban). *)
    | Invalid_generation_bound of { relation : string; bound : int }
        (** A generation stratum that does not bound: the counter must
            admit at least one generation or the loop it carries is an
            infinite factory. *)
    | Unjudgeable_law of { law : string; reason : string }
        (** A law the compiler cannot turn into a final-state query — prose
            wearing law's clothing, rejected at admission. *)

  val to_string : error -> string
  val pp : Format.formatter -> error -> unit
end

type admitted
(** An admitted theory. {b No public constructor}: the only way to obtain
    one is {!declare}, and it is the only theory type the rest of the API
    mentions — [Run.exec] cannot be called on anything else, so an
    unadmitted theory cannot reach the engine by any code path (falsifier
    F15 asserts the negative compile;
    docs/architecture/80-validation.md). *)

val declare :
  relations:Relation.packed list ->
  statements:Spawn.t list ->
  laws:Law.t list ->
  (admitted, Admission.error list) result
(** Declaration runs admission immediately, and admission is a parse: weak
    acyclicity (the dependency graph over relation positions, rejecting
    cycles through mint edges — edges into a generation-bounded relation
    cross a stratum and never close one), the acceptance gate (every law
    compiled to its judge), the schema parse into
    {!Contract.Wire_schema.t}, and ref-slot resolution all happen here,
    once. Errors accumulate — the planner's repair call sees all of
    them. *)

(** {2 Reading an admitted theory}

    Accessors return what admission proved; none of them re-check
    anything. *)

val relations : admitted -> Relation.packed list
val statements : admitted -> (Statement.id * Spawn.t) list
val laws : admitted -> Law.t list
val edges : admitted -> Edge.t list

val wire_schema : admitted -> relation:string -> Contract.Wire_schema.t option
(** The parsed, safe schema — the proof admission kept
    (docs/architecture/20-contracts.md § the LLM-safe subset). [None] for
    names the theory doesn't declare. *)

val schema_hash : admitted -> relation:string -> Contract.Schema_hash.t option
(** The contract's generation-witness input
    (docs/architecture/50-commit.md § law 2). *)

val slots : admitted -> relation:string -> Slot.t list option
(** Slot classification as parsed from the contract at admission: the
    synthetic mint slot, the top-level payload fields, then the nested ref
    slots — total over every [Ref_id] the schema carries. *)

val generations : admitted -> relation:string -> int option
(** The relation's declared generation bound — the stratum data the
    weak-acyclicity judgment consumed, and the firing bound the chase
    enforces at the loop's terminal generation
    (docs/architecture/10-theory.md § feedback is forward). [None] for
    unstratified relations and undeclared names. *)

(** The meta-catalog: a theory as wire data, which is how the planner emits
    one — relations, statements, templates, pins are just more catalog. A
    meta-theory admits through {!Meta.admit}, which builds dynamic relations
    and runs the {e same} admission judgment as hand-written theories
    (docs/architecture/60-agents.md § the planner). *)
module Meta : sig
  type t
  (** A wire-shaped theory description. *)

  val contract : unit -> t Contract.t
  (** The catalog entry for meta-theories: the planner template's head
      contract. *)

  val admit : t -> (admitted, Admission.error list) result
  (** Identical judgment to {!declare}; a rejected meta-theory returns to
      the planner with these errors through the standard repair lane. *)
end
