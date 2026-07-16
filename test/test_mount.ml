(* Falsifiers, group "mount" — the chase engine on the fiber substrate
   (docs/architecture/30-scheduling.md § read-time binding;
   docs/effects-evaluation.md; fiber.mli):

   - FM1 — engine-level overlap: two nodes' provider calls are
     simultaneously in flight under a rigged-slow transport. Both POSTs
     are submitted before either completes (interleaving order, never
     wall clock), the scripted completion order — not submit order —
     decides which node's turn lands first, and the run is
     replay-coherent. The lane is the REAL Anthropic Messages
     encoder/decoder posting through [Fiber.http_post]; only the
     transport is rigged.

   - FM2 — mid-flight squash, end to end: a consumer that snooped a
     doomed producer's store buffer is squashed WHILE its provider call
     is in flight. The discontinue unwinds the fiber's stack, so the
     worktree drop rides [Fun.protect] (the substrate's FB2 proves the
     mechanism; this proves it through the engine): the on-disk buffer is
     gone, the node settles with its upstream-squash cause, the abandoned
     transfer's completion is dropped, and the squashed node bills no
     further turn — it CANNOT run further.

   - FM3 — wake precision: two consumers park on two different operands;
     each producer's landing wakes exactly the fiber whose address
     committed — one suspension and one resumption per consumer, never
     the old requeue-the-whole-parked-list drumbeat.

   - FM4 — stop-cleanly is a discontinue, not a convention: a consumer
     whose yield delivers a breaking-broad note (it provably read the
     moved file, in the same tool batch that drafted it) is discontinued
     AT the yield — the fiber requests no further turn (the transport
     sees no second submit from it), the worktree drop rides
     [Fun.protect], the attempt settles reissue-loser, and the body
     match reissues against the landed state.

   Rigged transports and scripted turns only; no network, no sleeps. *)

open Goatcode
module R = Agent.Rigged

(* The provider lane reads its key from the environment at turn time; the
   rigged transport never puts it on a wire. One process, one domain —
   the multidomain alert does not apply to this suite. *)
let putenv = (Unix.putenv [@alert "-unsafe_multidomain"])

