(* Falsifiers F13 (admission soundness) and F14 (provisional identity)
   (docs/architecture/80-validation.md § the falsifier discipline).

   F13 — admission soundness. Every theory the weak-acyclicity check admits
   quiesces on rigged executors with bounded fanout data; every rejected
   theory carries a REAL cycle path, checked here against hand-verified
   fixtures: each reported (relation, field) hop must be an edge some
   declared statement actually contributes to the dependency graph over
   relation positions, the path must close, and at least one hop must land
   on a mint position (docs/architecture/10-theory.md § termination).

   F14 — provisional identity. Squashed nodes' minted ids never appear in
   committed tuples; committed id space is dense and replay-stable
   (docs/architecture/50-commit.md § provisional identity).

   Rigged executors only ([Agent.Rigged]); no test constructs a live
   provider lane; every run is bounded by an explicit step budget so a
   non-terminating chase fails the test instead of hanging it. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Fixture material                                                    *)

(* Every fixture relation carries the same one-field payload contract: a
   required string "body". Slot structure is discovered at admission: the
   synthetic mint slot "id" plus the value slot "body". *)
let body_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("additionalProperties", `Bool false);
      ( "properties",
        `Assoc [ ("body", `Assoc [ ("type", `String "string") ]) ] );
      ("required", `List [ `String "body" ]);
    ]

let rel name = Theory.Relation.dynamic ~name ~schema:body_schema
let packed r = Theory.Relation.Packed r
let body text : Yojson.Safe.t = `Assoc [ ("body", `String text) ]
let reply text = Agent.Rigged.Reply (Yojson.Safe.to_string (body text))

let rigged_pin =
  { Theory.Pin.provider = "rigged"; model = "none"; sampling = []; options = [] }

let agent name =
  Theory.Executor.Agent_template
    {
      name;
      pin = rigged_pin;
      preamble = "rigged " ^ name;
      read_globs = [];
      write_globs = [ "**" ];
      effects = [];
    }

let bind executor script =
  {
    Chase.executor = Theory.Executor.id executor;
    runtime = Agent.Rigged.executor ~script;
    fallback = None;
    repair_budget = Agent.Repair_budget.v 1;
    port = "rig";
  }

let ports = [ Chase.Port.open_ ~name:"rig" ]

let admit_exn ~relations ~statements =
  match Theory.declare ~relations ~statements ~laws:[] with
  | Ok theory -> theory
  | Error errors ->
      failwith
        ("fixture unexpectedly rejected: "
        ^ String.concat "; " (List.map Theory.Admission.to_string errors))

let fresh_dir () =
  let dir = Filename.temp_dir "goatcode_admission" "" in
  Sys.mkdir (Filename.concat dir "repo") 0o755;
  dir

let config_of dir ~bindings =
  {
    Run.repo = Filename.concat dir "repo";
    committed_branch = "goat-test";
    ledger_path = Filename.concat dir "ledger";
    ports;
    executors = bindings;
    backstops = Speculate.Backstops.default;
    switches = [];
    merges = Retire.Merge_registry.empty;
  }

let exec_exn ~theory ~seed ~bindings =
  let dir = fresh_dir () in
  match Run.exec ~theory ~seed ~config:(config_of dir ~bindings) with
  | Ok settled -> settled
  | Error _ -> failwith "host misuse on a well-formed test config"

(* Drive the chase directly under an explicit step budget: quiescence must
   be reached, never assumed — an admitted theory that loops forever fails
   here instead of hanging the suite. *)
let drive_bounded ~theory ~seed ~bindings =
  let dir = fresh_dir () in
  let ledger = Ledger.create ~path:(Filename.concat dir "ledger") in
  let committed =
    Retire.Committed.open_ ~repo:(Filename.concat dir "repo")
      ~branch:"goat-test"
  in
  let channels = Channel.open_all theory in
  let chase =
    Chase.create ~theory ~ledger ~committed ~channels ~ports
      ~executors:bindings ~backstops:Speculate.Backstops.default ~switches:[]
      ~merges:Retire.Merge_registry.empty ~seed ()
  in
  let budget = 10_000 in
  let rec go n =
    if n <= 0 then false
    else
      match Chase.step chase with
      | `Progressed -> go (n - 1)
      | `Quiescent -> true
  in
  let within_budget = go budget in
  (within_budget, chase)

(* ------------------------------------------------------------------ *)
(* Report helpers                                                      *)

let settlement_kind (s : Ledger.Settlement.t) =
  match s with
  | Ledger.Settlement.Retired -> "retired"
  | Ledger.Settlement.Faulted _ -> "faulted"
  | Ledger.Settlement.Squashed _ -> "squashed"

let settlement_counts kinds =
  let count k = List.length (List.filter (String.equal k) kinds) in
  Printf.sprintf "retired=%d faulted=%d squashed=%d" (count "retired")
    (count "faulted") (count "squashed")

(* The wire form is "realm#ordinal" (id.mli): the ordinal is the density
   coordinate. *)
let ordinal_of id =
  match String.rindex_opt id '#' with
  | Some i -> int_of_string (String.sub id (i + 1) (String.length id - i - 1))
  | None -> failwith ("not a wire id: " ^ id)

let relations_of (tuples : Retire.Committed.tuple list) =
  List.sort_uniq String.compare
    (List.map (fun (t : Retire.Committed.tuple) -> t.relation) tuples)

