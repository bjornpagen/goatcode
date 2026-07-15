(* Falsifiers for the head boundary rewiring (campaign roster B1, B4, B13,
   B14):

   - B4 — seed payloads are real: a seed tuple's payload reaches the
     executor's operand section, enters committed state at run open, and
     makes law judgment over a seeded relation non-vacuous
     (docs/architecture/70-api.md § running).
   - B13 — cardinality windows are shape: a tuples window is handed to the
     invocation as the array-rooted wire schema (minItems/maxItems), and a
     reply conforming to that handed schema parses; the bound is unwritable
     at the decode boundary, never a count check after it
     (docs/architecture/10-theory.md § statement grammar;
     docs/architecture/20-contracts.md § lowering).
   - B1 — the boundary is the admitted contract: head replies parse through
     [Contract.Codec] against the admitted wire schema with ref resolution
     against mint provenance — wrong enums, stray fields, and invented ref
     ids die at the boundary with diagnostics, never in committed state
     (docs/architecture/20-contracts.md § failure surface).
   - B14 — provenance is total for tuple-window heads: every committed head
     id traces to a firing record of its retired producer in the ledger
     (docs/architecture/10-theory.md § provenance is total).

   Rigged executors only; no live provider lane, no network, no sleeps. *)

open Goatcode
module R = Agent.Rigged

(* ------------------------------------------------------------------ *)
(* Fixture material.                                                   *)

let obj_schema ~doc props required : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("description", `String doc);
      ("properties", `Assoc props);
      ("required", `List (List.map (fun s -> `String s) required));
      ("additionalProperties", `Bool false);
    ]

let str_prop doc : Yojson.Safe.t =
  `Assoc [ ("type", `String "string"); ("description", `String doc) ]

let ref_prop target doc : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "string");
      ("format", `String ("ref:" ^ target));
      ("description", `String doc);
    ]

