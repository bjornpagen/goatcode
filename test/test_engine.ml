(* Falsifiers, group "engine" (docs/architecture/80-validation.md § the
   falsifier discipline):

   - F1 max-of-legs: a diamond theory's wall clock is the slowest leg,
     never the sum — the dependency structure IS the schedule
     (docs/architecture/40-scheduling.md § eager start, § read-time
     binding).
   - F2 no head-of-line blocking: a slow node on an open port never delays
     an unrelated ready node.
   - F4 dispatch purity: no I/O, logging, or await on the
     settlement-to-issue path beyond the ledger append, enforced by
     instrumentation in this test build
     (docs/architecture/40-scheduling.md § ports and priority).

   Rigged executors only ([Agent.Rigged]); [Agent.claude_cli] is never
   constructed here. No sleeps: [Delay_s] is scheduling pressure the rigged
   executor consumes without wall-clock cost, and the F1 expectation that
   7200 scripted seconds finish in real milliseconds is itself an
   assertion.

   The v0 substrate is synchronous (one process; one scheduling action per
   [Chase.step]), so wall-clock overlap is asserted where v0 records the
   schedule: the ledger's decision trace. "The dependency structure IS the
   schedule" is judged on issue order — an engine that gated a leg's start
   on anything but its operands (a sibling's completion, a settlement)
   would reorder the trace and fail these expectations, which is exactly
   the sum-of-legs scheduler each falsifier tries to smuggle in. *)

open Goatcode
module R = Agent.Rigged

(* ------------------------------------------------------------------ *)
(* Harness: theories over raw-JSON payloads, rigged executors, temp
   sandboxes. The identity codec is enough — these falsifiers exercise the
   engine's scheduling laws, not the contract layer's parse. *)

let msg_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "properties",
        `Assoc
          [
            ( "msg",
              `Assoc
                [
                  ("type", `String "string");
                  ("description", `String "A short status message.");
                ] );
          ] );
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

let template name =
  Theory.Executor.Agent_template
    { name; pin; preamble = name ^ ": a rigged test template"; read_globs = []; effects = [] }

let binding ~by ~port ~script =
  {
    Chase.executor = Theory.Executor.id by;
    runtime = R.executor ~script;
    fallback = None;
    repair_budget = Agent.Repair_budget.v 1;
    port;
  }

let admit ~relations ~statements =
  match Theory.declare ~relations ~statements ~laws:[] with
  | Ok theory -> theory
  | Error errors ->
      List.iter (fun e -> print_endline (Theory.Admission.to_string e)) errors;
      failwith "theory did not admit"

let fresh_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

type sandbox = {
  root : string;
  repo : string;
  worktrees : string;
  ledger_path : string;
}

let sandbox prefix =
  let root = fresh_dir prefix in
  let sub name =
    let p = Filename.concat root name in
    Unix.mkdir p 0o755;
    p
  in
  {
    root;
    repo = sub "repo";
    worktrees = sub "worktrees";
    ledger_path = Filename.concat root "ledger.bin";
  }

let config sb ~ports ~executors =
  {
    Run.repo = sb.repo;
    committed_branch = "goat-committed";
    worktree_root = sb.worktrees;
    ledger_path = sb.ledger_path;
    ports;
    executors;
    backstops = Speculate.Backstops.default;
    switches = [];
    merges = Retire.Merge_registry.empty;
  }

let seed_task task = [ Theory.Tuple.v task (`Assoc [ ("msg", `String "go") ]) ]

(* ------------------------------------------------------------------ *)
(* Ledger-trace utilities: every assertion below is a query over the
   recorded decision trace, per the falsifier discipline (the ledger is
   the journal the laws are judged against). *)

let indexed events = List.mapi (fun i e -> (i, e)) events

let first_index events pred =
  List.find_map (fun (i, e) -> if pred e then Some i else None) (indexed events)

let is_agent_turn (e : Ledger.Event.t) =
  match e.kind with Ledger.Event.Agent_turn _ -> true | _ -> false

let is_settled (e : Ledger.Event.t) =
  match e.kind with Ledger.Event.Settled _ -> true | _ -> false

let of_node node (e : Ledger.Event.t) =
  match e.node with Some n -> Id.equal n node | None -> false

(* The (index, node) of a statement's firing record. One firing per
   statement in these theories. *)