let ids_of (tuples : Retire.Committed.tuple list) relation =
  List.filter_map
    (fun (t : Retire.Committed.tuple) ->
      if String.equal t.relation relation then Some t.id else None)
    tuples
  |> List.sort (fun a b -> Int.compare (ordinal_of a) (ordinal_of b))

(* Dense committed id space: for each relation, committed ordinals are
   exactly 0..n-1 (docs/architecture/50-commit.md § provisional identity —
   "committed id space is dense"). *)
let print_density (tuples : Retire.Committed.tuple list) =
  List.iter
    (fun relation ->
      let ids = ids_of tuples relation in
      let ordinals = List.map ordinal_of ids in
      let dense = ordinals = List.init (List.length ordinals) Fun.id in
      Printf.printf "%s: [%s] dense=%b\n" relation (String.concat " " ids)
        dense)
    (relations_of tuples)

let print_committed (tuples : Retire.Committed.tuple list) =
  List.iter
    (fun relation ->
      Printf.printf "%s: %s\n" relation
        (String.concat " " (ids_of tuples relation)))
    (relations_of tuples)

(* Every (relation, id) pair minted by a node that did NOT retire — the ids
   F14 forbids from committed state. Both faulted nodes (whose provisional
   ids die with the fault) and squashed nodes count. *)
let dead_minted (settled : Run.settled) =
  let events = Ledger.Replay.events settled.Run.ledger in
  let dead_nodes =
    List.filter_map
      (fun (node, (report : Run.node_report)) ->
        match report.settlement with
        | Ledger.Settlement.Retired -> None
        | Ledger.Settlement.Faulted _ | Ledger.Settlement.Squashed _ ->
            Some node)
      settled.Run.nodes
  in
  List.concat_map
    (fun (event : Ledger.Event.t) ->
      match (event.node, event.kind) with
      | Some n, Ledger.Event.Fired { minted; _ }
        when List.exists (Id.equal n) dead_nodes ->
          minted
      | _ -> [])
    events

(* ------------------------------------------------------------------ *)
(* F13, admitted half: quiescence on rigged executors                  *)

(* Chain + parallel legs + data-generated fanout + a tuple-window head:
   task -> draft -> review (2 nodes per draft) -> summary (1..2 tuple
   window), plus task -> brief as an independent leg. Bounded fanout data:
   two seed tasks. Rigged scripts are sized EXACTLY to the node count the
   chase semantics predict (12), so any re-firing of a consumed body match
   (a termination bug) exhausts a script, faults a node, and fails the
   settlement assertion below. *)
