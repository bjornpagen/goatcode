(* Stubs only: signatures are normative (see speculate.mli). *)

module Shape = struct
  type t = {
    statement : Theory.Statement.id;
    executor : Theory.Executor.id;
    pin : string;
  }

  let equal _ _ = failwith "TODO: speculate"
  let compare _ _ = failwith "TODO: speculate"
  let to_string _ = failwith "TODO: speculate"
end

module Hypothesis = struct
  type source =
    | Issued_contract of {
        relation : string;
        schema : Contract.Schema_hash.t;
      }
    | Store_buffer of {
        producer : Ledger.node Id.t;
        snapshot : Ledger.Content_hash.t;
      }

  type t = {
    id : Ledger.hypothesis Id.t;
    consumer : Ledger.node Id.t;
    address : Ledger.Address.t;
    source : source;
    content : Ledger.Content_hash.t;
    confidence : float;
  }

  type status = Pending | Discharged | Dead
end

module Drift = struct
  type cls =
    | Schema_identical
    | Additive of { diff : Contract.Diff.t }
    | Breaking_narrow of {
        diff : Contract.Diff.t;
        touched : Contract.Path.t list;
      }
    | Breaking_broad of { diff : Contract.Diff.t; refired : bool }
    | Producer_squashed

  type tag =
    | Schema_identical_t
    | Additive_t
    | Breaking_narrow_t
    | Breaking_broad_t
    | Producer_squashed_t

  let tag _ = failwith "TODO: speculate"

  module Route = struct
    type t =
      | Discharge_silently
      | Reconcile_note
      | Reconcile_delta
      | Flush_subtree
  end

  let table =
    [
      (Schema_identical_t, Route.Discharge_silently);
      (Additive_t, Route.Reconcile_note);
      (Breaking_narrow_t, Route.Reconcile_delta);
      (Breaking_broad_t, Route.Flush_subtree);
      (Producer_squashed_t, Route.Flush_subtree);
    ]

  let route _ = failwith "TODO: speculate"
  let classify ~landing:_ ~consumed:_ = failwith "TODO: speculate"

  type note = {
    address : Ledger.Address.t;
    cls : cls;
    delta : Ledger.Delta_ref.t option;
    disposition : [ `Continue | `Patch_then_continue | `Stop_cleanly ];
  }
end

module Counters = struct
  type t = {
    survival : float;
    reconcile_cost : float;
    flush_cost : float;
    overlap_s : float;
    suspended_reads_s : float;
    samples : int;
  }

  let of_ledger _ _ = failwith "TODO: speculate"
end

module Predictor = struct
  type t = unit

  let of_ledger _ = failwith "TODO: speculate"
  let survival _ _ = failwith "TODO: speculate"
  let prefer_source _ _ ~issued:_ ~snooped:_ = failwith "TODO: speculate"
  let compare_for_port _ _ _ = failwith "TODO: speculate"
end

module Churn = struct
  type measurement = unit

  let measure _ ~shape:_ = failwith "TODO: speculate"
  let shape _ = failwith "TODO: speculate"
  let lengthening_s _ = failwith "TODO: speculate"
end

module Switch = struct
  type t = unit

  let throw ~evidence:_ ~thrown_by:_ = failwith "TODO: speculate"
  let shape _ = failwith "TODO: speculate"
  let evidence _ = failwith "TODO: speculate"
  let thrown_by _ = failwith "TODO: speculate"
end

module Backstops = struct
  type t = { token_ceiling : int; confidence_floor : float }

  let default = { token_ceiling = max_int; confidence_floor = 0.05 }
end
