(* The work representation: relations plus dependency statements, admitted
   into a refined type. Admission is a parse (docs/architecture/10-theory.md
   § termination): [declare] is the only constructor of [admitted], and every
   judgment — weak acyclicity, the acceptance gate, the schema parse into
   [Contract.Wire_schema.t], ref-slot resolution — happens there, once. *)

module Relation = struct
  type 'a t = {
    name : string;
    contract : 'a Contract.t;
    witness : 'a Type.Id.t;
        (* The payload witness, minted once per declaration: the channel
           registry's name-keyed table recovers the payload type by
           [Type.Id.provably_equal] against this, so a channel end at the
           wrong payload type is unconstructible
           (docs/architecture/30-channels.md § pre-opened channels). *)
    generations : int option;
        (* The feedback stratum bound: at most this many engine-minted
           generations along one derivation chain
           (docs/architecture/10-theory.md § feedback is forward). *)
  }

  let v ~name contract =
    { name; contract; witness = Type.Id.make (); generations = None }

  let dynamic ~name ~schema =
    (* The planner lane: the payload is schema-checked JSON, so the codec is
       the identity pair — the boundary check is the schema parse plus ref
       resolution, exactly as for typed payloads
       (docs/architecture/60-agents.md § the planner). *)
    let codec = Contract.Codec.v ~of_json:(fun j -> j) ~to_json:(fun j -> j) in
    {
      name;
      contract = Contract.v ~name ~schema ~codec;
      witness = Type.Id.make ();
      generations = None;
    }

  let stratified ~generations t = { t with generations = Some generations }

  let name t = t.name
  let witness t = t.witness

  type packed = Packed : 'a t -> packed
end

module Slot = struct
  type kind = Mint | Ref of string | Value
  type t = { field : string; kind : kind }
end

module Window = struct
  type t = Tuples of { min : int; max : int } | Nodes of int

  let exactly n = Tuples { min = n; max = n }
  let between ~min ~max = Tuples { min; max }
  let upto n = Tuples { min = 0; max = n }
  let nodes n = Nodes n
end

module Pin = struct
  type t = {
    provider : string;
    model : string;
    sampling : (string * float) list;
    options : (string * string) list;
  }

  (* Stable under reordering of the sampling/options alists: the key is the
     pin's identity for predictor counters, so two structurally-equal pins
     written in different field orders must not read as a pin bump. *)
  let key t =
    let sorted l = List.sort (fun (a, _) (b, _) -> String.compare a b) l in
    let render to_s l =
      String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ to_s v) (sorted l))
    in
    Printf.sprintf "%s/%s;sampling=%s;options=%s" t.provider t.model
      (render (Printf.sprintf "%.17g") t.sampling)
      (render Fun.id t.options)

  let equal a b = String.equal (key a) (key b)
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

  type id = string

  let id = function
    | Agent_template { name; _ } -> "agent:" ^ name
    | Pure_fn { name } -> "fn:" ^ name
    | Shell_gate { name; _ } -> "shell:" ^ name

  let id_to_string i = i
  let id_equal = String.equal
  let id_compare = String.compare
  let pin = function Agent_template { pin; _ } -> Some pin | Pure_fn _ | Shell_gate _ -> None
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
  type id = string

  let to_string i = i
  let equal = String.equal
  let compare = String.compare
end

module Spawn = struct
  type t = {
    name : string;
    for_ : string;
    where : Filter.t option;
    exists : string * Window.t;
    by : Executor.t;
  }

  let v ~name ~for_ ?where ~exists ~by () = { name; for_; where; exists; by }
end

module Law = struct
  type bound = At_least of int | At_most of int | Exactly of int

  type t =
    | Count of { name : string; over : string; group_by : string; bound : bound }
    | Disjoint_writes of { name : string }

  let name = function Count { name; _ } -> name | Disjoint_writes { name } -> name

  type verdict = { law : string; satisfied : bool; offenders : string list }
end

module Tuple = struct
  type t = Packed : 'a Relation.t * 'a -> t

  let v r x = Packed (r, x)
  let relation_name (Packed (r, _)) = Relation.name r

  let payload_json (Packed (r, x)) =
    Contract.Codec.print (Contract.codec r.Relation.contract) x
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
    | Reserved_field of { relation : string; field : string }
    | Invalid_window of { statement : string; reason : string }
    | Invalid_generation_bound of { relation : string; bound : int }
    | Unjudgeable_law of { law : string; reason : string }

  let position (rel, field) = rel ^ "." ^ field

  let to_string = function
    | Cycle { path } ->
        Printf.sprintf
          "weak-acyclicity violation: this statement chain can spawn itself \
           forever; cycle through mint positions [%s]"
          (String.concat " -> " (List.map position path))
    | Schema_escape { relation; escape = { path; construct; hint } } ->
        Printf.sprintf
          "relation %s: derived schema escapes the LLM-safe subset at %s: %s \
           (%s)"
          relation
          (match path with [] -> "<root>" | steps -> String.concat "." steps)
          construct hint
    | Unknown_relation { statement; relation } ->
        Printf.sprintf "statement %s names undeclared relation %s" statement
          relation
    | Unknown_ref_target { relation; field; target } ->
        Printf.sprintf "relation %s: field %s must be a ref to relation %s, \
                        which this position does not resolve to"
          relation field target
    | Duplicate_relation { name } ->
        Printf.sprintf "relation %s is declared twice" name
    | Duplicate_statement { name } ->
        Printf.sprintf "statement %s is declared twice" name
    | Reserved_field { relation; field } ->
        Printf.sprintf
          "relation %s: payload field %s collides with the engine-filled \
           mint slot"
          relation field
    | Invalid_window { statement; reason } ->
        Printf.sprintf "statement %s: no firing plan satisfies its window: %s"
          statement reason
    | Invalid_generation_bound { relation; bound } ->
        Printf.sprintf
          "relation %s: generation bound %d admits no generation; a stratum \
           must bound at least one"
          relation bound
    | Unjudgeable_law { law; reason } ->
        Printf.sprintf
          "law %s cannot compile to a final-state query and is rejected at \
           admission: %s"
          law reason

  let pp ppf e = Format.pp_print_string ppf (to_string e)
