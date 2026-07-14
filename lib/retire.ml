(* Stubs only: signatures are normative (see retire.mli). *)

module Worktree = struct
  type t = unit

  let create ~root:_ ~node:_ = failwith "TODO: retire"
  let path _ = failwith "TODO: retire"
  let snoop_mount _ = failwith "TODO: retire"
  let net_delta _ = failwith "TODO: retire"
  let drop _ = failwith "TODO: retire"
end

module Committed = struct
  type t = unit

  let open_ ~repo:_ ~branch:_ = failwith "TODO: retire"
  let generation _ _ = failwith "TODO: retire"

  type tuple = {
    relation : string;
    id : string;
    payload : Yojson.Safe.t;
    generation : Ledger.Generation.t;
  }

  let tuples _ = failwith "TODO: retire"
end

type generation_moved = {
  address : Ledger.Address.t;
  witnessed : Ledger.Generation.t;
  current : Ledger.Generation.t;
  delta_ref : Ledger.Delta_ref.t;
}

module Conflict = struct
  type t = {
    node : Ledger.node Id.t;
    sibling : Ledger.node Id.t;
    overlap : Ledger.Footprint.t;
  }

  type route =
    | Serialize of { loser : Ledger.node Id.t; winner : Ledger.node Id.t }
    | Merge of { merge_fn : string }
end

module Merge_registry = struct
  type t = unit

  let empty = ()
  let register _ ~address_class:_ ~merge_fn:_ = failwith "TODO: retire"
  let lookup _ _ = failwith "TODO: retire"
end

type rejection =
  | Witness_moved of generation_moved list
  | Undischarged of Ledger.hypothesis Id.t list
  | Conflict of Conflict.t

type head_tuple = { relation : string; id : string; payload : Yojson.Safe.t }

let dependency_order _ ~candidates:_ = failwith "TODO: retire"

let step ~committed:_ ~ledger:_ ~registry:_ ~merges:_ ~node:_ ~worktree:_
    ~witness:_ ~heads:_ =
  failwith "TODO: retire"

let squash_set _ ~cause:_ = failwith "TODO: retire"
let squash ~ledger:_ ~registry:_ ~worktrees:_ ~cause:_ = failwith "TODO: retire"
let judge ~theory:_ ~committed:_ ~ledger:_ = failwith "TODO: retire"
