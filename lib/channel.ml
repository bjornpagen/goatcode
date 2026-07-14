(* Stubs only: signatures are normative (see channel.mli). *)

module Invalidation = struct
  type t = {
    address : Ledger.Address.t;
    new_generation : Ledger.Generation.t;
    producer : Ledger.node Id.t;
    delta_ref : Ledger.Delta_ref.t;
  }

  let passes ~footprint:_ _ = failwith "TODO: channel"
end

type 'a tx = unit
type 'a rx = unit
type registry = unit

let open_all _ = failwith "TODO: channel"
let tx _ _ = failwith "TODO: channel"
let rx _ _ ~edge:_ = failwith "TODO: channel"
let publish _ ~id:_ _ = failwith "TODO: channel"
let invalidate _ _ = failwith "TODO: channel"
let pull_tuples _ = failwith "TODO: channel"
let pull_invalidations _ = failwith "TODO: channel"
let footprint _ = failwith "TODO: channel"
