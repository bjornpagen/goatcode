(* The contract layer: one supply, everything derived
   (docs/architecture/20-contracts.md). The signatures in contract.mli are
   normative; this file holds the admission parse into the LLM-safe subset,
   the mechanical drift diff, the boundary codec, and the code-interface
   meta-contract. *)

module Schema_hash = struct
  (* The raw digest bytes of a canonical serialization of the parsed
     schema. Canonical means order-insensitive where JSON is
     order-insensitive (record fields, $defs, enum case sets), so a pure
     reordering is generation-silent — a semantic no-op is free
     (docs/architecture/20-contracts.md § versioning). *)
  type t = string

  let equal = String.equal
  let compare = String.compare
  let to_hex = Digest.to_hex
  let pp fmt t = Format.pp_print_string fmt (to_hex t)
end

module Path = struct
  type t = string list

  let to_string = function
    | [] -> "/"
    | steps -> "/" ^ String.concat "/" steps

  let equal = List.equal String.equal
  let pp fmt t = Format.pp_print_string fmt (to_string t)
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

  (* Internal early exit for the admission parse; converted to [Error] at
     the [parse] boundary, never escaping this module. *)
  exception Escape of escape

  let escape path construct hint = raise (Escape { path; construct; hint })
  let prim_name = function
    | Str -> "string"
    | Int -> "integer"
    | Num -> "number"
    | Bool -> "boolean"

  (* --- the admission parse ------------------------------------------- *)

  (* Annotation keywords carry prose or metadata the validator ignores
     harmlessly; structural keywords are the safe subset itself. Any other
     key is an escape: a constraint a provider validator would silently
     drop is a validator that lies (docs/architecture/20-contracts.md
     § lowering). *)
  let annotation_keys =
    [
      "$schema"; "$id"; "$comment"; "title"; "description"; "default";
      "examples"; "deprecated"; "readOnly"; "writeOnly";
    ]

  let structural_keys =
    [
      "$ref"; "enum"; "const"; "anyOf"; "oneOf"; "type"; "properties";
      "required"; "additionalProperties"; "items"; "minItems"; "maxItems";
      "format";
    ]

  let hint_for_key = function
    | "$defs" | "definitions" ->
        "declare shared definitions once, at the schema root"
    | "prefixItems" | "additionalItems" ->
        "tuple layouts are outside the safe subset; use a closed record"
    | "allOf" | "not" | "if" | "then" | "else" | "dependentSchemas" ->
        "schema combinators are outside the safe subset; write one concrete \
         shape"
    | "patternProperties" | "propertyNames" | "unevaluatedProperties"
    | "minProperties" | "maxProperties" ->
        "records are closed; declare every field under properties"
    | "pattern" | "minLength" | "maxLength" | "minimum" | "maximum"
    | "exclusiveMinimum" | "exclusiveMaximum" | "multipleOf" | "uniqueItems"
    | "contains" ->
        "value constraints are silently ignored by structured-output \
         validators; enforce them in the payload type or a retire law"
    | _ ->
        "outside the LLM-safe subset (records, string enums, arrays, \
         nullables, $defs recursion)"

  let check_keys ~path kvs =
    List.iter
      (fun (k, _) ->
        if not (List.mem k annotation_keys || List.mem k structural_keys)
        then escape path k (hint_for_key k))
      kvs

  let doc_of kvs =
    match List.assoc_opt "description" kvs with
    | Some (`String s) -> s
    | _ -> ""

  (* A union node's own description would otherwise be dropped when the
     union collapses to [Nullable]; push it into the wrapped node when that
     node carries none — the model reads every description. *)
  let with_outer_doc doc node =
    if String.equal doc "" then node
    else
      match node with
      | Prim r when String.equal r.doc "" -> Prim { r with doc }
      | Str_enum r when String.equal r.doc "" -> Str_enum { r with doc }
      | Record r when String.equal r.doc "" -> Record { r with doc }
      | Array r when String.equal r.doc "" -> Array { r with doc }
      | Ref_id r when String.equal r.doc "" -> Ref_id { r with doc }
      | node -> node

  let parse_ref ~path v =
    match v with
    | `String r ->
        let strip prefix =
          if String.starts_with ~prefix r then
            Some
              (String.sub r (String.length prefix)
                 (String.length r - String.length prefix))
          else None
        in
        let name =
          match strip "#/$defs/" with
          | Some n when not (String.equal n "") -> Some n
          | _ -> (
              match strip "#/definitions/" with
              | Some n when not (String.equal n "") -> Some n
              | _ -> None)
        in
        (match name with
        | Some n -> Def_ref n
        | None ->
            escape path ("$ref: " ^ r)
              "recursion must reference #/$defs/<name> in this document")
    | _ -> escape path "$ref" "must be a string reference into #/$defs"

  let union_of kvs =
    match List.assoc_opt "anyOf" kvs with
    | Some v -> Some ("anyOf", v)
    | None -> (
        match List.assoc_opt "oneOf" kvs with
        | Some v -> Some ("oneOf", v)
        | None -> None)

  let rec parse_node ~path (json : Yojson.Safe.t) : node =
    match json with
    | `Assoc kvs -> parse_assoc ~path kvs
    | other ->
        escape path
          (Yojson.Safe.to_string other)
          "every schema node is a JSON object"

  and parse_assoc ~path kvs =
    check_keys ~path kvs;
    let doc = doc_of kvs in
    let find k = List.assoc_opt k kvs in
    match find "$ref" with
    | Some r -> parse_ref ~path r
    | None -> (
        match find "enum" with
        | Some e -> parse_enum ~path ~doc e
        | None -> (
            match find "const" with
            | Some (`String c) -> Str_enum { cases = [ c ]; doc }
            | Some _ ->
                escape path "const"
                  "only string constants are in the safe subset"
            | None -> (
                match union_of kvs with
                | Some (kw, branches) -> parse_union ~path ~doc kw branches
                | None -> (
                    match find "type" with
                    | Some ty -> parse_type ~path ~doc kvs ty
                    | None ->
                        escape path "(untyped node)"
                          "every schema node needs a type, enum, const, or \
                           $ref"))))

  and parse_enum ~path ~doc e =
    match e with
    | `List cases ->
        let cases =
          List.map
            (function
              | `String s -> s
              | _ ->
                  escape path "enum"
                    "enum cases must all be strings (variants as string \
                     enums)")
            cases
        in
        Str_enum { cases; doc }
    | _ -> escape path "enum" "must be a list of string cases"

  and parse_union ~path ~doc kw v =
    match v with
    | `List branches -> (
        let is_null = function
          | `Assoc kv -> List.assoc_opt "type" kv = Some (`String "null")
          | _ -> false
        in
        match branches with
        | [ a; b ] when is_null b && not (is_null a) ->
            Nullable (with_outer_doc doc (parse_node ~path a))
        | [ a; b ] when is_null a && not (is_null b) ->
            Nullable (with_outer_doc doc (parse_node ~path b))
        | _ ->
            let const_of = function
              | `Assoc kv -> (
                  match List.assoc_opt "const" kv with
                  | Some (`String s) -> Some s
                  | _ -> None)
              | _ -> None
            in
            let consts = List.map const_of branches in
            if branches <> [] && List.for_all Option.is_some consts then
              Str_enum { cases = List.filter_map Fun.id consts; doc }
            else
              escape path kw
                "only nullability (shape | null) and string-constant unions \
                 are in the safe subset")
    | _ -> escape path kw "must be a list of schemas"

  and parse_type ~path ~doc kvs ty =
    match ty with
    | `String "string" -> (
        match List.assoc_opt "format" kvs with
        | Some (`String f) when String.starts_with ~prefix:"ref:" f ->
            let relation = String.sub f 4 (String.length f - 4) in
            if String.equal relation "" then
              escape path "format: \"ref:\""
                "name the target relation, e.g. format: \"ref:finding\""
            else Ref_id { relation; doc }
        | _ -> Prim { prim = Str; doc })
    | `String "integer" -> Prim { prim = Int; doc }
    | `String "number" -> Prim { prim = Num; doc }
    | `String "boolean" -> Prim { prim = Bool; doc }
    | `String "object" -> parse_object ~path ~doc kvs
    | `String "array" -> parse_array ~path ~doc kvs
    | `String "null" ->
        escape path "type: null"
          "null stands alone only as the null half of a nullable union"
    | `String other -> escape path ("type: " ^ other) (hint_for_key other)
    | `List [ (`String s as a); `String "null" ] when s <> "null" ->
        Nullable (parse_type ~path ~doc kvs a)
    | `List [ `String "null"; (`String s as a) ] when s <> "null" ->
        Nullable (parse_type ~path ~doc kvs a)
    | _ ->
        escape path "type"
          "must be a single type name or a two-element nullable pair"

  and parse_object ~path ~doc kvs =
    (match List.assoc_opt "additionalProperties" kvs with
    | None | Some (`Bool false) -> ()
    | Some _ ->
        escape path "additionalProperties"
          "records are closed; only false (or absence) is expressible");
    let props =
      match List.assoc_opt "properties" kvs with
      | Some (`Assoc ps) -> ps
      | Some _ ->
          escape path "properties"
            "must be an object mapping field names to schemas"
      | None -> []
    in
    let required =
      match List.assoc_opt "required" kvs with
      | Some (`List rs) ->
          List.map
            (function
              | `String s -> s
              | _ -> escape path "required" "must be a list of field names")
            rs
      | Some _ -> escape path "required" "must be a list of field names"
      | None -> []
    in
    List.iter
      (fun r ->
        if not (List.mem_assoc r props) then
          escape (path @ [ r ]) "required"
            "names a field not declared under properties")
      required;
    let fields =
      List.map
        (fun (fname, fjson) ->
          {
            name = fname;
            required = List.mem fname required;
            schema = parse_node ~path:(path @ [ fname ]) fjson;
          })
        props
    in
    Record { fields; doc }

  and parse_array ~path ~doc kvs =
    let items =
      match List.assoc_opt "items" kvs with
      | Some j -> parse_node ~path:(path @ [ "items" ]) j
      | None -> escape path "array" "arrays must declare items"
    in
    let bound key =
      match List.assoc_opt key kvs with
      | Some (`Int n) -> Some n
      | Some _ -> escape path key "must be an integer"
      | None -> None
    in
    Array
      { items; min_items = bound "minItems"; max_items = bound "maxItems"; doc }

  (* A [$ref] into a [$defs] entry the document never declares is an escape
     too: everything downstream dereferences defs blindly, so admission
     proves resolution once. *)
  let check_def_refs { defs; root } =
    let known = List.map fst defs in
    let rec go path = function
      | Def_ref n ->
          if not (List.mem n known) then
            escape path ("$ref: #/$defs/" ^ n)
              "references a $defs entry the document does not declare"
      | Record { fields; _ } ->
          List.iter (fun f -> go (path @ [ f.name ]) f.schema) fields
      | Array { items; _ } -> go (path @ [ "items" ]) items
      | Nullable n -> go path n
      | Prim _ | Str_enum _ | Ref_id _ -> ()
    in
    List.iter (fun (n, node) -> go [ "$defs"; n ] node) defs;
    go [] root

  let parse json =
    match json with
    | `Assoc kvs -> (
        try
          let defs_json =
            match
              (List.assoc_opt "$defs" kvs, List.assoc_opt "definitions" kvs)
            with
            | Some d, _ | None, Some d -> Some d
            | None, None -> None
          in
          let defs =
            match defs_json with
            | None -> []
            | Some (`Assoc ds) ->
                List.map
                  (fun (n, j) -> (n, parse_node ~path:[ "$defs"; n ] j))
                  ds
            | Some _ ->
                escape [ "$defs" ] "$defs"
                  "must be an object mapping names to schemas"
          in
          let root_kvs =
            List.filter
              (fun (k, _) -> k <> "$defs" && k <> "definitions")
              kvs
          in
          let root = parse_assoc ~path:[] root_kvs in
          let t = { defs; root } in
          check_def_refs t;
          Ok t
        with Escape e -> Error e)
    | other ->
        Error
          {
            path = [];
            construct = Yojson.Safe.to_string other;
            hint = "a derived schema is a JSON object at its root";
          }

  (* --- rendering for the model API ------------------------------------ *)

  let rec node_to_json node : Yojson.Safe.t =
    let described doc rest =
      if String.equal doc "" then rest
      else rest @ [ ("description", `String doc) ]
    in
    match node with
    | Prim { prim; doc } ->
        `Assoc (described doc [ ("type", `String (prim_name prim)) ])
    | Str_enum { cases; doc } ->
        `Assoc
          (described doc
             [
               ("type", `String "string");
               ("enum", `List (List.map (fun c -> `String c) cases));
             ])
    | Record { fields; doc } ->
        let required =
          List.filter_map
            (fun f -> if f.required then Some (`String f.name) else None)
            fields
        in
        `Assoc
          (described doc
             [
               ("type", `String "object");
               ( "properties",
                 `Assoc
                   (List.map (fun f -> (f.name, node_to_json f.schema)) fields)
               );
               ("required", `List required);
               ("additionalProperties", `Bool false);
             ])
    | Array { items; min_items; max_items; doc } ->
        let bound key = function
          | Some n -> [ (key, `Int n) ]
          | None -> []
        in
        `Assoc
          (described doc
             (("type", `String "array")
             :: ("items", node_to_json items)
             :: (bound "minItems" min_items @ bound "maxItems" max_items)))
    | Nullable inner ->
        `Assoc
          [
            ( "anyOf",
              `List [ node_to_json inner; `Assoc [ ("type", `String "null") ] ]
            );
          ]
    | Ref_id { relation; doc } ->
        `Assoc
          (described doc
             [
               ("type", `String "string");
               ("format", `String ("ref:" ^ relation));
             ])
    | Def_ref n -> `Assoc [ ("$ref", `String ("#/$defs/" ^ n)) ]

  let to_json { defs; root } =
    let root_kvs =
      match node_to_json root with `Assoc kvs -> kvs | j -> [ ("value", j) ]
    in
    match defs with
    | [] -> `Assoc root_kvs
    | ds ->
        `Assoc
          (("$defs", `Assoc (List.map (fun (n, d) -> (n, node_to_json d)) ds))
          :: root_kvs)

  (* --- the generation-witness input ------------------------------------ *)

  (* Injective canonical serialization: strings length-prefixed, one tag
     character per node kind, record fields and $defs sorted by name, enum
     cases as a sorted set. Two schemas hash equal iff [Diff.between] of
     them is empty (docs/architecture/50-commit.md § law 2). *)
  let hash t =
    let buf = Buffer.create 512 in
    let str s =
      Buffer.add_string buf (string_of_int (String.length s));
      Buffer.add_char buf ':';
      Buffer.add_string buf s
    in
    let rec go = function
      | Prim { prim; doc } ->
          Buffer.add_char buf 'P';
          str (prim_name prim);
          str doc
      | Str_enum { cases; doc } ->
          Buffer.add_char buf 'E';
          List.iter str (List.sort_uniq String.compare cases);
          Buffer.add_char buf ';';
          str doc
      | Record { fields; doc } ->
          Buffer.add_char buf 'R';
          let fields =
            List.sort (fun a b -> String.compare a.name b.name) fields
          in
          List.iter
            (fun f ->
              str f.name;
              Buffer.add_char buf (if f.required then '!' else '?');
              go f.schema)
            fields;
          Buffer.add_char buf ';';
          str doc
      | Array { items; min_items; max_items; doc } ->
          Buffer.add_char buf 'A';
          go items;
          str (match min_items with Some n -> string_of_int n | None -> "");
          str (match max_items with Some n -> string_of_int n | None -> "");
          str doc
      | Nullable n ->
          Buffer.add_char buf 'N';
          go n
      | Ref_id { relation; doc } ->
          Buffer.add_char buf 'I';
          str relation;
          str doc
      | Def_ref n ->
          Buffer.add_char buf 'D';
          str n
    in
    let defs = List.sort (fun (a, _) (b, _) -> String.compare a b) t.defs in
    List.iter
      (fun (n, node) ->
        Buffer.add_char buf 'd';
        str n;
        go node)
      defs;
    Buffer.add_char buf 'r';
    go t.root;
    Digest.string (Buffer.contents buf)
end

module Diff = struct
  type change =
    | Added of Path.t
    | Removed of Path.t
    | Retyped of { path : Path.t; was : string; now : string }
    | Doc_changed of Path.t

  type t = change list

  let doc_change path d1 d2 =
    if String.equal d1 d2 then [] else [ Doc_changed path ]

  let describe n =
    let open Wire_schema in
    let rec go = function
      | Prim { prim; _ } -> prim_name prim
      | Str_enum { cases; _ } ->
          "enum(" ^ String.concat "|" (List.sort_uniq String.compare cases)
          ^ ")"
      | Record _ -> "object"
      | Array _ -> "array"
      | Nullable inner -> "nullable " ^ go inner
      | Ref_id { relation; _ } -> "ref " ^ relation
      | Def_ref name -> "$ref " ^ name
    in
    go n

  let window_string min_items max_items =
    let b = function Some n -> string_of_int n | None -> "*" in
    Printf.sprintf "items %s..%s" (b min_items) (b max_items)

  let rec diff_node path (a : Wire_schema.node) (b : Wire_schema.node) :
      change list =
    let open Wire_schema in
    match (a, b) with
    | Prim p1, Prim p2 ->
        if p1.prim <> p2.prim then
          [ Retyped { path; was = prim_name p1.prim; now = prim_name p2.prim } ]
        else doc_change path p1.doc p2.doc
    | Str_enum e1, Str_enum e2 ->
        let c1 = List.sort_uniq String.compare e1.cases
        and c2 = List.sort_uniq String.compare e2.cases in
        let widened = List.exists (fun c -> not (List.mem c c1)) c2 in
        let narrowed = List.exists (fun c -> not (List.mem c c2)) c1 in
        (if widened then [ Added path ] else [])
        @ (if narrowed then [ Removed path ] else [])
        @ doc_change path e1.doc e2.doc
    | Record r1, Record r2 ->
        doc_change path r1.doc r2.doc @ diff_fields path r1.fields r2.fields
    | Array a1, Array a2 ->
        (if a1.min_items <> a2.min_items || a1.max_items <> a2.max_items then
           [
             Retyped
               {
                 path;
                 was = window_string a1.min_items a1.max_items;
                 now = window_string a2.min_items a2.max_items;
               };
           ]
         else [])
        @ doc_change path a1.doc a2.doc
        @ diff_node (path @ [ "items" ]) a1.items a2.items
    | Nullable x, Nullable y -> diff_node path x y
    | Ref_id r1, Ref_id r2 ->
        (if String.equal r1.relation r2.relation then []
         else
           [
             Retyped
               {
                 path;
                 was = "ref " ^ r1.relation;
                 now = "ref " ^ r2.relation;
               };
           ])
        @ doc_change path r1.doc r2.doc
    | Def_ref n1, Def_ref n2 ->
        if String.equal n1 n2 then []
        else [ Retyped { path; was = "$ref " ^ n1; now = "$ref " ^ n2 } ]
    | x, y -> [ Retyped { path; was = describe x; now = describe y } ]

  and diff_fields path (fs1 : Wire_schema.field list)
      (fs2 : Wire_schema.field list) : change list =
    let open Wire_schema in
    let has fs (f : field) =
      List.exists (fun (g : field) -> String.equal g.name f.name) fs
    in
    let added =
      List.filter_map
        (fun (f : field) ->
          if has fs1 f then None else Some (Added (path @ [ f.name ])))
        fs2
    in
    let removed =
      List.filter_map
        (fun (f : field) ->
          if has fs2 f then None else Some (Removed (path @ [ f.name ])))
        fs1
    in
    let common =
      List.concat_map
        (fun (f1 : field) ->
          match
            List.find_opt
              (fun (g : field) -> String.equal g.name f1.name)
              fs2
          with
          | None -> []
          | Some f2 ->
              let fpath = path @ [ f1.name ] in
              (if f1.required <> f2.required then
                 let word r = if r then "required" else "optional" in
                 [
                   Retyped
                     {
                       path = fpath;
                       was = word f1.required;
                       now = word f2.required;
                     };
                 ]
               else [])
              @ diff_node fpath f1.schema f2.schema)
        fs1
    in
    added @ removed @ common

  let between (s1 : Wire_schema.t) (s2 : Wire_schema.t) : t =
    let names =
      List.sort_uniq String.compare
        (List.map fst s1.defs @ List.map fst s2.defs)
    in
    let def_changes =
      List.concat_map
        (fun n ->
          match (List.assoc_opt n s1.defs, List.assoc_opt n s2.defs) with
          | Some d1, Some d2 -> diff_node [ "$defs"; n ] d1 d2
          | None, Some _ -> [ Added [ "$defs"; n ] ]
          | Some _, None -> [ Removed [ "$defs"; n ] ]
          | None, None -> [])
        names
    in
    def_changes @ diff_node [] s1.root s2.root

  let is_empty = function [] -> true | _ :: _ -> false

  let additive_only t =
    List.for_all (function Added _ -> true | _ -> false) t

  let touched_paths t =
    let path_of = function
      | Added p | Removed p | Doc_changed p -> p
      | Retyped { path; _ } -> path
    in
    List.rev
      (List.fold_left
         (fun acc c ->
           let p = path_of c in
           if List.exists (Path.equal p) acc then acc else p :: acc)
         [] t)
end

module Repair = struct
  type complaint = { path : Path.t; expected : string; got : string }

  type diagnostics = {
    raw_reply : string;
    complaints : complaint list;
    refusal : bool;
  }
end

(* Raised by hand-written decoders (the [module_contract] codec below, and
   any host codec that wants precise complaints); caught exactly once, at
   the codec boundary. Hidden by the mli. *)
exception Decode_error of Repair.complaint

(* --- reply-text JSON extraction --------------------------------------- *)

let find_sub s sub from =
  let n = String.length s and m = String.length sub in
  let limit = n - m in
  let rec go i =
    if i > limit then None
    else if String.equal (String.sub s i m) sub then Some i
    else go (i + 1)
  in
  if m = 0 then None else go (max 0 from)

let contains hay needle = Option.is_some (find_sub hay needle 0)

(* Contents of ```-fenced blocks, in order: the primary lane is freeform,
   so the payload commonly arrives fenced inside prose
   (docs/architecture/60-agents.md § the primary lane). *)
let fenced_blocks s =
  let fence = "```" in
  let rec loop i acc =
    match find_sub s fence i with
    | None -> List.rev acc
    | Some open_i -> (
        match String.index_from_opt s open_i '\n' with
        | None -> List.rev acc
        | Some nl -> (
            let start = nl + 1 in
            match find_sub s fence start with
            | None -> List.rev acc
            | Some close_i ->
                let block = String.sub s start (close_i - start) in
                loop (close_i + 3) (block :: acc)))
  in
  loop 0 []

let bracketed s op cl =
  match (String.index_opt s op, String.rindex_opt s cl) with
  | Some i, Some j when j > i -> Some (String.sub s i (j - i + 1))
  | _ -> None

let try_parse s =
  match Yojson.Safe.from_string (String.trim s) with
  | j -> Some j
  | exception _ -> None

let extract_json raw =
  match try_parse raw with
  | Some j -> Some j
  | None ->
      let candidates =
        fenced_blocks raw
        @ List.filter_map Fun.id
            [ bracketed raw '{' '}'; bracketed raw '[' ']' ]
      in
      List.find_map try_parse candidates

(* Refusal markers: a non-parse carrying one of these (or carrying no JSON
   syntax at all — the model meta-commented instead of producing tuples)
   routes to the constrained-decode fallback lane rather than the repair
   loop (docs/architecture/60-agents.md § the fallback lane). *)
let refusal_markers =
  [
    "i cannot"; "i can't"; "i won't"; "i will not"; "i am unable";
    "i'm unable"; "i'm sorry"; "i am sorry"; "as an ai"; "i refuse";
    "i must decline";
  ]

module Codec = struct
  (* Ref resolution rides inside the decode, so the decode takes the run's
     registry: [by_schema] consumes it directly; a typed host codec wrapped
     by [v] resolves refs by closing over its own registry (the ppx pair
     has no registry parameter), and the threaded one passes it by. *)
  type 'a t = {
    of_json : registry:Id.Registry.t -> Yojson.Safe.t -> 'a;
    to_json : 'a -> Yojson.Safe.t;
  }

  let v ~of_json ~to_json =
    { of_json = (fun ~registry:_ json -> of_json json); to_json }

  (* The schema-driven boundary: shape, enum membership, array windows, and
     ref resolution judged by one walk of the admitted [Wire_schema.t] —
     the same value the model was handed, one supply. A ref slot resolves
     through the registry against mint provenance, so an agent-invented id
     is a complaint naming the expected relation, never a tuple
     (docs/architecture/20-contracts.md § failure surface). *)
  let by_schema (ws : Wire_schema.t) : Yojson.Safe.t t =
    let open Wire_schema in
    let complain path expected got =
      raise (Decode_error { Repair.path; expected; got })
    in
    let brief json =
      let s = Yojson.Safe.to_string json in
      if String.length s > 60 then String.sub s 0 57 ^ "..." else s
    in
    let rec check ~registry path node (json : Yojson.Safe.t) =
      match (node, json) with
      | Prim { prim = Str; _ }, `String _
      | Prim { prim = Int; _ }, `Int _
      | Prim { prim = Num; _ }, (`Int _ | `Float _)
      | Prim { prim = Bool; _ }, `Bool _ ->
          ()
      | Prim { prim; _ }, other ->
          let expected =
            match prim with
            | Str -> "a string"
            | Int -> "an integer"
            | Num -> "a number"
            | Bool -> "a boolean"
          in
          complain path expected (brief other)
      | Str_enum { cases; _ }, `String s when List.mem s cases -> ()
      | Str_enum { cases; _ }, other ->
          complain path ("one of " ^ String.concat " | " cases) (brief other)
      | Record { fields; _ }, `Assoc kvs ->
          List.iter
            (fun (k, _) ->
              if not (List.exists (fun f -> String.equal f.name k) fields)
              then
                complain (path @ [ k ]) "no fields beyond the contract's"
                  ("unexpected field \"" ^ k ^ "\""))
            kvs;
          List.iter
            (fun f ->
              match List.assoc_opt f.name kvs with
              | Some v -> check ~registry (path @ [ f.name ]) f.schema v
              | None ->
                  if f.required then
                    complain (path @ [ f.name ]) "the field to be present"
                      "no field")
            fields
      | Record _, other -> complain path "an object" (brief other)
      | Array { items; min_items; max_items; _ }, `List elements ->
          let n = List.length elements in
          (match min_items with
          | Some m when n < m ->
              complain path
                (Printf.sprintf "at least %d tuples in this window" m)
                (Printf.sprintf "%d" n)
          | Some _ | None -> ());
          (match max_items with
          | Some m when n > m ->
              complain path
                (Printf.sprintf "at most %d tuples in this window" m)
                (Printf.sprintf "%d" n)
          | Some _ | None -> ());
          List.iteri
            (fun i el ->
              check ~registry (path @ [ string_of_int i ]) items el)
            elements
      | Array _, other -> complain path "an array" (brief other)
      | Nullable _, `Null -> ()
      | Nullable inner, json -> check ~registry path inner json
      | Ref_id { relation; _ }, `String s -> (
          match Id.Registry.resolve registry ~realm:relation s with
          | Ok _ -> ()
          | Error (`Unknown_id _) ->
              complain path
                (Printf.sprintf
                   "a %s id this run minted (a ref echoes an operand's id)"
                   relation)
                s)
      | Ref_id { relation; _ }, other ->
          complain path
            (Printf.sprintf "a %s ref id string" relation)
            (brief other)
      | Def_ref d, json -> (
          match List.assoc_opt d ws.defs with
          | Some n -> check ~registry path n json
          | None ->
              (* Unreachable for admitted schemas: admission proved every
                 $ref resolves ([check_def_refs]). *)
              complain path ("$defs." ^ d) "an unresolvable $ref")
    in
    {
      of_json =
        (fun ~registry json ->
          check ~registry [] ws.root json;
          json);
      to_json = Fun.id;
    }

  (* The one place decode exceptions become data. Asynchronous-resource
     exceptions are re-raised: they are not wire data. *)
  let decode c ~registry ~raw_reply json =
    match c.of_json ~registry json with
    | value -> Ok value
    | exception Decode_error complaint ->
        Error { Repair.raw_reply; complaints = [ complaint ]; refusal = false }
    | exception ((Out_of_memory | Stack_overflow) as e) -> raise e
    | exception e ->
        Error
          {
            Repair.raw_reply;
            complaints =
              [
                {
                  Repair.path = [];
                  expected = "a payload of this contract's shape";
                  got = Printexc.to_string e;
                };
              ];
            refusal = false;
          }

  let parse c ~registry raw =
    match extract_json raw with
    | Some json -> decode c ~registry ~raw_reply:raw json
    | None ->
        let lowered = String.lowercase_ascii raw in
        let refused =
          List.exists (fun m -> contains lowered m) refusal_markers
        in
        let has_json_syntax =
          String.exists (fun ch -> ch = '{' || ch = '[') raw
        in
        if refused || not has_json_syntax then
          Error
            {
              Repair.raw_reply = raw;
              complaints =
                [
                  {
                    Repair.path = [];
                    expected = "a JSON payload matching the contract schema";
                    got = "prose with no JSON value";
                  };
                ];
              refusal = true;
            }
        else
          Error
            {
              Repair.raw_reply = raw;
              complaints =
                [
                  {
                    Repair.path = [];
                    expected = "well-formed JSON";
                    got = "malformed or truncated JSON text";
                  };
                ];
              refusal = false;
            }

  let parse_json c ~registry json =
    decode c ~registry ~raw_reply:(Yojson.Safe.to_string json) json

  let print c value = c.to_json value
  let render c value = Yojson.Safe.pretty_to_string (c.to_json value)
end

type 'a t = { name : string; raw_schema : Yojson.Safe.t; codec : 'a Codec.t }

let v ~name ~schema ~codec = { name; raw_schema = schema; codec }
let name (c : _ t) = c.name
let raw_schema (c : _ t) = c.raw_schema
let codec (c : _ t) = c.codec

module Module_contract = struct
  type sig_item = { name : string; type_expr : string; doc : string }

  type t = {
    module_name : string;
    items : sig_item list;
    invariants : string list;
  }

  let render_mli { module_name; items; invariants } =
    let buf = Buffer.create 256 in
    Buffer.add_string buf
      (Printf.sprintf "(** Interface contract for [%s]." module_name);
    if invariants <> [] then (
      Buffer.add_string buf
        "\n\n    Invariants (judged by the module's test gate):";
      List.iter
        (fun inv -> Buffer.add_string buf ("\n    - " ^ inv))
        invariants);
    Buffer.add_string buf " *)\n";
    List.iter
      (fun item ->
        Buffer.add_char buf '\n';
        Buffer.add_string buf
          (Printf.sprintf "val %s : %s\n" item.name item.type_expr);
        if not (String.equal item.doc "") then
          Buffer.add_string buf (Printf.sprintf "(** %s *)\n" item.doc))
      items;
    Buffer.contents buf

  (* --- the meta-contract's own derived artifacts ----------------------
     The library takes no ppx (lib/dune), so the schema and codec for the
     meta-type are hand-derived here, once, from the declaration above;
     the doc strings mirror the mli's doc comments — the one supply is the
     declaration, and this is its single derivation site. *)

  let wire_schema_json : Yojson.Safe.t =
    let str_prop doc : Yojson.Safe.t =
      if String.equal doc "" then `Assoc [ ("type", `String "string") ]
      else
        `Assoc [ ("type", `String "string"); ("description", `String doc) ]
    in
    `Assoc
      [
        ( "$defs",
          `Assoc
            [
              ( "sig_item",
                `Assoc
                  [
                    ("type", `String "object");
                    ( "description",
                      `String "One value in a module's public interface." );
                    ( "properties",
                      `Assoc
                        [
                          ( "name",
                            str_prop
                              "The value's name as it appears in the mli." );
                          ( "type_expr",
                            str_prop "Its type, OCaml concrete syntax." );
                          ("doc", str_prop "The doc comment the mli will carry.");
                        ] );
                    ( "required",
                      `List
                        [ `String "name"; `String "type_expr"; `String "doc" ]
                    );
                    ("additionalProperties", `Bool false);
                  ] );
            ] );
        ("type", `String "object");
        ( "description",
          `String
            "A speculative module interface: the contract an implementer \
             fills and a consumer may start against before the \
             implementation exists." );
        ( "properties",
          `Assoc
            [
              ("module_name", str_prop "The OCaml module name, capitalized.");
              ( "items",
                `Assoc
                  [
                    ("type", `String "array");
                    ("items", `Assoc [ ("$ref", `String "#/$defs/sig_item") ]);
                    ( "description",
                      `String "The module's public interface, in mli order."
                    );
                  ] );
              ( "invariants",
                `Assoc
                  [
                    ("type", `String "array");
                    ( "items",
                      str_prop
                        "One prose obligation judged by the module's test \
                         gate." );
                    ( "description",
                      `String
                        "Prose obligations judged by the module's test gate."
                    );
                  ] );
            ] );
        ( "required",
          `List
            [ `String "module_name"; `String "items"; `String "invariants" ]
        );
        ("additionalProperties", `Bool false);
      ]

  let complain path expected got =
    raise (Decode_error { Repair.path; expected; got })

  let obj ~path (j : Yojson.Safe.t) =
    match j with
    | `Assoc kvs -> kvs
    | j -> complain path "an object" (Yojson.Safe.to_string j)

  let str ~path (j : Yojson.Safe.t) =
    match j with
    | `String s -> s
    | j -> complain path "a string" (Yojson.Safe.to_string j)

  let field ~path kvs key =
    match List.assoc_opt key kvs with
    | Some v -> v
    | None -> complain (path @ [ key ]) "the field to be present" "no field"

  let str_field ~path kvs key = str ~path:(path @ [ key ]) (field ~path kvs key)

  let list_field ~path kvs key =
    match field ~path kvs key with
    | `List l -> l
    | j -> complain (path @ [ key ]) "an array" (Yojson.Safe.to_string j)

  (* The record is closed ([additionalProperties: false]); the codec
     mirrors the schema by construction, so it rejects strays too. *)
  let check_closed ~path ~allowed kvs =
    List.iter
      (fun (k, _) ->
        if not (List.mem k allowed) then
          complain (path @ [ k ]) "no fields beyond the contract's"
            ("unexpected field \"" ^ k ^ "\""))
      kvs

  let sig_item_of_json ~path j =
    let kvs = obj ~path j in
    check_closed ~path ~allowed:[ "name"; "type_expr"; "doc" ] kvs;
    {
      name = str_field ~path kvs "name";
      type_expr = str_field ~path kvs "type_expr";
      doc = str_field ~path kvs "doc";
    }

  let of_json (j : Yojson.Safe.t) : t =
    let kvs = obj ~path:[] j in
    check_closed ~path:[]
      ~allowed:[ "module_name"; "items"; "invariants" ]
      kvs;
    let items =
      List.mapi
        (fun i x -> sig_item_of_json ~path:[ "items"; string_of_int i ] x)
        (list_field ~path:[] kvs "items")
    in
    let invariants =
      List.mapi
        (fun i x -> str ~path:[ "invariants"; string_of_int i ] x)
        (list_field ~path:[] kvs "invariants")
    in
    { module_name = str_field ~path:[] kvs "module_name"; items; invariants }

  let sig_item_to_json (i : sig_item) : Yojson.Safe.t =
    `Assoc
      [
        ("name", `String i.name);
        ("type_expr", `String i.type_expr);
        ("doc", `String i.doc);
      ]

  let to_json (t : t) : Yojson.Safe.t =
    `Assoc
      [
        ("module_name", `String t.module_name);
        ("items", `List (List.map sig_item_to_json t.items));
        ("invariants", `List (List.map (fun s -> `String s) t.invariants));
      ]
end

let module_contract : Module_contract.t t =
  v ~name:"module_contract" ~schema:Module_contract.wire_schema_json
    ~codec:
      (Codec.v ~of_json:Module_contract.of_json
         ~to_json:Module_contract.to_json)
