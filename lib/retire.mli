(** Retirement: how speculative state becomes committed state, and how
    everything else becomes nothing.

    A node's entire mutable output is its ledger events — its stores land
    in the ONE shared tree at store time, with the bytes content-addressed
    into git's object database. Squash is the settlement append: the
    subtree's events become provenance-dead by derivation, its tree bytes
    are the hygiene sweep's ({!Frontier.materialize}) — "failed work
    leaves nothing committable" is true by construction, and no
    compensating action is representable here
    (docs/architecture/20-medium.md § squash without isolation).

    Nodes retire in dependency order — a node's producers retire before it
    does — and retirement is the only writer of committed state. Git is the
    storage engine, not a metaphor: the committed tree is a branch,
    retirements are commits, the object database is the blob store, and
    the engine holds the only writer lock on the committed branch; agents
    never run git against it (docs/architecture/30-scheduling.md
    § durability boundary). The landing is built from the ledger, never
    from any tree: the write set from the node's Store events, the bytes
    from the object database's blobs, the commit's tree entries from the
    store events' oids (docs/architecture/30-scheduling.md § retirement
    order and the landing). *)

(** The committed tree and tuple set: reachable only through {!step}, the
    retire path. *)
module Committed : sig
  type t

  val open_ : repo:string -> branch:string -> t

  val root : t -> string
  (** The repo directory the committed branch stays checked out in — the
      ONE shared tree agents' reads resolve and stores land in
      ({!Agent.Invocation.t} [repo]; README.md § design of record vs
      shipped engine, row 4). *)

  val generation : t -> Ledger.Address.t -> Ledger.Generation.t option
  (** The committed generation of an address — the engine's read-time
      lookup (a read of an address with no committed generation is a
      pre-commit read). *)

  val state : t -> Ledger.Address.t -> Witness.Committed_state.t
  (** The committed state of an address — the lookup {!Witness.holds}
      judges against. Absence is a real case: a fresh address's first
      landing is distinguishable from never-committed state, which is what
      rejects a consumer that witnessed a differing pre-commit draft
      (docs/architecture/50-commit.md § law 3). *)

  type tuple = {
    relation : string;
    id : string;
    payload : Yojson.Safe.t;
    generation : Ledger.Generation.t;
  }

  val tuples : t -> tuple list
  (** The final tuple set, the object of law judgment and the settled
      map's [tuples] field. *)

  val seed : t -> relation:string -> id:string -> payload:Yojson.Safe.t -> unit
  (** Enter one run input as committed state, at the primordial generation.
      Seeds are facts, not work product — they are committed by definition,
      so where-filters match their fields, law judgment counts them in its
      universe, and a consumer's read of one witnesses committed state. No
      node wrote a seed: nothing enters the write log, and {!step} remains
      the only writer of node-produced committed state
      (docs/architecture/70-api.md § running). *)
end

(** The live frontier: validity is a ledger coordinate, never a filesystem
    fact — the working tree is a materialization, a cache, of this derived
    view over ledger + committed state. Liveness is a derived judgment,
    not a second supply: a store event is live iff its node is unsettled
    or retired, so the squash settlement is the one appended fact and
    every coordinate under a squashed or faulted node is provenance-dead
    by derivation — no per-event kill marks, no tombstones. Readers: the
    read resolver (hypothesis sourcing), the retire step (commit
    construction), boot and crash recovery ({!Frontier.materialize}), and
    the hygiene sweep (garbage identification)
    (docs/architecture/20-medium.md § validity is a ledger coordinate). *)
module Frontier : sig
  type t

  type in_flight = {
    writer : Ledger.node Id.t;
    content : Ledger.Content_hash.t;
    base : Ledger.Content_hash.t option;
        (** The writer's read point — the same base coordinate the
            disjoint law judges (docs/architecture/30-scheduling.md
            § retirement order and the landing). *)
  }
  (** One live in-flight top: the writer and its uncommitted content. *)

  (** The live top of one address. [In_flight] tops carry the writer —
      the read resolver turns a read of one into a [Store_buffer]
      hypothesis on exactly that node. *)
  type top =
    | Committed of Witness.Committed_state.t
    | In_flight of in_flight

  val of_ledger : Ledger.t -> committed:Committed.t -> t
  (** Derive the frontier. The in-flight half is a snapshot of the
      ledger's live store tops at derivation (re-derive after settlements
      move); the committed half reads through {!Committed.state}, falling
      back to the one ref's tip plus the ledger's invalidation trail when
      the in-memory map is amnesiac — boot after a crash opens an empty
      map, and the committed coordinate survives as ledger state
      (docs/architecture/30-scheduling.md § one ref). *)

  val top : t -> Ledger.Address.t -> top

  val in_flight_tops : t -> (Ledger.Address.t * in_flight) list
  (** Every address whose live top is in flight, in derivation order —
      the gate snapshot's universe: at gate dispatch each one becomes a
      [Store_buffer] hypothesis on its writer plus a witness triple at
      the uncommitted coordinate (docs/architecture/30-scheduling.md
      § gates on the shared tree; falsifier FL6). *)

  val materialize : t -> repo:string -> unit
  (** Converge the tree to the frontier: write each address's live top,
      delete files whose top is [Absent] or [Deleted]. Idempotent;
      appends nothing; moves no coordinate. Checkout semantics — it runs
      at boot, after a crash, and as the hygiene sweep, never on any
      per-node path (docs/architecture/20-medium.md § squash without
      isolation: overwrite-on-reissue primary, lazy convergence
      backstop). *)