let msg_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "properties",
        `Assoc [ ("msg", `Assoc [ ("type", `String "string") ]) ] );
      ("required", `List [ `String "msg" ]);
      ("additionalProperties", `Bool false);
    ]

let json_relation name =
  Theory.Relation.v ~name
    (Contract.v ~name ~schema:msg_schema
       ~codec:(Contract.Codec.v ~of_json:Fun.id ~to_json:Fun.id))

let rigged_pin =
  {
    Theory.Pin.provider = "rigged";
    model = "deterministic";
    sampling = [];
    options = [];
  }

let anthropic_pin =
  {
    Theory.Pin.provider = "anthropic";
    model = "claude-fable-5";
    sampling = [];
    options = [];
  }

let template ?(pin = rigged_pin) name =
  Theory.Executor.Agent_template
    {
      name;
      pin;
      preamble = name ^ ": a test template";
      read_globs = [];
      write_globs = [ "**" ];
      effects = [];
    }

let binding ~by ~runtime =
  {
    Chase.executor = Theory.Executor.id by;
    runtime;
    fallback = None;
    repair_budget = Agent.Repair_budget.v 1;
    port = "main";
  }

let rigged ~by ~script = binding ~by ~runtime:(R.executor ~script)

(* The live Anthropic Messages lane, posting through the fiber's
   [Http_post] instruction — the seam under test. *)
let fibered_anthropic ~by =
  binding ~by
    ~runtime:
      (Agent.agent ~stop:[]
         ~provider:(Agent.Provider.anthropic ~post:Fiber.http_post ()))

let admit ~relations ~statements =
  match Theory.declare ~relations ~statements ~laws:[] with
  | Ok theory -> theory
  | Error errors ->
      List.iter (fun e -> print_endline (Theory.Admission.to_string e)) errors;
      failwith "theory did not admit"

let sandbox ?(files = []) prefix =
  let root = Filename.temp_dir prefix "" in
  let repo = Filename.concat root "repo" in
  Unix.mkdir repo 0o755;
  let sh cmd =
    if Sys.command (cmd ^ " >/dev/null 2>&1") <> 0 then
      failwith ("fixture command failed: " ^ cmd)
  in
  sh (Printf.sprintf "git -C %s init -q" (Filename.quote repo));
  (* Optional committed fixture files: pre-run repository state a node
     may read through its worktree checkout. *)
  List.iter
    (fun (path, contents) ->
      Out_channel.with_open_bin (Filename.concat repo path) (fun oc ->
          Out_channel.output_string oc contents))
    files;
  if files <> [] then
    sh (Printf.sprintf "git -C %s add -A" (Filename.quote repo));
  sh
    (Printf.sprintf
       "git -C %s -c user.name=goatcode-test -c user.email=test@localhost \
        commit -q --allow-empty -m fixture-seed"
       (Filename.quote repo));
  let worktrees = Filename.concat repo "_buffers" in
  Unix.mkdir worktrees 0o755;
  (repo, worktrees, Filename.concat root "ledger.bin")

let engine ?(backstops = Speculate.Backstops.default)
    ?(merges = Retire.Merge_registry.empty) ~theory ~executors ~transport
    ~seed (repo, _worktrees, ledger_path) =
  let ledger = Ledger.create ~path:ledger_path in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat-committed" in
  let channels = Channel.open_all theory in
  let chase =
    Chase.create ~theory ~ledger ~committed ~channels ~transport
      ~ports:[ Chase.Port.open_ ~name:"main" ]
      ~executors ~backstops ~switches:[] ~merges ~seed ()
  in
  (chase, ledger)

let seed_task task = [ Theory.Tuple.v task (`Assoc [ ("msg", `String "go") ]) ]

let check label ok = Printf.printf "%s: %b\n" label ok

let of_node node (e : Ledger.Event.t) =
  match e.node with Some n -> Id.equal n node | None -> false

let node_of_stmt events stmt =
  List.find_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Fired { provenance; _ }
        when String.equal
               (Theory.Statement.to_string
                  provenance.Ledger.Provenance.statement)
               stmt ->
          e.node
      | _ -> None)
    events

let nodes_of_stmt events stmt =
  List.filter_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Fired { provenance; _ }
        when String.equal
               (Theory.Statement.to_string
                  provenance.Ledger.Provenance.statement)
               stmt ->
          e.node
      | _ -> None)
    events

let indexed events = List.mapi (fun i e -> (i, e)) events

let first_index events pred =
  List.find_map (fun (i, e) -> if pred e then Some i else None) (indexed events)

let turn_index events node =
  first_index events (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Agent_turn _ -> of_node node e
      | _ -> false)

let settled_index events node =
  first_index events (fun (e : Ledger.Event.t) ->
      match e.kind with Ledger.Event.Settled _ -> of_node node e | _ -> false)

let decision_indexes events node action =
  List.filter_map
    (fun (i, (e : Ledger.Event.t)) ->
      match e.kind with
      | Ledger.Event.Decision { action = a; _ }
        when of_node node e
             && String.equal (Ledger.Decision.to_string a) action ->
          Some i
      | _ -> None)
    (indexed events)

let settlement_of chase node =
  List.find_map
    (fun (n, s) -> if Id.equal n node then Some s else None)
    (Chase.settlements chase)

let settlement_str = function
  | Some Ledger.Settlement.Retired -> "retired"
  | Some (Ledger.Settlement.Faulted f) ->
      "faulted: " ^ f.Ledger.Fault.message
  | Some (Ledger.Settlement.Squashed (Ledger.Squash_cause.Upstream_squash _))
    ->
      "squashed(upstream-squash)"
  | Some (Ledger.Settlement.Squashed Ledger.Squash_cause.Reissue_loser) ->
      "squashed(reissue-loser)"
  | Some (Ledger.Settlement.Squashed _) -> "squashed(other)"
  | None -> "unsettled"