let fired events stmt =
  List.find_map
    (fun (i, (e : Ledger.Event.t)) ->
      match e.kind with
      | Ledger.Event.Fired { provenance; _ }
        when String.equal
               (Theory.Statement.to_string
                  provenance.Ledger.Provenance.statement)
               stmt ->
          Option.map (fun n -> (i, n)) e.node
      | _ -> None)
    (indexed events)

let settled_index events node =
  first_index events (fun e -> is_settled e && of_node node e)

let turn_index events node =
  first_index events (fun e -> is_agent_turn e && of_node node e)

let req label = function
  | Some v -> v
  | None -> failwith (label ^ ": absent from the trace")

let check label ok = Printf.printf "%s: %b\n" label ok

let settlement_name = function
  | Ledger.Settlement.Retired -> "retired"
  | Ledger.Settlement.Faulted _ -> "faulted"
  | Ledger.Settlement.Squashed _ -> "squashed"

let settlement_of (settled : Run.settled) node =
  List.find_map
    (fun (n, (report : Run.node_report)) ->
      if Id.equal n node then Some report.Run.settlement else None)
    settled.Run.nodes

let all_retired (settled : Run.settled) =
  settled.Run.nodes <> []
  && List.for_all
       (fun (_, (report : Run.node_report)) ->
         match report.Run.settlement with
         | Ledger.Settlement.Retired -> true
         | Ledger.Settlement.Faulted _ | Ledger.Settlement.Squashed _ -> false)
       settled.Run.nodes

let committed_relations (settled : Run.settled) =
  settled.Run.tuples
  |> List.map (fun (t : Retire.Committed.tuple) -> t.Retire.Committed.relation)
  |> List.sort_uniq String.compare
  |> String.concat " "

(* ------------------------------------------------------------------ *)
(* F1 — max-of-legs.

   The diamond, in the v0 statement grammar (single-relation bodies; the
   true join body is OPEN in 10-theory.md): one source forks into two
   independent legs, and a downstream statement consumes one leg — the
   only real dependency edge.

       task ──> make_left  ──> left ──> wrap_left ──> wrap
            └─> make_right ──> right

   The left leg is scripted slow (two hours of scheduling pressure); the
   right leg is instant. A sum-of-legs scheduler — one that runs a leg to
   settlement before issuing its sibling — puts make_right's firing after
   make_left's settlement in the trace; a schedule that is the dependency
   structure issues both legs before either runs a single turn, and delays
   wrap_left only until its operand materializes in the producer's store
   buffer — data-generated instances start at materialization or
   hypothesis, whichever is earlier, BEFORE the producer settles
   (docs/architecture/40-scheduling.md § eager start). The wall clock of
   the whole run is then bounded by the slowest leg's own span, never the
   legs' sum — asserted here at trace level (issue order) and at
   real-clock level (7200 scripted seconds must not appear in the test's
   wall clock). *)

