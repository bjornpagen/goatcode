(** Observed witnesses: the read-set a node can prove, assembled from its
    own ledger events.

    The witness is the artifact, never an asserted version number. A node's
    witness is the set of (address, generation, content-hash) triples
    captured from its {e observed} load events — parse-don't-validate
    applied to trust: a version number is a validator's residue, a claim
    whose proof was thrown away; the observed triple set is the proof
    itself, carried to the commit point. An agent cannot fabricate a
    witness, cannot forget a dependency it consulted, and cannot claim
    staleness-immunity it doesn't have — which is why the witness needs no
    trust boundary of its own
    (docs/architecture/50-commit.md § the generation-witness protocol;
    docs/architecture/30-channels.md § mechanized witnesses;
    falsifier F6). *)

(** One observed read. A snooped read of a producer's store buffer enters
    with the producer's {e uncommitted} generation — exactly what makes the
    speculation honest (docs/architecture/30-channels.md § store-to-load
    forwarding). *)
type triple = {
  address : Ledger.Address.t;
  generation : Ledger.Generation.t;
  content : Ledger.Content_hash.t;
}

type t
(** A witness: a set of {!triple}s. Obtainable only from ledger observation
    ({!observed}) — there is deliberately no [of_list]. *)

val observed : Ledger.t -> node:Ledger.node Id.t -> t
(** Assemble the node's witness from its load events via
    {!Ledger.Witness_index.reads}. Captured by observation, never
    self-report. *)

val triples : t -> triple list
val addresses : t -> Ledger.Footprint.t

val consumed_paths :
  t -> contract_of:(Ledger.Address.t -> string option) -> string list
(** The contract payload paths this witness proves the node read — the
    input to the per-consumer drift refinement: a breaking change to a
    field the consumer never read is additive from that consumer's
    perspective (docs/architecture/40-scheduling.md § drift routing). *)

val observed_content :
  t -> Ledger.Address.t -> Ledger.Content_hash.t option
(** The content the node's latest observed read of [address] proves it
    derived from — the base coordinate of its committed writes, from which
    the disjoint law detects clobbers by construction
    (docs/architecture/50-commit.md § retirement order and the merge).
    [None]: the node never read the address (a blind write's base). *)

(** {2 The commit-point check} *)

(** The committed side of the check: what the committed store knows about
    one address. Absence is a real case, never a sentinel generation — a
    fresh address's first landing ([Landed] at the first generation) is a
    different state from [Absent], which is what closes the hole where a
    consumer that witnessed a pre-commit draft could retire over a
    producer's differing first landing. *)
module Committed_state : sig
  type t =
    | Absent  (** Nothing has ever landed at the address. *)
    | Landed of {
        generation : Ledger.Generation.t;
        content : Ledger.Content_hash.t;
      }
    | Deleted of { generation : Ledger.Generation.t }
        (** A committed deletion: the address has a generation but no
            content — every triple witnessed against it is stale. *)
end

type stale = {
  address : Ledger.Address.t;
  witnessed : Ledger.Generation.t;
  current : Committed_state.t;
}
(** One witnessed triple the committed state no longer supports. *)

val holds :
  t ->
  committed:(Ledger.Address.t -> Committed_state.t) ->
  (unit, stale list) result
(** Commit iff the witness holds: every witnessed triple still describes
    the committed state. The judged thing is the artifact (law 1) — the
    committed content is the content the triple carries; generation
    equality is that comparison's shadow under law 2, never the check
    itself. A triple witnessed at the primordial generation holds against
    [Absent] (a pre-commit read of state nothing has landed over). [Error
    stales] is the raw material of [Retire.Generation_moved] — the engine
    performs no retry, no merge heroics, no silent re-read; routing is the
    scheduler's (docs/architecture/50-commit.md § law 3).

    Soundness, never freshness: a held witness proves the node's outputs
    were derived from the state they claim — it does not prove no better
    input existed. Freshness is scheduler economics, never a
    commit-blocking judgment (docs/architecture/50-commit.md § law 4). *)