let replay_verdict ledger =
  match Run.replay ledger with
  | Ok () -> "coherent"
  | Error ds -> Printf.sprintf "%d divergences" (List.length ds)

let committed_msg chase relation =
  List.filter_map
    (fun (tu : Retire.Committed.tuple) ->
      if String.equal tu.Retire.Committed.relation relation then
        match tu.Retire.Committed.payload with
        | `Assoc fields -> (
            match List.assoc_opt "msg" fields with
            | Some (`String s) -> Some s
            | _ -> None)
        | _ -> None
      else None)
    (Retire.Committed.tuples (Chase.committed chase))

(* One Anthropic-Messages-shaped 200 whose settled text is the head
   payload [{"msg": msg}]. *)
let anthropic_reply msg =
  Yojson.Safe.to_string
    (`Assoc
      [
        ( "content",
          `List
            [
              `Assoc
                [
                  ("type", `String "text");
                  ( "text",
                    `String
                      (Yojson.Safe.to_string (`Assoc [ ("msg", `String msg) ]))
                  );
                ];
            ] );
        ("stop_reason", `String "end_turn");
        ( "usage",
          `Assoc [ ("input_tokens", `Int 7); ("output_tokens", `Int 5) ] );
      ])

(* The rigged-slow transport (the substrate FB4 rig, at engine level):
   submissions are held — nothing completes inside a dispatch action, so
   in-flight transfers pile up — and one [poll] completes everything
   pending in the order the script says. Each completion's reply text
   names its own transfer, so committed payloads prove which completion
   fed which node. *)
let scripted_transport ~say ~complete_in_order:reorder =
  let pending = ref [] in
  let next = ref 0 in
  {
    Fiber.Transport.submit =
      (fun (_ : Http.Request.t) ->
        let tok = !next in
        incr next;
        say (Printf.sprintf "transport: submit #%d" tok);
        pending := !pending @ [ tok ];
        tok);
    poll =
      (fun ~block:_ ->
        let order = reorder !pending in
        pending := [];
        List.map
          (fun tok ->
            say (Printf.sprintf "transport: complete #%d" tok);
            (tok, Ok (200, anthropic_reply (Printf.sprintf "turn-%d" tok))))
          order);
  }

(* ------------------------------------------------------------------ *)
(* FM1 — engine-level overlap under the real Anthropic Messages lane.   *)

let%expect_test "FM1: two provider calls overlap through the engine; \
                 completion order, not submit order, decides turn order" =
  putenv "ANTHROPIC_API_KEY" "test-key-never-used-on-a-wire";
  let task = json_relation "task" in
  let left = json_relation "left" in
  let right = json_relation "right" in
  let lefty = template ~pin:anthropic_pin "lefty" in
  let righty = template ~pin:anthropic_pin "righty" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed left;
          Theory.Relation.Packed right;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"make_left" ~for_:"task"
            ~exists:("left", Theory.Window.nodes 1)
            ~by:lefty ();
          Theory.Spawn.v ~name:"make_right" ~for_:"task"
            ~exists:("right", Theory.Window.nodes 1)
            ~by:righty ();
        ]
  in
  let trace = ref [] in
  let say s = trace := !trace @ [ s ] in
  let transport = scripted_transport ~say ~complete_in_order:List.rev in
  let chase, ledger =
    engine ~theory
      ~executors:[ fibered_anthropic ~by:lefty; fibered_anthropic ~by:righty ]
      ~transport ~seed:(seed_task task) (sandbox "goat_fm1_")
  in
  Chase.run_to_quiescence chase;
  List.iter print_endline !trace;
  let events = Ledger.Replay.events ledger in
  let l_node =
    match node_of_stmt events "make_left" with
    | Some n -> n
    | None -> failwith "make_left never fired"
  in
  let r_node =
    match node_of_stmt events "make_right" with
    | Some n -> n
    | None -> failwith "make_right never fired"
  in
  (match (turn_index events r_node, turn_index events l_node) with
  | Some r, Some l ->
      check "the completion order (right first) decided turn order" (r < l)
  | _ -> print_endline "!! a node billed no turn");
  Printf.printf "left committed: %s\n"
    (String.concat ", " (committed_msg chase "left"));
  Printf.printf "right committed: %s\n"
    (String.concat ", " (committed_msg chase "right"));
  check "both nodes retired"
    (List.for_all
       (fun n ->
         match settlement_of chase n with
         | Some Ledger.Settlement.Retired -> true
         | _ -> false)
       [ l_node; r_node ]);
  Printf.printf "replay: %s\n" (replay_verdict ledger);
  [%expect
    {|
    transport: submit #0
    transport: submit #1
    transport: complete #1
    transport: complete #0
    the completion order (right first) decided turn order: true
    left committed: turn-0
    right committed: turn-1
    both nodes retired: true
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* FM2 — mid-flight squash through the engine.                          *)

let write_tool path content =
  R.Call_tool
    {
      name = "write_file";
      input = `Assoc [ ("path", `String path); ("content", `String content) ];
    }

let worktree_dirs wt =
  Sys.readdir wt |> Array.to_list |> List.sort String.compare

let%expect_test "FM2: a consumer squashed while its provider call is in \
                 flight — Fun.protect drops its worktree, the completion \
                 is dropped, no further turn bills" =
  putenv "ANTHROPIC_API_KEY" "test-key-never-used-on-a-wire";
  let task = json_relation "task" in
  let amid = json_relation "amid" in
  let bmid = json_relation "bmid" in
  let out = json_relation "out" in
  let winner = template "winner" in
  let loser = template "loser" in
  let consumer = template ~pin:anthropic_pin "consumer" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed amid;
          Theory.Relation.Packed bmid;
          Theory.Relation.Packed out;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"win" ~for_:"task"
            ~exists:("amid", Theory.Window.nodes 1)
            ~by:winner ();
          Theory.Spawn.v ~name:"lose" ~for_:"task"
            ~exists:("bmid", Theory.Window.nodes 1)
            ~by:loser ();
          Theory.Spawn.v ~name:"consume" ~for_:"bmid"
            ~exists:("out", Theory.Window.nodes 1)
            ~by:consumer ();
        ]
  in
  let trace = ref [] in
  let say s = trace := !trace @ [ s ] in
  let transport = scripted_transport ~say ~complete_in_order:Fun.id in
  let ((_, worktrees, _) as sb) = sandbox "goat_fm2_" in
  let chase, ledger =
    engine ~theory
      ~executors:
        [
          rigged ~by:winner
            ~script:[ write_tool "same.txt" "winner"; R.Reply {|{"msg":"a"}|} ];
          rigged ~by:loser
            ~script:
              [
                write_tool "same.txt" "loser";
                R.Reply {|{"msg":"b1"}|};
                R.Reply {|{"msg":"b2"}|};
              ];
          fibered_anthropic ~by:consumer;
        ]
      ~transport ~seed:(seed_task task) sb
  in
  Chase.run_to_quiescence chase;
  List.iter print_endline !trace;
  let events = Ledger.Replay.events ledger in
  let attempts = nodes_of_stmt events "consume" in
  (match attempts with
  | [ doomed; survivor ] ->
      Printf.printf "doomed consumer settled: %s\n"
        (settlement_str (settlement_of chase doomed));
      check
        "the doomed consumer took the store-buffer hypothesis before its \
         post"
        (List.exists
           (fun (e : Ledger.Event.t) ->
             match e.kind with
             | Ledger.Event.Hypothesis_taken _ -> of_node doomed e
             | _ -> false)
           events);
      check "the doomed consumer billed no turn (squash mid-flight is total)"
        (Option.is_none (turn_index events doomed));
      check "Fun.protect dropped the doomed consumer's worktree"
        (not (List.mem (Id.to_string doomed) (worktree_dirs worktrees)));
      Printf.printf "reissued consumer settled: %s\n"
        (settlement_str (settlement_of chase survivor))
  | attempts ->
      Printf.printf "!! expected 2 consume attempts, saw %d\n"
        (List.length attempts));
  Printf.printf "out committed: %s\n"
    (String.concat ", " (committed_msg chase "out"));
  Printf.printf "replay: %s\n" (replay_verdict ledger);
  [%expect
    {|
    transport: submit #0
    transport: submit #1
    transport: complete #0
    transport: complete #1
    doomed consumer settled: squashed(upstream-squash)
    the doomed consumer took the store-buffer hypothesis before its post: true
    the doomed consumer billed no turn (squash mid-flight is total): true
    Fun.protect dropped the doomed consumer's worktree: true
    reissued consumer settled: retired
    out committed: turn-1
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* FM3 — wake precision.                                                *)

let%expect_test "FM3: a landing wakes exactly the fiber parked on the \
                 committed address; the other consumer stays parked" =
  let task = json_relation "task" in
  let mid1 = json_relation "mid1" in
  let mid2 = json_relation "mid2" in
  let out1 = json_relation "out1" in
  let out2 = json_relation "out2" in
  let p1 = template "producer-one" in
  let p2 = template "producer-two" in
  let c1 = template "consumer-one" in
  let c2 = template "consumer-two" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed mid1;
          Theory.Relation.Packed mid2;
          Theory.Relation.Packed out1;
          Theory.Relation.Packed out2;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"produce_one" ~for_:"task"
            ~exists:("mid1", Theory.Window.nodes 1)
            ~by:p1 ();
          Theory.Spawn.v ~name:"produce_two" ~for_:"task"
            ~exists:("mid2", Theory.Window.nodes 1)
            ~by:p2 ();
          Theory.Spawn.v ~name:"consume_one" ~for_:"mid1"
            ~exists:("out1", Theory.Window.nodes 1)
            ~by:c1 ();
          Theory.Spawn.v ~name:"consume_two" ~for_:"mid2"
            ~exists:("out2", Theory.Window.nodes 1)
            ~by:c2 ();
        ]
  in
  (* The confidence floor above any chain: every uncommitted read parks —
     delivery mechanics under test, not the speculation posture. *)
  let backstops =
    { Speculate.Backstops.default with confidence_floor = 2.0 }
  in
  let no_transport =
    {
      Fiber.Transport.submit = (fun _ -> failwith "no transport in FM3");
      poll = (fun ~block:_ -> []);
    }
  in
  let chase, ledger =
    engine ~backstops ~theory
      ~executors:
        [
          rigged ~by:p1 ~script:[ R.Reply {|{"msg":"m1"}|} ];
          rigged ~by:p2 ~script:[ R.Reply {|{"msg":"m2"}|} ];
          rigged ~by:c1 ~script:[ R.Reply {|{"msg":"o1"}|} ];
          rigged ~by:c2 ~script:[ R.Reply {|{"msg":"o2"}|} ];
        ]
      ~transport:no_transport ~seed:(seed_task task) (sandbox "goat_fm3_")
  in
  Chase.run_to_quiescence chase;
  let events = Ledger.Replay.events ledger in
  let node stmt =
    match node_of_stmt events stmt with
    | Some n -> n
    | None -> failwith (stmt ^ " never fired")
  in
  let p1n = node "produce_one" and p2n = node "produce_two" in
  let c1n = node "consume_one" and c2n = node "consume_two" in
  check "each consumer parked exactly once and resumed exactly once"
    (List.for_all
       (fun c ->
         List.length (decision_indexes events c "suspended") = 1
         && List.length (decision_indexes events c "resumed") = 1)
       [ c1n; c2n ]);
  (match
     ( settled_index events p1n,
       decision_indexes events c1n "resumed",
       settled_index events p2n,
       decision_indexes events c2n "resumed" )
   with
  | Some p1_settled, [ c1_resumed ], Some p2_settled, [ c2_resumed ] ->
      check "consumer one woke on ITS producer's landing, before the other"
        (p1_settled < c1_resumed && c1_resumed < p2_settled);
      check "consumer two stayed parked until ITS producer landed"
        (p2_settled < c2_resumed)
  | _ -> print_endline "!! the trace is missing a settle or a resume");
  check "every node retired"
    (List.for_all
       (fun n ->
         match settlement_of chase n with
         | Some Ledger.Settlement.Retired -> true
         | _ -> false)
       [ p1n; p2n; c1n; c2n ]);
  Printf.printf "replay: %s\n" (replay_verdict ledger);
  [%expect
    {|
    each consumer parked exactly once and resumed exactly once: true
    consumer one woke on ITS producer's landing, before the other: true
    consumer two stayed parked until ITS producer landed: true
    every node retired: true
    replay: coherent
    |}]


(* ------------------------------------------------------------------ *)
(* FM4 — stop-cleanly at a yield is a discontinue.                      *)

(* An Anthropic-Messages-shaped 200 whose assistant turn is a BATCH of
   tool calls (parallel tool_use blocks): the loop executes the whole
   batch, then yields once — so the drift note drains at a yield that
   follows the reads the batch performed. *)
let anthropic_tool_batch calls =
  let block (id, name, input) =
    `Assoc
      [
        ("type", `String "tool_use");
        ("id", `String id);
        ("name", `String name);
        ("input", input);
      ]
  in
  Yojson.Safe.to_string
    (`Assoc
      [
        ("content", `List (List.map block calls));
        ("stop_reason", `String "tool_use");
        ( "usage",
          `Assoc [ ("input_tokens", `Int 7); ("output_tokens", `Int 5) ] );
      ])

