(* Falsifiers, group "delivery and speculation" — the wired delivery half
   and the hypothesis lifecycle (docs/architecture/30-channels.md
   § delivery, § store-to-load forwarding;
   docs/architecture/40-scheduling.md § read-time binding, § drift
   routing, § settlement):

   - F7 (discharge-on-exact-landing): a consumer that snooped a producer's
     store buffer takes a real hypothesis; the refresher discharges it
     silently when the producer lands exactly the snooped content, and the
     consumer retires for free — no invalidation, no drift note, no
     reissue. Correct speculation costs zero.
   - Delivery: a generation move at retirement fans a payload-free
     invalidation over the channel layer; a consumer whose declared
     footprint covers the address receives it AND the typed drift note at
     its next yield — check-on-yield, buffered-socket semantics (queued
     before the consumer started).
   - The drift-routing table's rejection-site consumer: a moved witness is
     classified per consumer and routed by the table — a move touching all
     of the consumer's reads flushes (breaking-broad); a move touching a
     minority reconciles by reissue (breaking-narrow). Both notes carry
     the typed class and the table's route, and replay re-judges them.
   - The squash-cause taxonomy: a conflict loser settles
     [Reissue_loser] (never [Operator_abort]) and reissues bounded.
   - F6, the end-to-end half: an observed [read_file] tool load gates
     retirement through the real machinery (the claim/hide directions
     drive Retire.step directly in test_witness.ml).
   - B7 generation threading: a tool load of a committed address
     witnesses the real committed generation, threaded from the chase
     through the invocation into the toolset.

   Rigged executors only; no live model call; no sleeps. *)

open Goatcode
module R = Agent.Rigged

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

let pin =
  {
    Theory.Pin.provider = "rigged";
    model = "deterministic";
    sampling = [];
    options = [];
  }

let template ?(read_globs = []) name =
  Theory.Executor.Agent_template
    { name; pin; preamble = name ^ ": a rigged test template"; read_globs }

let binding ~by ~script =
  {
    Chase.executor = Theory.Executor.id by;
    runtime = R.executor ~script;
    fallback = None;
    repair_budget = Agent.Repair_budget.v 1;
    port = "main";
  }

let admit ~relations ~statements =
  match Theory.declare ~relations ~statements ~laws:[] with
  | Ok theory -> theory
  | Error errors ->
      List.iter (fun e -> print_endline (Theory.Admission.to_string e)) errors;
      failwith "theory did not admit"

(* A real git repo: the committed branch's storage engine — file deltas,
   generation moves, and the write log all ride it
   (docs/architecture/50-commit.md § durability boundary). Store buffers
   live inside it so they are real git worktrees. *)
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

let config ~repo ~worktrees ~ledger_path ?(backstops = Speculate.Backstops.default)
    ?(merges = Retire.Merge_registry.empty) ~executors () =
  {
    Run.repo;
    committed_branch = "goat-committed";
    worktree_root = worktrees;
    ledger_path;
    ports = [ Chase.Port.open_ ~name:"main" ];
    executors;
    backstops;
    switches = [];
    merges;
  }

let seed_task task = [ Theory.Tuple.v task (`Assoc [ ("msg", `String "go") ]) ]

