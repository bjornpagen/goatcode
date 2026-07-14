(* Stubs only: signatures are normative (see chase.mli). *)

module Port = struct
  type t = unit

  let open_ ~name:_ = failwith "TODO: chase"
  let bounded ~name:_ ~limit:_ ~bottleneck:_ = failwith "TODO: chase"
  let name _ = failwith "TODO: chase"
  let limit _ = failwith "TODO: chase"
end

module Priority = struct
  type cls = Resumed_witnessed | Eager_or_speculative

  let compare _ _ = failwith "TODO: chase"
end

module Read = struct
  type outcome =
    | Witnessed of {
        generation : Ledger.Generation.t;
        content : Ledger.Content_hash.t;
      }
    | Hypothesis of Speculate.Hypothesis.t
    | Suspended
end

module Settlement = Ledger.Settlement

type executor_binding = {
  executor : Theory.Executor.id;
  runtime : Agent.Executor.t;
  fallback : Agent.Executor.t option;
  repair_budget : Agent.Repair_budget.t;
  port : string;
}

type t = unit

let create ~theory:_ ~ledger:_ ~committed:_ ~channels:_ ~worktree_root:_
    ~ports:_ ~executors:_ ~backstops:_ ~switches:_ ~merges:_ ~seed:_ =
  failwith "TODO: chase"

let step _ = failwith "TODO: chase"
let run_to_quiescence _ = failwith "TODO: chase"
let quiescent _ = failwith "TODO: chase"
let settlements _ = failwith "TODO: chase"
let committed _ = failwith "TODO: chase"
let judge _ = failwith "TODO: chase"
