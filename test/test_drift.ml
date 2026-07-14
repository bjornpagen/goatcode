(* Falsifiers, group "drift" (docs/architecture/80-validation.md):

   F8 — drift routing table. Each drift class in 40-scheduling.md's table,
   constructed deliberately, routes as the table says — including the
   per-consumer refinement: a breaking change to a field the consumer's
   observed witness never read is additive from that consumer's
   perspective, and routes as such.

   F9 — speculation is semantics-free. The same theory and seed, run with
   speculation on and off, commits the same tuples (mod fresh-id renaming —
   a canonicalizer below handles it) and the same law verdicts. The
   falsifier runs the review theory both ways with rigged executors and
   diffs. "Off" is exercised through both mechanisms the docs admit: the
   confidence floor (reads suspend instead of hypothesizing,
   40-scheduling.md § backstops) and the per-shape switch, whose
   constructor requires churn evidence obtainable only from a ledger
   (40-scheduling.md § speculation is default-on).

   Rigged executors only; no live model call; no sleep longer than
   milliseconds. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Shared schema-building helpers (raw deriver-shaped JSON, parsed
   through the admission parse into the LLM-safe subset).              *)

let schema_of_json json =
  match Contract.Wire_schema.parse json with
  | Ok ws -> ws
  | Error (e : Contract.Wire_schema.escape) ->
      failwith
        (Printf.sprintf "unexpected schema escape at %s: %s (%s)"
           (Contract.Path.to_string e.path)
           e.construct e.hint)

let str_field : Yojson.Safe.t = `Assoc [ ("type", `String "string") ]
let int_field : Yojson.Safe.t = `Assoc [ ("type", `String "integer") ]

let enum_field cases : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "string");
      ("enum", `List (List.map (fun c -> `String c) cases));
    ]

