(* Stubs only: signatures are normative (see report.mli). *)

type speculation_account = {
  tokens_under_hypotheses : int;
  tokens_squashed : int;
  overlap_bought_s : float;
  per_shape : (Speculate.Shape.t * Speculate.Counters.t) list;
}

type summary = {
  wall_clock_s : float;
  total_work_s : float;
  realized_parallelism : float;
  critical_path : Ledger.node Id.t list;
  port_queues : (string * float) list;
  speculation : speculation_account;
  token_ceiling_bound : bool;
}

let summarize _ = failwith "TODO: report"

type scoreboard = {
  ports : (string * int * int) list;
  in_flight_hypotheses : (Ledger.hypothesis Id.t * float) list;
  ledger_appends_per_s : float;
}

let scoreboard _ = failwith "TODO: report"

type story = {
  node : Ledger.node Id.t;
  fired_because : string;
  drift_notes : (Ledger.Timestamp.t * string * string) list;
  witness : Witness.triple list;
  settlement : Ledger.Settlement.t;
  timing : Ledger.Telemetry.timing;
  usage : Ledger.Usage.t;
}

let explain _ ~node:_ = failwith "TODO: report"