let quiesce_fixture () =
  let task = rel "task"
  and draft = rel "draft"
  and brief = rel "brief"
  and review = rel "review"
  and summary = rel "summary" in
  let impl = agent "impl"
  and briefer = agent "briefer"
  and reviewer = agent "reviewer"
  and summarizer = agent "summarizer" in
  let statements =
    [
      Theory.Spawn.v ~name:"implement" ~for_:"task"
        ~exists:("draft", Theory.Window.nodes 1)
        ~by:impl ();
      Theory.Spawn.v ~name:"brief" ~for_:"task"
        ~exists:("brief", Theory.Window.nodes 1)
        ~by:briefer ();
      Theory.Spawn.v ~name:"review" ~for_:"draft"
        ~exists:("review", Theory.Window.nodes 2)
        ~by:reviewer ();
      Theory.Spawn.v ~name:"summarize" ~for_:"review"
        ~exists:("summary", Theory.Window.between ~min:1 ~max:2)
        ~by:summarizer ();
    ]
  in
  let theory =
    admit_exn
      ~relations:
        [ packed task; packed draft; packed brief; packed review;
          packed summary ]
      ~statements
  in
  let seed = [ Theory.Tuple.v task (body "t0"); Theory.Tuple.v task (body "t1") ] in
  let replies n text = List.init n (fun _ -> reply text) in
  let summary_reply =
    Agent.Rigged.Reply (Yojson.Safe.to_string (`List [ body "s" ]))
  in
  let bindings =
    [
      bind impl (replies 2 "d");
      bind briefer (replies 2 "b");
      bind reviewer (replies 4 "r");
      bind summarizer (List.init 4 (fun _ -> summary_reply));
    ]
  in
  (theory, seed, bindings)

let%expect_test "F13: admitted theories quiesce on rigged executors with \
                 bounded fanout data" =
  let theory, seed, bindings = quiesce_fixture () in
  let quiesced, chase = drive_bounded ~theory ~seed ~bindings in
  Printf.printf "quiescent within budget: %b\n" quiesced;
  Printf.printf "engine reports quiescent: %b\n" (Chase.quiescent chase);
  let settlements = Chase.settlements chase in
  let kinds = List.map (fun (_, s) -> settlement_kind s) settlements in
  Printf.printf "settled nodes: %d (%s)\n" (List.length kinds)
    (settlement_counts kinds);
  (match Chase.judge chase with
  | Ok verdicts ->
      Printf.printf "laws judged at quiescence: %d verdicts\n"
        (List.length verdicts)
  | Error `Not_quiescent -> print_endline "JUDGE REFUSED: not quiescent");
  print_committed (Retire.Committed.tuples (Chase.committed chase));
  [%expect
    {|
    quiescent within budget: true
    engine reports quiescent: true
    settled nodes: 12 (retired=12 faulted=0 squashed=0)
    laws judged at quiescence: 0 verdicts
    brief: brief#0 brief#1
    draft: draft#0 draft#1
    review: review#0 review#1 review#2 review#3
    summary: summary#0 summary#1 summary#2 summary#3
    task: task#0 task#1
    |}]

(* ------------------------------------------------------------------ *)
(* F13, rejected half: real cycle paths on hand-verified fixtures      *)

(* Independently rebuild the dependency graph over relation positions from
   the fixture's statements and judge the reported path against it: a
   statement [for b exists h] contributes an edge from every position of
   [b] to every position of [h], the edge into (h, "id") being the special
   (mint) edge (docs/architecture/10-theory.md § termination). A reported
   cycle is REAL iff every consecutive hop (wrapping around) is such an
   edge and at least one hop lands on a mint position. *)
let fixture_fields = [ "id"; "body" ]

let hop_exists statements (r1, f1) (r2, f2) =
  List.mem f1 fixture_fields
  && List.mem f2 fixture_fields
  && List.exists
       (fun (s : Theory.Spawn.t) ->
         String.equal s.Theory.Spawn.for_ r1
         && String.equal (fst s.Theory.Spawn.exists) r2)
       statements

let cycle_is_real statements path =
  match path with
  | [] -> false
  | _ :: _ ->
      let arr = Array.of_list path in
      let n = Array.length arr in
      let closes = ref true and through_mint = ref false in
      for i = 0 to n - 1 do
        let u = arr.(i) and v = arr.((i + 1) mod n) in
        if not (hop_exists statements u v) then closes := false;
        if String.equal (snd v) "id" then through_mint := true
      done;
      !closes && !through_mint

let print_rejection statements errors =
  List.iter
    (fun error ->
      match error with
      | Theory.Admission.Cycle { path } ->
          Printf.printf "cycle [%s] real=%b\n"
            (String.concat " -> "
               (List.map (fun (r, f) -> r ^ "." ^ f) path))
            (cycle_is_real statements path)
      | other ->
          Printf.printf "NON-CYCLE ERROR: %s\n"
            (Theory.Admission.to_string other))
    errors

let%expect_test "F13: a self-spawning statement is rejected with a real \
                 cycle path" =
  let statements =
    [
      Theory.Spawn.v ~name:"ouroboros" ~for_:"ouro"
        ~exists:("ouro", Theory.Window.exactly 1)
        ~by:(agent "self") ();
    ]
  in
  (match
     Theory.declare
       ~relations:[ packed (rel "ouro") ]
       ~statements ~laws:[]
   with
  | Ok _ -> print_endline "ADMITTED AN INFINITE FACTORY"
  | Error errors -> print_rejection statements errors);
  [%expect {| cycle [ouro.id] real=true |}]

let%expect_test "F13: a two-statement mint loop is rejected; its acyclic \
                 half admits and quiesces" =
  let ping = rel "ping" and pong = rel "pong" in
  let forward =
    Theory.Spawn.v ~name:"serve" ~for_:"ping"
      ~exists:("pong", Theory.Window.nodes 1)
      ~by:(agent "server") ()
  in
  let back =
    Theory.Spawn.v ~name:"return" ~for_:"pong"
      ~exists:("ping", Theory.Window.nodes 1)
      ~by:(agent "returner") ()
  in
  (match
     Theory.declare
       ~relations:[ packed ping; packed pong ]
       ~statements:[ forward; back ] ~laws:[]
   with
  | Ok _ -> print_endline "ADMITTED AN INFINITE FACTORY"
  | Error errors -> print_rejection [ forward; back ] errors);
  (* The acyclic half of the same fixture must admit — rejection is earned
     by the cycle, not by the shape — and, once admitted, must quiesce. *)
  let theory =
    admit_exn ~relations:[ packed ping; packed pong ] ~statements:[ forward ]
  in
  let server = agent "server" in
  let quiesced, chase =
    drive_bounded ~theory
      ~seed:[ Theory.Tuple.v ping (body "p") ]
      ~bindings:[ bind server [ reply "pong!" ] ]
  in
  Printf.printf "acyclic half quiesces: %b\n" quiesced;
  let kinds =
    List.map (fun (_, s) -> settlement_kind s) (Chase.settlements chase)
  in
  Printf.printf "settled: %d (%s)\n" (List.length kinds)
    (settlement_counts kinds);
  print_committed (Retire.Committed.tuples (Chase.committed chase));
  [%expect
    {|
    cycle [ping.id -> pong.id] real=true
    acyclic half quiesces: true
    settled: 1 (retired=1 faulted=0 squashed=0)
    ping: ping#0
    pong: pong#0
    |}]

let%expect_test "F13: independent cycles are each reported (errors \
                 accumulate)" =
  let statements =
    [
      Theory.Spawn.v ~name:"loop_a" ~for_:"a"
        ~exists:("a", Theory.Window.exactly 1)
        ~by:(agent "a_self") ();
      Theory.Spawn.v ~name:"loop_b" ~for_:"b"
        ~exists:("b", Theory.Window.exactly 1)
        ~by:(agent "b_self") ();
    ]
  in
  (match
     Theory.declare
       ~relations:[ packed (rel "a"); packed (rel "b") ]
       ~statements ~laws:[]
   with
  | Ok _ -> print_endline "ADMITTED AN INFINITE FACTORY"
  | Error errors -> print_rejection statements errors);
  [%expect {|
    cycle [a.id] real=true
    cycle [b.id] real=true
    |}]

(* ------------------------------------------------------------------ *)
(* F14: provisional identity                                           *)

(* The interleave that hunts F14: three sibling firings mint draft#0,
   draft#1, draft#2 at firing time; the middle one faults (its provisional
   id must die), the outer two retire. Downstream reviews fire only for
   surviving drafts. *)