let%expect_test "FM4: a breaking-broad note at a yield discontinues the \
                 fiber — no further turn is requested, the worktree \
                 drops, and the body match reissues" =
  putenv "ANTHROPIC_API_KEY" "test-key-never-used-on-a-wire";
  let task = json_relation "task" in
  let mid1 = json_relation "mid1" in
  let mid2 = json_relation "mid2" in
  let out = json_relation "out" in
  let w1 = template "writer-one" in
  let w2 = template "writer-two" in
  let c =
    Theory.Executor.Agent_template
      {
        name = "watcher";
        pin = anthropic_pin;
        preamble = "watcher: a test template";
        read_globs = [ "shared.txt" ];
        write_globs = [ "**" ];
        effects = [];
      }
  in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed mid1;
          Theory.Relation.Packed mid2;
          Theory.Relation.Packed out;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"first_write" ~for_:"task"
            ~exists:("mid1", Theory.Window.nodes 1)
            ~by:w1 ();
          Theory.Spawn.v ~name:"second_write" ~for_:"mid1"
            ~exists:("mid2", Theory.Window.nodes 1)
            ~by:w2 ();
          Theory.Spawn.v ~name:"watch" ~for_:"mid2"
            ~exists:("out", Theory.Window.nodes 1)
            ~by:c ();
        ]
  in
  (* Speculation default-on: the watcher starts against writer-two's
     store buffer and is IN FLIGHT when writer-two's retirement moves
     shared.txt. Its one assistant turn drafts its own product AND reads
     the committed fixture shared.txt through its checkout in a single
     batch (a read of its own draft would claim nothing — the
     self-witness ruling), so the yield after the batch drains the
     invalidation against a witness that provably read the moved file:
     breaking-broad, flush, stop-cleanly — the handler discontinues, and
     the transport never sees another submit from this fiber. *)
  let merges =
    Retire.Merge_registry.register Retire.Merge_registry.empty
      ~address_class:"shared.txt" ~merge_fn:"last-writer-wins"
  in
  let trace = ref [] in
  let say s = trace := !trace @ [ s ] in
  let replies =
    [
      anthropic_tool_batch
        [
          ( "t1",
            "write_file",
            `Assoc
              [
                ("path", `String "product.txt"); ("content", `String "draft");
              ] );
          ("t2", "read_file", `Assoc [ ("path", `String "shared.txt") ]);
        ];
      anthropic_reply "done";
    ]
  in
  let pending = ref [] in
  let next = ref 0 in
  let transport =
    {
      Fiber.Transport.submit =
        (fun (_ : Http.Request.t) ->
          let tok = !next in
          incr next;
          say (Printf.sprintf "transport: submit #%d" tok);
          pending := !pending @ [ tok ];
          tok);
      poll =
        (fun ~block:_ ->
          let order = !pending in
          pending := [];
          List.map
            (fun tok ->
              say (Printf.sprintf "transport: complete #%d" tok);
              (tok, Ok (200, List.nth replies tok)))
            order);
    }
  in
  let ((_, worktrees, _) as sb) =
    sandbox ~files:[ ("shared.txt", "zero\n") ] "goat_fm4_"
  in
  let chase, ledger =
    engine ~merges ~theory
      ~executors:
        [
          (* writer-one writes its OWN product: shared.txt (a committed
             fixture) moves exactly once — at writer-two's landing — so
             the yield drains exactly one invalidation. *)
          rigged ~by:w1
            ~script:[ write_tool "w1.txt" "one"; R.Reply {|{"msg":"m1"}|} ];
          rigged ~by:w2
            ~script:[ write_tool "shared.txt" "two"; R.Reply {|{"msg":"m2"}|} ];
          fibered_anthropic ~by:c;
        ]
      ~transport ~seed:(seed_task task) sb
  in
  Chase.run_to_quiescence chase;
  List.iter print_endline !trace;
  let events = Ledger.Replay.events ledger in
  let attempts = nodes_of_stmt events "watch" in
  (match attempts with
  | [ doomed; survivor ] ->
      List.iter print_endline
        (List.filter_map
           (fun (e : Ledger.Event.t) ->
             match e.kind with
             | Ledger.Event.Drift_note { address; cls; route }
               when of_node doomed e ->
                 Some
                   (Printf.sprintf "%s: %s -> %s"
                      (Ledger.Address.to_string address)
                      (Ledger.Drift.cls_to_string cls)
                      (Ledger.Drift.route_to_string route))
             | _ -> None)
           events);
      Printf.printf "doomed attempt settled: %s\n"
        (settlement_str (settlement_of chase doomed));
      check "the flush decision recorded the stop-cleanly note"
        (not (List.is_empty (decision_indexes events doomed "flush-subtree")));
      check "Fun.protect dropped the doomed attempt's worktree"
        (not (List.mem (Id.to_string doomed) (worktree_dirs worktrees)));
      Printf.printf "reissued attempt settled: %s\n"
        (settlement_str (settlement_of chase survivor));
      Printf.printf "out committed: %s\n"
        (String.concat ", " (committed_msg chase "out"))
  | attempts ->
      Printf.printf "!! expected 2 watch attempts, saw %d\n"
        (List.length attempts));
  Printf.printf "replay: %s\n" (replay_verdict ledger);
  [%expect
    {|
    transport: submit #0
    transport: complete #0
    transport: submit #1
    transport: complete #1
    file:shared.txt: breaking_broad -> flush_subtree
    doomed attempt settled: squashed(reissue-loser)
    the flush decision recorded the stop-cleanly note: true
    Fun.protect dropped the doomed attempt's worktree: true
    reissued attempt settled: retired
    out committed: done
    replay: coherent
    |}]
