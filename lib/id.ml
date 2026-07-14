(* Stubs only: signatures are normative (see id.mli); a later gate makes
   these compile and a later phase implements them. *)

type 'realm t = unit

let equal _ _ = failwith "TODO: id"
let compare _ _ = failwith "TODO: id"
let pp _ _ = failwith "TODO: id"
let to_string _ = failwith "TODO: id"

module Registry = struct
  type t = unit

  let create () = failwith "TODO: id"
  let resolve _ ~realm:_ _ = failwith "TODO: id"
  let status _ _ = failwith "TODO: id"
  let bind _ _ = failwith "TODO: id"
  let drop_provisional _ _ = failwith "TODO: id"
end

module Minter = struct
  type 'realm t = unit

  let create ~registry:_ ~realm:_ = failwith "TODO: id"
end

let mint _ = failwith "TODO: id"