let write_tool path content =
  R.Call_tool
    {
      name = "write_file";
      input = `Assoc [ ("path", `String path); ("content", `String content) ];
    }

let read_tool path =
  R.Call_tool { name = "read_file"; input = `Assoc [ ("path", `String path) ] }

(* ------------------------------------------------------------------ *)
(* Ledger-trace queries.                                               *)

let node_of_stmt events stmt =
  List.find_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Fired { provenance; _ }
        when String.equal
               (Theory.Statement.to_string provenance.Ledger.Provenance.statement)
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
               (Theory.Statement.to_string provenance.Ledger.Provenance.statement)
               stmt ->
          e.node
      | _ -> None)
    events

let of_node node (e : Ledger.Event.t) =
  match e.node with Some n -> Id.equal n node | None -> false

let settlement_of (settled : Run.settled) node =
  List.find_map
    (fun (n, (r : Run.node_report)) ->
      if Id.equal n node then Some r.Run.settlement else None)
    settled.Run.nodes

let settlement_str = function
  | Ledger.Settlement.Retired -> "retired"
  | Ledger.Settlement.Faulted _ -> "faulted"
  | Ledger.Settlement.Squashed (Ledger.Squash_cause.Dead_hypothesis _) ->
      "squashed(dead-hypothesis)"
  | Ledger.Settlement.Squashed (Ledger.Squash_cause.Upstream_fault _) ->
      "squashed(upstream-fault)"
  | Ledger.Settlement.Squashed (Ledger.Squash_cause.Upstream_squash _) ->
      "squashed(upstream-squash)"
  | Ledger.Settlement.Squashed Ledger.Squash_cause.Reissue_loser ->
      "squashed(reissue-loser)"
  | Ledger.Settlement.Squashed Ledger.Squash_cause.No_producer ->
      "squashed(no-producer)"
  | Ledger.Settlement.Squashed Ledger.Squash_cause.Operator_abort ->
      "squashed(operator-abort)"

let drift_notes events node =
  List.filter_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Drift_note { address; cls; route } when of_node node e ->
          Some
            (Printf.sprintf "%s: %s -> %s"
               (Ledger.Address.to_string address)
               (Ledger.Drift.cls_to_string cls)
               (Ledger.Drift.route_to_string route))
      | _ -> None)
    events

let decisions events node =
  List.filter_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Decision { action; _ } when of_node node e ->
          Some (Ledger.Decision.to_string action)
      | _ -> None)
    events

let invalidations events =
  List.filter_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Invalidation_sent { address; new_generation } ->
          Some
            (Format.asprintf "%a at %a" Ledger.Address.pp address
               Ledger.Generation.pp new_generation)
      | _ -> None)
    events

let check label ok = Printf.printf "%s: %b\n" label ok

(* The witness triples a node's [read_file] tool loads observed, rendered
   with their generations — what F6's end-to-end half and the B7
   generation-threading falsifier assert on. *)
let file_load_triples events node =
  List.concat_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Load { tool = "read_file"; observed } when of_node node e
        ->
          List.map
            (fun (a, g, _) ->
              Format.asprintf "%a @@ %a" Ledger.Address.pp a
                Ledger.Generation.pp g)
            observed
      | _ -> [])
    events

let replay_verdict ledger =
  match Run.replay ledger with
  | Ok () -> "coherent"
  | Error ds -> Printf.sprintf "%d divergences" (List.length ds)

(* ------------------------------------------------------------------ *)
(* F7 — discharge on exact landing: the hypothesis lifecycle end to
   end. The consumer starts against the producer's parsed, uncommitted
   heads (store-buffer forwarding), takes a store-buffer hypothesis at the
   read, and the refresher discharges it silently at the producer's
   identical landing — the free commit. *)

let%expect_test "F7: a snooped hypothesis discharges on exact landing and \
                 the consumer retires free" =
  let task = json_relation "task" in
  let mid = json_relation "mid" in
  let out = json_relation "out" in
  let producer = template "producer" in
  let consumer = template "consumer" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed mid;
          Theory.Relation.Packed out;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"produce" ~for_:"task"
            ~exists:("mid", Theory.Window.nodes 1)
            ~by:producer ();
          Theory.Spawn.v ~name:"consume" ~for_:"mid"
            ~exists:("out", Theory.Window.nodes 1)
            ~by:consumer ();
        ]
  in
  let repo, worktrees, ledger_path = sandbox "goat_f7_" in
  let executors =
    [
      binding ~by:producer ~script:[ R.Reply {|{"msg":"mid landed"}|} ];
      binding ~by:consumer ~script:[ R.Reply {|{"msg":"out landed"}|} ];
    ]
  in
  (match
     Run.exec ~theory ~seed:(seed_task task)
       ~config:(config ~repo ~worktrees ~ledger_path ~executors ())
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let p_node =
        match node_of_stmt events "produce" with
        | Some n -> n
        | None -> failwith "produce never fired"
      in
      let c_node =
        match node_of_stmt events "consume" with
        | Some n -> n
        | None -> failwith "consume never fired"
      in
      let taken =
        List.find_map
          (fun (e : Ledger.Event.t) ->
            match e.kind with
            | Ledger.Event.Hypothesis_taken { hypothesis; source; _ }
              when of_node c_node e ->
                Some (hypothesis, source)
            | _ -> None)
          events
      in
      (match taken with
      | None -> print_endline "!! the consumer took no hypothesis"
      | Some (h, source) ->
          check "hypothesis source is the producer's store buffer"
            (String.equal source ("store-buffer:" ^ Id.to_string p_node));
          check "the snooped read entered the observed witness (Load)"
            (List.exists
               (fun (e : Ledger.Event.t) ->
                 match e.kind with
                 | Ledger.Event.Load { tool; _ } when of_node c_node e ->
                     String.equal tool "chase.snoop"
                 | _ -> false)
               events);
          check "the refresher discharged it at the producer's landing"
            (List.exists
               (fun (e : Ledger.Event.t) ->
                 match e.kind with
                 | Ledger.Event.Hypothesis_discharged { hypothesis } ->
                     Id.equal hypothesis h
                 | _ -> false)
               events));
      check "both nodes retired"
        (List.for_all
           (fun n ->
             match settlement_of settled n with
             | Some Ledger.Settlement.Retired -> true
             | _ -> false)
           [ p_node; c_node ]);
      check "no invalidation fired (free commit)"
        (List.is_empty (invalidations events));
      check "no drift note; no reissue; no flush"
        (List.is_empty (drift_notes events c_node)
        && not
             (List.exists
                (fun d ->
                  String.equal d "serialize-reissue"
                  || String.equal d "flush-subtree")
                (decisions events c_node)));
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    hypothesis source is the producer's store buffer: true
    the snooped read entered the observed witness (Load): true
    the refresher discharged it at the producer's landing: true
    both nodes retired: true
    no invalidation fired (free commit): true
    no drift note; no reissue; no flush: true
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* Delivery — a consumer receives the invalidation and the drift note at
   its yield. A three-stage chain with speculation suspended (the
   confidence floor set above any chain: delivery is check-on-yield
   semantics, orthogonal to the speculation posture) so the consumer
   parks and resumes; the second writer moves a file the first committed
   (a declared merge function covers the address class, so the write
   serializes without conflict), and the moved generation fans a
   payload-free invalidation the consumer's declared footprint covers —
   queued before the consumer ran, delivered at its first yield as a
   typed note. *)

let%expect_test "delivery: the invalidation and the typed drift note reach \
                 the consumer's yield" =
  let task = json_relation "task" in
  let mid1 = json_relation "mid1" in
  let mid2 = json_relation "mid2" in
  let out = json_relation "out" in
  let w1 = template "writer-one" in
  let w2 = template "writer-two" in
  let c = template ~read_globs:[ "shared.txt" ] "watcher" in
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
  let repo, worktrees, ledger_path = sandbox "goat_delivery_" in
  let executors =
    [
      binding ~by:w1
        ~script:[ write_tool "shared.txt" "one"; R.Reply {|{"msg":"m1"}|} ];
      binding ~by:w2
        ~script:[ write_tool "shared.txt" "two"; R.Reply {|{"msg":"m2"}|} ];
      binding ~by:c ~script:[ R.Yield; R.Reply {|{"msg":"seen"}|} ];
    ]
  in
  let backstops =
    { Speculate.Backstops.default with confidence_floor = 2.0 }
  in
  let merges =
    Retire.Merge_registry.register Retire.Merge_registry.empty
      ~address_class:"shared.txt" ~merge_fn:"last-writer-wins"
  in
  (match
     Run.exec ~theory ~seed:(seed_task task)
       ~config:(config ~repo ~worktrees ~ledger_path ~backstops ~merges ~executors ())
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let c_node =
        match node_of_stmt events "watch" with
        | Some n -> n
        | None -> failwith "watch never fired"
      in
      List.iter print_endline (invalidations events);
      List.iter print_endline (drift_notes events c_node);
      check "the parked consumer walked the suspended -> resumed lifecycle"
        (let ds = decisions events c_node in
         List.mem "suspended" ds && List.mem "resumed" ds
         && List.mem "queued:main" ds && List.mem "admitted:main" ds
         && List.mem "dispatched" ds);
      check "the consumer retired"
        (match settlement_of settled c_node with
        | Some Ledger.Settlement.Retired -> true
        | _ -> false);
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    file:shared.txt at g1
    file:shared.txt: additive -> reconcile_note
    the parked consumer walked the suspended -> resumed lifecycle: true
    the consumer retired: true
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* The drift table's rejection-site consumer (B6). A consumer reads the
   committed base (its checkout) of a file a sibling lands differently;
   the sibling retires first, the consumer's witness fails, and the
   rejection is classified per consumer and routed by the table:
   - reads ONLY the moved file: the move touches all of its reads —
     breaking-broad, flush the subtree;
   - reads the moved file and one other: a minority moved —
     breaking-narrow, reconcile (serialize-reissue in the synchronous v0
     engine).
   Both reissue bounded; the second attempt retires against the landed
   state. (The reads are committed fixtures, not the consumer's own
   drafts: a draft read claims nothing in the witness — the self-witness
   ruling, wave 3.) *)

let run_moved_witness ~consumer_script =
  let task = json_relation "task" in
  let smid = json_relation "smid" in
  let cmid = json_relation "cmid" in
  let lander = template "lander" in
  let drafter = template "drafter" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed smid;
          Theory.Relation.Packed cmid;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"land" ~for_:"task"
            ~exists:("smid", Theory.Window.nodes 1)
            ~by:lander ();
          Theory.Spawn.v ~name:"draft" ~for_:"task"
            ~exists:("cmid", Theory.Window.nodes 1)
            ~by:drafter ();
        ]
  in
  let repo, worktrees, ledger_path =
    sandbox
      ~files:[ ("shared.txt", "base\n"); ("other.txt", "o1\n") ]
      "goat_moved_"
  in
  let executors =
    [
      binding ~by:lander
        ~script:[ write_tool "shared.txt" "landed"; R.Reply {|{"msg":"s"}|} ];
      binding ~by:drafter ~script:consumer_script;
    ]
  in
  match
    Run.exec ~theory ~seed:(seed_task task)
      ~config:(config ~repo ~worktrees ~ledger_path ~executors ())
  with
  | Error _ -> failwith "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let attempts = nodes_of_stmt events "draft" in
      (match attempts with
      | [ first; second ] ->
          List.iter print_endline (drift_notes events first);
          Printf.printf "loser decisions: %s\n"
            (String.concat ", "
               (List.filter
                  (fun d ->
                    String.equal d "serialize-reissue"
                    || String.equal d "flush-subtree")
                  (decisions events first)));
          Printf.printf "loser settled: %s\n"
            (match settlement_of settled first with
            | Some s -> settlement_str s
            | None -> "unsettled");
          Printf.printf "reissued attempt settled: %s\n"
            (match settlement_of settled second with
            | Some s -> settlement_str s
            | None -> "unsettled")
      | attempts ->
          Printf.printf "!! expected 2 draft attempts, saw %d\n"
            (List.length attempts));
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger)

let%expect_test "drift table at the rejection site: a move touching every \
                 read flushes (breaking-broad)" =
  run_moved_witness
    ~consumer_script:
      [
        read_tool "shared.txt";
        R.Reply {|{"msg":"c1"}|};
        R.Reply {|{"msg":"c2"}|};
      ];
  [%expect
    {|
    file:shared.txt: breaking_broad -> flush_subtree
    loser decisions: flush-subtree
    loser settled: squashed(reissue-loser)
    reissued attempt settled: retired
    replay: coherent
    |}]

let%expect_test "drift table at the rejection site: a minority move \
                 reconciles by reissue (breaking-narrow)" =
  run_moved_witness
    ~consumer_script:
      [
        read_tool "shared.txt";
        read_tool "other.txt";
        R.Reply {|{"msg":"c1"}|};
        R.Reply {|{"msg":"c2"}|};
      ];
  [%expect
    {|
    file:shared.txt: breaking_narrow -> reconcile_delta
    loser decisions: serialize-reissue
    loser settled: squashed(reissue-loser)
    reissued attempt settled: retired
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* The hypothesis lifecycle's one landing judgment, exhaustively: taken ->
   discharged | drifted{cls}. The engine's refresher discharges identical
   landings (F7, above, end to end); the drift arm is judged here — the
   per-consumer refinement included
   (docs/architecture/40-scheduling.md § read-time binding). *)

let%expect_test "the refresher's landing judgment: discharge or drifted, \
                 per consumer" =
  let judge label ~snooped ~consumed ~landed =
    let verdict =
      match Speculate.Lifecycle.landing ~snooped ~consumed ~landed with
      | Speculate.Lifecycle.Discharged -> "discharged"
      | Speculate.Lifecycle.Drifted { cls } ->
          Printf.sprintf "drifted %s -> %s"
            (Ledger.Drift.cls_to_string (Speculate.Drift.tag cls))
            (Ledger.Drift.route_to_string (Speculate.Drift.route cls))
      | Speculate.Lifecycle.Taken | Speculate.Lifecycle.Squashed ->
          "!! not in landing's image"
    in
    Printf.printf "%-34s %s\n" label verdict
  in
  let snooped : Yojson.Safe.t =
    `Assoc [ ("summary", `String "s"); ("severity", `String "low") ]
  in
  judge "identical landing" ~snooped
    ~consumed:[ [ "summary" ]; [ "severity" ] ]
    ~landed:snooped;
  judge "key order only" ~snooped
    ~consumed:[ [ "summary" ]; [ "severity" ] ]
    ~landed:(`Assoc [ ("severity", `String "low"); ("summary", `String "s") ]);
  judge "new field landed" ~snooped
    ~consumed:[ [ "summary" ]; [ "severity" ] ]
    ~landed:
      (`Assoc
         [
           ("summary", `String "s");
           ("severity", `String "low");
           ("notes", `String "n");
         ]);
  judge "one of two reads changed" ~snooped
    ~consumed:[ [ "summary" ]; [ "severity" ] ]
    ~landed:(`Assoc [ ("summary", `String "s"); ("severity", `String "high") ]);
  judge "every read changed" ~snooped ~consumed:[ [ "severity" ] ]
    ~landed:(`Assoc [ ("summary", `String "s"); ("severity", `String "high") ]);
  judge "changed field never read" ~snooped ~consumed:[ [ "summary" ] ]
    ~landed:(`Assoc [ ("summary", `String "s"); ("severity", `String "high") ]);
  [%expect
    {|
    identical landing                  discharged
    key order only                     discharged
    new field landed                   drifted additive -> reconcile_note
    one of two reads changed           drifted breaking_narrow -> reconcile_delta
    every read changed                 drifted breaking_broad -> flush_subtree
    changed field never read           drifted additive -> reconcile_note
    |}]

(* ------------------------------------------------------------------ *)
(* The token-ceiling backstop binds (B11): with the ceiling at zero and a
   hypothesis pending, an eager candidate is deflected — the binding is
   announced as the [Ceiling_bound] anomaly with its numbers — and admits
   only after discharges catch up (here: the producer retires, the
   refresher discharges, and the deflected node reads witnessed state)
   (docs/architecture/40-scheduling.md § backstops). *)

let%expect_test "the token ceiling binds: eager work deflected, announced, \
                 admitted after discharge" =
  let task = json_relation "task" in
  let mid = json_relation "mid" in
  let out1 = json_relation "out1" in
  let out2 = json_relation "out2" in
  let producer = template "producer" in
  let eager = template "eager-consumer" in
  let deflected = template "deflected-consumer" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed mid;
          Theory.Relation.Packed out1;
          Theory.Relation.Packed out2;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"produce" ~for_:"task"
            ~exists:("mid", Theory.Window.nodes 1)
            ~by:producer ();
          Theory.Spawn.v ~name:"consume_eagerly" ~for_:"mid"
            ~exists:("out1", Theory.Window.nodes 1)
            ~by:eager ();
          Theory.Spawn.v ~name:"consume_deflected" ~for_:"mid"
            ~exists:("out2", Theory.Window.nodes 1)
            ~by:deflected ();
        ]
  in
  let repo, worktrees, ledger_path = sandbox "goat_ceiling_" in
  let executors =
    [
      binding ~by:producer ~script:[ R.Reply {|{"msg":"mid landed"}|} ];
      binding ~by:eager ~script:[ R.Reply {|{"msg":"one"}|} ];
      binding ~by:deflected ~script:[ R.Reply {|{"msg":"two"}|} ];
    ]
  in
  let backstops = { Speculate.Backstops.default with token_ceiling = 0 } in
  (match
     Run.exec ~theory ~seed:(seed_task task)
       ~config:(config ~repo ~worktrees ~ledger_path ~backstops ~executors ())
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let indexed = List.mapi (fun i e -> (i, e)) events in
      let ceiling_at =
        List.find_map
          (fun (i, (e : Ledger.Event.t)) ->
            match e.kind with
            | Ledger.Event.Decision
                { action = Ledger.Decision.Ceiling_bound; counters; _ } ->
                Some (i, counters)
            | _ -> None)
          indexed
      in
      (match ceiling_at with
      | None -> print_endline "!! the binding ceiling was never announced"
      | Some (_, counters) ->
          check "the anomaly carries its numbers"
            (List.mem_assoc "token_ceiling" counters
            && List.mem_assoc "run_tokens" counters));
      let p_node =
        match node_of_stmt events "produce" with
        | Some n -> n
        | None -> failwith "produce never fired"
      in
      let d_node =
        match node_of_stmt events "consume_deflected" with
        | Some n -> n
        | None -> failwith "consume_deflected never fired"
      in
      let index_of pred =
        List.find_map (fun (i, e) -> if pred e then Some i else None) indexed
      in
      let produce_retired =
        index_of (fun (e : Ledger.Event.t) ->
            match e.kind with
            | Ledger.Event.Settled Ledger.Settlement.Retired ->
                of_node p_node e
            | _ -> false)
      in
      let deflected_dispatched =
        index_of (fun (e : Ledger.Event.t) ->
            match e.kind with
            | Ledger.Event.Decision { action = Ledger.Decision.Dispatched; _ }
              ->
                of_node d_node e
            | _ -> false)
      in
      (match (produce_retired, deflected_dispatched) with
      | Some r, Some d ->
          check "the deflected node dispatched only after the discharge" (d > r)
      | _ -> print_endline "!! trace is missing the retire or the dispatch");
      check "every node retired"
        (List.for_all
           (fun (_, (r : Run.node_report)) ->
             match r.Run.settlement with
             | Ledger.Settlement.Retired -> true
             | _ -> false)
           settled.Run.nodes);
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    the anomaly carries its numbers: true
    the deflected node dispatched only after the discharge: true
    every node retired: true
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* The squash-cause taxonomy (B15): a write-set conflict loser settles
   [Reissue_loser] — never [Operator_abort] — and its body match reissues
   against the winner's committed state. Two blind writers, one file, no
   merge function: the second to retire is the loser. *)

let%expect_test "squash causes: a conflict loser is a reissue-loser, and \
                 reissues" =
  let task = json_relation "task" in
  let amid = json_relation "amid" in
  let bmid = json_relation "bmid" in
  let first = template "first-writer" in
  let second = template "second-writer" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed amid;
          Theory.Relation.Packed bmid;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"win" ~for_:"task"
            ~exists:("amid", Theory.Window.nodes 1)
            ~by:first ();
          Theory.Spawn.v ~name:"lose" ~for_:"task"
            ~exists:("bmid", Theory.Window.nodes 1)
            ~by:second ();
        ]
  in
  let repo, worktrees, ledger_path = sandbox "goat_conflict_" in
  let executors =
    [
      binding ~by:first
        ~script:[ write_tool "same.txt" "winner"; R.Reply {|{"msg":"a"}|} ];
      binding ~by:second
        ~script:
          [
            write_tool "same.txt" "loser";
            R.Reply {|{"msg":"b1"}|};
            R.Reply {|{"msg":"b2"}|};
          ];
    ]
  in
  (match
     Run.exec ~theory ~seed:(seed_task task)
       ~config:(config ~repo ~worktrees ~ledger_path ~executors ())
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let winner =
        match node_of_stmt events "win" with
        | Some n -> n
        | None -> failwith "win never fired"
      in
      let attempts = nodes_of_stmt events "lose" in
      Printf.printf "winner settled: %s\n"
        (match settlement_of settled winner with
        | Some s -> settlement_str s
        | None -> "unsettled");
      (match attempts with
      | [ first_try; second_try ] ->
          check "the loser's rejection routed serialize-reissue"
            (List.mem "serialize-reissue" (decisions events first_try));
          Printf.printf "loser settled: %s\n"
            (match settlement_of settled first_try with
            | Some s -> settlement_str s
            | None -> "unsettled");
          Printf.printf "reissued attempt settled: %s\n"
            (match settlement_of settled second_try with
            | Some s -> settlement_str s
            | None -> "unsettled")
      | attempts ->
          Printf.printf "!! expected 2 lose attempts, saw %d\n"
            (List.length attempts));
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    winner settled: retired
    the loser's rejection routed serialize-reissue: true
    loser settled: squashed(reissue-loser)
    reissued attempt settled: retired
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* Footprint escapes (the B15 remainder): a load the node's event stream
   proves, landing outside its edge's compiled delivery filter, surfaces
   at retire as the typed [Footprint_escape] event, a violated
   [footprint_cover] verdict on the settled map, and the escape list in
   [Report.explain]'s story — the witness the declaration must grow to
   cover (the node consulted state whose invalidations its subscription
   will never carry). The declaration is a filter, never a wall: the
   escapee still retires. A sibling whose read_globs cover its read is
   the control — no event, no offender
   (docs/architecture/30-channels.md § footprint filtering). *)

let%expect_test "footprint escape: an uncovered load surfaces at retire as \
                 the typed event and the footprint_cover verdict" =
  let task = json_relation "task" in
  let eout = json_relation "eout" in
  let cout = json_relation "cout" in
  let escapee = template "escapee" in
  let covered = template ~read_globs:[ "covered.txt" ] "covered" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed eout;
          Theory.Relation.Packed cout;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"escape" ~for_:"task"
            ~exists:("eout", Theory.Window.nodes 1)
            ~by:escapee ();
          Theory.Spawn.v ~name:"cover" ~for_:"task"
            ~exists:("cout", Theory.Window.nodes 1)
            ~by:covered ();
        ]
  in
  let repo, worktrees, ledger_path =
    sandbox
      ~files:[ ("notes.txt", "n1\n"); ("covered.txt", "c1\n") ]
      "goat_escape_"
  in
  let executors =
    [
      (* The escapee reads the committed fixture notes.txt through its
         checkout — twice, so the one-event-per-address dedup is
         exercised — with an empty read_globs declaration: the load lands
         outside the compiled footprint (the constructible v0 escape; a
         read of the node's OWN draft is not one — it observes nothing,
         per the self-witness ruling). *)
      binding ~by:escapee
        ~script:
          [
            read_tool "notes.txt";
            read_tool "notes.txt";
            R.Reply {|{"msg":"escaped"}|};
          ];
      (* The control performs the same shape with the read declared. *)
      binding ~by:covered
        ~script:[ read_tool "covered.txt"; R.Reply {|{"msg":"covered"}|} ];
    ]
  in
  (match
     Run.exec ~theory ~seed:(seed_task task)
       ~config:(config ~repo ~worktrees ~ledger_path ~executors ())
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let escaper =
        match node_of_stmt events "escape" with
        | Some n -> n
        | None -> failwith "escape never fired"
      in
      let coverer =
        match node_of_stmt events "cover" with
        | Some n -> n
        | None -> failwith "cover never fired"
      in
      let escapes_of node =
        List.filter_map
          (fun (e : Ledger.Event.t) ->
            match e.kind with
            | Ledger.Event.Footprint_escape { tool; address }
              when of_node node e ->
                Some
                  (Printf.sprintf "%s via %s"
                     (Ledger.Address.to_string address)
                     tool)
            | _ -> None)
          events
      in
      List.iter print_endline (escapes_of escaper);
      check "one escape event per address, tool named"
        (match escapes_of escaper with
        | [ "file:notes.txt via read_file" ] -> true
        | _ -> false);
      check "the covered sibling surfaced nothing"
        (List.is_empty (escapes_of coverer));
      check "the escapee still retired (the declaration is a filter, never \
             a wall)"
        (match settlement_of settled escaper with
        | Some Ledger.Settlement.Retired -> true
        | _ -> false);
      List.iter
        (fun (v : Theory.Law.verdict) ->
          Printf.printf "law %s: %s (offenders: %s)\n" v.law
            (if v.satisfied then "satisfied" else "violated")
            (String.concat ", " v.offenders))
        settled.Run.laws;
      (match Report.explain settled ~node:escaper with
      | None -> print_endline "!! no story for the escapee"
      | Some story ->
          check "the story reader carries the escape"
            (match story.Report.escapes with
            | [ ("read_file", Ledger.Address.File "notes.txt") ] -> true
            | _ -> false));
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    file:notes.txt via read_file
    one escape event per address, tool named: true
    the covered sibling surfaced nothing: true
    the escapee still retired (the declaration is a filter, never a wall): true
    law footprint_cover: violated (offenders: node#0 read file:notes.txt)
    the story reader carries the escape: true
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* F6, the end-to-end half (the claim/hide directions drive Retire.step
   with hand-appended events in test_witness.ml; this runs the ENGINE):
   a rigged node's [read_file] tool load enters the observed witness
   through the real tool loop, and gates its retirement through the real
   machinery — the sibling lands new content over the file first, the
   reader's witness fails to hold at retire, the typed Witness_moved
   rejection is classified per consumer and routed by the drift table,
   and the bounded reissue retires against the landed state. *)

let%expect_test "F6 end-to-end: an observed tool read gates retirement \
                 (stale content -> Witness_moved through the engine)" =
  let task = json_relation "task" in
  let mmid = json_relation "mmid" in
  let rmid = json_relation "rmid" in
  let mover = template "mover" in
  let reader = template ~read_globs:[ "notes.txt" ] "reader" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed mmid;
          Theory.Relation.Packed rmid;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"move" ~for_:"task"
            ~exists:("mmid", Theory.Window.nodes 1)
            ~by:mover ();
          Theory.Spawn.v ~name:"read" ~for_:"task"
            ~exists:("rmid", Theory.Window.nodes 1)
            ~by:reader ();
        ]
  in
  (* notes.txt is committed repository state before the run: the reader's
     worktree checkout carries v1 until the mover's landing moves it. *)
  let repo, worktrees, ledger_path =
    sandbox ~files:[ ("notes.txt", "v1\n") ] "goat_f6_e2e_"
  in
  let executors =
    [
      binding ~by:mover
        ~script:[ write_tool "notes.txt" "v2\n"; R.Reply {|{"msg":"moved"}|} ];
      (* Steps are consumed across attempts of the same executor value:
         the reissued attempt drains the landing's queued invalidation at
         a read-free yield (additive for a node that has read nothing —
         the delivery test's pattern), then re-reads and re-replies. *)
      binding ~by:reader
        ~script:
          [
            read_tool "notes.txt";
            R.Reply {|{"msg":"r1"}|};
            R.Yield;
            read_tool "notes.txt";
            R.Reply {|{"msg":"r2"}|};
          ];
    ]
  in
  (match
     Run.exec ~theory ~seed:(seed_task task)
       ~config:(config ~repo ~worktrees ~ledger_path ~executors ())
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      (match nodes_of_stmt events "read" with
      | [ first; second ] ->
          check "the tool read entered the observed witness (read_file Load)"
            (not (List.is_empty (file_load_triples events first)));
          List.iter
            (fun d -> Printf.printf "first attempt drift: %s\n" d)
            (drift_notes events first);
          Printf.printf "first attempt settled: %s\n"
            (match settlement_of settled first with
            | Some s -> settlement_str s
            | None -> "unsettled");
          List.iter
            (fun d -> Printf.printf "reissue drift: %s\n" d)
            (drift_notes events second);
          Printf.printf "reissued attempt settled: %s\n"
            (match settlement_of settled second with
            | Some s -> settlement_str s
            | None -> "unsettled");
          (* The reissue read the landed state: its witness triple carries
             the moved file's committed generation, not a zero stamp. *)
          List.iter
            (fun t -> Printf.printf "reissue witnessed %s\n" t)
            (file_load_triples events second)
      | attempts ->
          Printf.printf "!! expected 2 read attempts, saw %d\n"
            (List.length attempts));
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    the tool read entered the observed witness (read_file Load): true
    first attempt drift: file:notes.txt: breaking_broad -> flush_subtree
    first attempt settled: squashed(reissue-loser)
    reissue drift: file:notes.txt: additive -> reconcile_note
    reissued attempt settled: retired
    reissue witnessed file:notes.txt @ g1
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* B7's generation threading (the wave-2 OPEN item closed): a tool load
   of a COMMITTED address witnesses the real committed generation — the
   chase threads its committed-state lookup into the executor's toolset
   through the invocation — while in-flight and absent addresses stay at
   the zero stamp with the content hash carrying the judgment. The
   consumer parks (floor above any chain) so it provably reads after the
   landing. *)

(* Shared skeleton for the committed-read falsifiers below (B7 threading,
   C1 self-witness, C2 glob listing): a mover lands notes.txt v2 (the
   committed entry moves to g1), and a floored reader — parked on the
   mover's head, so it provably runs after the landing — exercises one
   read shape against it. *)
let run_reader_after_landing ~prefix ~reader_globs ~reader_script =
  let task = json_relation "task" in
  let mid = json_relation "mid" in
  let out = json_relation "out" in
  let mover = template "gen-mover" in
  let reader = template ~read_globs:reader_globs "gen-reader" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed mid;
          Theory.Relation.Packed out;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"move" ~for_:"task"
            ~exists:("mid", Theory.Window.nodes 1)
            ~by:mover ();
          Theory.Spawn.v ~name:"read" ~for_:"mid"
            ~exists:("out", Theory.Window.nodes 1)
            ~by:reader ();
        ]
  in
  let repo, worktrees, ledger_path = sandbox ~files:[ ("notes.txt", "v1\n") ] prefix in
  let executors =
    [
      binding ~by:mover
        ~script:[ write_tool "notes.txt" "v2\n"; R.Reply {|{"msg":"m"}|} ];
      binding ~by:reader ~script:reader_script;
    ]
  in
  (* The floor suspends the read instead of hypothesizing, so the reader
     provably runs after the mover's landing committed notes.txt. *)
  let backstops =
    { Speculate.Backstops.default with confidence_floor = 2.0 }
  in
  Run.exec ~theory ~seed:(seed_task task)
    ~config:(config ~repo ~worktrees ~ledger_path ~backstops ~executors ())

let%expect_test "tool loads witness the real committed generation once the \
                 address is committed" =
  (* The read-free yield drains the landing's invalidation (additive
     for a node that has read nothing) so the falsifier isolates the
     generation stamp, not the delivery lane. *)
  (match
     run_reader_after_landing ~prefix:"goat_gen_"
       ~reader_globs:[ "notes.txt" ]
       ~reader_script:
         [ R.Yield; read_tool "notes.txt"; R.Reply {|{"msg":"r"}|} ]
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let r_node =
        match node_of_stmt events "read" with
        | Some n -> n
        | None -> failwith "read never fired"
      in
      List.iter
        (fun t -> Printf.printf "reader witnessed %s\n" t)
        (file_load_triples events r_node);
      check "the reader retired (content matched, witness held)"
        (match settlement_of settled r_node with
        | Some Ledger.Settlement.Retired -> true
        | _ -> false);
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    reader witnessed file:notes.txt @ g1
    the reader retired (content matched, witness held): true
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* C1 (wave 3) — self-witness: a read served from the node's OWN draft
   is store-to-load forwarding of in-flight work, not an observation of
   committed state, so it claims NOTHING in the observed witness. A
   draft triple could never hold at the node's own retire (its landing
   has not happened when the witness is judged), so pre-fix this
   scenario poisoned the witness — the draft's content hash stamped at
   the committed generation — and correct work Witness_moved through
   three spurious reissues into a Reissue_loser squash. The committed
   read that SEEDED the draft still gates retirement (F6 stays
   red-capable: a sibling landing over notes.txt still rejects). *)

let%expect_test "a read served from the node's own draft claims nothing: \
                 edit a committed file, read the draft back, retire \
                 cleanly on the first attempt" =
  (match
     run_reader_after_landing ~prefix:"goat_selfwit_"
       ~reader_globs:[ "notes.txt" ]
       ~reader_script:
         [
           R.Yield;
           (* the committed read: witnesses (g1, v2) — this is the claim
              that gates retirement *)
           read_tool "notes.txt";
           (* the node's own edit: notes.txt becomes a draft *)
           write_tool "notes.txt" "v3\n";
           (* the draft read-back: store-to-load forwarding, no claim *)
           read_tool "notes.txt";
           R.Reply {|{"msg":"r"}|};
         ]
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      (match nodes_of_stmt events "read" with
      | [ r_node ] ->
          List.iter
            (fun t -> Printf.printf "reader witnessed %s\n" t)
            (file_load_triples events r_node);
          check "the reader retired on the first attempt (no reissue)"
            (match settlement_of settled r_node with
            | Some Ledger.Settlement.Retired -> true
            | _ -> false)
      | attempts ->
          Printf.printf "!! expected 1 read attempt, saw %d\n"
            (List.length attempts));
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    reader witnessed file:notes.txt @ g1
    the reader retired on the first attempt (no reissue): true
    replay: coherent
    |}]

(* ------------------------------------------------------------------ *)
(* C2 (wave 3) — the glob listing's observation: which paths exist. For
   a path whose committed state is Landed the listing witnesses the
   committed (generation, content) pair straight from the lookup — never
   a hash of the path string (the pre-fix poison, which could not hold
   against any Landed comparison). A path that exists only in flight (a
   draft, or absent from committed state) contributes no triple:
   existence-of-uncommitted is not a witnessable claim in v0. *)

let glob_load_triples events node =
  List.concat_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Load { tool = "glob_list"; observed } when of_node node e
        ->
          List.map
            (fun (a, g, _) ->
              Format.asprintf "%a @@ %a" Ledger.Address.pp a
                Ledger.Generation.pp g)
            observed
      | _ -> [])
    events

let%expect_test "glob_list over a committed file witnesses the committed \
                 (generation, content) pair and retires cleanly; a \
                 draft-only match contributes no triple" =
  (match
     run_reader_after_landing ~prefix:"goat_glob_"
       ~reader_globs:[ "notes.txt" ]
       ~reader_script:
         [
           R.Yield;
           (* a draft-only file that the glob will also match *)
           write_tool "scratch.txt" "wip\n";
           R.Call_tool
             {
               name = "glob_list";
               input = `Assoc [ ("pattern", `String "*.txt") ];
             };
           R.Reply {|{"msg":"g"}|};
         ]
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      (match nodes_of_stmt events "read" with
      | [ r_node ] ->
          List.iter
            (fun t -> Printf.printf "glob witnessed %s\n" t)
            (glob_load_triples events r_node);
          check "the glob-lister retired on the first attempt"
            (match settlement_of settled r_node with
            | Some Ledger.Settlement.Retired -> true
            | _ -> false)
      | attempts ->
          Printf.printf "!! expected 1 read attempt, saw %d\n"
            (List.length attempts));
      Printf.printf "replay: %s\n" (replay_verdict settled.Run.ledger));
  [%expect
    {|
    glob witnessed file:notes.txt @ g1
    the glob-lister retired on the first attempt: true
    replay: coherent
    |}]