end

type generation_moved = {
  address : Ledger.Address.t;
  witnessed : Ledger.Generation.t;
  current : Ledger.Generation.t;
  delta_ref : Ledger.Delta_ref.t;
}
(** The typed signal shipped to the scheduler when a witness fails to hold:
    the engine performs no retry, no merge heroics, no silent re-read —
    the scheduler's drift-routing table owns what happens next
    (docs/architecture/50-commit.md § law 3;
    docs/architecture/40-scheduling.md § drift routing). *)

(** Write-set conflict: the [disjoint] EGD's violation, detected as a set
    intersection over logged footprints — my read-set × your write-set at a
    newer generation; memory disambiguation, mechanized. *)
module Conflict : sig
  type t = {
    node : Ledger.node Id.t;
    sibling : Ledger.node Id.t;
    overlap : Ledger.Footprint.t;
  }

  type route =
    | Serialize of { loser : Ledger.node Id.t; winner : Ledger.node Id.t }
        (** Reissue the loser against the winner's state — the v0 default
            for every conflict. *)
    | Merge of { merge_fn : string }
        (** Only when a declared merge function exists for the address
            class; never improvised. *)
end

(** Merge functions, registered per address class at theory accept. v0
    ships empty — every conflict serializes — until a real pipeline shows a
    serialization hot spot with an obviously-safe merge
    (docs/architecture/50-commit.md § OPEN items). *)
module Merge_registry : sig
  type t

  val empty : t

  val register : t -> address_class:string -> merge_fn:string -> t
  (** [address_class] is a path pattern (dune files, lockfiles); [merge_fn]
      names a registered combiner. Registration happens at theory accept,
      nowhere else. *)

  val lookup : t -> Ledger.Address.t -> string option
end

(** Why one retire step was refused. Every case is a typed signal routed to
    the scheduler; none is an exception. *)
type rejection =
  | Witness_moved of generation_moved list
  | Undischarged of Ledger.hypothesis Id.t list
      (** Undischarged hypotheses block retirement
          (docs/architecture/40-scheduling.md § read-time binding). *)
  | Conflict of Conflict.t

type head_tuple = { relation : string; id : string; payload : Yojson.Safe.t }
(** A head tuple ready to insert: codec-proven payload, provisionally
    minted id. *)

val dependency_order :
  Ledger.t -> candidates:Ledger.node Id.t list -> Ledger.node Id.t list
(** Order retirable nodes so every node's producers precede it — computed
    from firing provenance. Commit-as-you-go lost by ruling: it lets a
    speculative node's output become visible before its hypotheses
    discharge (docs/architecture/50-commit.md § retirement order). *)

val step :
  committed:Committed.t ->
  ledger:Ledger.t ->
  registry:Id.Registry.t ->
  merges:Merge_registry.t ->
  node:Ledger.node Id.t ->
  witness:Witness.t ->
  heads:head_tuple list ->
  (unit, rejection) result
(** The retire step for one node, in the constitutional order:
    (1) discharge check — all hypotheses discharged, the witness holds;
    (2) conflict judgment — write-set intersection against siblings'
    committed write-sets within the current generation;
    (3) the landing — the node's write set, from its Store events, lands
    from the ledger's blobs, never from any tree: a blob ref's bytes come
    out of the object database, a locator ref at a file address is a
    deletion, and the commit's tree entries come from the store events'
    oids, so a neighbor's later in-flight bytes on the same path cannot
    tear the commit; generations advance only on semantic change
    (byte-null landings advance nothing), so an upstream that lands
    exactly what speculators predicted retires them for free (falsifier
    F7); head tuples insert; provisional ids bind ({!Id.Registry.bind},
    dense, replay-stable);
    (4) ledger seal — the settlement event, with timings, closes the node
    (docs/architecture/30-scheduling.md § retirement order and the
    landing). *)

val squash_set :
  Ledger.t -> cause:Ledger.Squash_cause.t -> Ledger.node Id.t list
(** The provenance-closed subtree of a dead hypothesis or faulted node —
    exactly it, computed from tuple provenance. Squash precision is
    absolute: siblings retire undisturbed (falsifier F3;
    docs/architecture/10-theory.md § provenance is total). *)

val squash :
  ledger:Ledger.t ->
  registry:Id.Registry.t ->
  cause:Ledger.Squash_cause.t ->
  unit
(** Execute a squash: {!squash_set}, drop the subtree's provisional ids,
    append [Settled (Squashed cause)] for each node. The settlement
    append is the whole act — nothing filesystem-shaped rides a squash;
    the subtree's tree bytes are {!Frontier.materialize}'s hygiene.
    Nothing renumbers; nothing compensates. *)

val judge :
  theory:Theory.admitted ->
  committed:Committed.t ->
  ledger:Ledger.t ->
  Theory.Law.verdict list
(** Final-state judgment: retire laws judged once, at quiescence, against
    the merged final state and the footprint index — no per-event checking,
    no deferral modes. Mid-run, laws are invisible to executing nodes; a
    node never blocks on a law, only on operands and ports. Verdicts land
    on the settled map, never as faults of any node
    (docs/architecture/50-commit.md § final-state judgment). *)
