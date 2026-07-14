(* Stubs only: signatures are normative (see contract.mli). *)

module Schema_hash = struct
  type t = unit

  let equal _ _ = failwith "TODO: contract"
  let compare _ _ = failwith "TODO: contract"
  let to_hex _ = failwith "TODO: contract"
  let pp _ _ = failwith "TODO: contract"
end

module Path = struct
  type t = string list

  let to_string _ = failwith "TODO: contract"
  let equal _ _ = failwith "TODO: contract"
  let pp _ _ = failwith "TODO: contract"
end

module Wire_schema = struct
  type prim = Str | Int | Num | Bool

  type node =
    | Prim of { prim : prim; doc : string }
    | Str_enum of { cases : string list; doc : string }
    | Record of { fields : field list; doc : string }
    | Array of {
        items : node;
        min_items : int option;
        max_items : int option;
        doc : string;
      }
    | Nullable of node
    | Ref_id of { relation : string; doc : string }
    | Def_ref of string

  and field = { name : string; required : bool; schema : node }

  type t = { defs : (string * node) list; root : node }
  type escape = { path : Path.t; construct : string; hint : string }

  let parse _ = failwith "TODO: contract"
  let to_json _ = failwith "TODO: contract"
  let hash _ = failwith "TODO: contract"
end

module Diff = struct
  type change =
    | Added of Path.t
    | Removed of Path.t
    | Retyped of { path : Path.t; was : string; now : string }
    | Doc_changed of Path.t

  type t = change list

  let between _ _ = failwith "TODO: contract"
  let is_empty _ = failwith "TODO: contract"
  let additive_only _ = failwith "TODO: contract"
  let touched_paths _ = failwith "TODO: contract"
end

module Repair = struct
  type complaint = { path : Path.t; expected : string; got : string }

  type diagnostics = {
    raw_reply : string;
    complaints : complaint list;
    refusal : bool;
  }
end

module Codec = struct
  type 'a t = unit

  let v ~of_json:_ ~to_json:_ = failwith "TODO: contract"
  let parse _ ~registry:_ _ = failwith "TODO: contract"
  let parse_json _ ~registry:_ _ = failwith "TODO: contract"
  let print _ _ = failwith "TODO: contract"
  let render _ _ = failwith "TODO: contract"
end

type 'a t = unit

let v ~name:_ ~schema:_ ~codec:_ = failwith "TODO: contract"
let name _ = failwith "TODO: contract"
let raw_schema _ = failwith "TODO: contract"
let codec _ = failwith "TODO: contract"

module Module_contract = struct
  type sig_item = { name : string; type_expr : string; doc : string }

  type t = {
    module_name : string;
    items : sig_item list;
    invariants : string list;
  }

  let render_mli _ = failwith "TODO: contract"
end

let module_contract : Module_contract.t t = ()