let enum_prop cases doc : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "string");
      ("enum", `List (List.map (fun c -> `String c) cases));
      ("description", `String doc);
    ]

let pin =
  { Theory.Pin.provider = "rigged"; model = "none"; sampling = []; options = [] }

let template name =
  Theory.Executor.Agent_template
    {
      name;
      pin;
      preamble = name ^ ": a rigged test template";
      read_globs = [];
      write_globs = [ "**" ];
      effects = [];
    }

let binding ?(budget = 0) ~by runtime =
  {
    Chase.executor = Theory.Executor.id by;
    runtime;
    fallback = None;
    repair_budget = Agent.Repair_budget.v budget;
    port = "rig";
  }

let admit ~relations ~statements ~laws =
  match Theory.declare ~relations ~statements ~laws with
  | Ok theory -> theory
  | Error errors ->
      failwith
        ("fixture unexpectedly rejected: "
        ^ String.concat "; " (List.map Theory.Admission.to_string errors))

let fresh_dir () =
  let dir = Filename.temp_dir "goatcode_heads" "" in
  Sys.mkdir (Filename.concat dir "repo") 0o755;
  dir

let run_exn ~theory ~seed ~bindings =
  let dir = fresh_dir () in
  let config =
    {
      Run.repo = Filename.concat dir "repo";
      committed_branch = "goat-test";
      ledger_path = Filename.concat dir "ledger";
      ports = [ Chase.Port.open_ ~name:"rig" ];
      executors = bindings;
      backstops = Speculate.Backstops.default;
      switches = [];
      merges = Retire.Merge_registry.empty;
    }
  in
  match Run.exec ~theory ~seed ~config with
  | Ok settled -> settled
  | Error _ -> failwith "host misuse on a well-formed test config"

(* A pass-through executor that captures what the engine handed the
   invocation — the prompt the model reads and the wire schema the decode
   is forced against. *)
let probing capture (inner : Agent.Executor.t) =
  let run :
      type s.
      s Agent.Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:(unit -> Speculate.Drift.note list) ->
      (Agent.Executor.reply, Ledger.Fault.t) result =
   fun inv ~ledger ~node ~on_yield ->
    capture inv.Agent.Invocation.prompt inv.Agent.Invocation.schema;
    inner.Agent.Executor.run inv ~ledger ~node ~on_yield
  in
  { Agent.Executor.run }

let contains hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    i + m <= n && (String.equal (String.sub hay i m) needle || go (i + 1))
  in
  m > 0 && go 0

let settlement_kind = function
  | Ledger.Settlement.Retired -> "retired"
  | Ledger.Settlement.Faulted { origin; _ } -> (
      "faulted:"
      ^
      match origin with
      | Ledger.Fault.Executor_error -> "executor-error"
      | Ledger.Fault.Repair_exhausted -> "repair-exhausted"
      | Ledger.Fault.Context_exhausted -> "context-exhausted")
  | Ledger.Settlement.Squashed _ -> "squashed"

let print_settlements (settled : Run.settled) =
  List.iter
    (fun (_, (r : Run.node_report)) ->
      Printf.printf "settled: %s\n" (settlement_kind r.Run.settlement))
    settled.Run.nodes

let print_committed (settled : Run.settled) =
  List.iter
    (fun (t : Retire.Committed.tuple) ->
      Printf.printf "committed: %s %s %s\n" t.Retire.Committed.relation
        t.Retire.Committed.id
        (Yojson.Safe.to_string t.Retire.Committed.payload))
    settled.Run.tuples

(* ------------------------------------------------------------------ *)
(* B4 — seed payloads are real.                                        *)

let%expect_test "B4: a seed's payload reaches the executor and committed \
                 state" =
  let spec =
    Theory.Relation.dynamic ~name:"spec"
      ~schema:
        (obj_schema ~doc:"An operator's prose specification."
           [ ("text", str_prop "The specification, verbatim.") ]
           [ "text" ])
  in
  let note =
    Theory.Relation.dynamic ~name:"note"
      ~schema:
        (obj_schema ~doc:"A planner note."
           [ ("msg", str_prop "One line.") ]
           [ "msg" ])
  in
  let planner = template "planner" in
  let theory =
    admit
      ~relations:[ Theory.Relation.Packed spec; Theory.Relation.Packed note ]
      ~statements:
        [
          Theory.Spawn.v ~name:"plan" ~for_:"spec"
            ~exists:("note", Theory.Window.nodes 1)
            ~by:planner ();
        ]
      ~laws:[]
  in
  let seen_prompt = ref "" in
  let capture prompt _schema = seen_prompt := Agent.Prompt.render prompt in
  let runtime =
    probing capture (R.executor ~script:[ R.Reply {|{"msg":"planned"}|} ])
  in
  let settled =
    run_exn ~theory
      ~seed:
        [
          Theory.Tuple.v spec
            (`Assoc [ ("text", `String "rewrite the widget in OCaml") ]);
        ]
      ~bindings:[ binding ~by:planner runtime ]
  in
  Printf.printf "prompt carries the seed payload: %b\n"
    (contains !seen_prompt "rewrite the widget in OCaml");
  print_settlements settled;
  print_committed settled;
  [%expect
    {|
    prompt carries the seed payload: true
    settled: retired
    committed: spec spec#0 {"text":"rewrite the widget in OCaml"}
    committed: note note#0 {"msg":"planned"}
    |}]

let%expect_test "B4: judge_count over a seeded relation is not vacuously \
                 satisfied" =
  let finding =
    Theory.Relation.dynamic ~name:"finding"
      ~schema:
        (obj_schema ~doc:"A claim under review."
           [ ("claim", str_prop "The claim text.") ]
           [ "claim" ])
  in
  let verdict =
    Theory.Relation.dynamic ~name:"verdict"
      ~schema:
        (obj_schema ~doc:"One refuter's judgment."
           [
             ("finding", ref_prop "finding" "The judged finding.");
             ("refuted", enum_prop [ "yes"; "no" ] "Whether the claim fell.");
           ]
           [ "finding"; "refuted" ])
  in
  let reviewer = template "reviewer" in
  let theory =
    admit
      ~relations:
        [ Theory.Relation.Packed finding; Theory.Relation.Packed verdict ]
      ~statements:
        [
          Theory.Spawn.v ~name:"review" ~for_:"finding"
            ~exists:("verdict", Theory.Window.upto 2)
            ~by:reviewer ();
        ]
      ~laws:
        [
          Theory.Law.Count
            {
              name = "quorum";
              over = "verdict";
              group_by = "finding";
              bound = Theory.Law.At_least 1;
            };
        ]
  in
  (* The reviewer produces ZERO verdicts (an empty array inside the 0..2
     window): the seeded finding must be judged as a quorum shortfall, not
     vanish from the law's universe. *)
  let settled =
    run_exn ~theory
      ~seed:[ Theory.Tuple.v finding (`Assoc [ ("claim", `String "it leaks") ]) ]
      ~bindings:[ binding ~by:reviewer (R.executor ~script:[ R.Reply "[]" ]) ]
  in
  List.iter
    (fun (v : Theory.Law.verdict) ->
      Printf.printf "law %s satisfied=%b offenders=[%s]\n" v.Theory.Law.law
        v.satisfied
        (String.concat "; " v.offenders))
    settled.Run.laws;
  [%expect {| law quorum satisfied=false offenders=[finding/finding#0] |}]

(* ------------------------------------------------------------------ *)
(* B13 + B14 — the window is shape; provenance is total.               *)

let%expect_test "B13: a tuples window is handed as the array schema, a \
                 window-conformant reply parses, and (B14) every committed \
                 head traces to its firing" =
  let task =
    Theory.Relation.dynamic ~name:"task"
      ~schema:
        (obj_schema ~doc:"A work item."
           [ ("msg", str_prop "A short status message.") ]
           [ "msg" ])
  in
  let item =
    Theory.Relation.dynamic ~name:"item"
      ~schema:
        (obj_schema ~doc:"One produced item."
           [ ("msg", str_prop "A short status message.") ]
           [ "msg" ])
  in
  let sweeper = template "sweeper" in
  let theory =
    admit
      ~relations:[ Theory.Relation.Packed task; Theory.Relation.Packed item ]
      ~statements:
        [
          Theory.Spawn.v ~name:"sweep" ~for_:"task"
            ~exists:("item", Theory.Window.between ~min:2 ~max:3)
            ~by:sweeper ();
        ]
      ~laws:[]
  in
  let seen_schema = ref `Null in
  let capture _prompt schema =
    seen_schema := Contract.Wire_schema.to_json schema
  in
  let runtime =
    probing capture
      (R.executor ~script:[ R.Reply {|[{"msg":"a"},{"msg":"b"}]|} ])
  in
  let settled =
    run_exn ~theory
      ~seed:[ Theory.Tuple.v task (`Assoc [ ("msg", `String "go") ]) ]
      ~bindings:[ binding ~by:sweeper runtime ]
  in
  (match !seen_schema with
  | `Assoc kvs ->
      let str k =
        match List.assoc_opt k kvs with Some (`String s) -> s | _ -> "-"
      in
      let num k =
        match List.assoc_opt k kvs with
        | Some (`Int n) -> string_of_int n
        | _ -> "-"
      in
      let items_type =
        match List.assoc_opt "items" kvs with
        | Some (`Assoc iks) -> (
            match List.assoc_opt "type" iks with
            | Some (`String s) -> s
            | _ -> "-")
        | _ -> "-"
      in
      Printf.printf "handed schema: type=%s items=%s minItems=%s maxItems=%s\n"
        (str "type") items_type (num "minItems") (num "maxItems")
  | _ -> print_endline "handed schema: not captured");
  print_settlements settled;
  print_committed settled;
  (* B14: every committed head id appears in a firing record of a retired
     node — squash, dep-order, and replay all walk this trace. *)
  let events = Ledger.Replay.events settled.Run.ledger in
  let retired =
    List.filter_map
      (fun (n, (r : Run.node_report)) ->
        match r.Run.settlement with
        | Ledger.Settlement.Retired -> Some n
        | _ -> None)
      settled.Run.nodes
  in
  let minted_by_retired =
    List.concat_map
      (fun (e : Ledger.Event.t) ->
        match (e.node, e.kind) with
        | Some n, Ledger.Event.Fired { minted; _ }
          when List.exists (Id.equal n) retired ->
            minted
        | _ -> [])
      events
  in
  let traced =
    List.for_all
      (fun (t : Retire.Committed.tuple) ->
        String.equal t.Retire.Committed.relation "task"
        || List.exists
             (fun (rel, id) ->
               String.equal rel t.Retire.Committed.relation
               && String.equal id t.Retire.Committed.id)
             minted_by_retired)
      settled.Run.tuples
  in
  Printf.printf "every committed head traces to its firing: %b\n" traced;
  [%expect
    {|
    handed schema: type=array items=object minItems=2 maxItems=3
    settled: retired
    committed: task task#0 {"msg":"go"}
    committed: item item#0 {"msg":"a"}
    committed: item item#1 {"msg":"b"}
    every committed head traces to its firing: true
    |}]

let%expect_test "B13: a reply outside the window dies at the decode \
                 boundary, committing nothing" =
  let task =
    Theory.Relation.dynamic ~name:"task"
      ~schema:
        (obj_schema ~doc:"A work item."
           [ ("msg", str_prop "A short status message.") ]
           [ "msg" ])
  in
  let item =
    Theory.Relation.dynamic ~name:"item"
      ~schema:
        (obj_schema ~doc:"One produced item."
           [ ("msg", str_prop "A short status message.") ]
           [ "msg" ])
  in
  let sweeper = template "sweeper" in
  let theory () =
    admit
      ~relations:[ Theory.Relation.Packed task; Theory.Relation.Packed item ]
      ~statements:
        [
          Theory.Spawn.v ~name:"sweep" ~for_:"task"
            ~exists:("item", Theory.Window.between ~min:2 ~max:3)
            ~by:sweeper ();
        ]
      ~laws:[]
  in
  let drive label reply =
    let settled =
      run_exn ~theory:(theory ())
        ~seed:[ Theory.Tuple.v task (`Assoc [ ("msg", `String "go") ]) ]
        ~bindings:
          [ binding ~by:sweeper (R.executor ~script:[ R.Reply reply ]) ]
    in
    let items =
      List.filter
        (fun (t : Retire.Committed.tuple) ->
          String.equal t.Retire.Committed.relation "item")
        settled.Run.tuples
    in
    Printf.printf "%s -> %s, items committed: %d\n" label
      (String.concat " "
         (List.map
            (fun (_, (r : Run.node_report)) ->
              settlement_kind r.Run.settlement)
            settled.Run.nodes))
      (List.length items)
  in
  (* One bare tuple: the shape the OLD bare-schema handoff invited. *)
  drive "a single object" {|{"msg":"lonely"}|};
  (* An array wider than the window. *)
  drive "an array of four" {|[{"msg":"a"},{"msg":"b"},{"msg":"c"},{"msg":"d"}]|};
  [%expect
    {|
    a single object -> faulted:repair-exhausted, items committed: 0
    an array of four -> faulted:repair-exhausted, items committed: 0
    |}]

(* ------------------------------------------------------------------ *)
(* B1 — the head boundary is the admitted contract.                    *)

let%expect_test "B1: shape, enum membership, and ref resolution are judged \
                 at the head boundary; nothing invalid commits" =
  let finding =
    Theory.Relation.dynamic ~name:"finding"
      ~schema:
        (obj_schema ~doc:"A claim under review."
           [ ("claim", str_prop "The claim text.") ]
           [ "claim" ])
  in
  let verdict =
    Theory.Relation.dynamic ~name:"verdict"
      ~schema:
        (obj_schema ~doc:"One refuter's judgment."
           [
             ("finding", ref_prop "finding" "The judged finding.");
             ("refuted", enum_prop [ "yes"; "no" ] "Whether the claim fell.");
           ]
           [ "finding"; "refuted" ])
  in
  let refuter = template "refuter" in
  let theory () =
    admit
      ~relations:
        [ Theory.Relation.Packed finding; Theory.Relation.Packed verdict ]
      ~statements:
        [
          Theory.Spawn.v ~name:"judge" ~for_:"finding"
            ~exists:("verdict", Theory.Window.nodes 1)
            ~by:refuter ();
        ]
      ~laws:[]
  in
  let drive label reply =
    let settled =
      run_exn ~theory:(theory ())
        ~seed:
          [ Theory.Tuple.v finding (`Assoc [ ("claim", `String "it leaks") ]) ]
        ~bindings:
          [ binding ~by:refuter (R.executor ~script:[ R.Reply reply ]) ]
    in
    let verdicts =
      List.filter_map
        (fun (t : Retire.Committed.tuple) ->
          if String.equal t.Retire.Committed.relation "verdict" then
            Some (Yojson.Safe.to_string t.Retire.Committed.payload)
          else None)
        settled.Run.tuples
    in
    Printf.printf "%s -> %s, verdicts: [%s]\n" label
      (String.concat " "
         (List.map
            (fun (_, (r : Run.node_report)) ->
              settlement_kind r.Run.settlement)
            settled.Run.nodes))
      (String.concat "; " verdicts)
  in
  drive "an invented ref id" {|{"finding":"finding#99","refuted":"yes"}|};
  drive "an out-of-enum value" {|{"finding":"finding#0","refuted":"maybe"}|};
  drive "a smuggled stray field"
    {|{"finding":"finding#0","refuted":"yes","note":"smuggled"}|};
  drive "the contract, echoed honestly" {|{"finding":"finding#0","refuted":"no"}|};
  [%expect
    {|
    an invented ref id -> faulted:repair-exhausted, verdicts: []
    an out-of-enum value -> faulted:repair-exhausted, verdicts: []
    a smuggled stray field -> faulted:repair-exhausted, verdicts: []
    the contract, echoed honestly -> retired, verdicts: [{"finding":"finding#0","refuted":"no"}]
    |}]
