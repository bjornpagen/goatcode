(* Stubs only: signatures are normative (see run.mli). *)

type config = {
  repo : string;
  committed_branch : string;
  worktree_root : string;
  ledger_path : string;
  ports : Chase.Port.t list;
  executors : Chase.executor_binding list;
  backstops : Speculate.Backstops.t;
  switches : Speculate.Switch.t list;
  merges : Retire.Merge_registry.t;
}

type misuse =
  | Missing_path of { field : string; path : string }
  | Unbound_executor of { executor : string }
  | Unknown_port of { executor : string; port : string }

type node_report = {
  settlement : Ledger.Settlement.t;
  timing : Ledger.Telemetry.timing;
  usage : Ledger.Usage.t;
  hypotheses : Ledger.hypothesis Id.t list;
}

type settled = {
  nodes : (Ledger.node Id.t * node_report) list;
  tuples : Retire.Committed.tuple list;
  laws : Theory.Law.verdict list;
  ledger : Ledger.t;
}

let exec ~theory:_ ~seed:_ ~config:_ = failwith "TODO: run"

type handle = unit

let start ~theory:_ ~seed:_ ~config:_ = failwith "TODO: run"
let ledger _ = failwith "TODO: run"
let wait _ = failwith "TODO: run"

type divergence = {
  at : Ledger.Timestamp.t;
  recorded : string;
  replayed : string;
}

let replay _ = failwith "TODO: run"
