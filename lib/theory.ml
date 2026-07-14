(* Stubs only: signatures are normative (see theory.mli). *)

module Relation = struct
  type 'a t = unit

  let v ~name:_ _ = failwith "TODO: theory"
  let dynamic ~name:_ ~schema:_ = failwith "TODO: theory"
  let name _ = failwith "TODO: theory"

  type packed = Packed : 'a t -> packed
end

module Slot = struct
  type kind = Mint | Ref of string | Value
  type t = { field : string; kind : kind }
end

module Window = struct
  type t = Tuples of { min : int; max : int } | Nodes of int

  let exactly _ = failwith "TODO: theory"
  let between ~min:_ ~max:_ = failwith "TODO: theory"
  let upto _ = failwith "TODO: theory"
  let nodes _ = failwith "TODO: theory"
end

module Pin = struct
  type t = {
    provider : string;
    model : string;
    sampling : (string * float) list;
    options : (string * string) list;
  }

  let key _ = failwith "TODO: theory"
  let equal _ _ = failwith "TODO: theory"
end

module Executor = struct
  type t =
    | Agent_template of {
        name : string;
        pin : Pin.t;
        preamble : string;
        read_globs : string list;
      }
    | Pure_fn of { name : string }
    | Shell_gate of { name : string; command : string list }

  type id = unit

  let id _ = failwith "TODO: theory"
  let id_to_string _ = failwith "TODO: theory"
  let id_equal _ _ = failwith "TODO: theory"
  let id_compare _ _ = failwith "TODO: theory"
  let pin _ = failwith "TODO: theory"
end

module Filter = struct
  type cmp = Lt | Le | Eq | Ge | Gt

  type t =
    | Count of {
        over : string;
        link : string;
        where_equals : (string * Yojson.Safe.t) list;
        cmp : cmp;
        bound : int;
      }
end

module Statement = struct
  type id = unit

  let to_string _ = failwith "TODO: theory"
  let equal _ _ = failwith "TODO: theory"
  let compare _ _ = failwith "TODO: theory"
end

module Spawn = struct
  type t = {
    name : string;
    for_ : string;
    where : Filter.t option;
    exists : string * Window.t;
    by : Executor.t;
  }

  let v ~name:_ ~for_:_ ?where:_ ~exists:_ ~by:_ () = failwith "TODO: theory"
end

module Law = struct
  type bound = At_least of int | At_most of int | Exactly of int

  type t =
    | Count of { name : string; over : string; group_by : string; bound : bound }
    | Disjoint_writes of { name : string }

  let name _ = failwith "TODO: theory"

  type verdict = { law : string; satisfied : bool; offenders : string list }
end

module Tuple = struct
  type t = Packed : 'a Relation.t * 'a -> t

  let v _ _ = failwith "TODO: theory"
  let relation_name _ = failwith "TODO: theory"
end

module Edge = struct
  type t = {
    statement : Statement.id;
    reads : string;
    ref_fields : string list;
    read_globs : string list;
  }
end

module Admission = struct
  type error =
    | Cycle of { path : (string * string) list }
    | Schema_escape of {
        relation : string;
        escape : Contract.Wire_schema.escape;
      }
    | Unknown_relation of { statement : string; relation : string }
    | Unknown_ref_target of {
        relation : string;
        field : string;
        target : string;
      }
    | Duplicate_relation of { name : string }
    | Duplicate_statement of { name : string }
    | Unjudgeable_law of { law : string; reason : string }

  let to_string _ = failwith "TODO: theory"
  let pp _ _ = failwith "TODO: theory"
end

type admitted = unit

let declare ~relations:_ ~statements:_ ~laws:_ = failwith "TODO: theory"
let relations _ = failwith "TODO: theory"
let statements _ = failwith "TODO: theory"
let laws _ = failwith "TODO: theory"
let edges _ = failwith "TODO: theory"
let wire_schema _ ~relation:_ = failwith "TODO: theory"
let schema_hash _ ~relation:_ = failwith "TODO: theory"
let slots _ ~relation:_ = failwith "TODO: theory"

module Meta = struct
  type t = unit

  let contract () = failwith "TODO: theory"
  let admit _ = failwith "TODO: theory"
end