end

(* {2 Private admission machinery} *)

(* The engine-filled mint id sits outside the payload; every relation gets
   exactly one mint slot under this name (docs/architecture/10-theory.md
   § relations, notation [{ id: mint, ... }]). *)
let mint_field = "id"

(* Names appearing more than once, each reported once, in first-repeat
   order. *)
let duplicates names =
  let seen = Hashtbl.create 16 in
  List.filter_map
    (fun n ->
      match Hashtbl.find_opt seen n with
      | None ->
          Hashtbl.add seen n false;
          None
      | Some true -> None
      | Some false ->
          Hashtbl.replace seen n true;
          Some n)
    names

(* Slot classification, parsed from the contract's derived schema: the mint
   slot is synthetic (outside the payload); ref slots are the schema's
   [Ref_id] nodes; everything else is value. The slot set is total over the
   schema: a ref nested below the top level (inside arrays or sub-records)
   carries the same edge, footprint subscription, and witness obligation as
   a top-level one, so it gets a slot of its own, named by its dotted
   payload path. Returned as (top-level slots, nested ref slots): the v0
   filter/law grammar addresses top-level fields only, everything else
   consumes the union. *)
let slots_of_schema (ws : Contract.Wire_schema.t) : Slot.t list * Slot.t list =
  let open Contract.Wire_schema in
  let rec resolve seen node =
    match node with
    | Def_ref d when not (List.mem d seen) -> (
        match List.assoc_opt d ws.defs with
        | Some n -> resolve (d :: seen) n
        | None -> node)
    | n -> n
  in
  let rec kind_of seen node =
    match resolve seen node with
    | Ref_id { relation; _ } -> Slot.Ref relation
    | Nullable n -> kind_of seen n
    | _ -> Slot.Value
  in
  (* Every [Ref_id] under [node], at its dotted payload path (array items
     step spelled "[]"). [$defs] hops are walked in place so the path stays
     a payload coordinate; [seen] cuts recursive defs, whose deeper refs
     repeat slots already collected at the first level. *)
  let rec nested_refs seen path node acc =
    match node with
    | Prim _ | Str_enum _ -> acc
    | Def_ref d -> (
        if List.mem d seen then acc
        else
          match List.assoc_opt d ws.defs with
          | Some n -> nested_refs (d :: seen) path n acc
          | None -> acc)
    | Nullable n -> nested_refs seen path n acc
    | Record { fields; _ } ->
        List.fold_left
          (fun acc (f : field) -> nested_refs seen (f.name :: path) f.schema acc)
          acc fields
    | Array { items; _ } -> nested_refs seen ("[]" :: path) items acc
    | Ref_id { relation; _ } ->
        { Slot.field = String.concat "." (List.rev path); kind = Slot.Ref relation }
        :: acc
  in
  (* A position directly classified Ref has no interior; anything else may
     hide refs below it. *)
  let slot_of name node =
    match kind_of [] node with
    | Slot.Ref _ as kind -> ({ Slot.field = name; kind }, [])
    | kind -> ({ Slot.field = name; kind }, List.rev (nested_refs [] [ name ] node []))
  in
  let classified =
    match resolve [] ws.root with
    | Record { fields; _ } ->
        List.map (fun (f : field) -> slot_of f.name f.schema) fields
    | node -> [ slot_of "value" node ]
  in
  ( { Slot.field = mint_field; kind = Slot.Mint } :: List.map fst classified,
    List.concat_map snd classified )

(* Every [Ref_id] node anywhere in the schema, with a dotted diagnostic path:
   the raw material of ref-slot resolution. *)
let refs_of_schema (ws : Contract.Wire_schema.t) : (string * string) list =
  let open Contract.Wire_schema in
  let acc = ref [] in
  let rec walk path node =
    match node with
    | Prim _ | Str_enum _ | Def_ref _ -> ()
    | Record { fields; _ } ->
        List.iter (fun (f : field) -> walk (f.name :: path) f.schema) fields
    | Array { items; _ } -> walk ("[]" :: path) items
    | Nullable n -> walk path n
    | Ref_id { relation; _ } ->
        acc := (String.concat "." (List.rev path), relation) :: !acc
  in
  walk [] ws.root;
  List.iter (fun (d, n) -> walk [ d ] n) ws.defs;
  List.rev !acc

