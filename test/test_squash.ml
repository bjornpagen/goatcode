(* Falsifiers, group "squash" (docs/architecture/50-api.md § the
   falsifier discipline):

   - F3 — squash precision. A fault or dead hypothesis squashes exactly the
     provenance-closed subtree; siblings retire undisturbed. The falsifier
     builds graphs where any over-squash removes a committed tuple a sibling
     owns and any under-squash leaks a doomed node's tuple into committed
     state, and asserts neither happens (docs/architecture/30-scheduling.md).

   - F5 — abort by construction. Kill a run at arbitrary points (fault
     injection at every yield class of the rigged executor, plus abandoning
     the engine after every possible number of scheduling steps); committed
     state contains only fully-retired nodes' effects
     (docs/architecture/30-scheduling.md § abort by construction). The
     old worktree-drop cleanliness arm is re-aimed per the flat org
     (50-api.md F5: the injection asserts committed-state purity and
     frontier re-derivation — boot = crash recovery, 20-medium.md § the
     crash story — instead of buffer-drop cleanliness; README.md § design
     of record vs shipped engine, rows 5 and 7): every kill point is
     re-booted through [Run.start]'s ordinary open path and the tree must
     agree with the re-derived frontier.

   - FL1 — squash-revert counterfactual. A producer stores over committed
     content, then squashes: the committed coordinate never moves, squash
     appends only settlements, the repair is a forward event, a consumer
     of the dead bytes is refused at retire and routed forward, and the
     only code path that can bring the old bytes back to the tree is
     [Retire.Frontier.materialize]'s cache fill (50-api.md § the flat-org
     roster, FL1; the grep-gate arm — no worktree/restore vocabulary in
     lib/ — is a dune rule in test/dune, and the negative-compile arm is
     probe_fl1_generation_retreat.ml).

   Rigged executors only ([Agent.Rigged]); no test constructs
   [Agent.claude_cli]; no network, no model, no sleeps ([Delay_s] is
   consumed without sleeping). *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Shell and fixture helpers.                                          *)

let sh cmd =
  let status = Sys.command (cmd ^ " >/dev/null 2>&1") in
  if status <> 0 then failwith ("command failed: " ^ cmd)

let sh_lines cmd =
  let tmp = Filename.temp_file "goatcode_test" ".out" in
  let status =
    Sys.command (Printf.sprintf "%s >%s 2>/dev/null" cmd (Filename.quote tmp))
  in
  let lines =
    if status = 0 then
      In_channel.with_open_text tmp (fun ic ->
          let rec go acc =
            match In_channel.input_line ic with
            | Some l -> go (l :: acc)
            | None -> List.rev acc
          in
          go [])
    else []
  in
  (try Sys.remove tmp with Sys_error _ -> ());
  lines

let git ~repo args =
  sh (Printf.sprintf "git -C %s %s" (Filename.quote repo) args)

(* One disposable run environment: a real git repo (the committed branch's
   storage engine — the ONE shared tree) and a ledger path. *)
let with_fixture f =
  let tmp = Filename.temp_dir "goatcode_squash" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () ->
      let repo = Filename.concat tmp "repo" in
      Sys.mkdir repo 0o755;
      git ~repo "init -q";
      git ~repo
        "-c user.name=goatcode-test -c user.email=test@localhost commit -q \
         --allow-empty -m fixture-seed";
      let ledger_path = Filename.concat tmp "ledger" in
      f ~repo ~ledger_path)

(* ------------------------------------------------------------------ *)
(* A small pipeline theory: task --work--> result --summarize--> summary.
   Payloads are schema-checked JSON (one closed record, one string field) —
   the smallest shape the LLM-safe subset admits. *)