let%expect_test "F1 max-of-legs: the dependency structure is the schedule" =
  let task = json_relation "task" in
  let left = json_relation "left" in
  let right = json_relation "right" in
  let wrap = json_relation "wrap" in
  let lefty = template "lefty" in
  let righty = template "righty" in
  let wrapper = template "wrapper" in
  let theory =
    admit
      ~relations:
        [
          Theory.Relation.Packed task;
          Theory.Relation.Packed left;
          Theory.Relation.Packed right;
          Theory.Relation.Packed wrap;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"make_left" ~for_:"task"
            ~exists:("left", Theory.Window.nodes 1)
            ~by:lefty ();
          Theory.Spawn.v ~name:"make_right" ~for_:"task"
            ~exists:("right", Theory.Window.nodes 1)
            ~by:righty ();
          Theory.Spawn.v ~name:"wrap_left" ~for_:"left"
            ~exists:("wrap", Theory.Window.nodes 1)
            ~by:wrapper ();
        ]
  in
  let slow_leg =
    [
      R.Delay_s 3600.;
      R.Yield;
      R.Delay_s 3600.;
      R.Reply {|{"msg":"left landed"}|};
    ]
  in
  let executors =
    [
      binding ~by:lefty ~port:"main" ~script:slow_leg;
      binding ~by:righty ~port:"main"
        ~script:[ R.Reply {|{"msg":"right landed"}|} ];
      binding ~by:wrapper ~port:"main"
        ~script:[ R.Reply {|{"msg":"wrapped"}|} ];
    ]
  in
  let sb = sandbox "goat_f1_" in
  let started = Unix.gettimeofday () in
  let outcome =
    Run.exec ~theory ~seed:(seed_task task)
      ~config:(config sb ~ports:[ Chase.Port.open_ ~name:"main" ] ~executors)
  in
  let elapsed = Unix.gettimeofday () -. started in
  (match outcome with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let fired_left, left_node = req "make_left fired" (fired events "make_left") in
      let fired_right, _ = req "make_right fired" (fired events "make_right") in
      let fired_wrap, _ = req "wrap_left fired" (fired events "wrap_left") in
      let first_turn = req "an agent turn" (first_index events is_agent_turn) in
      let first_settle = req "a settlement" (first_index events is_settled) in
      let left_turn =
        req "make_left ran" (turn_index events left_node)
      in
      let left_settled =
        req "make_left settled" (settled_index events left_node)
      in
      check "both legs issued before any leg ran a turn"
        (fired_left < first_turn && fired_right < first_turn);
      check "both legs issued before any settlement"
        (fired_left < first_settle && fired_right < first_settle);
      check "the joining statement issued at its operand's materialization"
        (fired_wrap > left_turn);
      check "and before its producer settled (eager start)"
        (fired_wrap < left_settled);
      check "every node retired" (all_retired settled);
      Printf.printf "committed relations: %s\n" (committed_relations settled);
      check "wall clock bounded by the legs, never their 7200s sum"
        (elapsed < 60.));
  [%expect
    {|
    both legs issued before any leg ran a turn: true
    both legs issued before any settlement: true
    the joining statement issued at its operand's materialization: true
    and before its producer settled (eager start): true
    every node retired: true
    committed relations: left right task wrap
    wall clock bounded by the legs, never their 7200s sum: true
    |}]

(* ------------------------------------------------------------------ *)
(* F2 — no head-of-line blocking.

   Two unrelated statements share one OPEN port; the occupant declared
   first (and therefore fired and admitted first, FIFO within class) is
   slow. A head-of-line-blocking scheduler drives the occupant all the way
   to settlement before the unrelated ready node gets a turn — in the
   trace, fast's first agent turn would land after slow's settlement. The
   law says never: the open port admits the ready node, and the trace
   shows fast running before the slow occupant settles.

   Second killing attempt: the slow occupant dies mid-flight. Its fault is
   its own — the unrelated node still retires, its tuple still commits,
   and nothing of the occupant's failure leaks into the sibling's
   settlement (docs/architecture/40-scheduling.md § settlement). *)

let%expect_test "F2 no head-of-line blocking on an open port" =
  let run ~slow_script =
    let task = json_relation "task" in
    let slow_out = json_relation "slow_out" in
    let fast_out = json_relation "fast_out" in
    let slowpoke = template "slowpoke" in
    let speedy = template "speedy" in
    let theory =
      admit
        ~relations:
          [
            Theory.Relation.Packed task;
            Theory.Relation.Packed slow_out;
            Theory.Relation.Packed fast_out;
          ]
        ~statements:
          [
            (* Declared first: fires first, admitted first — the occupant. *)
            Theory.Spawn.v ~name:"slow_stmt" ~for_:"task"
              ~exists:("slow_out", Theory.Window.nodes 1)
              ~by:slowpoke ();
            Theory.Spawn.v ~name:"fast_stmt" ~for_:"task"
              ~exists:("fast_out", Theory.Window.nodes 1)
              ~by:speedy ();
          ]
    in
    let executors =
      [
        binding ~by:slowpoke ~port:"shared" ~script:slow_script;
        binding ~by:speedy ~port:"shared"
          ~script:[ R.Reply {|{"msg":"fast landed"}|} ];
      ]
    in
    let sb = sandbox "goat_f2_" in
    Run.exec ~theory ~seed:(seed_task task)
      ~config:
        (config sb ~ports:[ Chase.Port.open_ ~name:"shared" ] ~executors)
  in
  (* Attempt 1: a slow-but-successful occupant. *)
  (match
     run
       ~slow_script:
         [
           R.Delay_s 3600.;
           R.Yield;
           R.Delay_s 3600.;
           R.Yield;
           R.Reply {|{"msg":"slow landed"}|};
         ]
   with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let _, slow_node = req "slow_stmt fired" (fired events "slow_stmt") in
      let _, fast_node = req "fast_stmt fired" (fired events "fast_stmt") in
      let fast_turn = req "fast ran" (turn_index events fast_node) in
      let slow_settle = req "slow settled" (settled_index events slow_node) in
      check "unrelated ready node ran before the slow occupant settled"
        (fast_turn < slow_settle);
      check "both nodes retired" (all_retired settled);
      Printf.printf "committed relations: %s\n" (committed_relations settled));
  (* Attempt 2: the occupant dies mid-flight; unrelated work is untouched. *)
  (match run ~slow_script:[ R.Delay_s 3600.; R.Fault "provider stalled" ] with
  | Error _ -> print_endline "run rejected as misuse"
  | Ok settled ->
      let events = Ledger.Replay.events settled.Run.ledger in
      let _, slow_node = req "slow_stmt fired" (fired events "slow_stmt") in
      let _, fast_node = req "fast_stmt fired" (fired events "fast_stmt") in
      let name_of node =
        settlement_name (req "a settlement" (settlement_of settled node))
      in
      Printf.printf "dead occupant settled: %s\n" (name_of slow_node);
      Printf.printf "unrelated ready node settled: %s\n" (name_of fast_node);
      Printf.printf "committed relations: %s\n" (committed_relations settled));
  [%expect
    {|
    unrelated ready node ran before the slow occupant settled: true
    both nodes retired: true
    committed relations: fast_out slow_out task
    dead occupant settled: faulted
    unrelated ready node settled: retired
    committed relations: fast_out task
    |}]

