(** Retirement: how speculative state becomes committed state, and how
    everything else becomes nothing.

    A node's entire mutable output lives in its own git worktree and its
    ledger events. Squash is: drop the worktree, mark the events squashed —
    nothing else exists to clean up; "failed work leaves nothing" is true
    by construction, never by rollback, and no compensating action is
    representable here (docs/architecture/50-commit.md § abort by
    construction).

    Nodes retire in dependency order — a node's producers retire before it
    does — and retirement is the only writer of committed state. Git is the
    storage engine, not a metaphor: the committed tree is a branch,
    retirements are commits, worktrees are git worktrees, and the engine
    holds the only writer lock on the committed branch; agents never run
    git against it (docs/architecture/50-commit.md § durability
    boundary). *)

(** A node's store buffer: its git worktree. Uncommitted, squashable by
    dropping, snoopable by speculative consumers
    (docs/architecture/30-channels.md § event taxonomy, § store-to-load
    forwarding). *)
module Worktree : sig
  type t

  val create : root:string -> node:Ledger.node Id.t -> t
  val path : t -> string

  val snoop_mount : t -> string
  (** The read-only mount speculative downstream nodes read; a snooped read
      enters the consumer's witness at this producer's uncommitted
      generation. *)

  val net_delta : t -> (Ledger.Address.t * Ledger.Delta_ref.t) list
  (** Stores coalesce here: twelve edits to one file forward as one delta;
      an edit that restores the original cancels to nothing. The ref is
      the worktree-relative locator — the same locator the agent layer's
      store tools mint (the v0 blob scheme;
      docs/architecture/30-channels.md § OPEN items). *)

  val drop : t -> unit
  (** Squash's entire filesystem action ([git worktree remove]). *)
end

(** The committed tree and tuple set: reachable only through {!step}, the
    retire path. *)
module Committed : sig
  type t

  val open_ : repo:string -> branch:string -> t

  val root : t -> string
  (** The repo directory the committed branch stays checked out in — the
      read root an agent's in-glob load falls through to when its own
      worktree misses ({!Agent.Grant.t} [committed_root]). *)

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
  worktree:Worktree.t ->
  witness:Witness.t ->
  heads:head_tuple list ->
  (unit, rejection) result
(** The retire step for one node, in the constitutional order:
    (1) discharge check — all hypotheses discharged, the witness holds;
    (2) conflict judgment — write-set intersection against siblings'
    committed write-sets within the current generation;
    (3) the merge — the worktree's net delta applies to the committed
    tree; generations advance only on semantic change (byte-null deltas
    advance nothing; contract addresses compare by derived-schema hash),
    so an upstream that lands exactly what speculators predicted retires
    them for free (falsifier F7); head tuples insert; provisional ids bind
    ({!Id.Registry.bind}, dense, replay-stable);
    (4) ledger seal — the settlement event, with timings, closes the node
    (docs/architecture/50-commit.md § retirement order and the merge). *)

val squash_set :
  Ledger.t -> cause:Ledger.Squash_cause.t -> Ledger.node Id.t list
(** The provenance-closed subtree of a dead hypothesis or faulted node —
    exactly it, computed from tuple provenance. Squash precision is
    absolute: siblings retire undisturbed (falsifier F3;
    docs/architecture/10-theory.md § provenance is total). *)

val squash :
  ledger:Ledger.t ->
  registry:Id.Registry.t ->
  worktrees:(Ledger.node Id.t * Worktree.t) list ->
  cause:Ledger.Squash_cause.t ->
  unit
(** Execute a squash: {!squash_set}, drop each worktree, drop the subtree's
    provisional ids, append [Settled (Squashed cause)] for each node.
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