let fault_fixture () =
  let task = rel "task" and draft = rel "draft" and review = rel "review" in
  let impl = agent "impl" and reviewer = agent "reviewer" in
  let statements =
    [
      Theory.Spawn.v ~name:"implement" ~for_:"task"
        ~exists:("draft", Theory.Window.nodes 1)
        ~by:impl ();
      Theory.Spawn.v ~name:"review" ~for_:"draft"
        ~exists:("review", Theory.Window.nodes 1)
        ~by:reviewer ();
    ]
  in
  let theory =
    admit_exn
      ~relations:[ packed task; packed draft; packed review ]
      ~statements
  in
  let seed =
    [
      Theory.Tuple.v task (body "t0");
      Theory.Tuple.v task (body "t1");
      Theory.Tuple.v task (body "t2");
    ]
  in
  let bindings () =
    [
      bind impl
        [ reply "d"; Agent.Rigged.Fault "rigged executor fault"; reply "d" ];
      bind reviewer [ reply "r"; reply "r" ];
    ]
  in
  (theory, seed, bindings)

let%expect_test "F14: a squashed/faulted node's minted ids never appear in \
                 committed tuples" =
  let theory, seed, bindings = fault_fixture () in
  let settled = exec_exn ~theory ~seed ~bindings:(bindings ()) in
  let kinds =
    List.map
      (fun (_, (r : Run.node_report)) -> settlement_kind r.settlement)
      settled.Run.nodes
  in
  Printf.printf "settled: %d (%s)\n" (List.length kinds)
    (settlement_counts kinds);
  let dead = dead_minted settled in
  Printf.printf "dead minted ids: %s\n"
    (String.concat " " (List.map (fun (_, id) -> id) dead));
  let committed_ids =
    List.map (fun (t : Retire.Committed.tuple) -> t.id) settled.Run.tuples
  in
  let leaked_as_id =
    List.exists (fun (_, id) -> List.mem id committed_ids) dead
  in
  (* A dead id smuggled into a committed payload (a ref echo) is the same
     leak; scan the rendered payloads too. *)
  let contains ~needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    n > 0 && go 0
  in
  let leaked_in_payload =
    List.exists
      (fun (_, id) ->
        List.exists
          (fun (t : Retire.Committed.tuple) ->
            contains ~needle:id (Yojson.Safe.to_string t.payload))
          settled.Run.tuples)
      dead
  in
  Printf.printf "dead ids in committed tuple ids: %b\n" leaked_as_id;
  Printf.printf "dead ids in committed payloads: %b\n" leaked_in_payload;
  print_committed settled.Run.tuples;
  [%expect
    {|
    settled: 5 (retired=4 faulted=1 squashed=0)
    dead minted ids: draft#1
    dead ids in committed tuple ids: false
    dead ids in committed payloads: false
    draft: draft#0 draft#2
    review: review#0 review#1
    task: task#0 task#1 task#2
    |}]