(* ------------------------------------------------------------------ *)
(* F4 — dispatch purity, instrumented.

   The law: between a settlement (or a producer's completion — under
   eager start the dependent issues at materialization, before the
   producer settles) and the dispatch of its dependents the engine
   performs no I/O, no logging, no awaits beyond the ledger append (the
   one store the path owes). The test build instruments the path directly
   by driving [Chase.step] one scheduling action at a time:

   - drive a two-stage theory (task -> produce -> mid -> consume -> out)
     until the producer completes (its heads materialize in its store
     buffer);
   - the next scheduling action IS the issue path: it must issue the
     dependent (fire [consume]);
   - around exactly that action, capture stderr (logging), snapshot every
     file under the sandbox (I/O), and diff the ledger (the permitted
     append: the firing record and the lifecycle decision markers, both
     ledger events). stdout is implicitly instrumented: this is an expect
     test, so any engine print would corrupt the expectation below.

   The whole-trace check then re-reads the finished ledger: between every
   settlement event and the next firing event there is no load, store,
   effect, agent-turn, or repair event — the taxonomy's I/O classes never
   ride the path, anywhere in the run. *)

let rec snapshot dir ~exclude acc =
  Array.fold_left
    (fun acc name ->
      let p = Filename.concat dir name in
      if String.equal p exclude then acc
      else if Sys.is_directory p then snapshot p ~exclude (("dir " ^ p) :: acc)
      else
        Printf.sprintf "file %s %s" p (Digest.to_hex (Digest.file p)) :: acc)
    acc (Sys.readdir dir)

let world sb = List.sort String.compare (snapshot sb.root ~exclude:sb.ledger_path [])

let ledger_size sb = (Unix.stat sb.ledger_path).Unix.st_size

let with_stderr_captured f =
  let tmp = Filename.temp_file "goat_f4_stderr" ".txt" in
  Out_channel.flush Out_channel.stderr;
  let saved = Unix.dup Unix.stderr in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 fd Unix.stderr;
  Unix.close fd;
  let restore () =
    Out_channel.flush Out_channel.stderr;
    Unix.dup2 saved Unix.stderr;
    Unix.close saved
  in
  let result =
    try f ()
    with exn ->
      restore ();
      raise exn
  in
  restore ();
  let logged = In_channel.with_open_bin tmp In_channel.input_all in
  Sys.remove tmp;
  (result, logged)