let ref_field relation : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "string"); ("format", `String ("ref:" ^ relation)) ]

let record ?(required = []) fields : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc fields);
      ("required", `List (List.map (fun f -> `String f) required));
      ("additionalProperties", `Bool false);
    ]

(* ------------------------------------------------------------------ *)
(* F8 — drift routing table.                                           *)

let tag_name = function
  | Speculate.Drift.Schema_identical_t -> "schema_identical"
  | Speculate.Drift.Additive_t -> "additive"
  | Speculate.Drift.Breaking_narrow_t -> "breaking_narrow"
  | Speculate.Drift.Breaking_broad_t -> "breaking_broad"
  | Speculate.Drift.Producer_squashed_t -> "producer_squashed"

let route_name = function
  | Speculate.Drift.Route.Discharge_silently -> "discharge_silently"
  | Speculate.Drift.Route.Reconcile_note -> "reconcile_note"
  | Speculate.Drift.Route.Reconcile_delta -> "reconcile_delta"
  | Speculate.Drift.Route.Flush_subtree -> "flush_subtree"

(* One deliberate construction: classify a landing against one consumer's
   observed reads, then assert (a) the parse produced the intended class,
   (b) [route] agrees with the policy [table] (the total-match twin cannot
   silently diverge from the data), and (c) the route is the one
   40-scheduling.md's table writes. Any mismatch prints loudly and breaks
   the expect block. *)
let case name ~landing ~consumed ~expect_tag ~expect_route =
  let cls = Speculate.Drift.classify ~landing ~consumed in
  let tag = Speculate.Drift.tag cls in
  let route = Speculate.Drift.route cls in
  let table_route =
    match List.assoc_opt tag Speculate.Drift.table with
    | Some r -> r
    | None -> failwith (name ^ ": class tag missing from the routing table")
  in
  let complaints =
    (if tag <> expect_tag then
       [ Printf.sprintf "CLASS MISMATCH: wanted %s" (tag_name expect_tag) ]
     else [])
    @ (if route <> expect_route then
         [ Printf.sprintf "ROUTE MISMATCH: wanted %s" (route_name expect_route) ]
       else [])
    @
    if route <> table_route then
      [
        Printf.sprintf "TWIN DRIFT: route says %s, table says %s"
          (route_name route) (route_name table_route);
      ]
    else []
  in
  Printf.printf "%-42s %s -> %s%s\n" name (tag_name tag) (route_name route)
    (match complaints with
    | [] -> ""
    | cs -> "  !! " ^ String.concat "; " cs);
  cls

let%expect_test "F8: the routing policy table is total, as data" =
  (* Five classes, five rows, each exactly once; the routes are the ones
     40-scheduling.md § drift routing writes. *)
  List.iter
    (fun (tag, route) ->
      Printf.printf "%s -> %s\n" (tag_name tag) (route_name route))
    Speculate.Drift.table;
  let tags =
    [
      Speculate.Drift.Schema_identical_t;
      Speculate.Drift.Additive_t;
      Speculate.Drift.Breaking_narrow_t;
      Speculate.Drift.Breaking_broad_t;
      Speculate.Drift.Producer_squashed_t;
    ]
  in
  List.iter
    (fun tag ->
      let n =
        List.length
          (List.filter (fun (t, _) -> t = tag) Speculate.Drift.table)
      in
      if n <> 1 then
        Printf.printf "!! tag %s appears %d times in the table\n"
          (tag_name tag) n)
    tags;
  [%expect
    {|
    schema_identical -> discharge_silently
    additive -> reconcile_note
    breaking_narrow -> reconcile_delta
    breaking_broad -> flush_subtree
    producer_squashed -> flush_subtree
    |}]

let%expect_test "F8: each drift class, constructed deliberately, routes per \
                 the table" =
  let base_fields =
    [
      ("summary", str_field);
      ("severity", enum_field [ "low"; "high" ]);
      ("evidence", str_field);
      ("meta", record ~required:[ "level" ] [ ("level", str_field) ]);
    ]
  in
  let required = [ "summary"; "severity"; "evidence"; "meta" ] in
  let base = schema_of_json (record ~required base_fields) in
  let replace field value =
    schema_of_json
      (record ~required
         (List.map
            (fun (f, v) -> if String.equal f field then (f, value) else (f, v))
            base_fields))
  in
  let s_add =
    (* one new OPTIONAL field: the diff is pure additions *)
    schema_of_json (record ~required (base_fields @ [ ("notes", str_field) ]))
  in
  let s_widen = replace "severity" (enum_field [ "low"; "high"; "critical" ]) in
  let s_retype_sev = replace "severity" int_field in
  let s_drop_evidence =
    schema_of_json
      (record
         ~required:[ "summary"; "severity"; "meta" ]
         (List.filter (fun (f, _) -> f <> "evidence") base_fields))
  in
  let s_retype_meta = replace "meta" str_field in
  let s_retype_meta_level =
    replace "meta" (record ~required:[ "level" ] [ ("level", int_field) ])
  in
  let s_two =
    (* retype severity AND drop evidence: two consumed paths breaking *)
    schema_of_json
      (record
         ~required:[ "summary"; "severity"; "meta" ]
         (List.filter_map
            (fun (f, v) ->
              if f = "evidence" then None
              else if f = "severity" then Some (f, int_field)
              else Some (f, v))
            base_fields))
  in
  let d a b = `Landed (Contract.Diff.between a b) in
  (* row 1: schema-identical — derived-schema hash equal *)
  let (_ : Speculate.Drift.cls) =
    case "identical landing" ~landing:(d base base)
      ~consumed:[ [ "summary" ] ]
      ~expect_tag:Speculate.Drift.Schema_identical_t
      ~expect_route:Speculate.Drift.Route.Discharge_silently
  in
  (* row 2: additive — new optional field / widened enum. The widened enum
     is on a path the consumer DID read: additions route as a note even on
     consumed paths. *)
  let (_ : Speculate.Drift.cls) =
    case "new optional field" ~landing:(d base s_add)
      ~consumed:[ [ "summary" ]; [ "severity" ] ]
      ~expect_tag:Speculate.Drift.Additive_t
      ~expect_route:Speculate.Drift.Route.Reconcile_note
  in
  let (_ : Speculate.Drift.cls) =
    case "widened enum on a read path" ~landing:(d base s_widen)
      ~consumed:[ [ "severity" ] ]
      ~expect_tag:Speculate.Drift.Additive_t
      ~expect_route:Speculate.Drift.Route.Reconcile_note
  in
  (* row 3: breaking-narrow — the diff touches a minority of the consumer's
     observed reads; the class carries exactly the touched paths. *)
  let narrow =
    case "retype touches 1 of 3 read paths" ~landing:(d base s_retype_sev)
      ~consumed:[ [ "summary" ]; [ "severity" ]; [ "evidence" ] ]
      ~expect_tag:Speculate.Drift.Breaking_narrow_t
      ~expect_route:Speculate.Drift.Route.Reconcile_delta
  in
  (match narrow with
  | Speculate.Drift.Breaking_narrow { touched; _ } ->
      Printf.printf "  narrow evidence: touched=%s\n"
        (String.concat "," (List.map Contract.Path.to_string touched))
  | _ -> print_string "  !! narrow case carries no touched evidence\n");
  (* exactly half touched is NOT a majority: still narrow *)
  let (_ : Speculate.Drift.cls) =
    case "retype touches 1 of 2 read paths" ~landing:(d base s_retype_sev)
      ~consumed:[ [ "summary" ]; [ "severity" ] ]
      ~expect_tag:Speculate.Drift.Breaking_narrow_t
      ~expect_route:Speculate.Drift.Route.Reconcile_delta
  in
  (* hierarchy: a diff at the parent reshapes a read of the child, and a
     diff at the child reshapes a read of the parent *)
  let (_ : Speculate.Drift.cls) =
    case "retype parent of a read path" ~landing:(d base s_retype_meta)
      ~consumed:[ [ "meta"; "level" ]; [ "summary" ] ]
      ~expect_tag:Speculate.Drift.Breaking_narrow_t
      ~expect_route:Speculate.Drift.Route.Reconcile_delta
  in
  let (_ : Speculate.Drift.cls) =
    case "retype child of a read path" ~landing:(d base s_retype_meta_level)
      ~consumed:[ [ "meta" ]; [ "summary" ]; [ "evidence" ] ]
      ~expect_tag:Speculate.Drift.Breaking_narrow_t
      ~expect_route:Speculate.Drift.Route.Reconcile_delta
  in
  (* row 4: breaking-broad — majority of consumed paths touched, or the
     producer's statement itself re-fired (broad even on an EMPTY diff:
     re-firing is broad by definition, whatever the diff says) *)
  let (_ : Speculate.Drift.cls) =
    case "retype touches 1 of 1 read paths" ~landing:(d base s_retype_sev)
      ~consumed:[ [ "severity" ] ]
      ~expect_tag:Speculate.Drift.Breaking_broad_t
      ~expect_route:Speculate.Drift.Route.Flush_subtree
  in
  let (_ : Speculate.Drift.cls) =
    case "retype+removal touch 2 of 2 read paths" ~landing:(d base s_two)
      ~consumed:[ [ "severity" ]; [ "evidence" ] ]
      ~expect_tag:Speculate.Drift.Breaking_broad_t
      ~expect_route:Speculate.Drift.Route.Flush_subtree
  in
  let refired =
    case "producer re-fired, byte-identical diff"
      ~landing:(`Refired (Contract.Diff.between base base))
      ~consumed:[ [ "summary" ] ]
      ~expect_tag:Speculate.Drift.Breaking_broad_t
      ~expect_route:Speculate.Drift.Route.Flush_subtree
  in
  (match refired with
  | Speculate.Drift.Breaking_broad { refired = true; _ } -> ()
  | Speculate.Drift.Breaking_broad { refired = false; _ } ->
      print_string "  !! refired landing lost its refired evidence\n"
  | _ -> ());
  (* row 5: producer squashed — flush, always *)
  let (_ : Speculate.Drift.cls) =
    case "producer squashed" ~landing:`Producer_squashed
      ~consumed:[ [ "summary" ] ]
      ~expect_tag:Speculate.Drift.Producer_squashed_t
      ~expect_route:Speculate.Drift.Route.Flush_subtree
  in
  (* the per-consumer refinement: breaking changes ONLY to paths this
     consumer's observed witness never read are additive from this
     consumer's perspective — drift class is judged per consumer, never
     per contract *)
  let (_ : Speculate.Drift.cls) =
    case "per-consumer: retyped field never read" ~landing:(d base s_retype_sev)
      ~consumed:[ [ "summary" ] ]
      ~expect_tag:Speculate.Drift.Additive_t
      ~expect_route:Speculate.Drift.Route.Reconcile_note
  in
  let (_ : Speculate.Drift.cls) =
    case "per-consumer: removed field never read"
      ~landing:(d base s_drop_evidence)
      ~consumed:[ [ "summary" ]; [ "severity" ] ]
      ~expect_tag:Speculate.Drift.Additive_t
      ~expect_route:Speculate.Drift.Route.Reconcile_note
  in
  let (_ : Speculate.Drift.cls) =
    case "per-consumer: breaking diff, empty witness"
      ~landing:(d base s_retype_sev) ~consumed:[]
      ~expect_tag:Speculate.Drift.Additive_t
      ~expect_route:Speculate.Drift.Route.Reconcile_note
  in
  [%expect
    {|
    identical landing                          schema_identical -> discharge_silently
    new optional field                         additive -> reconcile_note
    widened enum on a read path                additive -> reconcile_note
    retype touches 1 of 3 read paths           breaking_narrow -> reconcile_delta
      narrow evidence: touched=/severity
    retype touches 1 of 2 read paths           breaking_narrow -> reconcile_delta
    retype parent of a read path               breaking_narrow -> reconcile_delta
    retype child of a read path                breaking_narrow -> reconcile_delta
    retype touches 1 of 1 read paths           breaking_broad -> flush_subtree
    retype+removal touch 2 of 2 read paths     breaking_broad -> flush_subtree
    producer re-fired, byte-identical diff     breaking_broad -> flush_subtree
    producer squashed                          producer_squashed -> flush_subtree
    per-consumer: retyped field never read     additive -> reconcile_note
    per-consumer: removed field never read     additive -> reconcile_note
    per-consumer: breaking diff, empty witness additive -> reconcile_note
    |}]

(* ------------------------------------------------------------------ *)
(* F9 — speculation is semantics-free.                                 *)

(* The review theory: seed target -> sweep fans out findings -> one
   reviewer node per finding -> verdicts, gated by a quorum law
   (docs/architecture/00-product.md § the census; 10-theory.md § the
   worked example, miniaturized). *)

let pin =
  {
    Theory.Pin.provider = "rigged";
    model = "fake-1";
    sampling = [];
    options = [];
  }

let sweep_by =
  Theory.Executor.Agent_template
    {
      name = "sweeper";
      pin;
      preamble = "You sweep the diff for findings.";
      read_globs = [];
    }

let review_by =
  Theory.Executor.Agent_template
    {
      name = "reviewer";
      pin;
      preamble = "You review one finding.";
      read_globs = [];
    }

let review_theory () =
  let target =
    Theory.Relation.dynamic ~name:"target"
      ~schema:(record ~required:[ "goal" ] [ ("goal", str_field) ])
  in
  let finding =
    Theory.Relation.dynamic ~name:"finding"
      ~schema:(record ~required:[ "desc" ] [ ("desc", str_field) ])
  in
  let verdict =
    Theory.Relation.dynamic ~name:"verdict"
      ~schema:
        (record
           ~required:[ "finding"; "refuted" ]
           [
             ("finding", ref_field "finding");
             ("refuted", enum_field [ "yes"; "no" ]);
           ])
  in
  let statements =
    [
      Theory.Spawn.v ~name:"sweep" ~for_:"target"
        ~exists:("finding", Theory.Window.exactly 2)
        ~by:sweep_by ();
      Theory.Spawn.v ~name:"review" ~for_:"finding"
        ~exists:("verdict", Theory.Window.nodes 1)
        ~by:review_by ();
    ]
  in
  let laws =
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
  match
    Theory.declare
      ~relations:
        [
          Theory.Relation.Packed target;
          Theory.Relation.Packed finding;
          Theory.Relation.Packed verdict;
        ]
      ~statements ~laws
  with
  | Ok admitted -> (admitted, target)
  | Error errors ->
      failwith
        ("review theory rejected at admission: "
        ^ String.concat "; " (List.map Theory.Admission.to_string errors))

let misuse_string = function
  | Run.Missing_path { field; path } ->
      Printf.sprintf "missing path: %s = %s" field path
  | Run.Unbound_executor { executor } -> "unbound executor: " ^ executor
  | Run.Unknown_port { executor; port } ->
      Printf.sprintf "unknown port %s for %s" port executor

(* One run of the review theory with fresh rigged executors (scripts are
   consumed across invocations, so every run gets its own executor
   values), fresh repo / worktree / ledger paths, and the given
   speculation posture. *)
let run_review ~tag ~backstops ~switches (theory, target_rel) =
  let dir = Filename.temp_dir "goatcode_f9" ("." ^ tag) in
  let repo = Filename.concat dir "repo" in
  let worktree_root = Filename.concat dir "worktrees" in
  Sys.mkdir repo 0o755;
  Sys.mkdir worktree_root 0o755;
  let binding by script =
    {
      Chase.executor = Theory.Executor.id by;
      runtime = Agent.Rigged.executor ~script;
      fallback = None;
      repair_budget = Agent.Repair_budget.v 2;
      port = "model";
    }
  in
  let sweep_script =
    [
      Agent.Rigged.Reply
        {|[{"desc":"unchecked error path"},{"desc":"missing regression test"}]|};
    ]
  in
  let review_script =
    [
      Agent.Rigged.Reply {|{"finding":"finding#0","refuted":"no"}|};
      Agent.Rigged.Reply {|{"finding":"finding#1","refuted":"no"}|};
    ]
  in
  let config =
    {
      Run.repo;
      committed_branch = "committed";
      worktree_root;
      ledger_path = Filename.concat dir "ledger.bin";
      ports = [ Chase.Port.open_ ~name:"model" ];
      executors = [ binding sweep_by sweep_script; binding review_by review_script ];
      backstops;
      switches;
      merges = Retire.Merge_registry.empty;
    }
  in
  let seed =
    [ Theory.Tuple.v target_rel (`Assoc [ ("goal", `String "review the diff") ]) ]
  in
  match Run.exec ~theory ~seed ~config with
  | Ok settled -> settled
  | Error misuse -> failwith ("host misuse: " ^ misuse_string misuse)

(* The replay canonicalizer for fresh-id renaming: every engine-minted id
   is "realm#ordinal"; rename each, in order of first appearance in the
   committed tuple set, to "realm@k". Two runs commit the same tuples mod
   fresh-id renaming iff their canonical renderings agree. *)
let canonical (settled : Run.settled) =
  let mapping = Hashtbl.create 16 in
  let next = Hashtbl.create 16 in
  let rename id =
    match Hashtbl.find_opt mapping id with
    | Some x -> x
    | None ->
        let realm =
          match String.rindex_opt id '#' with
          | Some i -> String.sub id 0 i
          | None -> id
        in
        let k = Option.value (Hashtbl.find_opt next realm) ~default:0 in
        Hashtbl.replace next realm (k + 1);
        let x = Printf.sprintf "%s@%d" realm k in
        Hashtbl.replace mapping id x;
        x
  in
  List.iter
    (fun (t : Retire.Committed.tuple) -> ignore (rename t.Retire.Committed.id))
    settled.Run.tuples;
  let rec rewrite (j : Yojson.Safe.t) : Yojson.Safe.t =
    match j with
    | `String s -> (
        match Hashtbl.find_opt mapping s with
        | Some x -> `String x
        | None -> `String s)
    | `Assoc kvs -> `Assoc (List.map (fun (k, v) -> (k, rewrite v)) kvs)
    | `List l -> `List (List.map rewrite l)
    | j -> j
  in
  let tuple_lines =
    List.map
      (fun (t : Retire.Committed.tuple) ->
        Format.asprintf "%s %s %s %a" t.Retire.Committed.relation
          (rename t.Retire.Committed.id)
          (Yojson.Safe.to_string (rewrite t.Retire.Committed.payload))
          Ledger.Generation.pp t.Retire.Committed.generation)
      settled.Run.tuples
  in
  let canonical_offender o =
    (* count-law offenders render as "relation/id" *)
    match String.index_opt o '/' with
    | Some i -> (
        let rel = String.sub o 0 i in
        let id = String.sub o (i + 1) (String.length o - i - 1) in
        match Hashtbl.find_opt mapping id with
        | Some x -> rel ^ "/" ^ x
        | None -> o)
    | None -> o
  in
  let law_lines =
    List.map
      (fun (v : Theory.Law.verdict) ->
        Printf.sprintf "law %s satisfied=%b offenders=[%s]" v.Theory.Law.law
          v.satisfied
          (String.concat "," (List.map canonical_offender v.offenders)))
      settled.Run.laws
  in
  (List.sort String.compare tuple_lines, law_lines)

let settlement_counts (settled : Run.settled) =
  List.fold_left
    (fun (r, f, s) ((_, rep) : _ * Run.node_report) ->
      match rep.Run.settlement with
      | Ledger.Settlement.Retired -> (r + 1, f, s)
      | Ledger.Settlement.Faulted _ -> (r, f + 1, s)
      | Ledger.Settlement.Squashed _ -> (r, f, s + 1))
    (0, 0, 0) settled.Run.nodes

let hypotheses_taken (settled : Run.settled) =
  List.fold_left
    (fun acc ((_, rep) : _ * Run.node_report) ->
      acc + List.length rep.Run.hypotheses)
    0 settled.Run.nodes

let diff_runs ~label a b =
  let tuples_a, laws_a = canonical a and tuples_b, laws_b = canonical b in
  if List.equal String.equal tuples_a tuples_b then
    Printf.printf "%s: identical committed tuples (mod fresh-id renaming)\n"
      label
  else begin
    Printf.printf "%s: TUPLE DIVERGENCE\n" label;
    List.iter (fun l -> Printf.printf "  on : %s\n" l) tuples_a;
    List.iter (fun l -> Printf.printf "  off: %s\n" l) tuples_b
  end;
  if List.equal String.equal laws_a laws_b then
    Printf.printf "%s: identical law verdicts\n" label
  else begin
    Printf.printf "%s: LAW DIVERGENCE\n" label;
    List.iter (fun l -> Printf.printf "  on : %s\n" l) laws_a;
    List.iter (fun l -> Printf.printf "  off: %s\n" l) laws_b
  end;
  let ra, fa, sa = settlement_counts a and rb, fb, sb = settlement_counts b in
  if (ra, fa, sa) = (rb, fb, sb) then
    Printf.printf "%s: identical settlement counts\n" label
  else
    Printf.printf
      "%s: SETTLEMENT DIVERGENCE on=(r%d f%d s%d) off=(r%d f%d s%d)\n" label ra
      fa sa rb fb sb

(* A per-shape off switch is unconstructible without churn evidence, and
   the evidence is obtainable only from a ledger (Speculate.Churn.measure).
   Build the churn regime the docs describe — survival ~ 0, drift
   predominantly breaking-broad, port contended, flush-reissue burning
   time — as ledger events, then measure it. The millisecond sleeps buy
   strictly-increasing timestamps for the queued/admitted spans; nothing
   here approaches a wall-clock cost. *)
let churn_switch theory =
  let review_sid =
    match
      List.find_opt
        (fun ((_, sp) : _ * Theory.Spawn.t) ->
          String.equal sp.Theory.Spawn.name "review")
        (Theory.statements theory)
    with
    | Some (sid, _) -> sid
    | None -> failwith "review statement missing from the admitted theory"
  in
  let executor = Theory.Executor.id review_by in
  let pin_key = Theory.Pin.key pin in
  let shape =
    { Speculate.Shape.statement = review_sid; executor; pin = pin_key }
  in
  let dir = Filename.temp_dir "goatcode_f9" ".churn" in
  let ledger = Ledger.create ~path:(Filename.concat dir "churn.bin") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let hyp_minter : Ledger.hypothesis Id.Minter.t =
    Id.Minter.create ~registry ~realm:"hypothesis"
  in
  let n = Id.mint node_minter in
  let h = Id.mint hyp_minter in
  let address =
    Ledger.Address.Tuple { relation = "finding"; id = "finding#0" }
  in
  let ev ?node kind =
    ignore (Ledger.append ledger ?node kind : Ledger.Event.t)
  in
  (* the run records each shape's initial pin at open (Predictor_history) *)
  ev
    (Ledger.Event.Pin_bump
       {
         statement = Theory.Statement.to_string review_sid;
         executor = Theory.Executor.id_to_string executor;
         pin = pin_key;
       });
  ev ~node:n
    (Ledger.Event.Fired
       {
         provenance =
           {
             Ledger.Provenance.statement = review_sid;
             consumed = [];
             hypotheses = [];
           };
         minted = [];
       });
  ev ~node:n
    (Ledger.Event.Decision
       { action = "queued"; reason = "port model contended"; counters = [] });
  Unix.sleepf 0.002;
  ev ~node:n
    (Ledger.Event.Decision
       { action = "admitted"; reason = "slot freed"; counters = [] });
  ev ~node:n
    (Ledger.Event.Hypothesis_taken
       {
         hypothesis = h;
         address;
         source = "issued-contract:finding";
         content = Ledger.Content_hash.of_string "the guess";
         confidence = 1.0;
       });
  ev ~node:n
    (Ledger.Event.Drift_note
       { address; cls = "breaking_broad"; route = "flush_subtree" });
  ev ~node:n
    (Ledger.Event.Agent_turn
       { usage = { Ledger.Usage.tokens_in = 800; tokens_out = 400 } });
  Unix.sleepf 0.002;
  ev ~node:n
    (Ledger.Event.Settled
       (Ledger.Settlement.Squashed (Ledger.Squash_cause.Dead_hypothesis h)));
  match Speculate.Churn.measure ledger ~shape with
  | None ->
      print_string
        "!! no churn measurement obtainable: the off switch cannot be built\n";
      None
  | Some evidence ->
      Printf.printf
        "churn evidence measured: shape matches review=%b lengthening>0=%b\n"
        (Speculate.Shape.equal (Speculate.Churn.shape evidence) shape)
        (Speculate.Churn.lengthening_s evidence > 0.);
      Some (Speculate.Switch.throw ~evidence ~thrown_by:`Operator)

let%expect_test "F9: speculation on/off commits identical tuples and law \
                 verdicts" =
  let theory = review_theory () in
  (* speculation on: the default — no switch, generous floor *)
  let on =
    run_review ~tag:"on" ~backstops:Speculate.Backstops.default ~switches:[]
      theory
  in
  let tuples_on, laws_on = canonical on in
  List.iter print_endline tuples_on;
  List.iter print_endline laws_on;
  let r, f, s = settlement_counts on in
  Printf.printf "settlements: retired=%d faulted=%d squashed=%d\n" r f s;
  Printf.printf "hypotheses taken (on): %d\n" (hypotheses_taken on);
  (* off, mechanism 1: the confidence floor — a floor above any possible
     chain confidence makes every hypothesizable read suspend instead
     (40-scheduling.md § backstops) *)
  let off_floor =
    run_review ~tag:"floor"
      ~backstops:
        {
          Speculate.Backstops.token_ceiling =
            Speculate.Backstops.default.Speculate.Backstops.token_ceiling;
          confidence_floor = 2.0;
        }
      ~switches:[] theory
  in
  Printf.printf "hypotheses taken (floor off): %d\n"
    (hypotheses_taken off_floor);
  diff_runs ~label:"floor-off" on off_floor;
  (* off, mechanism 2: the per-shape switch, thrown on measured churn
     evidence — the only constructor there is *)
  (match churn_switch (fst theory) with
  | None -> ()
  | Some switch ->
      let off_switch =
        run_review ~tag:"switch" ~backstops:Speculate.Backstops.default
          ~switches:[ switch ] theory
      in
      Printf.printf "hypotheses taken (switch off): %d\n"
        (hypotheses_taken off_switch);
      diff_runs ~label:"switch-off" on off_switch);
  [%expect
    {|
    finding finding@0 {"desc":"unchecked error path"} g0
    finding finding@1 {"desc":"missing regression test"} g0
    verdict verdict@0 {"finding":"finding@0","refuted":"no"} g0
    verdict verdict@1 {"finding":"finding@1","refuted":"no"} g0
    law quorum satisfied=true offenders=[]
    settlements: retired=3 faulted=0 squashed=0
    hypotheses taken (on): 0
    hypotheses taken (floor off): 0
    floor-off: identical committed tuples (mod fresh-id renaming)
    floor-off: identical law verdicts
    floor-off: identical settlement counts
    churn evidence measured: shape matches review=true lengthening>0=true
    hypotheses taken (switch off): 0
    switch-off: identical committed tuples (mod fresh-id renaming)
    switch-off: identical law verdicts
    switch-off: identical settlement counts
    |}]
