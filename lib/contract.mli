(** Per-relation payload catalog; derives JSON Schema and codecs for the
    payloads carried by each relation. *)

type payload = {
  relation : string;
  arity : int;
}
(** Smoke-test payload record exercising the deriving ppx stack. *)

val payload_schema : Yojson.Safe.t
(** JSON Schema for {!payload}, derived via [ppx_deriving_jsonschema]. *)

val yojson_of_payload : payload -> Yojson.Safe.t
val payload_of_yojson : Yojson.Safe.t -> payload
