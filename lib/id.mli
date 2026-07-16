(** Phantom-typed identifiers: engine-minted identity for tuples, nodes, and
    hypotheses.

    An identifier is ['realm t], where ['realm] names what the id identifies.
    For relation tuples the realm is the relation's payload type, so a ref
    slot in a payload is written [Finding.t Id.t] — a verdict referencing a
    [change] where a [finding] belongs is a compile error in host code and a
    parse failure at the wire boundary, never a runtime admission check in
    between (docs/architecture/10-theory.md § failure surface). Engine
    realms ([Ledger.node], [Ledger.hypothesis]) reuse the same machinery.

    Minting is engine-only with respect to every untyped party: there is no
    [of_string], so the only way an id string coming off the wire becomes an
    ['realm t] is {!Registry.resolve}, which succeeds only for ids this run's
    own minters produced — an agent inventing an id is rejected at the codec
    boundary with a diagnostic naming the expected relation
    (docs/architecture/10-theory.md § inclusions;
    docs/architecture/10-theory.md § failure surface).

    Ids are minted {e provisionally} against the committed counter as of the
    minting node's snapshot; they bind (become committed identity) only at
    the minting node's retirement, in dependency order, so committed id
    space is dense and replay-deterministic. A squashed node's provisional
    ids die with it; nothing renumbers
    (docs/architecture/30-scheduling.md § provisional identity). *)

type 'realm t
(** An identifier in realm ['realm]. Abstract; obtainable only via {!mint}
    (the engine, at firing time) or {!Registry.resolve} (the codec boundary,
    against mint provenance). *)

val equal : 'realm t -> 'realm t -> bool
val compare : 'realm t -> 'realm t -> int
val pp : Format.formatter -> 'realm t -> unit

val to_string : 'realm t -> string
(** Wire rendering of the id. This is the string form agents see in operand
    sections and must echo back in ref slots; there is deliberately no
    inverse — see {!Registry.resolve}. *)

type 'realm id := 'realm t
(* Local alias so submodule signatures can name the outer id type. *)

(** The run's mint-provenance index: which id strings were actually minted,
    in which realm, and whether each is still provisional or has bound.

    One registry exists per run; the codec boundary consults it to reject
    agent-invented ids, and retirement drives the provisional→committed
    transition (docs/architecture/30-scheduling.md § provisional identity). *)
module Registry : sig
  type t
  (** The mutable per-run registry. *)

  val create : unit -> t

  val resolve :
    t ->
    realm:string ->
    string ->
    ('realm id, [ `Unknown_id of string ]) result
  (** [resolve reg ~realm s] is the {e only} conversion from a wire string to
      a typed id: it succeeds iff [s] was minted by this run's minter for
      [realm]. The caller (the codec for one statically-known relation)
      chooses ['realm]; the [realm] name it passes is that relation's name,
      so the phantom it conjures is the one the registry checked.
      [`Unknown_id] is the codec-boundary rejection of invented refs
      (docs/architecture/10-theory.md § failure surface). *)

  val status : t -> 'realm id -> [ `Provisional | `Committed ] option
  (** [None] when the id is not from this registry (impossible for ids
      obtained through {!mint}/{!resolve} on the same run). *)

  val bind : t -> 'realm id -> (unit, [ `Already_bound ]) result
  (** Bind a provisional id at its minting node's retirement. Binding order
      is retirement order, keeping committed id space dense and
      replay-stable (falsifier F14, docs/architecture/50-api.md). *)

  val drop_provisional : t -> 'realm id list -> unit
  (** Squash support: forget a squashed node's provisional ids. Dropped ids
      can never resolve again; nothing renumbers. *)
end

(** A per-realm minting capability. Minters are created by the engine when a
    run opens (one per relation of the admitted theory, plus the node and
    hypothesis realms) and are never handed to executors or host callbacks —
    the engine is the only holder, which is what "engine-only minting" means
    operationally. Host code has no honest way to a ['realm Minter.t] for a
    running theory because the run creates its own. *)
module Minter : sig
  type 'realm t

  val create : registry:Registry.t -> realm:string -> 'realm t
  (** [create ~registry ~realm] opens the realm's id supply, recording every
      mint in [registry]. Called once per realm at run start; calling it
      outside the engine yields a minter whose ids no run's registry
      recognizes, so forgery cannot cross the codec boundary. *)
end

val mint : 'realm Minter.t -> 'realm t
(** Mint a fresh provisional id: fills a head mint slot at firing time
    (the rename — docs/architecture/10-theory.md § relations). Provisional
    ids are real ids — downstream speculative nodes ref them, tuples carry
    them — but they bind only at the minting node's retirement. *)
