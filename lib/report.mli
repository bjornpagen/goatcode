(** Reading a run: pull surfaces, all ledger queries, none on any hot path
    (docs/architecture/70-api.md § reading a run).

    [summarize] is where the success criteria are read, so its fields are
    the criteria's fields (docs/architecture/00-product.md § success
    criteria). Honest-measurement discipline applies to every number that
    leaves here: regime on every claim, fresh tasks for headlines, gross
    (never net) wasted-token accounting
    (docs/architecture/80-validation.md § honest measurement). *)

(** The speculation account: tokens are reported, never gated. *)
type speculation_account = {
  tokens_under_hypotheses : int;
      (** Spend while hypotheses were undischarged. *)
  tokens_squashed : int;
      (** Gross: salvageable work in squashed subtrees counts in full. *)
  overlap_bought_s : float;
      (** Measured overlap, not theoretical — the wall clock speculation
          actually bought. *)
  per_shape : (Speculate.Shape.t * Speculate.Counters.t) list;
      (** The per-shape breakdown the economics criterion publishes. *)
}

type summary = {
  wall_clock_s : float;  (** The objective. *)
  total_work_s : float;  (** Sum of node run times. *)
  realized_parallelism : float;  (** [total_work_s /. wall_clock_s]. *)
  critical_path : Ledger.node Id.t list;
      (** The chain that {e was} the wall clock, walked backward through
          latest-settling operands. *)
  port_queues : (string * float) list;
      (** Per-port queue-time rankings. *)
  speculation : speculation_account;
  token_ceiling_bound : bool;
      (** A run where the ceiling bound is an anomaly with a named cause,
          not a cost-control success. *)
}

val summarize : Run.settled -> summary

(** Live occupancy while running. Pull-only: polling never touches the
    dispatch path (docs/architecture/40-scheduling.md § ports and
    priority). *)
type scoreboard = {
  ports : (string * int * int) list;  (** (port, active, pending). *)
  in_flight_hypotheses : (Ledger.hypothesis Id.t * float) list;
      (** Each with its chain-confidence product. *)
  ledger_appends_per_s : float;
}

val scoreboard : Run.handle -> scoreboard

(** One node's story, assembled from the ledger. The scheduler's ruling
    that every decision lands in the ledger with reasons exists so this
    function can exist; "why did this run twice" is answered here
    (docs/architecture/40-scheduling.md § drift routing). *)
type story = {
  node : Ledger.node Id.t;
  fired_because : string;
      (** The firing provenance rendered: statement, consumed tuples,
          counters consulted, hypothesis constructed. *)
  decisions : (Ledger.Timestamp.t * string * string) list;
      (** Every scheduler ruling recorded against the node, rendered:
          (when, action, reason). A reissue or flush lands here — "why did
          this run twice" reads straight off the story. *)
  drift_notes : (Ledger.Timestamp.t * string * string) list;
      (** Each note received: (when, class, route taken). *)
  witness : Witness.triple list;  (** The witness at retire. *)
  escapes : (string * Ledger.Address.t) list;
      (** Footprint escapes surfaced at retire: (tool, address) for each
          observed load outside the edge's compiled delivery filter — the
          witnesses the declaration must grow to cover
          (docs/architecture/30-channels.md § footprint filtering). *)
  settlement : Ledger.Settlement.t;
  timing : Ledger.Telemetry.timing;
  usage : Ledger.Usage.t;
}

val explain : Run.settled -> node:Ledger.node Id.t -> story option
(** [None] for a node id the run never fired. *)
