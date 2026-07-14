(** Channels: pre-opened, unidirectional, invalidation-carrying.

    A channel is a relation in motion: flow is from the statement that
    mints into it to the statements whose bodies read it, permanently —
    the only bidirectional party in the system is the scheduler. Everything
    a backchannel would carry is representable forward: a question, a
    revision request, a refutation is a new fact in a new relation that
    fires a new node (docs/architecture/30-channels.md § the unidirectional
    law; docs/architecture/10-theory.md § feedback is forward).

    Unidirectionality is by construction, not by check: the reader end
    ({!type-rx}) has no publish operation and the writer end ({!type-tx})
    has no pull operation, and no function converts between them (falsifier
    F11 sweeps for any such surface).

    Every channel exists at admission, before any node runs — socket
    activation with tuples for datagrams: a consumer can begin before its
    producers have produced, because the channel it will eventually read is
    already a real object it can hold, subscribe to, and suspend on.
    Readiness is a property of a read, never of a node
    (docs/architecture/30-channels.md § pre-opened channels). *)

(** A notification: small, typed, payload-free. Consumers pull the net
    delta through [delta_ref] if and when they decide it matters — the
    scarcest resource in the system is the consumer agent's context window,
    and update-flooding fills it with other agents' play-by-play
    (docs/architecture/30-channels.md § invalidate, don't update). *)
module Invalidation : sig
  type t = {
    address : Ledger.Address.t;
    new_generation : Ledger.Generation.t;
    producer : Ledger.node Id.t;
    delta_ref : Ledger.Delta_ref.t;
  }

  val passes : footprint:Ledger.Footprint.t -> t -> bool
  (** Footprint filtering: an invalidation forwards down an edge only when
      its address intersects the edge's declared footprint. The declaration
      is a filter, never a wall — correctness comes from the observed
      witness; the declaration only tunes delivery
      (docs/architecture/30-channels.md § footprint filtering). *)
end

type 'a tx
(** The producer end of the channel for a relation with payload ['a]. Held
    only by the engine's retire path (committed tuples, invalidations) and
    the store-buffer forwarder. No pull operation exists on this type. *)

type 'a rx
(** One consumer edge's end: a cursor over committed tuples plus a
    footprint-filtered invalidation queue. No publish operation exists on
    this type. *)

(** The run's channel table, allocated at admission. *)
type registry

val open_all : Theory.admitted -> registry
(** Pre-open every relation's channel the moment admission passes — before
    any node runs. This is what makes eager start legal
    (docs/architecture/40-scheduling.md § eager start). *)

val tx : registry -> 'a Theory.Relation.t -> 'a tx
(** The unique writer end for a relation. The engine is the only caller;
    executors never hold channel ends (their reads and writes are tool
    calls against worktrees, observed by the ledger). *)

val rx : registry -> 'a Theory.Relation.t -> edge:Theory.Edge.t -> 'a rx
(** A reader end scoped to one consumer edge; deliveries are filtered by
    the footprint compiled from the edge's contract-derived ref slots and
    file-glob grant. The theory author never writes routing
    (docs/architecture/30-channels.md § footprint filtering). *)

(** {2 Producer side (engine-only by possession of ['a tx])} *)

val publish : 'a tx -> id:'a Id.t -> 'a -> unit
(** Insert a committed tuple: called by retirement, the only writer of
    committed state (docs/architecture/50-commit.md § retirement order). *)

val invalidate : 'a tx -> Invalidation.t -> unit
(** Fan an invalidation out to every subscribed edge whose footprint it
    passes. Fired only when a generation actually advances — an upstream
    that lands exactly the predicted contract fires nothing (free commit,
    falsifier F7). *)

(** {2 Consumer side} *)

val pull_tuples : 'a rx -> ('a Id.t * 'a) list
(** Drain committed tuples since this edge's cursor: the chase's body-match
    feed. *)

val pull_invalidations : 'a rx -> Invalidation.t list
(** Drain pending invalidations at a yield point — check-on-yield delivery,
    never mid-flight interrupts (docs/architecture/30-channels.md
    § delivery). The caller renders these into drift notes
    ([Speculate.Drift], [Agent.Prompt]). *)

val footprint : 'a rx -> Ledger.Footprint.t
(** The edge's compiled delivery filter, for footprint-escape reporting:
    a load outside it is logged and surfaced at retire as a witness the
    declaration must grow to cover. *)