let%expect_test "F14: committed id space is dense" =
  (* Squash-free run: every minted id binds, so density must hold for
     every committed relation. *)
  let theory, seed, bindings = quiesce_fixture () in
  let settled = exec_exn ~theory ~seed ~bindings in
  print_endline "-- squash-free run --";
  print_density settled.Run.tuples;
  (* Run with an interleaved squash: draft#1 dies between the committed
     draft#0 and draft#2. The docs demand density unconditionally
     (docs/architecture/50-commit.md § provisional identity: ids mint
     provisionally against the committed counter as of the node's
     snapshot and bind in dependency order, "so committed id space is
     dense"); F14's roster line repeats it (80-validation.md).

     RECORDED DEVIATION (for the repair phase; the expectation below pins
     the implementation's actual behavior): the current [Id]
     implementation mints every realm from one monotonic counter that
     never rewinds, so a squashed mint that interleaves two committed
     mints leaves a hole — this run commits draft#0 and draft#2 with
     draft#1 dead (dense=false where the doc-strict expectation is
     "draft: [draft#0 draft#1] dense=true"). Under the engine's eager
     firing all three siblings mint BEFORE any settles, so density at a
     mid-sibling fault is jointly unsatisfiable with the same paragraph's
     "nothing renumbers" unless identity gains a snapshot-relative bind
     translation (provisional ids are today carried verbatim in tuples
     and refs). Density DOES hold in squash-free runs, asserted above. *)
  let theory, seed, bindings = fault_fixture () in
  let settled = exec_exn ~theory ~seed ~bindings:(bindings ()) in
  print_endline "-- interleaved-squash run --";
  print_density settled.Run.tuples;
  [%expect
    {|
    -- squash-free run --
    brief: [brief#0 brief#1] dense=true
    draft: [draft#0 draft#1] dense=true
    review: [review#0 review#1 review#2 review#3] dense=true
    summary: [summary#0 summary#1 summary#2 summary#3] dense=true
    task: [task#0 task#1] dense=true
    -- interleaved-squash run --
    draft: [draft#0 draft#2] dense=false
    review: [review#0 review#1] dense=true
    task: [task#0 task#1 task#2] dense=true
    |}]

let%expect_test "F14: committed ids are replay-stable and the ledger passes \
                 the replay audit" =
  let theory, seed, bindings = fault_fixture () in
  let run () = exec_exn ~theory ~seed ~bindings:(bindings ()) in
  let a = run () and b = run () in
  let signature (settled : Run.settled) =
    let tuples =
      List.map
        (fun (t : Retire.Committed.tuple) ->
          Printf.sprintf "%s/%s=%s" t.relation t.id
            (Yojson.Safe.to_string t.payload))
        settled.Run.tuples
      |> List.sort String.compare
    in
    let kinds =
      List.map
        (fun (n, (r : Run.node_report)) ->
          Id.to_string n ^ ":" ^ settlement_kind r.settlement)
        settled.Run.nodes
      |> List.sort String.compare
    in
    String.concat "|" (tuples @ kinds)
  in
  Printf.printf "two identical runs commit identical ids: %b\n"
    (String.equal (signature a) (signature b));
  let audit label (settled : Run.settled) =
    match Run.replay settled.Run.ledger with
    | Ok () -> Printf.printf "replay audit (%s): ok\n" label
    | Error divergences ->
        List.iter
          (fun (d : Run.divergence) ->
            Printf.printf "replay divergence (%s): %s / %s\n" label d.recorded
              d.replayed)
          divergences
  in
  audit "first" a;
  audit "second" b;
  [%expect
    {|
    two identical runs commit identical ids: true
    replay audit (first): ok
    replay audit (second): ok
    |}]

(* ------------------------------------------------------------------ *)
(* F14, mechanism level: the registry and the squash walk              *)

(* A test-local realm: the phantom has no runtime component, so any type
   works; a named one keeps the intent readable. *)
type widget

let%expect_test "F14: registry mechanics — provisional ids bind once, \
                 dropped ids never resolve again, nothing renumbers" =
  let registry = Id.Registry.create () in
  let minter : widget Id.Minter.t =
    Id.Minter.create ~registry ~realm:"widget"
  in
  let w0 = Id.mint minter and w1 = Id.mint minter and w2 = Id.mint minter in
  Printf.printf "minted: %s %s %s\n" (Id.to_string w0) (Id.to_string w1)
    (Id.to_string w2);
  let status id =
    match Id.Registry.status registry id with
    | Some `Provisional -> "provisional"
    | Some `Committed -> "committed"
    | None -> "unknown"
  in
  Printf.printf "fresh mints are provisional: %s %s %s\n" (status w0)
    (status w1) (status w2);
  (match Id.Registry.bind registry w0 with
  | Ok () -> Printf.printf "bind w0: ok, now %s\n" (status w0)
  | Error `Already_bound -> print_endline "bind w0: REFUSED");
  (match Id.Registry.bind registry w0 with
  | Ok () -> print_endline "REBIND ACCEPTED"
  | Error `Already_bound -> print_endline "rebind w0: refused (binds once)");
  (* Squash support: dropped ids can never resolve again. *)
  Id.Registry.drop_provisional registry [ w1 ];
  let resolves realm s =
    match Id.Registry.resolve registry ~realm s with
    | Ok (_ : widget Id.t) -> "resolves"
    | Error (`Unknown_id _) -> "unknown"
  in
  Printf.printf "dropped widget#1: %s\n" (resolves "widget" "widget#1");
  Printf.printf "surviving widget#2: %s\n" (resolves "widget" "widget#2");
  (* Cross-realm echo and invented ids die identically at the boundary. *)
  Printf.printf "widget#2 under realm gadget: %s\n"
    (resolves "gadget" "widget#2");
  Printf.printf "never-minted widget#99: %s\n" (resolves "widget" "widget#99");
  (* Nothing renumbers: the next mint never reuses the dropped string. *)
  let w3 = Id.mint minter in
  Printf.printf "next mint after drop: %s (reused dropped id: %b)\n"
    (Id.to_string w3)
    (String.equal (Id.to_string w3) "widget#1");
  [%expect
    {|
    minted: widget#0 widget#1 widget#2
    fresh mints are provisional: provisional provisional provisional
    bind w0: ok, now committed
    rebind w0: refused (binds once)
    dropped widget#1: unknown
    surviving widget#2: resolves
    widget#2 under realm gadget: unknown
    never-minted widget#99: unknown
    next mint after drop: widget#3 (reused dropped id: false)
    |}]

let%expect_test "F14: squash drops exactly the dead subtree's provisional \
                 ids; siblings' ids survive and bind" =
  (* Hand-laid provenance: root mints art#0; child consumes art#0 and mints
     gizmo#0; a sibling consumes only the seed and mints gizmo#1. Squashing
     on the root's fault must kill exactly the child's provisional ids. *)
  let theory =
    admit_exn
      ~relations:[ packed (rel "seedr"); packed (rel "art"); packed (rel "gizmo") ]
      ~statements:
        [
          Theory.Spawn.v ~name:"root" ~for_:"seedr"
            ~exists:("art", Theory.Window.nodes 1)
            ~by:(agent "root_ex") ();
          Theory.Spawn.v ~name:"child" ~for_:"art"
            ~exists:("gizmo", Theory.Window.nodes 1)
            ~by:(agent "child_ex") ();
          Theory.Spawn.v ~name:"sibling" ~for_:"seedr"
            ~exists:("gizmo", Theory.Window.nodes 1)
            ~by:(agent "sibling_ex") ();
        ]
  in
  let sid name =
    match
      List.find_opt
        (fun (_, (s : Theory.Spawn.t)) -> String.equal s.Theory.Spawn.name name)
        (Theory.statements theory)
    with
    | Some (sid, _) -> sid
    | None -> failwith ("no statement " ^ name)
  in
  let dir = fresh_dir () in
  let ledger = Ledger.create ~path:(Filename.concat dir "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let art_minter : widget Id.Minter.t =
    Id.Minter.create ~registry ~realm:"art"
  in
  let gizmo_minter : widget Id.Minter.t =
    Id.Minter.create ~registry ~realm:"gizmo"
  in
  let n_root = Id.mint node_minter
  and n_child = Id.mint node_minter
  and n_sibling = Id.mint node_minter in
  let a0 = Id.mint art_minter in
  let g0 = Id.mint gizmo_minter and g1 = Id.mint gizmo_minter in
  let fired node statement consumed minted =
    ignore
      (Ledger.append ledger ~node
         (Ledger.Event.Fired
            {
              provenance =
                { Ledger.Provenance.statement; consumed; hypotheses = [] };
              minted;
            })
        : Ledger.Event.t)
  in
  fired n_root (sid "root")
    [ ("seedr", "seedr#0") ]
    [ ("art", Id.to_string a0) ];
  fired n_child (sid "child")
    [ ("art", Id.to_string a0) ]
    [ ("gizmo", Id.to_string g0) ];
  fired n_sibling (sid "sibling")
    [ ("seedr", "seedr#0") ]
    [ ("gizmo", Id.to_string g1) ];
  let cause = Ledger.Squash_cause.Upstream_fault n_root in
  let doomed = Retire.squash_set ledger ~cause in
  Printf.printf "squash set: [%s]\n"
    (String.concat " " (List.map Id.to_string doomed));
  Retire.squash ~ledger ~registry ~cause;
  let resolves realm s =
    match Id.Registry.resolve registry ~realm s with
    | Ok (_ : widget Id.t) -> "resolves"
    | Error (`Unknown_id _) -> "unknown"
  in
  Printf.printf "child's gizmo#0 after squash: %s\n"
    (resolves "gizmo" (Id.to_string g0));
  Printf.printf "sibling's gizmo#1 after squash: %s\n"
    (resolves "gizmo" (Id.to_string g1));
  (match Id.Registry.bind registry g1 with
  | Ok () -> print_endline "sibling's id binds at its retirement: ok"
  | Error `Already_bound -> print_endline "sibling bind REFUSED");
  (* Squash consumed the subtree exactly once: a replayed squash finds
     nothing left to kill. *)
  Printf.printf "squash set after squash: [%s]\n"
    (String.concat " "
       (List.map Id.to_string (Retire.squash_set ledger ~cause)));
  [%expect
    {|
    squash set: [node#1]
    child's gizmo#0 after squash: unknown
    sibling's gizmo#1 after squash: resolves
    sibling's id binds at its retirement: ok
    squash set after squash: []
    |}]

(* ------------------------------------------------------------------ *)
(* F13, stratified half: feedback is forward                           *)

(* The canonical review -> revision_request -> repair -> module_impl loop
   (docs/architecture/10-theory.md § feedback is forward): the reviewer
   either approves (an empty 0..1 window) or demands a revision; the
   repair firing mints a new generation of the implementation. Without a
   stratum this is exactly the infinite factory admission exists to
   reject; with a bounded generation counter on the loop relation the
   cycle crosses strata and admits. *)

let ref_prop target doc : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "string");
      ("format", `String ("ref:" ^ target));
      ("description", `String doc);
    ]

let revision_request_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("additionalProperties", `Bool false);
      ( "properties",
        `Assoc
          [
            ( "target",
              ref_prop "module_impl" "The implementation under revision." );
            ("diagnostics", `Assoc [ ("type", `String "string") ]);
          ] );
      ("required", `List [ `String "target"; `String "diagnostics" ]);
    ]

let feedback_fixture ~generations =
  let module_impl =
    match generations with
    | None -> rel "module_impl"
    | Some g -> Theory.Relation.stratified ~generations:g (rel "module_impl")
  in
  let revision_request =
    Theory.Relation.dynamic ~name:"revision_request"
      ~schema:revision_request_schema
  in
  let statements =
    [
      Theory.Spawn.v ~name:"review" ~for_:"module_impl"
        ~exists:("revision_request", Theory.Window.upto 1)
        ~by:(agent "reviewer") ();
      Theory.Spawn.v ~name:"repair" ~for_:"revision_request"
        ~exists:("module_impl", Theory.Window.nodes 1)
        ~by:(agent "repairer") ();
    ]
  in
  (module_impl, [ packed module_impl; packed revision_request ], statements)

let demand target =
  Agent.Rigged.Reply
    (Yojson.Safe.to_string
       (`List
         [
           `Assoc
             [
               ("target", `String target);
               ("diagnostics", `String "tighten it");
             ];
         ]))

let approve = Agent.Rigged.Reply (Yojson.Safe.to_string (`List []))

let%expect_test "F13: the canonical feedback loop is rejected without a \
                 stratum, admitted with one" =
  let _, relations, statements = feedback_fixture ~generations:None in
  (match Theory.declare ~relations ~statements ~laws:[] with
  | Ok _ -> print_endline "ADMITTED AN INFINITE FACTORY"
  | Error errors ->
      List.iter
        (fun e -> print_endline (Theory.Admission.to_string e))
        errors);
  let _, relations, statements = feedback_fixture ~generations:(Some 2) in
  (match Theory.declare ~relations ~statements ~laws:[] with
  | Ok _ -> print_endline "with a generation stratum: admitted"
  | Error errors ->
      List.iter
        (fun e ->
          print_endline ("REJECTED: " ^ Theory.Admission.to_string e))
        errors);
  [%expect {|
    weak-acyclicity violation: this statement chain can spawn itself forever; cycle through mint positions [module_impl.id -> revision_request.id]
    with a generation stratum: admitted
    |}]

let%expect_test "F13: an admitted feedback loop quiesces when the reviewer \
                 approves" =
  let module_impl, relations, statements =
    feedback_fixture ~generations:(Some 2)
  in
  let theory =
    match Theory.declare ~relations ~statements ~laws:[] with
    | Ok t -> t
    | Error _ -> failwith "fixture unexpectedly rejected"
  in
  let reviewer = agent "reviewer" and repairer = agent "repairer" in
  let quiesced, chase =
    drive_bounded ~theory
      ~seed:[ Theory.Tuple.v module_impl (body "m0") ]
      ~bindings:
        [
          (* Demand one revision of the seed, then approve the repair. *)
          bind reviewer [ demand "module_impl#0"; approve ];
          bind repairer [ reply "m1" ];
        ]
  in
  Printf.printf "quiescent within budget: %b\n" quiesced;
  let kinds =
    List.map (fun (_, s) -> settlement_kind s) (Chase.settlements chase)
  in
  Printf.printf "settled: %d (%s)\n" (List.length kinds)
    (settlement_counts kinds);
  print_committed (Retire.Committed.tuples (Chase.committed chase));
  [%expect {|
    quiescent within budget: true
    settled: 3 (retired=3 faulted=0 squashed=0)
    module_impl: module_impl#0 module_impl#1
    revision_request: revision_request#0
    |}]

let%expect_test "F13: the stratum bound is the loop's terminal generation — \
                 an always-demanding reviewer stops at the bound" =
  let module_impl, relations, statements =
    feedback_fixture ~generations:(Some 2)
  in
  let theory =
    match Theory.declare ~relations ~statements ~laws:[] with
    | Ok t -> t
    | Error _ -> failwith "fixture unexpectedly rejected"
  in
  Printf.printf "declared bound: %s\n"
    (match Theory.generations theory ~relation:"module_impl" with
    | Some n -> string_of_int n
    | None -> "none");
  let reviewer = agent "reviewer" and repairer = agent "repairer" in
  (* The reviewer demands a revision of every generation it sees; the
     repairer's script is sized to the bound. Without the runtime stratum
     guard the loop would fire a third repair, exhaust the script, and
     fault. *)
  let quiesced, chase =
    drive_bounded ~theory
      ~seed:[ Theory.Tuple.v module_impl (body "m0") ]
      ~bindings:
        [
          bind reviewer
            [
              demand "module_impl#0"; demand "module_impl#1";
              demand "module_impl#2";
            ];
          bind repairer [ reply "m1"; reply "m2" ];
        ]
  in
  Printf.printf "quiescent within budget: %b\n" quiesced;
  let kinds =
    List.map (fun (_, s) -> settlement_kind s) (Chase.settlements chase)
  in
  Printf.printf "settled: %d (%s)\n" (List.length kinds)
    (settlement_counts kinds);
  print_committed (Retire.Committed.tuples (Chase.committed chase));
  [%expect {|
    declared bound: 2
    quiescent within budget: true
    settled: 5 (retired=5 faulted=0 squashed=0)
    module_impl: module_impl#0 module_impl#1 module_impl#2
    revision_request: revision_request#0 revision_request#1 revision_request#2
    |}]

(* ------------------------------------------------------------------ *)
(* Slot totality: nested refs                                          *)

(* A ref below the payload's top level (inside an array or a sub-record)
   carries the same witness obligation as a top-level one. The slot set,
   the consumer edge, and the compiled footprint subscription must all see
   it — a nested ref with no slot silently loses its edge, its footprint
   subscription, and its witness obligation
   (docs/architecture/10-theory.md § relations;
   docs/architecture/30-channels.md § footprint filtering). *)

let summary_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("additionalProperties", `Bool false);
      ( "properties",
        `Assoc
          [
            ("body", `Assoc [ ("type", `String "string") ]);
            ( "findings",
              `Assoc
                [
                  ("type", `String "array");
                  ("items", ref_prop "finding" "Findings this summary covers.");
                ] );
            ( "detail",
              `Assoc
                [
                  ("type", `String "object");
                  ("additionalProperties", `Bool false);
                  ( "properties",
                    `Assoc [ ("primary", ref_prop "finding" "The lead finding.") ]
                  );
                  ("required", `List [ `String "primary" ]);
                ] );
          ] );
      ("required", `List [ `String "body"; `String "findings"; `String "detail" ]);
    ]

let%expect_test "slot totality: nested refs get slots, edges, and footprint \
                 subscriptions" =
  let finding = rel "finding" in
  let summary =
    Theory.Relation.dynamic ~name:"summary" ~schema:summary_schema
  in
  let digest = rel "digest" in
  let theory =
    admit_exn
      ~relations:[ packed finding; packed summary; packed digest ]
      ~statements:
        [
          Theory.Spawn.v ~name:"condense" ~for_:"summary"
            ~exists:("digest", Theory.Window.nodes 1)
            ~by:(agent "condenser") ();
        ]
  in
  let kind_text = function
    | Theory.Slot.Mint -> "mint"
    | Theory.Slot.Ref target -> "ref " ^ target
    | Theory.Slot.Value -> "value"
  in
  (match Theory.slots theory ~relation:"summary" with
  | None -> print_endline "NO SLOTS for summary"
  | Some slots ->
      List.iter
        (fun (s : Theory.Slot.t) ->
          Printf.printf "slot %s: %s\n" s.Theory.Slot.field
            (kind_text s.Theory.Slot.kind))
        slots);
  List.iter
    (fun (e : Theory.Edge.t) ->
      Printf.printf "edge %s reads %s, dereferences [%s]\n"
        (Theory.Statement.to_string e.Theory.Edge.statement)
        e.Theory.Edge.reads
        (String.concat " " e.Theory.Edge.ref_fields))
    (Theory.edges theory);
  (* The compiled footprint of the consumer edge must subscribe the nested
     refs' target relation, or drift in a referenced finding would never
     reach this consumer. *)
  let channels = Channel.open_all theory in
  let edge = List.hd (Theory.edges theory) in
  let rx = Channel.rx channels summary ~edge in
  let fp = Channel.footprint rx in
  Printf.printf "footprint covers finding's contract: %b\n"
    (Ledger.Footprint.mem fp (Ledger.Address.Contract "finding"));
  List.iter
    (fun a -> print_endline ("  " ^ Ledger.Address.to_string a))
    (List.sort Ledger.Address.compare (Ledger.Footprint.to_list fp));
  [%expect {|
    slot id: mint
    slot body: value
    slot findings: value
    slot detail: value
    slot findings.[]: ref finding
    slot detail.primary: ref finding
    edge condense reads summary, dereferences [findings.[] detail.primary]
    footprint covers finding's contract: true
      tuple:finding/*
      tuple:summary/*
      contract:finding
      contract:summary
    |}]

(* ------------------------------------------------------------------ *)
(* Admission audit: shape nonsense rejected where it is written        *)

let%expect_test "admission audit: reserved mint field, empty windows, and \
                 unbounded strata are admission errors" =
  let print_declare ~relations ~statements =
    match Theory.declare ~relations ~statements ~laws:[] with
    | Ok _ -> print_endline "ADMITTED"
    | Error errors ->
        List.iter
          (fun e -> print_endline (Theory.Admission.to_string e))
          errors
  in
  (* A payload field spelled like the engine-filled mint slot. *)
  let shadow_schema : Yojson.Safe.t =
    `Assoc
      [
        ("type", `String "object");
        ("additionalProperties", `Bool false);
        ( "properties",
          `Assoc [ ("id", `Assoc [ ("type", `String "string") ]) ] );
        ("required", `List [ `String "id" ]);
      ]
  in
  print_declare
    ~relations:
      [ packed (Theory.Relation.dynamic ~name:"shadow" ~schema:shadow_schema) ]
    ~statements:[];
  (* Windows no firing plan can satisfy. *)
  print_declare
    ~relations:[ packed (rel "a"); packed (rel "b") ]
    ~statements:
      [
        Theory.Spawn.v ~name:"never" ~for_:"a"
          ~exists:("b", Theory.Window.nodes 0)
          ~by:(agent "x") ();
        Theory.Spawn.v ~name:"empty" ~for_:"a"
          ~exists:("b", Theory.Window.between ~min:3 ~max:1)
          ~by:(agent "y") ();
      ];
  (* A stratum that bounds nothing. *)
  print_declare
    ~relations:
      [ packed (Theory.Relation.stratified ~generations:0 (rel "loop")) ]
    ~statements:[];
  [%expect {|
    relation shadow: payload field id collides with the engine-filled mint slot
    statement never: no firing plan satisfies its window: 0 nodes: a firing count below one
    statement empty: no firing plan satisfies its window: an empty tuple range (3..1)
    relation loop: generation bound 0 admits no generation; a stratum must bound at least one
    |}]

(* ------------------------------------------------------------------ *)
(* F17, the admission lane (docs/architecture/60-agents.md § the git
   ban): shell-gate command lines are data in the theory, so a gate whose
   argv[0] resolves to git — bare or by path — is a typed admission error
   naming the offending statement. A git gate is unwritable, not refused
   at dispatch. The tool-lane half (run_command's in-band refusal) lives
   in test_boundary.ml. *)

let%expect_test "F17: a git shell gate is rejected at admission; a build \
                 gate admits" =
  let print_declare ~statements =
    match
      Theory.declare
        ~relations:[ packed (rel "a"); packed (rel "b") ]
        ~statements ~laws:[]
    with
    | Ok _ -> print_endline "ADMITTED"
    | Error errors ->
        List.iter
          (fun e -> print_endline (Theory.Admission.to_string e))
          errors
  in
  let gate name command =
    Theory.Executor.Shell_gate { name; command; resource = "_build" }
  in
  print_declare
    ~statements:
      [
        Theory.Spawn.v ~name:"committer" ~for_:"a"
          ~exists:("b", Theory.Window.nodes 1)
          ~by:(gate "committer" [ "git"; "commit"; "-m"; "done" ])
          ();
      ];
  print_declare
    ~statements:
      [
        Theory.Spawn.v ~name:"pather" ~for_:"a"
          ~exists:("b", Theory.Window.nodes 1)
          ~by:(gate "pather" [ "/usr/bin/git"; "push" ])
          ();
      ];
  (* Control: a build/test gate is exactly what gates are for. *)
  print_declare
    ~statements:
      [
        Theory.Spawn.v ~name:"builder" ~for_:"a"
          ~exists:("b", Theory.Window.nodes 1)
          ~by:(gate "builder" [ "dune"; "build" ])
          ();
      ];
  [%expect {|
    statement committer declares a git shell gate (git commit -m done): git is the harness's commit substrate; workers never touch it
    statement pather declares a git shell gate (/usr/bin/git push): git is the harness's commit substrate; workers never touch it
    ADMITTED
    |}]
