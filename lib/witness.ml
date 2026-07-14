(* Stubs only: signatures are normative (see witness.mli). *)

type triple = {
  address : Ledger.Address.t;
  generation : Ledger.Generation.t;
  content : Ledger.Content_hash.t;
}

type t = unit

let observed _ ~node:_ = failwith "TODO: witness"
let triples _ = failwith "TODO: witness"
let addresses _ = failwith "TODO: witness"
let consumed_paths _ ~contract_of:_ = failwith "TODO: witness"

type stale = {
  address : Ledger.Address.t;
  witnessed : Ledger.Generation.t;
  current : Ledger.Generation.t;
}

let holds _ ~committed:_ = failwith "TODO: witness"