let schema_json : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "properties",
        `Assoc
          [
            ( "note",
              `Assoc
                [
                  ("type", `String "string");
                  ("description", `String "free text");
                ] );
          ] );
      ("required", `List [ `String "note" ]);
      ("additionalProperties", `Bool false);
    ]

let json_codec : Yojson.Safe.t Contract.Codec.t =
  Contract.Codec.v ~of_json:Fun.id ~to_json:Fun.id

let relation name : Yojson.Safe.t Theory.Relation.t =
  Theory.Relation.v ~name (Contract.v ~name ~schema:schema_json ~codec:json_codec)

let task_rel = relation "task"
let result_rel = relation "result"
let summary_rel = relation "summary"

let pin =
  { Theory.Pin.provider = "rigged"; model = "fake"; sampling = []; options = [] }

let worker =
  Theory.Executor.Agent_template
    {
      name = "worker";
      pin;
      preamble = "produce the result tuple";
      read_globs = [];
      write_globs = [ "**" ];
      effects = [];
    }

let summarizer =
  Theory.Executor.Agent_template
    {
      name = "summarizer";
      pin;
      preamble = "summarize the result";
      read_globs = [];
      write_globs = [ "**" ];
      effects = [];
    }

let pipeline_theory () =
  match
    Theory.declare
      ~relations:
        [
          Theory.Relation.Packed task_rel;
          Theory.Relation.Packed result_rel;
          Theory.Relation.Packed summary_rel;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"work" ~for_:"task"
            ~exists:("result", Theory.Window.nodes 1)
            ~by:worker ();
          Theory.Spawn.v ~name:"summarize" ~for_:"result"
            ~exists:("summary", Theory.Window.nodes 1)
            ~by:summarizer ();
        ]
      ~laws:[]
  with
  | Ok t -> t
  | Error errs ->
      failwith
        ("pipeline theory rejected: "
        ^ String.concat "; " (List.map Theory.Admission.to_string errs))

let binding by script =
  {
    Chase.executor = Theory.Executor.id by;
    runtime = Agent.Rigged.executor ~script;
    fallback = None;
    repair_budget = Agent.Repair_budget.v 2;
    port = "main";
  }

let config ~repo ~ledger_path ~executors =
  {
    Run.repo;
    committed_branch = "goat";
    ledger_path;
    ports = [ Chase.Port.open_ ~name:"main" ];
    executors;
    backstops = Speculate.Backstops.default;
    switches = [];
    merges = Retire.Merge_registry.empty;
  }

let task_seed note = Theory.Tuple.v task_rel (`Assoc [ ("note", `String note) ])
let ok_reply note = Agent.Rigged.Reply (Printf.sprintf {|{"note":%S}|} note)

let write_tool path content =
  Agent.Rigged.Call_tool
    {
      name = "write_file";
      input = `Assoc [ ("path", `String path); ("content", `String content) ];
    }

(* ------------------------------------------------------------------ *)
(* Rendering helpers.                                                  *)

let origin_str = function
  | Ledger.Fault.Executor_error -> "executor-error"
  | Ledger.Fault.Repair_exhausted -> "repair-exhausted"
  | Ledger.Fault.Context_exhausted -> "context-exhausted"

let cause_str = function
  | Ledger.Squash_cause.Dead_hypothesis h -> "dead-hypothesis " ^ Id.to_string h
  | Ledger.Squash_cause.Upstream_fault n -> "upstream-fault " ^ Id.to_string n
  | Ledger.Squash_cause.Upstream_squash n -> "upstream-squash " ^ Id.to_string n
  | Ledger.Squash_cause.Reissue_loser -> "reissue-loser"
  | Ledger.Squash_cause.No_producer -> "no-producer"
  | Ledger.Squash_cause.Operator_abort -> "operator-abort"

let settlement_str = function
  | Ledger.Settlement.Retired -> "retired"
  | Ledger.Settlement.Faulted { origin; message } ->
      Printf.sprintf "faulted(%s: %s)" (origin_str origin) message
  | Ledger.Settlement.Squashed cause -> "squashed(" ^ cause_str cause ^ ")"

let ids_str ids = "[" ^ String.concat "; " (List.map Id.to_string ids) ^ "]"

let tuple_key (t : Retire.Committed.tuple) =
  t.Retire.Committed.relation ^ "/" ^ t.Retire.Committed.id

let retire_log ~repo =
  sh_lines
    (Printf.sprintf "git -C %s log --format=%%s goat --" (Filename.quote repo))
  |> List.filter_map (fun s ->
         let prefix = "retire " in
         if String.starts_with ~prefix s then
           Some
             (String.sub s (String.length prefix)
                (String.length s - String.length prefix))
         else None)
  |> List.sort String.compare

(* ------------------------------------------------------------------ *)
(* The F5 invariant: committed state contains only fully-retired nodes'
   effects. Checked from the ledger, the committed tuple set, and the
   durability boundary (git log). Re-aimed per the flat org (50-api.md
   F5; README.md § design of record vs shipped engine, row 5): the old
   checks 3-4 — per-node buffer directories and git's linked-worktree
   table — judged machinery that no longer exists; a squashed node's
   tree bytes are hygiene for [Retire.Frontier.materialize] (FL3's
   sweep), never committable state. *)

let abort_invariant_violations ~ledger ~settlements ~tuples ~seeds ~repo =
  let violations = ref [] in
  let bad fmt = Printf.ksprintf (fun s -> violations := s :: !violations) fmt in
  let minted_by =
    List.concat_map
      (fun (e : Ledger.Event.t) ->
        match (e.node, e.kind) with
        | Some n, Ledger.Event.Fired { minted; _ } ->
            List.map (fun (rel, id) -> (rel ^ "/" ^ id, Id.to_string n)) minted
        | _ -> [])
      (Ledger.Replay.events ledger)
  in
  let retired =
    List.filter_map
      (fun (n, s) ->
        match s with
        | Ledger.Settlement.Retired -> Some (Id.to_string n)
        | _ -> None)
      settlements
    |> List.sort String.compare
  in
  (* 1. Every committed tuple was minted by a node that fully retired — or
     is one of the run's seeds, committed at run open with no minting node
     (docs/architecture/70-api.md § running). *)
  List.iter
    (fun t ->
      let key = tuple_key t in
      if not (List.mem key seeds) then
        match List.assoc_opt key minted_by with
        | None -> bad "committed tuple %s has no minting provenance" key
        | Some n ->
            if not (List.mem n retired) then
              bad "committed tuple %s leaked from non-retired node %s" key n)
    tuples;
  (* 2. The durability boundary agrees: retirement commits on the committed
     branch are exactly the retired nodes. *)
  let log = retire_log ~repo in
  if not (List.equal String.equal log retired) then
    bad "retire commits [%s] disagree with retired nodes [%s]"
      (String.concat "; " log)
      (String.concat "; " retired);
  List.rev !violations

let print_violations = function
  | [] -> print_endline "invariant: ok"
  | vs -> List.iter (fun v -> print_endline ("VIOLATION: " ^ v)) vs

(* ==================================================================== *)
(* F3, unit: [Retire.squash_set] walks exactly the provenance-closed     *)
(* subtree — consumed-tuple edges, inherited hypotheses, and nothing     *)
(* else; already-settled nodes and unrelated siblings stay out.          *)
(* ==================================================================== *)

let%expect_test "F3: squash_set is exactly the provenance-closed subtree" =
  let tmp = Filename.temp_dir "goatcode_squash_unit" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () ->
      let ledger = Ledger.create ~path:(Filename.concat tmp "ledger") in
      let registry = Id.Registry.create () in
      let nodes : Ledger.node Id.Minter.t =
        Id.Minter.create ~registry ~realm:"node"
      in
      let hyps : Ledger.hypothesis Id.Minter.t =
        Id.Minter.create ~registry ~realm:"hypothesis"
      in
      let r_minter : Yojson.Safe.t Id.Minter.t =
        Id.Minter.create ~registry ~realm:"r"
      in
      let s_minter : Yojson.Safe.t Id.Minter.t =
        Id.Minter.create ~registry ~realm:"s"
      in
      let statement =
        match Theory.statements (pipeline_theory ()) with
        | (sid, _) :: _ -> sid
        | [] -> failwith "pipeline theory has no statements"
      in
      let fired node ?(hypotheses = []) ~consumed ~minted () =
        ignore
          (Ledger.append ledger ~node
             (Ledger.Event.Fired
                {
                  provenance =
                    { Ledger.Provenance.statement; consumed; hypotheses };
                  minted;
                })
            : Ledger.Event.t)
      in
      (* The graph. [a] is the root under test: it minted r#0 and took
         hypothesis [h_a].
           b consumed r#0 (child), minted s#0
           c consumed s#0 (grandchild)
           d is an unrelated sibling: minted r#1 from another seed tuple
           e inherited h_a through its firing provenance
           g consumed the sibling's r#1 — must never squash with a
           settled consumed r#0 but already retired — settles exactly once,
             so no squash may touch it *)
      let a = Id.mint nodes in
      let b = Id.mint nodes in
      let c = Id.mint nodes in
      let d = Id.mint nodes in
      let e = Id.mint nodes in
      let g = Id.mint nodes in
      let settled = Id.mint nodes in
      let h_a = Id.mint hyps in
      let ra = Id.to_string (Id.mint r_minter) in
      let sb = Id.to_string (Id.mint s_minter) in
      let rd = Id.to_string (Id.mint r_minter) in
      fired a ~consumed:[ ("task", "t1") ] ~minted:[ ("r", ra) ] ();
      ignore
        (Ledger.append ledger ~node:a
           (Ledger.Event.Hypothesis_taken
              {
                hypothesis = h_a;
                address = Ledger.Address.Contract "r";
                source = "issued-contract:r";
                content = Ledger.Content_hash.of_string "guess";
                confidence = 1.0;
              })
          : Ledger.Event.t);
      fired b ~consumed:[ ("r", ra) ] ~minted:[ ("s", sb) ] ();
      fired c ~consumed:[ ("s", sb) ] ~minted:[] ();
      fired d ~consumed:[ ("task", "t2") ] ~minted:[ ("r", rd) ] ();
      fired e ~hypotheses:[ h_a ] ~consumed:[ ("task", "t3") ] ~minted:[] ();
      fired g ~consumed:[ ("r", rd) ] ~minted:[] ();
      fired settled ~consumed:[ ("r", ra) ] ~minted:[] ();
      ignore
        (Ledger.append ledger ~node:settled
           (Ledger.Event.Settled Ledger.Settlement.Retired)
          : Ledger.Event.t);
      (* Upstream fault at [a]: the set is a's dependents — b (consumed its
         mint), e (carries the hypothesis a took), and transitively c.
         Not a itself (it settles as its own fault), not d, not g, not the
         already-settled consumer. *)
      Printf.printf "upstream-fault a: %s\n"
        (ids_str
           (Retire.squash_set ledger
              ~cause:(Ledger.Squash_cause.Upstream_fault a)));
      (* Dead hypothesis h_a: every node carrying it (a took it, e
         inherited it) plus the provenance closure below them. *)
      Printf.printf "dead-hypothesis h_a: %s\n"
        (ids_str
           (Retire.squash_set ledger
              ~cause:(Ledger.Squash_cause.Dead_hypothesis h_a)));
      (* Operator abort: every unsettled fired node. *)
      Printf.printf "operator-abort: %s\n"
        (ids_str
           (Retire.squash_set ledger ~cause:Ledger.Squash_cause.Operator_abort));
      [%expect
        {|
        upstream-fault a: [node#1; node#2; node#4]
        dead-hypothesis h_a: [node#0; node#1; node#2; node#4]
        operator-abort: [node#0; node#1; node#2; node#3; node#4; node#5]
        |}];
      (* Execute the squash for the upstream fault. Provisional ids of the
         doomed subtree die with it (ra was minted by a, which settles as
         its own fault — [Retire.squash] handles only the dependents, so we
         pass a's cause and check the subtree's own mints). The squash is
         the settlement append — nothing filesystem-shaped rides it
         (README.md § design of record vs shipped engine, row 5); nothing
         renumbers; a second walk finds nothing left. *)
      Retire.squash ~ledger ~registry
        ~cause:(Ledger.Squash_cause.Upstream_fault a);
      Printf.printf "sb resolves: %b\n"
        (Result.is_ok (Id.Registry.resolve registry ~realm:"s" sb));
      Printf.printf "rd resolves: %b\n"
        (Result.is_ok (Id.Registry.resolve registry ~realm:"r" rd));
      let squash_settlements =
        List.length
          (List.filter
             (fun (ev : Ledger.Event.t) ->
               match ev.kind with
               | Ledger.Event.Settled (Ledger.Settlement.Squashed _) -> true
               | _ -> false)
             (Ledger.Replay.events ledger))
      in
      Printf.printf "squash settlements sealed: %d\n" squash_settlements;
      Printf.printf "second walk: %s\n"
        (ids_str
           (Retire.squash_set ledger
              ~cause:(Ledger.Squash_cause.Upstream_fault a)));
      [%expect
        {|
        sb resolves: false
        rd resolves: true
        squash settlements sealed: 3
        second walk: []
        |}])

(* ==================================================================== *)
(* F3, store-to-load edge: a consumer whose hypothesis was snooped from   *)
(* a producer's store buffer is in the producer's dead subtree —          *)
(* "producer squash → subtree squash", always                            *)
(* (docs/architecture/40-scheduling.md § read-time binding;              *)
(* docs/architecture/30-channels.md § store-to-load forwarding). The     *)
(* [source] string is written exactly as the engine writes it            *)
(* (chase.ml's [source_label]: "store-buffer:<producer id>").            *)
(* ==================================================================== *)

let%expect_test "F3: snooped store-buffer dependents squash with the producer" =
  let tmp = Filename.temp_dir "goatcode_squash_snoop" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () ->
      let ledger = Ledger.create ~path:(Filename.concat tmp "ledger") in
      let registry = Id.Registry.create () in
      let nodes : Ledger.node Id.Minter.t =
        Id.Minter.create ~registry ~realm:"node"
      in
      let hyps : Ledger.hypothesis Id.Minter.t =
        Id.Minter.create ~registry ~realm:"hypothesis"
      in
      let statement =
        match Theory.statements (pipeline_theory ()) with
        | (sid, _) :: _ -> sid
        | [] -> failwith "pipeline theory has no statements"
      in
      let producer = Id.mint nodes in
      let snooper = Id.mint nodes in
      let h = Id.mint hyps in
      ignore
        (Ledger.append ledger ~node:producer
           (Ledger.Event.Fired
              {
                provenance =
                  {
                    Ledger.Provenance.statement;
                    consumed = [ ("task", "t1") ];
                    hypotheses = [];
                  };
                minted = [ ("r", "r#0") ];
              })
          : Ledger.Event.t);
      ignore
        (Ledger.append ledger ~node:snooper
           (Ledger.Event.Fired
              {
                provenance =
                  {
                    Ledger.Provenance.statement;
                    consumed = [ ("task", "t2") ];
                    hypotheses = [];
                  };
                minted = [];
              })
          : Ledger.Event.t);
      (* The snooper read the producer's uncommitted store buffer: its
         hypothesis source is the producer — rendered exactly as the
         engine's dispatch path renders a [Store_buffer] source. *)
      ignore
        (Ledger.append ledger ~node:snooper
           (Ledger.Event.Hypothesis_taken
              {
                hypothesis = h;
                address = Ledger.Address.File "src/lib.ml";
                source = "store-buffer:" ^ Id.to_string producer;
                content = Ledger.Content_hash.of_string "partial artifact";
                confidence = 0.9;
              })
          : Ledger.Event.t);
      (* The producer faults. Its snooping consumer hypothesized from state
         that no longer exists; under-squashing it would let work derived
         from a dropped store buffer retire into committed state. *)
      Printf.printf "upstream-fault producer: %s\n"
        (ids_str
           (Retire.squash_set ledger
              ~cause:(Ledger.Squash_cause.Upstream_fault producer)));
      [%expect {| upstream-fault producer: [node#1] |}])

(* ==================================================================== *)
(* F3, end-to-end: two sibling subtrees from two seed tasks; one worker   *)
(* faults. The dead sibling's subtree squashes exactly; the healthy       *)
(* sibling's whole subtree retires undisturbed. Over-squash would remove  *)
(* result#0 or summary#0 from the committed tuples; under-squash would    *)
(* leak result#1. Neither happens.                                        *)
(* ==================================================================== *)

let%expect_test "F3: end-to-end sibling precision through Run.exec" =
  with_fixture (fun ~repo ~ledger_path ->
      let theory = pipeline_theory () in
      let executors =
        [
          (* First firing (task#0) answers; second firing (task#1) faults. *)
          binding worker [ ok_reply "from t1"; Agent.Rigged.Fault "injected" ];
          binding summarizer [ ok_reply "summary of t1" ];
        ]
      in
      let config = config ~repo ~ledger_path ~executors in
      match
        Run.exec ~theory ~seed:[ task_seed "t1"; task_seed "t2" ] ~config
      with
      | Error _ -> print_endline "unexpected host misuse"
      | Ok settled ->
          List.iter
            (fun (n, (report : Run.node_report)) ->
              Printf.printf "%s: %s\n" (Id.to_string n)
                (settlement_str report.settlement))
            settled.nodes;
          Printf.printf "tuples: [%s]\n"
            (String.concat "; " (List.map tuple_key settled.tuples));
          Printf.printf "retire commits: [%s]\n"
            (String.concat "; " (retire_log ~repo));
          let nodes_settlements =
            List.map
              (fun (n, (r : Run.node_report)) -> (n, r.settlement))
              settled.nodes
          in
          print_violations
            (abort_invariant_violations ~ledger:settled.ledger
               ~settlements:nodes_settlements ~tuples:settled.tuples
               ~seeds:[ "task/task#0"; "task/task#1" ] ~repo);
          (* Settle order: the fault lands at dispatch, before the sibling
             reaches retirement — so node#1 settles first. *)
          [%expect
            {|
            node#1: faulted(executor-error: injected)
            node#0: retired
            node#2: retired
            tuples: [task/task#0; task/task#1; result/result#0; summary/summary#0]
            retire commits: [node#0; node#2]
            invariant: ok
            |}])

(* ==================================================================== *)
(* F5: fault injection at every yield class of the rigged executor.       *)
(* Every class the executor can suspend or die at: immediately, after a   *)
(* forced [Yield], after a [Delay_s], mid-repair-loop (after [Invalid]),  *)
(* after a recognized refusal, and by script exhaustion at a yield. Each  *)
(* is injected twice: upstream (the pipeline's first node) and downstream *)
(* (after the first node retired) — committed state must contain exactly  *)
(* the fully-retired nodes' effects either way.                           *)
(* ==================================================================== *)

let fault_scripts =
  [
    ("fault-at-start", [ Agent.Rigged.Fault "injected at start" ]);
    ( "fault-after-yield",
      [ Agent.Rigged.Yield; Agent.Rigged.Fault "injected after yield" ] );
    ( "fault-after-delay",
      [ Agent.Rigged.Delay_s 0.001; Agent.Rigged.Fault "injected after delay" ]
    );
    ( "fault-mid-repair",
      [ Agent.Rigged.Invalid "{not json"; Agent.Rigged.Fault "injected mid repair" ]
    );
    ( "fault-after-refusal",
      [
        Agent.Rigged.Refuse "I cannot help with that.";
        Agent.Rigged.Fault "injected after refusal";
      ] );
    ("script-exhausted-at-yield", [ Agent.Rigged.Yield ]);
  ]

let run_fault_scenario ~label ~inject =
  with_fixture (fun ~repo ~ledger_path ->
      let theory = pipeline_theory () in
      let script = List.assoc label fault_scripts in
      let executors =
        match inject with
        | `Upstream ->
            [ binding worker script; binding summarizer [ ok_reply "s" ] ]
        | `Downstream ->
            [ binding worker [ ok_reply "r" ]; binding summarizer script ]
      in
      let config = config ~repo ~ledger_path ~executors in
      match Run.exec ~theory ~seed:[ task_seed "t1" ] ~config with
      | Error _ -> Printf.printf "%s: unexpected host misuse\n" label
      | Ok settled ->
          let settlements =
            List.map
              (fun (n, (r : Run.node_report)) -> (n, r.settlement))
              settled.nodes
          in
          let brief =
            String.concat " "
              (List.map
                 (fun (n, s) ->
                   Printf.sprintf "%s=%s" (Id.to_string n)
                     (match s with
                     | Ledger.Settlement.Retired -> "retired"
                     | Ledger.Settlement.Faulted { origin; _ } ->
                         "faulted:" ^ origin_str origin
                     | Ledger.Settlement.Squashed _ -> "squashed"))
                 settlements)
          in
          let violations =
            abort_invariant_violations ~ledger:settled.ledger ~settlements
              ~tuples:settled.tuples ~seeds:[ "task/task#0" ] ~repo
          in
          Printf.printf "%s | %s | tuples=[%s] | %s\n" label brief
            (String.concat "; " (List.map tuple_key settled.tuples))
            (match violations with
            | [] -> "ok"
            | vs -> "VIOLATIONS: " ^ String.concat " / " vs))

let%expect_test "F5: upstream fault at every yield class leaves nothing" =
  List.iter
    (fun (label, _) -> run_fault_scenario ~label ~inject:`Upstream)
    fault_scripts;
  [%expect
    {|
    fault-at-start | node#0=faulted:executor-error | tuples=[task/task#0] | ok
    fault-after-yield | node#0=faulted:executor-error | tuples=[task/task#0] | ok
    fault-after-delay | node#0=faulted:executor-error | tuples=[task/task#0] | ok
    fault-mid-repair | node#0=faulted:executor-error | tuples=[task/task#0] | ok
    fault-after-refusal | node#0=faulted:executor-error | tuples=[task/task#0] | ok
    script-exhausted-at-yield | node#0=faulted:executor-error | tuples=[task/task#0] | ok
    |}]

let%expect_test "F5: downstream fault at every yield class keeps exactly the \
                 retired upstream" =
  List.iter
    (fun (label, _) -> run_fault_scenario ~label ~inject:`Downstream)
    fault_scripts;
  [%expect
    {|
    fault-at-start | node#1=faulted:executor-error node#0=retired | tuples=[task/task#0; result/result#0] | ok
    fault-after-yield | node#1=faulted:executor-error node#0=retired | tuples=[task/task#0; result/result#0] | ok
    fault-after-delay | node#1=faulted:executor-error node#0=retired | tuples=[task/task#0; result/result#0] | ok
    fault-mid-repair | node#1=faulted:executor-error node#0=retired | tuples=[task/task#0; result/result#0] | ok
    fault-after-refusal | node#1=faulted:executor-error node#0=retired | tuples=[task/task#0; result/result#0] | ok
    script-exhausted-at-yield | node#1=faulted:executor-error node#0=retired | tuples=[task/task#0; result/result#0] | ok
    |}]

(* ==================================================================== *)
(* F5: kill the run at every possible point. The engine is abandoned      *)
(* after k scheduling steps for every k from 0 to quiescence; at each     *)
(* kill point committed state (tuples AND the committed branch's git      *)
(* history) contains only fully-retired nodes' effects. Abandoning the    *)
(* engine mid-run is the process-death model: nothing runs after step k.  *)
(*                                                                        *)
(* Re-aimed per the flat org (50-api.md F5: "the injection asserts        *)
(* frontier re-derivation (boot = crash recovery, 20-medium.md) instead   *)
(* of worktree-drop cleanliness"): the worker stores a real file, so a    *)
(* kill can strand draft bytes mid-flight; after every kill the tree is   *)
(* torn (crash residue over the stored path, when a store landed) and     *)
(* the run is re-booted through [Run.start]'s ordinary open path — the    *)
(* re-derived frontier must agree with the tree at every k: an in-flight  *)
(* store is the live top (kept for the forward reissue), a retired store  *)
(* is the committed top, and before any store the address has no          *)
(* coordinate at all.                                                     *)
(* ==================================================================== *)

let build_engine ~repo ~ledger_path =
  let theory = pipeline_theory () in
  let ledger = Ledger.create ~path:ledger_path in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let channels = Channel.open_all theory in
  let chase =
    Chase.create ~theory ~ledger ~committed ~channels
      ~ports:[ Chase.Port.open_ ~name:"main" ]
      ~executors:
        [
          binding worker [ write_tool "artifact.txt" "worker draft\n"; ok_reply "r" ];
          binding summarizer [ ok_reply "s" ];
        ]
      ~backstops:Speculate.Backstops.default ~switches:[]
      ~merges:Retire.Merge_registry.empty
      ~seed:[ task_seed "t1" ] ()
  in
  (chase, ledger)

(* Frontier re-derivation after boot: the tree must hold exactly what the
   re-derived frontier (amnesiac committed map + re-opened ledger) names
   as the live top of the worker's stored path. *)
let frontier_agrees ~repo ~ledger_path rel =
  let ledger = Ledger.load ~path:ledger_path in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let frontier = Retire.Frontier.of_ledger ledger ~committed in
  let target = Filename.concat repo rel in
  let tree_hash () =
    Ledger.Content_hash.of_string
      (In_channel.with_open_bin target In_channel.input_all)
  in
  match Retire.Frontier.top frontier (Ledger.Address.File rel) with
  | Retire.Frontier.In_flight { content; _ } ->
      Sys.file_exists target && Ledger.Content_hash.equal content (tree_hash ())
  | Retire.Frontier.Committed
      (Witness.Committed_state.Landed { content; _ }) ->
      Sys.file_exists target && Ledger.Content_hash.equal content (tree_hash ())
  | Retire.Frontier.Committed
      (Witness.Committed_state.Absent | Witness.Committed_state.Deleted _) ->
      not (Sys.file_exists target)

let%expect_test "F5: killing the run after any number of steps leaks \
                 nothing, and boot re-derives the frontier" =
  (* Measure the healthy run's step count once. *)
  let steps =
    with_fixture (fun ~repo ~ledger_path ->
        let chase, _ = build_engine ~repo ~ledger_path in
        let rec go n =
          match Chase.step chase with
          | `Progressed -> go (n + 1)
          | `Quiescent -> n
        in
        go 0)
  in
  Printf.printf "steps to quiescence: %d\n" steps;
  (* Kill after every k, on a fresh fixture each time. *)
  for k = 0 to steps do
    with_fixture (fun ~repo ~ledger_path ->
        let chase, ledger = build_engine ~repo ~ledger_path in
        for _ = 1 to k do
          ignore (Chase.step chase : [ `Progressed | `Quiescent ])
        done;
        let settlements = Chase.settlements chase in
        let tuples = Retire.Committed.tuples (Chase.committed chase) in
        let violations =
          abort_invariant_violations ~ledger ~settlements ~tuples
            ~seeds:[ "task/task#0" ] ~repo
        in
        (* The crash tears the cache wherever a store event named the
           path — the coordinate exists, so boot owns converging it;
           before any store the address has no coordinate and the sweep
           has no universe there. *)
        let stored =
          List.exists
            (fun (e : Ledger.Event.t) ->
              match e.kind with
              | Ledger.Event.Store { address; _ } ->
                  Ledger.Address.equal address
                    (Ledger.Address.File "artifact.txt")
              | _ -> false)
            (Ledger.Replay.events ledger)
        in
        if stored then
          Out_channel.with_open_bin (Filename.concat repo "artifact.txt")
            (fun oc -> Out_channel.output_string oc "torn crash residue");
        (* Boot = crash recovery: the host's ordinary open path over the
           same repo and journal (50-api.md F5, re-aimed). *)
        let booted =
          match
            Run.start ~theory:(pipeline_theory ()) ~seed:[ task_seed "t1" ]
              ~config:
                (config ~repo ~ledger_path
                   ~executors:[ binding worker []; binding summarizer [] ])
          with
          | Ok _ -> frontier_agrees ~repo ~ledger_path "artifact.txt"
          | Error _ -> false
        in
        Printf.printf "kill@%d: retired=[%s] tuples=[%s] %s | boot re-derives \
                       the frontier: %b\n"
          k
          (String.concat "; "
             (List.filter_map
                (fun (n, s) ->
                  match s with
                  | Ledger.Settlement.Retired -> Some (Id.to_string n)
                  | _ -> None)
                settlements))
          (String.concat "; " (List.map tuple_key tuples))
          (match violations with
          | [] -> "ok"
          | vs -> "VIOLATIONS: " ^ String.concat " / " vs)
          booted)
  done;
  [%expect
    {|
    steps to quiescence: 6
    kill@0: retired=[] tuples=[task/task#0] ok | boot re-derives the frontier: true
    kill@1: retired=[] tuples=[task/task#0] ok | boot re-derives the frontier: true
    kill@2: retired=[] tuples=[task/task#0] ok | boot re-derives the frontier: true
    kill@3: retired=[] tuples=[task/task#0] ok | boot re-derives the frontier: true
    kill@4: retired=[] tuples=[task/task#0] ok | boot re-derives the frontier: true
    kill@5: retired=[node#0] tuples=[task/task#0; result/result#0] ok | boot re-derives the frontier: true
    kill@6: retired=[node#0; node#1] tuples=[task/task#0; result/result#0; summary/summary#0] ok | boot re-derives the frontier: true
    |}]

(* ==================================================================== *)
(* FL1: the squash-revert counterfactual (docs/architecture/50-api.md    *)
(* § the flat-org roster). A producer stores over committed content,     *)
(* then squashes. The committed coordinate never moves — the squash      *)
(* appends settlements and nothing else (no event class expresses a      *)
(* retreat); the dead bytes sit in the tree with no authority until      *)
(* [Retire.Frontier.materialize]'s cache fill converges them away — the  *)
(* ONE code path that can bring the old bytes back, and it appends       *)
(* nothing and moves no coordinate; a consumer that read the dead bytes  *)
(* is refused at retire by the content-judged witness and routed         *)
(* forward, never retired; the repair is a forward event — a reissued    *)
(* store landing ABOVE the committed coordinate. The negative-compile    *)
(* arm (no constructor takes a generation backward) is                   *)
(* probe_fl1_generation_retreat.ml; the grep-gate arm (no worktree/      *)
(* restore vocabulary in lib/) is a dune rule in test/dune.              *)
(* ==================================================================== *)

let fl1_write_file path contents =
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc contents)

let fl1_read_file path = In_channel.with_open_bin path In_channel.input_all

let fl1_sh_out cmd =
  let tmp = Filename.temp_file "goat_fl1" ".out" in
  let status =
    Sys.command (Printf.sprintf "%s >%s 2>/dev/null" cmd (Filename.quote tmp))
  in
  let out = if status = 0 then Some (fl1_read_file tmp) else None in
  (try Sys.remove tmp with Sys_error _ -> ());
  out

(* A file store, the way the engine's tool path lands one: the blob into
   the object database first, the shared tree second, the Store event
   (carrying the oid) third — so the clobber over committed content is
   real at store time, before any settlement. *)
let fl1_store ~ledger ~repo ~node rel contents =
  let tmp = Filename.temp_file "goat_fl1_store" ".tmp" in
  fl1_write_file tmp contents;
  let oid =
    match
      fl1_sh_out
        (Printf.sprintf "git -C %s hash-object -w -- %s" (Filename.quote repo)
           (Filename.quote tmp))
    with
    | Some printed -> String.trim printed
    | None -> failwith ("hash-object refused " ^ rel)
  in
  (try Sys.remove tmp with Sys_error _ -> ());
  fl1_write_file (Filename.concat repo rel) contents;
  match Ledger.Delta_ref.blob oid with
  | None -> failwith ("hash-object printed no oid for " ^ rel)
  | Some delta ->
      ignore
        (Ledger.append ledger ~node
           (Ledger.Event.Store
              { tool = "write_file"; address = Ledger.Address.File rel; delta })
          : Ledger.Event.t)

let fl1_state_str = function
  | Witness.Committed_state.Absent -> "absent"
  | Witness.Committed_state.Landed { generation; _ } ->
      Format.asprintf "landed@%a" Ledger.Generation.pp generation
  | Witness.Committed_state.Deleted { generation } ->
      Format.asprintf "deleted@%a" Ledger.Generation.pp generation

let fl1_branch_content repo rel =
  match
    fl1_sh_out
      (Printf.sprintf "git -C %s show goat:%s" (Filename.quote repo)
         (Filename.quote rel))
  with
  | Some c -> Printf.sprintf "%S" c
  | None -> "<absent>"

let%expect_test "FL1: a squash retreats nothing — the settlement is the \
                 whole act, dead bytes are the frontier's cache fill, the \
                 repair is forward" =
  with_fixture (fun ~repo ~ledger_path ->
      let ledger = Ledger.create ~path:ledger_path in
      let registry = Id.Registry.create () in
      let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
      let nodes : Ledger.node Id.Minter.t =
        Id.Minter.create ~registry ~realm:"node"
      in
      let hyps : Ledger.hypothesis Id.Minter.t =
        Id.Minter.create ~registry ~realm:"hypothesis"
      in
      let statement =
        match Theory.statements (pipeline_theory ()) with
        | (sid, _) :: _ -> sid
        | [] -> failwith "pipeline theory has no statements"
      in
      let fired node seed_tuple =
        ignore
          (Ledger.append ledger ~node
             (Ledger.Event.Fired
                {
                  provenance =
                    {
                      Ledger.Provenance.statement;
                      consumed = [ ("task", seed_tuple) ];
                      hypotheses = [];
                    };
                  minted = [];
                })
            : Ledger.Event.t)
      in
      let retire node =
        match
          Retire.step ~committed ~ledger ~registry
            ~merges:Retire.Merge_registry.empty ~node
            ~witness:(Witness.observed ledger ~node)
            ~heads:[]
        with
        | Ok () -> "ok"
        | Error (Retire.Witness_moved _) ->
            "rejected (Witness_moved) — a typed forward signal"
        | Error (Retire.Undischarged _) -> "rejected (Undischarged)"
        | Error (Retire.Conflict _) -> "rejected (Conflict)"
      in
      let addr = Ledger.Address.File "f.txt" in
      let coordinate () =
        Printf.sprintf "%s %s"
          (fl1_state_str (Retire.Committed.state committed addr))
          (fl1_branch_content repo "f.txt")
      in
      let committed_gen () =
        match Retire.Committed.generation committed addr with
        | Some g -> g
        | None -> Ledger.Generation.zero
      in
      (* Baseline: c0 lands v1 as committed content. *)
      let c0 = Id.mint nodes in
      fired c0 "t0";
      fl1_store ~ledger ~repo ~node:c0 "f.txt" "v1\n";
      Printf.printf "baseline retire: %s\n" (retire c0);
      Printf.printf "baseline coordinate: %s\n" (coordinate ());
      (* The producer stores OVER the committed content — the clobber is
         in the shared tree at store time — on a hypothesis that will
         die. *)
      let p = Id.mint nodes in
      fired p "t1";
      let h = Id.mint hyps in
      ignore
        (Ledger.append ledger ~node:p
           (Ledger.Event.Hypothesis_taken
              {
                hypothesis = h;
                address = Ledger.Address.Contract "r";
                source = "issued-contract:r";
                content = Ledger.Content_hash.of_string "guess";
                confidence = 0.5;
              })
          : Ledger.Event.t);
      fl1_store ~ledger ~repo ~node:p "f.txt" "dead draft\n";
      Printf.printf "tree holds the producer's draft: %b\n"
        (String.equal (fl1_read_file (Filename.concat repo "f.txt"))
           "dead draft\n");
      (* The consumer read the dead bytes — an untracked read, judged by
         content at retire, not by any kill mark. *)
      let k = Id.mint nodes in
      fired k "t2";
      ignore
        (Ledger.append ledger ~node:k
           (Ledger.Event.Load
              {
                tool = "read_file";
                observed =
                  [
                    ( addr,
                      committed_gen (),
                      Ledger.Content_hash.of_string "dead draft\n" );
                  ];
              })
          : Ledger.Event.t);
      (* The hypothesis dies. The squash is the settlement append — count
         what it adds and prove every appended event is a settlement:
         no event class lowers, rewrites, or deletes a coordinate. *)
      let before_squash = List.length (Ledger.Replay.events ledger) in
      Retire.squash ~ledger ~registry
        ~cause:(Ledger.Squash_cause.Dead_hypothesis h);
      let appended =
        List.filteri
          (fun i _ -> i >= before_squash)
          (Ledger.Replay.events ledger)
      in
      Printf.printf "squash appended %d event(s); settlements only: %b\n"
        (List.length appended)
        (List.for_all
           (fun (e : Ledger.Event.t) ->
             match e.kind with
             | Ledger.Event.Settled (Ledger.Settlement.Squashed _) -> true
             | _ -> false)
           appended);
      Printf.printf "coordinate after squash (never moved): %s\n"
        (coordinate ());
      Printf.printf "dead bytes still in the tree (garbage, no authority): %b\n"
        (String.equal (fl1_read_file (Filename.concat repo "f.txt"))
           "dead draft\n");
      (* The counterfactual arm's positive half: the ONE code path that
         brings the old bytes back is the frontier's cache fill — and it
         appends nothing and moves no coordinate. *)
      let after_squash = List.length (Ledger.Replay.events ledger) in
      let frontier = Retire.Frontier.of_ledger ledger ~committed in
      Retire.Frontier.materialize frontier ~repo;
      Printf.printf "materialize converged the tree to the committed top: %b\n"
        (String.equal (fl1_read_file (Filename.concat repo "f.txt")) "v1\n");
      Printf.printf "materialize appended nothing: %b\n"
        (List.length (Ledger.Replay.events ledger) = after_squash);
      Printf.printf "coordinate after materialize: %s\n" (coordinate ());
      (* The consumer of the dead bytes: refused by the content-judged
         witness, routed forward as a typed signal — never retired. *)
      Printf.printf "consumer retire: %s\n" (retire k);
      Printf.printf "consumer settled events: %d\n"
        (List.length
           (List.filter
              (fun (e : Ledger.Event.t) ->
                match (e.node, e.kind) with
                | Some n, Ledger.Event.Settled _ -> Id.equal n k
                | _ -> false)
              (Ledger.Replay.events ledger)));
      (* The repair is a forward event: a reissued producer witnesses the
         committed coordinate and lands ABOVE it. *)
      let m = Id.mint nodes in
      fired m "t3";
      ignore
        (Ledger.append ledger ~node:m
           (Ledger.Event.Load
              {
                tool = "read_file";
                observed =
                  [
                    ( addr,
                      committed_gen (),
                      Ledger.Content_hash.of_string "v1\n" );
                  ];
              })
          : Ledger.Event.t);
      fl1_store ~ledger ~repo ~node:m "f.txt" "repaired v2\n";
      Printf.printf "repair retire: %s\n" (retire m);
      Printf.printf "repair coordinate (forward, never lowered): %s\n"
        (coordinate ());
      (* Monotonicity, read off the ledger's own trail: every published
         generation for the address strictly increases (FL4's fold,
         locally). *)
      let published =
        List.filter_map
          (fun (e : Ledger.Event.t) ->
            match e.kind with
            | Ledger.Event.Invalidation_sent { address; new_generation; _ }
              when Ledger.Address.equal address addr ->
                Some new_generation
            | _ -> None)
          (Ledger.Replay.events ledger)
      in
      let rec strictly_increasing = function
        | a :: (b :: _ as rest) ->
            Ledger.Generation.compare a b < 0 && strictly_increasing rest
        | _ -> true
      in
      Printf.printf "published generations strictly increase: %b\n"
        (strictly_increasing published);
      [%expect
        {|
        baseline retire: ok
        baseline coordinate: landed@g0 "v1\n"
        tree holds the producer's draft: true
        squash appended 1 event(s); settlements only: true
        coordinate after squash (never moved): landed@g0 "v1\n"
        dead bytes still in the tree (garbage, no authority): true
        materialize converged the tree to the committed top: true
        materialize appended nothing: true
        coordinate after materialize: landed@g0 "v1\n"
        consumer retire: rejected (Witness_moved) — a typed forward signal
        consumer settled events: 0
        repair retire: ok
        repair coordinate (forward, never lowered): landed@g1 "repaired v2\n"
        published generations strictly increase: true
        |}])