let%expect_test "F4 dispatch purity: settlement-to-issue is the ledger append and nothing else" =
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
  let sb = sandbox "goat_f4_" in
  let ledger = Ledger.create ~path:sb.ledger_path in
  let committed =
    Retire.Committed.open_ ~repo:sb.repo ~branch:"goat-committed"
  in
  let channels = Channel.open_all theory in
  let chase =
    Chase.create ~theory ~ledger ~committed ~channels
      ~worktree_root:sb.worktrees
      ~ports:[ Chase.Port.open_ ~name:"main" ]
      ~executors:
        [
          binding ~by:producer ~port:"main"
            ~script:[ R.Reply {|{"msg":"mid landed"}|} ];
          binding ~by:consumer ~port:"main"
            ~script:[ R.Reply {|{"msg":"out landed"}|} ];
        ]
      ~backstops:Speculate.Backstops.default ~switches:[]
      ~merges:Retire.Merge_registry.empty ~seed:(seed_task task) ()
  in
  let retired_count () =
    List.length
      (List.filter
         (fun (_, s) ->
           match s with Ledger.Settlement.Retired -> true | _ -> false)
         (Chase.settlements chase))
  in
  (* Drive to the producer's completion (its store buffer materializes),
     one scheduling action at a time. *)
  let rec until_producer_completed fuel =
    if fuel = 0 then failwith "producer did not complete within fuel"
    else if
      Option.is_some (first_index (Ledger.Replay.events ledger) is_agent_turn)
    then ()
    else
      match Chase.step chase with
      | `Progressed -> until_producer_completed (fuel - 1)
      | `Quiescent -> failwith "quiescent before the producer completed"
  in
  until_producer_completed 100;
  check "the producer completed; its dependent is not yet issued"
    (retired_count () = 0
    && Option.is_none (fired (Ledger.Replay.events ledger) "consume"));
  (* Instrument exactly the completion-to-issue action. *)
  let world_before = world sb in
  let ledger_before = ledger_size sb in
  let events_before = List.length (Ledger.Replay.events ledger) in
  let step_result, logged = with_stderr_captured (fun () -> Chase.step chase) in
  let world_after = world sb in
  let appended =
    List.filteri
      (fun i _ -> i >= events_before)
      (Ledger.Replay.events ledger)
  in
  check "the completion-to-issue action progressed"
    (match step_result with `Progressed -> true | `Quiescent -> false);
  check "it issued the dependent statement"
    (Option.is_some (fired (Ledger.Replay.events ledger) "consume"));
  check "every event it appended is a firing record or lifecycle decision"
    (appended <> []
    && List.for_all
         (fun (e : Ledger.Event.t) ->
           match e.kind with
           | Ledger.Event.Fired _ | Ledger.Event.Decision _ -> true
           | _ -> false)
         appended);
  check "the ledger grew (the one store the path owes)"
    (ledger_size sb > ledger_before);
  check "no other filesystem effect anywhere in the sandbox"
    (List.equal String.equal world_before world_after);
  check "nothing logged to stderr" (String.equal logged "");
  (* Finish the run, then re-read the whole trace: the taxonomy's I/O
     classes never appear between a settlement and the next issue. *)
  Chase.run_to_quiescence chase;
  check "the run quiesced with every node retired"
    (Chase.quiescent chase
    && retired_count () = 2
    && List.length (Chase.settlements chase) = 2);
  let pure_between_settle_and_fire events =
    let rec scan pure = function
      | [] -> pure
      | (e : Ledger.Event.t) :: rest -> (
          match e.kind with
          | Ledger.Event.Settled _ ->
              let rec upto_fire ok = function
                | [] -> ok
                | (f : Ledger.Event.t) :: more -> (
                    match f.kind with
                    | Ledger.Event.Fired _ -> ok
                    | Ledger.Event.Load _ | Ledger.Event.Store _
                    | Ledger.Event.Effect _ | Ledger.Event.Agent_turn _
                    | Ledger.Event.Repair_attempt _ ->
                        upto_fire false more
                    | _ -> upto_fire ok more)
              in
              scan (pure && upto_fire true rest) rest
          | _ -> scan pure rest)
    in
    scan true events
  in
  check "no I/O event rides any settlement-to-issue stretch of the trace"
    (pure_between_settle_and_fire (Ledger.Replay.events ledger));
  [%expect
    {|
    the producer completed; its dependent is not yet issued: true
    the completion-to-issue action progressed: true
    it issued the dependent statement: true
    every event it appended is a firing record or lifecycle decision: true
    the ledger grew (the one store the path owes): true
    no other filesystem effect anywhere in the sandbox: true
    nothing logged to stderr: true
    the run quiesced with every node retired: true
    no I/O event rides any settlement-to-issue stretch of the trace: true
    |}]
