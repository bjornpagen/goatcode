(* TODO: full per-relation payload catalog. The record below is a smoke test
   for the [jsonschema] and [yojson] derivers under the OxCaml switch. *)

type payload = {
  relation : string;
  arity : int;
}
[@@deriving jsonschema, yojson]

let payload_schema = (payload_jsonschema :> Yojson.Safe.t)