(* Weak acyclicity: the standard dependency graph over relation positions.
   Each spawn statement contributes, for every body position, a normal edge
   to every non-mint head position (value/ref propagation) and a special
   edge to the head's mint position (the fresh existential). The theory is
   weakly acyclic iff no cycle passes through a special edge; each offending
   strongly-connected component is reported once, as a position path
   (docs/architecture/10-theory.md § termination).

   Generation strata ride the edges as data: a statement whose head
   relation carries a generation bound places every head tuple in a new
   stratum, so all of its edges are [Advance] — in the unrolled
   (position, generation) coordinates they run from stratum g to g+1 of a
   bounded ladder and can never lie on a cycle. The check consumes that by
   building the graph without them; a cycle that survives is
   stratum-preserving, a real infinite factory
   (docs/architecture/10-theory.md § feedback is forward). *)
type dep_kind = Dep_value | Dep_mint | Dep_advance

let mint_cycles
    (edges : ((string * string) * (string * string) * dep_kind) list) :
    (string * string) list list =
  let edges =
    List.filter_map
      (function
        | _, _, Dep_advance -> None
        | u, v, Dep_mint -> Some (u, v, true)
        | u, v, Dep_value -> Some (u, v, false))
      edges
  in
  let pos_equal (a, b) (c, d) = String.equal a c && String.equal b d in
  let positions =
    List.fold_left
      (fun acc (u, v, _) ->
        let add p acc = if List.exists (pos_equal p) acc then acc else p :: acc in
        add u (add v acc))
      [] edges
  in
  let positions = Array.of_list positions in
  let n = Array.length positions in
  let index p =
    let rec go i =
      if i >= n then -1 else if pos_equal positions.(i) p then i else go (i + 1)
    in
    go 0
  in
  let succs = Array.make n [] in
  List.iter
    (fun (u, v, _) ->
      let ui = index u and vi = index v in
      if not (List.mem vi succs.(ui)) then succs.(ui) <- vi :: succs.(ui))
    edges;
  (* Tarjan's strongly connected components. *)
  let comp = Array.make n (-1) in
  let order = Array.make n (-1) in
  let low = Array.make n 0 in
  let on_stack = Array.make n false in
  let stack = ref [] in
  let counter = ref 0 in
  let ncomp = ref 0 in
  let rec strong v =
    order.(v) <- !counter;
    low.(v) <- !counter;
    incr counter;
    stack := v :: !stack;
    on_stack.(v) <- true;
    List.iter
      (fun w ->
        if order.(w) < 0 then (
          strong w;
          low.(v) <- min low.(v) low.(w))
        else if on_stack.(w) then low.(v) <- min low.(v) order.(w))
      succs.(v);
    if low.(v) = order.(v) then begin
      let rec pop () =
        match !stack with
        | w :: rest ->
            stack := rest;
            on_stack.(w) <- false;
            comp.(w) <- !ncomp;
            if w <> v then pop ()
        | [] -> ()
      in
      pop ();
      incr ncomp
    end
  in
  for v = 0 to n - 1 do
    if order.(v) < 0 then strong v
  done;
  let rec all_but_last = function [] | [ _ ] -> [] | x :: rest -> x :: all_but_last rest in
  let reported = Hashtbl.create 4 in
  List.filter_map
    (fun (u, v, special) ->
      if not special then None
      else
        let ui = index u and vi = index v in
        if comp.(ui) <> comp.(vi) || Hashtbl.mem reported comp.(ui) then None
        else begin
          Hashtbl.add reported comp.(ui) ();
          (* Shortest path v -> u within the component; the cycle is then
             u --special--> v -> ... -> u. *)
          let prev = Array.make n (-1) in
          let visited = Array.make n false in
          visited.(vi) <- true;
          let q = Queue.create () in
          Queue.add vi q;
          let found = ref (ui = vi) in
          while (not !found) && not (Queue.is_empty q) do
            let x = Queue.pop q in
            List.iter
              (fun w ->
                if (not visited.(w)) && comp.(w) = comp.(ui) then begin
                  visited.(w) <- true;
                  prev.(w) <- x;
                  if w = ui then found := true else Queue.add w q
                end)
              succs.(x)
          done;
          if (not !found) && ui <> vi then None
          else
            let rec build acc x =
              if x = vi then x :: acc else build (x :: acc) prev.(x)
            in
            let path = if ui = vi then [ vi ] else build [] ui in
            let cycle = ui :: all_but_last path in
            Some (List.map (fun i -> positions.(i)) cycle)
        end)
    edges

type admitted = {
  a_relations : Relation.packed list;
  a_statements : (Statement.id * Spawn.t) list;
  a_laws : Law.t list;
  a_edges : Edge.t list;
  a_schemas : (string * Contract.Wire_schema.t) list;
  a_hashes : (string * Contract.Schema_hash.t) list;
  a_slots : (string * Slot.t list) list;
}

let declare ~relations ~statements ~laws =
  let errs = ref [] in
  let err e = errs := e :: !errs in
  let rel_names = List.map (fun (Relation.Packed r) -> r.Relation.name) relations in
  List.iter
    (fun name -> err (Admission.Duplicate_relation { name }))
    (duplicates rel_names);
  List.iter
    (fun name -> err (Admission.Duplicate_statement { name }))
    (duplicates (List.map (fun (s : Spawn.t) -> s.Spawn.name) statements));
  let declared name = List.exists (String.equal name) rel_names in
  (* The schema parse into the LLM-safe subset, once per relation: the
     refined [Wire_schema.t] is kept as the proof
     (docs/architecture/20-contracts.md § lowering). *)
  let parsed =
    List.filter_map
      (fun (Relation.Packed r) ->
        let name = r.Relation.name in
        match Contract.Wire_schema.parse (Contract.raw_schema r.Relation.contract) with
        | Ok ws -> Some (name, ws)
        | Error escape ->
            err (Admission.Schema_escape { relation = name; escape });
            None)
      relations
  in
  let classified =
    List.map (fun (name, ws) -> (name, slots_of_schema ws)) parsed
  in
  (* The exported slot set is total (top-level fields plus nested refs);
     the filter/law checks below consult top-level slots only — the v0
     grammar's link and group_by are payload fields, never paths. *)
  let slot_table =
    List.map (fun (name, (top, nested)) -> (name, top @ nested)) classified
  in
  let top_kind rel field =
    match List.assoc_opt rel classified with
    | None -> None
    | Some (top, _) ->
        List.find_map
          (fun (s : Slot.t) ->
            if String.equal s.Slot.field field then Some s.Slot.kind else None)
          top
  in
  (* The engine owns the mint slot's name: a payload field spelled [id]
     would shadow the engine-filled identity at every consumer. *)
  List.iter
    (fun (name, (top, _)) ->
      if
        List.exists
          (fun (s : Slot.t) ->
            String.equal s.Slot.field mint_field && s.Slot.kind <> Slot.Mint)
          top
      then err (Admission.Reserved_field { relation = name; field = mint_field }))
    classified;
  (* Generation strata must bound: a bound below one admits no generation
     at all, so the loop it is meant to close is an infinite factory. *)
  List.iter
    (fun (Relation.Packed r) ->
      match r.Relation.generations with
      | Some bound when bound < 1 ->
          err
            (Admission.Invalid_generation_bound
               { relation = r.Relation.name; bound })
      | Some _ | None -> ())
    relations;
  (* Ref-slot resolution: every [Ref_id] anywhere in a payload schema must
     target a declared relation. *)
  List.iter
    (fun (name, ws) ->
      List.iter
        (fun (field, target) ->
          if not (declared target) then
            err (Admission.Unknown_ref_target { relation = name; field; target }))
        (refs_of_schema ws))
    parsed;
  (* Statement checks: body, head, and filter relations must be declared;
     the window must admit a firing plan; the filter's link must be a ref
     slot of the counted relation pointing at the body relation, or the
     readiness query cannot compile. *)
  let window_reason = function
    | Window.Nodes n when n < 1 ->
        Some (Printf.sprintf "%d nodes: a firing count below one" n)
    | Window.Tuples { min; _ } when min < 0 ->
        Some (Printf.sprintf "a negative tuple bound (min %d)" min)
    | Window.Tuples { min; max } when max < min ->
        Some (Printf.sprintf "an empty tuple range (%d..%d)" min max)
    | Window.Nodes _ | Window.Tuples _ -> None
  in
  List.iter
    (fun (s : Spawn.t) ->
      let unknown relation =
        err (Admission.Unknown_relation { statement = s.Spawn.name; relation })
      in
      if not (declared s.Spawn.for_) then unknown s.Spawn.for_;
      let head = fst s.Spawn.exists in
      if not (declared head) then unknown head;
      Option.iter
        (fun reason ->
          err (Admission.Invalid_window { statement = s.Spawn.name; reason }))
        (window_reason (snd s.Spawn.exists));
      Option.iter
        (fun (Filter.Count { over; link; _ }) ->
          if not (declared over) then unknown over
          else
            match top_kind over link with
            | None when not (List.mem_assoc over slot_table) ->
                () (* schema escape already reported for [over] *)
            | Some (Slot.Ref target) when String.equal target s.Spawn.for_ -> ()
            | Some _ | None ->
                err
                  (Admission.Unknown_ref_target
                     { relation = over; field = link; target = s.Spawn.for_ }))
        s.Spawn.where)
    statements;
  (* The acceptance gate: every law compiles to its final-state judge or is
     rejected (docs/architecture/10-theory.md § the acceptance gate). *)
  List.iter
    (fun (l : Law.t) ->
      match l with
      | Law.Disjoint_writes _ ->
          (* Judge: the footprint index at retire — always compilable
             (docs/architecture/50-commit.md § retirement order). *)
          ()
      | Law.Count { name; over; group_by; _ } ->
          let unjudgeable reason =
            err (Admission.Unjudgeable_law { law = name; reason })
          in
          if not (declared over) then
            unjudgeable
              (Printf.sprintf "counted relation %s is not declared" over)
          else if List.mem_assoc over slot_table then (
            match top_kind over group_by with
            | Some (Slot.Ref _) -> ()
            | Some Slot.Mint | Some Slot.Value ->
                unjudgeable
                  (Printf.sprintf
                     "group_by field %s of %s is not a ref slot, so counts \
                      cannot group per referent"
                     group_by over)
            | None ->
                unjudgeable
                  (Printf.sprintf "relation %s has no field %s" over group_by)))
    laws;
  (* Weak acyclicity over relation positions. A statement heading into a
     generation-bounded relation contributes only stratum-crossing edges:
     every firing mints a fresh, counted generation of the head, so no edge
     of that statement can preserve a stratum. *)
  let generational name =
    List.exists
      (fun (Relation.Packed r) ->
        String.equal r.Relation.name name
        && Option.is_some r.Relation.generations)
      relations
  in
  let dep_edges =
    List.concat_map
      (fun (s : Spawn.t) ->
        let body = s.Spawn.for_ and head = fst s.Spawn.exists in
        match (List.assoc_opt body slot_table, List.assoc_opt head slot_table) with
        | Some body_slots, Some head_slots ->
            let advances = generational head in
            List.concat_map
              (fun (bp : Slot.t) ->
                List.map
                  (fun (hp : Slot.t) ->
                    let kind =
                      if advances then Dep_advance
                      else if hp.Slot.kind = Slot.Mint then Dep_mint
                      else Dep_value
                    in
                    ((body, bp.Slot.field), (head, hp.Slot.field), kind))
                  head_slots)
              body_slots
        | _ -> [])
      statements
  in
  List.iter (fun path -> err (Admission.Cycle { path })) (mint_cycles dep_edges);
  match List.rev !errs with
  | [] ->
      let stmts =
        List.map (fun (s : Spawn.t) -> ((s.Spawn.name : Statement.id), s)) statements
      in
      let edges =
        List.map
          (fun (s : Spawn.t) ->
            let ref_fields =
              match List.assoc_opt s.Spawn.for_ slot_table with
              | None -> []
              | Some slots ->
                  List.filter_map
                    (fun (sl : Slot.t) ->
                      match sl.Slot.kind with
                      | Slot.Ref _ -> Some sl.Slot.field
                      | Slot.Mint | Slot.Value -> None)
                    slots
            in
            {
              Edge.statement = s.Spawn.name;
              reads = s.Spawn.for_;
              ref_fields;
              read_globs =
                (match s.Spawn.by with
                | Executor.Agent_template { read_globs; _ } -> read_globs
                | Executor.Pure_fn _ | Executor.Shell_gate _ -> []);
            })
          statements
      in
      let hashes =
        List.map (fun (name, ws) -> (name, Contract.Wire_schema.hash ws)) parsed
      in
      Ok
        {
          a_relations = relations;
          a_statements = stmts;
          a_laws = laws;
          a_edges = edges;
          a_schemas = parsed;
          a_hashes = hashes;
          a_slots = slot_table;
        }
  | errors -> Error errors

let relations a = a.a_relations
let statements a = a.a_statements
let laws a = a.a_laws
let edges a = a.a_edges
let wire_schema a ~relation = List.assoc_opt relation a.a_schemas
let schema_hash a ~relation = List.assoc_opt relation a.a_hashes
let slots a ~relation = List.assoc_opt relation a.a_slots

let generations a ~relation =
  List.find_map
    (fun (Relation.Packed r) ->
      if String.equal r.Relation.name relation then r.Relation.generations
      else None)
    a.a_relations

module Meta = struct
  module U = Yojson.Safe.Util

  type t = {
    m_relations : (string * Yojson.Safe.t * int option) list;
        (* (name, payload schema, generation bound). *)
    m_statements : Spawn.t list;
    m_laws : Law.t list;
  }

  (* {3 Decode (wire -> value)}

     Failures raise [Yojson.Safe.Util.Type_error]; the codec boundary owns
     the catch and converts to repair diagnostics
     (docs/architecture/20-contracts.md § failure surface). *)

  let typ_err msg j = raise (U.Type_error (msg, j))

  (* Nested payload schemas ride as JSON text: an arbitrary JSON Schema
     document is not expressible inside the LLM-safe subset (open records
     have no constructor), so the meta contract carries it as a string and
     admission parses it like any other raw schema. *)
  let embedded_json ~field j =
    let text = U.to_string (U.member field j) in
    try Yojson.Safe.from_string text
    with Yojson.Json_error msg ->
      typ_err (field ^ ": invalid JSON text: " ^ msg) j

  let pin_of_json j =
    {
      Pin.provider = U.to_string (U.member "provider" j);
      model = U.to_string (U.member "model" j);
      sampling =
        U.to_list (U.member "sampling" j)
        |> List.map (fun p ->
               ( U.to_string (U.member "param" p),
                 U.to_number (U.member "value" p) ));
      options =
        U.to_list (U.member "options" j)
        |> List.map (fun p ->
               ( U.to_string (U.member "option" p),
                 U.to_string (U.member "value" p) ));
    }

  let executor_of_json j =
    let name = U.to_string (U.member "name" j) in
    match U.to_string (U.member "kind" j) with
    | "agent_template" ->
        Executor.Agent_template
          {
            name;
            pin = pin_of_json (U.member "pin" j);
            preamble = U.to_string (U.member "preamble" j);
            read_globs = U.to_list (U.member "read_globs" j) |> List.map U.to_string;
          }
    | "pure_fn" -> Executor.Pure_fn { name }
    | "shell_gate" ->
        Executor.Shell_gate
          { name; command = U.to_list (U.member "command" j) |> List.map U.to_string }
    | k -> typ_err ("unknown executor kind: " ^ k) j

  let window_of_json j =
    match U.to_string (U.member "kind" j) with
    | "tuples" ->
        Window.Tuples
          { min = U.to_int (U.member "min" j); max = U.to_int (U.member "max" j) }
    | "nodes" -> Window.Nodes (U.to_int (U.member "count" j))
    | k -> typ_err ("unknown window kind: " ^ k) j

  let cmp_of_json j =
    match U.to_string j with
    | "lt" -> Filter.Lt
    | "le" -> Filter.Le
    | "eq" -> Filter.Eq
    | "ge" -> Filter.Ge
    | "gt" -> Filter.Gt
    | c -> typ_err ("unknown cmp: " ^ c) j

  let filter_of_json j =
    Filter.Count
      {
        over = U.to_string (U.member "over" j);
        link = U.to_string (U.member "link" j);
        where_equals =
          U.to_list (U.member "where_equals" j)
          |> List.map (fun p ->
                 ( U.to_string (U.member "field" p),
                   embedded_json ~field:"value_json" p ));
        cmp = cmp_of_json (U.member "cmp" j);
        bound = U.to_int (U.member "bound" j);
      }

  let statement_of_json j =
    let exists_j = U.member "exists" j in
    {
      Spawn.name = U.to_string (U.member "name" j);
      for_ = U.to_string (U.member "for" j);
      where =
        (match U.member "where" j with
        | `Null -> None
        | w -> Some (filter_of_json w));
      exists =
        ( U.to_string (U.member "relation" exists_j),
          window_of_json (U.member "window" exists_j) );
      by = executor_of_json (U.member "by" j);
    }

  let bound_of_json j =
    let n = U.to_int (U.member "n" j) in
    match U.to_string (U.member "kind" j) with
    | "at_least" -> Law.At_least n
    | "at_most" -> Law.At_most n
    | "exactly" -> Law.Exactly n
    | k -> typ_err ("unknown bound kind: " ^ k) j

  let law_of_json j =
    let name = U.to_string (U.member "name" j) in
    match U.to_string (U.member "kind" j) with
    | "count" ->
        Law.Count
          {
            name;
            over = U.to_string (U.member "over" j);
            group_by = U.to_string (U.member "group_by" j);
            bound = bound_of_json (U.member "bound" j);
          }
    | "disjoint_writes" -> Law.Disjoint_writes { name }
    | k -> typ_err ("unknown law kind: " ^ k) j

  let of_json j =
    {
      m_relations =
        U.to_list (U.member "relations" j)
        |> List.map (fun r ->
               ( U.to_string (U.member "name" r),
                 embedded_json ~field:"schema_json" r,
                 match U.member "generations" r with
                 | `Null -> None
                 | g -> Some (U.to_int g) ));
      m_statements = U.to_list (U.member "statements" j) |> List.map statement_of_json;
      m_laws = U.to_list (U.member "laws" j) |> List.map law_of_json;
    }

  (* {3 Encode (value -> wire)} *)

  let json_of_pin (p : Pin.t) : Yojson.Safe.t =
    `Assoc
      [
        ("provider", `String p.Pin.provider);
        ("model", `String p.Pin.model);
        ( "sampling",
          `List
            (List.map
               (fun (k, v) -> `Assoc [ ("param", `String k); ("value", `Float v) ])
               p.Pin.sampling) );
        ( "options",
          `List
            (List.map
               (fun (k, v) -> `Assoc [ ("option", `String k); ("value", `String v) ])
               p.Pin.options) );
      ]

  let json_of_executor (e : Executor.t) : Yojson.Safe.t =
    match e with
    | Executor.Agent_template { name; pin; preamble; read_globs } ->
        `Assoc
          [
            ("kind", `String "agent_template");
            ("name", `String name);
            ("pin", json_of_pin pin);
            ("preamble", `String preamble);
            ("read_globs", `List (List.map (fun g -> `String g) read_globs));
            ("command", `Null);
          ]
    | Executor.Pure_fn { name } ->
        `Assoc
          [
            ("kind", `String "pure_fn");
            ("name", `String name);
            ("pin", `Null);
            ("preamble", `Null);
            ("read_globs", `Null);
            ("command", `Null);
          ]
    | Executor.Shell_gate { name; command } ->
        `Assoc
          [
            ("kind", `String "shell_gate");
            ("name", `String name);
            ("pin", `Null);
            ("preamble", `Null);
            ("read_globs", `Null);
            ("command", `List (List.map (fun c -> `String c) command));
          ]

  let json_of_window (w : Window.t) : Yojson.Safe.t =
    match w with
    | Window.Tuples { min; max } ->
        `Assoc
          [
            ("kind", `String "tuples");
            ("min", `Int min);
            ("max", `Int max);
            ("count", `Null);
          ]
    | Window.Nodes n ->
        `Assoc
          [
            ("kind", `String "nodes");
            ("min", `Null);
            ("max", `Null);
            ("count", `Int n);
          ]

  let string_of_cmp = function
    | Filter.Lt -> "lt"
    | Filter.Le -> "le"
    | Filter.Eq -> "eq"
    | Filter.Ge -> "ge"
    | Filter.Gt -> "gt"

  let json_of_filter (Filter.Count { over; link; where_equals; cmp; bound }) :
      Yojson.Safe.t =
    `Assoc
      [
        ("over", `String over);
        ("link", `String link);
        ( "where_equals",
          `List
            (List.map
               (fun (f, v) ->
                 `Assoc
                   [
                     ("field", `String f);
                     ("value_json", `String (Yojson.Safe.to_string v));
                   ])
               where_equals) );
        ("cmp", `String (string_of_cmp cmp));
        ("bound", `Int bound);
      ]

  let json_of_statement (s : Spawn.t) : Yojson.Safe.t =
    `Assoc
      [
        ("name", `String s.Spawn.name);
        ("for", `String s.Spawn.for_);
        ( "where",
          match s.Spawn.where with None -> `Null | Some f -> json_of_filter f );
        ( "exists",
          `Assoc
            [
              ("relation", `String (fst s.Spawn.exists));
              ("window", json_of_window (snd s.Spawn.exists));
            ] );
        ("by", json_of_executor s.Spawn.by);
      ]

  let json_of_bound (b : Law.bound) : Yojson.Safe.t =
    match b with
    | Law.At_least n -> `Assoc [ ("kind", `String "at_least"); ("n", `Int n) ]
    | Law.At_most n -> `Assoc [ ("kind", `String "at_most"); ("n", `Int n) ]
    | Law.Exactly n -> `Assoc [ ("kind", `String "exactly"); ("n", `Int n) ]

  let json_of_law (l : Law.t) : Yojson.Safe.t =
    match l with
    | Law.Count { name; over; group_by; bound } ->
        `Assoc
          [
            ("kind", `String "count");
            ("name", `String name);
            ("over", `String over);
            ("group_by", `String group_by);
            ("bound", json_of_bound bound);
          ]
    | Law.Disjoint_writes { name } ->
        `Assoc
          [
            ("kind", `String "disjoint_writes");
            ("name", `String name);
            ("over", `Null);
            ("group_by", `Null);
            ("bound", `Null);
          ]

  let to_json (t : t) : Yojson.Safe.t =
    `Assoc
      [
        ( "relations",
          `List
            (List.map
               (fun (name, schema, generations) ->
                 `Assoc
                   [
                     ("name", `String name);
                     ("schema_json", `String (Yojson.Safe.to_string schema));
                     ( "generations",
                       match generations with
                       | None -> `Null
                       | Some n -> `Int n );
                   ])
               t.m_relations) );
        ("statements", `List (List.map json_of_statement t.m_statements));
        ("laws", `List (List.map json_of_law t.m_laws));
      ]

  (* The planner template's head contract: a theory as wire data. Doc
     comments become the schema descriptions the model reads; nullable
     per-case fields carry the executor/law/window sums, kind-discriminated,
     inside the LLM-safe subset (string enums, closed records, $defs). *)
  let schema_text =
    {json|{
  "type": "object",
  "description": "A theory as wire data: relations, spawn statements, and retire laws. Admitted through the same judgment as hand-written theories; admission errors return for repair.",
  "additionalProperties": false,
  "required": ["relations", "statements", "laws"],
  "properties": {
    "relations": {
      "type": "array",
      "description": "The relations this theory declares; each becomes a channel at admission.",
      "items": { "$ref": "#/$defs/relation" }
    },
    "statements": {
      "type": "array",
      "description": "Spawn statements (TGDs): for every body match, head tuples exist, produced by an executor.",
      "items": { "$ref": "#/$defs/statement" }
    },
    "laws": {
      "type": "array",
      "description": "Retire laws (EGD-class), judged once at quiescence against the merged final state.",
      "items": { "$ref": "#/$defs/law" }
    }
  },
  "$defs": {
    "relation": {
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "schema_json", "generations"],
      "properties": {
        "name": { "type": "string", "description": "The relation's name; unique within the theory." },
        "schema_json": { "type": "string", "description": "The payload's JSON Schema, as JSON text. Parsed into the LLM-safe subset at admission; escapes are admission errors." },
        "generations": { "anyOf": [ { "type": "integer" }, { "type": "null" } ], "description": "Generation bound for a feedback loop's stratum carrier: at most this many engine-minted generations of the relation along one derivation chain. Null for relations outside any loop." }
      }
    },
    "pin": {
      "type": "object",
      "description": "A model pin: provider, model id, sampling config, prompt-affecting options. Pins move deliberately, never implicitly.",
      "additionalProperties": false,
      "required": ["provider", "model", "sampling", "options"],
      "properties": {
        "provider": { "type": "string", "description": "Model provider name." },
        "model": { "type": "string", "description": "Pinned model id." },
        "sampling": {
          "type": "array",
          "description": "Sampling configuration, as named numeric parameters.",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["param", "value"],
            "properties": {
              "param": { "type": "string", "description": "Parameter name, e.g. temperature." },
              "value": { "type": "number", "description": "Parameter value." }
            }
          }
        },
        "options": {
          "type": "array",
          "description": "Prompt-affecting options, as named string values.",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["option", "value"],
            "properties": {
              "option": { "type": "string", "description": "Option name." },
              "value": { "type": "string", "description": "Option value." }
            }
          }
        }
      }
    },
    "executor": {
      "type": "object",
      "description": "What a spawn statement's by clause names. kind picks the case; fields that do not belong to the case are null.",
      "additionalProperties": false,
      "required": ["kind", "name", "pin", "preamble", "read_globs", "command"],
      "properties": {
        "kind": { "type": "string", "enum": ["agent_template", "pure_fn", "shell_gate"], "description": "Executor case." },
        "name": { "type": "string", "description": "Executor name; pure functions are bound by this name in the run config." },
        "pin": { "anyOf": [ { "$ref": "#/$defs/pin" }, { "type": "null" } ], "description": "Model pin; agent_template only, null otherwise." },
        "preamble": { "anyOf": [ { "type": "string" }, { "type": "null" } ], "description": "Role text stating stance and method, never shape; agent_template only, null otherwise." },
        "read_globs": { "anyOf": [ { "type": "array", "items": { "type": "string" } }, { "type": "null" } ], "description": "File-glob half of the footprint grant; agent_template only, null otherwise." },
        "command": { "anyOf": [ { "type": "array", "items": { "type": "string" } }, { "type": "null" } ], "description": "Build/test command line; shell_gate only, null otherwise." }
      }
    },
    "window": {
      "type": "object",
      "description": "Cardinality window. kind tuples: one node produces between min and max head tuples as an array. kind nodes: count independent firings, one tuple each.",
      "additionalProperties": false,
      "required": ["kind", "min", "max", "count"],
      "properties": {
        "kind": { "type": "string", "enum": ["tuples", "nodes"], "description": "Window case." },
        "min": { "anyOf": [ { "type": "integer" }, { "type": "null" } ], "description": "Minimum head tuples; tuples only, null otherwise." },
        "max": { "anyOf": [ { "type": "integer" }, { "type": "null" } ], "description": "Maximum head tuples; tuples only, null otherwise." },
        "count": { "anyOf": [ { "type": "integer" }, { "type": "null" } ], "description": "Number of independent firings; nodes only, null otherwise." }
      }
    },
    "filter": {
      "type": "object",
      "description": "Body filter, the v0 where grammar: count(x in over where x.link = body.id and where_equals) cmp bound.",
      "additionalProperties": false,
      "required": ["over", "link", "where_equals", "cmp", "bound"],
      "properties": {
        "over": { "type": "string", "description": "The counted relation." },
        "link": { "type": "string", "description": "The ref field of the counted relation pointing at the body tuple." },
        "where_equals": {
          "type": "array",
          "description": "Extra value-field equalities on counted tuples.",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["field", "value_json"],
            "properties": {
              "field": { "type": "string", "description": "Value field of the counted relation." },
              "value_json": { "type": "string", "description": "The compared value, as JSON text (e.g. true, 3, \"blocking\")." }
            }
          }
        },
        "cmp": { "type": "string", "enum": ["lt", "le", "eq", "ge", "gt"], "description": "Comparison of the count against the bound." },
        "bound": { "type": "integer", "description": "The count bound." }
      }
    },
    "statement": {
      "type": "object",
      "description": "One spawn statement: for every body match, head tuples exist within the window, produced by the executor.",
      "additionalProperties": false,
      "required": ["name", "for", "where", "exists", "by"],
      "properties": {
        "name": { "type": "string", "description": "Statement name; unique within the theory." },
        "for": { "type": "string", "description": "The body relation (single-relation bodies in v0)." },
        "where": { "anyOf": [ { "$ref": "#/$defs/filter" }, { "type": "null" } ], "description": "Optional body filter; null when absent." },
        "exists": {
          "type": "object",
          "description": "Head relation and its cardinality window.",
          "additionalProperties": false,
          "required": ["relation", "window"],
          "properties": {
            "relation": { "type": "string", "description": "The head relation." },
            "window": { "$ref": "#/$defs/window" }
          }
        },
        "by": { "$ref": "#/$defs/executor" }
      }
    },
    "law": {
      "type": "object",
      "description": "A retire law. kind picks the case; fields that do not belong to the case are null. Laws must compile to final-state queries; anything else is rejected at admission.",
      "additionalProperties": false,
      "required": ["kind", "name", "over", "group_by", "bound"],
      "properties": {
        "kind": { "type": "string", "enum": ["count", "disjoint_writes"], "description": "Law case." },
        "name": { "type": "string", "description": "Law name, quoted in verdicts." },
        "over": { "anyOf": [ { "type": "string" }, { "type": "null" } ], "description": "The counted relation; count only, null otherwise." },
        "group_by": { "anyOf": [ { "type": "string" }, { "type": "null" } ], "description": "The ref field of the counted relation grouping counts per referent; count only, null otherwise." },
        "bound": { "anyOf": [ { "$ref": "#/$defs/bound" }, { "type": "null" } ], "description": "The per-referent count bound; count only, null otherwise." }
      }
    },
    "bound": {
      "type": "object",
      "description": "A count bound.",
      "additionalProperties": false,
      "required": ["kind", "n"],
      "properties": {
        "kind": { "type": "string", "enum": ["at_least", "at_most", "exactly"], "description": "Bound case." },
        "n": { "type": "integer", "description": "The bound." }
      }
    }
  }
}|json}

  let contract () =
    Contract.v ~name:"meta_theory"
      ~schema:(Yojson.Safe.from_string schema_text)
      ~codec:(Contract.Codec.v ~of_json ~to_json)

  let admit t =
    declare
      ~relations:
        (List.map
           (fun (name, schema, generations) ->
             let r = Relation.dynamic ~name ~schema in
             let r =
               match generations with
               | None -> r
               | Some g -> Relation.stratified ~generations:g r
             in
             Relation.Packed r)
           t.m_relations)
      ~statements:t.m_statements ~laws:t.m_laws
end
