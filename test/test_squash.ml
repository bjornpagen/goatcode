(* Falsifiers, group "squash" (docs/architecture/80-validation.md):

   - F3 — squash precision. A fault or dead hypothesis squashes exactly the
     provenance-closed subtree; siblings retire undisturbed. The falsifier
     builds graphs where any over-squash removes a committed tuple a sibling
     owns and any under-squash leaks a doomed node's tuple into committed
     state, and asserts neither happens (docs/architecture/50-commit.md).

   - F5 — abort by construction. Kill a run at arbitrary points (fault
     injection at every yield class of the rigged executor, plus abandoning
     the engine after every possible number of scheduling steps); committed
     state contains only fully-retired nodes' effects; worktree drops leave
     no orphan state (docs/architecture/50-commit.md § abort by
     construction).

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
   storage engine), a worktree root inside it (so store buffers are real
   git worktrees), and a ledger path. *)
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
      let wt = Filename.concat repo "_buffers" in
      Sys.mkdir wt 0o755;
      let ledger_path = Filename.concat tmp "ledger" in
      f ~repo ~wt ~ledger_path)

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
    { name = "worker"; pin; preamble = "produce the result tuple"; read_globs = [] }

let summarizer =
  Theory.Executor.Agent_template
    { name = "summarizer"; pin; preamble = "summarize the result"; read_globs = [] }

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

let config ~repo ~wt ~ledger_path ~executors =
  {
    Run.repo;
    committed_branch = "goat";
    worktree_root = wt;
    ledger_path;
    ports = [ Chase.Port.open_ ~name:"main" ];
    executors;
    backstops = Speculate.Backstops.default;
    switches = [];
    merges = Retire.Merge_registry.empty;
  }

let task_seed note = Theory.Tuple.v task_rel (`Assoc [ ("note", `String note) ])
let ok_reply note = Agent.Rigged.Reply (Printf.sprintf {|{"note":%S}|} note)

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

let worktree_dirs wt =
  Sys.readdir wt |> Array.to_list |> List.sort String.compare

(* Store buffers registered with git (the linked-worktree table): the other
   half of "worktree drops leave no orphan state" — a dropped buffer must
   vanish from git's own bookkeeping, not only from the filesystem. *)
let registered_buffers ~repo =
  sh_lines
    (Printf.sprintf "git -C %s worktree list --porcelain" (Filename.quote repo))
  |> List.filter_map (fun line ->
         let prefix = "worktree " in
         if String.starts_with ~prefix line then
           let path =
             String.sub line (String.length prefix)
               (String.length line - String.length prefix)
           in
           if
             String.equal
               (Filename.basename (Filename.dirname path))
               "_buffers"
           then Some (Filename.basename path)
           else None
         else None)
  |> List.sort String.compare

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
   effects, and settled-without-retiring nodes leave no worktree state —
   filesystem or git bookkeeping. Checked from the ledger, the committed
   tuple set, the durability boundary (git log), and the worktree root. *)

let abort_invariant_violations ~ledger ~settlements ~tuples ~seeds ~repo ~wt =
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
  let fired_nodes = List.map snd minted_by in
  let retired =
    List.filter_map
      (fun (n, s) ->
        match s with
        | Ledger.Settlement.Retired -> Some (Id.to_string n)
        | _ -> None)
      settlements
    |> List.sort String.compare
  in
  let settled_not_retired =
    List.filter_map
      (fun (n, s) ->
        match s with
        | Ledger.Settlement.Retired -> None
        | _ -> Some (Id.to_string n))
      settlements
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
  (* 3. No settled-without-retiring node leaves a worktree directory, and
     every directory belongs to a node this run fired. *)
  List.iter
    (fun dir ->
      if List.mem dir settled_not_retired then
        bad "orphan worktree directory %s (node settled without retiring)" dir;
      if not (List.mem dir fired_nodes) then
        bad "stray worktree directory %s (no fired node owns it)" dir)
    (worktree_dirs wt);
  (* 4. Git's linked-worktree table holds no entry for a dropped buffer. *)
  List.iter
    (fun dir ->
      if List.mem dir settled_not_retired then
        bad "orphan git worktree registration %s" dir)
    (registered_buffers ~repo);
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
         pass a's cause and check the subtree's own mints). Worktrees are
         dropped; nothing renumbers; a second walk finds nothing left. *)
      let wt_root = Filename.concat tmp "buffers" in
      Sys.mkdir wt_root 0o755;
      let worktrees =
        List.map
          (fun n -> (n, Retire.Worktree.create ~root:wt_root ~node:n))
          [ b; c; e ]
      in
      Retire.squash ~ledger ~registry ~worktrees
        ~cause:(Ledger.Squash_cause.Upstream_fault a);
      Printf.printf "buffers left: [%s]\n"
        (String.concat "; " (worktree_dirs wt_root));
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
        buffers left: []
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
  with_fixture (fun ~repo ~wt ~ledger_path ->
      let theory = pipeline_theory () in
      let executors =
        [
          (* First firing (task#0) answers; second firing (task#1) faults. *)
          binding worker [ ok_reply "from t1"; Agent.Rigged.Fault "injected" ];
          binding summarizer [ ok_reply "summary of t1" ];
        ]
      in
      let config = config ~repo ~wt ~ledger_path ~executors in
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
          Printf.printf "buffers left: [%s]\n"
            (String.concat "; " (worktree_dirs wt));
          let nodes_settlements =
            List.map
              (fun (n, (r : Run.node_report)) -> (n, r.settlement))
              settled.nodes
          in
          print_violations
            (abort_invariant_violations ~ledger:settled.ledger
               ~settlements:nodes_settlements ~tuples:settled.tuples
               ~seeds:[ "task/task#0"; "task/task#1" ] ~repo ~wt);
          (* Settle order: the fault lands at dispatch, before the sibling
             reaches retirement — so node#1 settles first. *)
          [%expect
            {|
            node#1: faulted(executor-error: injected)
            node#0: retired
            node#2: retired
            tuples: [task/task#0; task/task#1; result/result#0; summary/summary#0]
            retire commits: [node#0; node#2]
            buffers left: [node#0; node#2]
            invariant: ok
            |}])

(* ==================================================================== *)
(* F5: fault injection at every yield class of the rigged executor.       *)
(* Every class the executor can suspend or die at: immediately, after a   *)
(* forced [Yield], after a [Delay_s], mid-repair-loop (after [Invalid]),  *)
(* after a recognized refusal, and by script exhaustion at a yield. Each  *)
(* is injected twice: upstream (the pipeline's first node) and downstream *)
(* (after the first node retired) — committed state must contain exactly  *)
(* the fully-retired nodes' effects either way, and no dropped worktree   *)
(* may leave state.                                                       *)
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
  with_fixture (fun ~repo ~wt ~ledger_path ->
      let theory = pipeline_theory () in
      let script = List.assoc label fault_scripts in
      let executors =
        match inject with
        | `Upstream ->
            [ binding worker script; binding summarizer [ ok_reply "s" ] ]
        | `Downstream ->
            [ binding worker [ ok_reply "r" ]; binding summarizer script ]
      in
      let config = config ~repo ~wt ~ledger_path ~executors in
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
              ~tuples:settled.tuples ~seeds:[ "task/task#0" ] ~repo ~wt
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
(* history) contains only fully-retired nodes' effects, and no            *)
(* settled-without-retiring node has worktree state. Abandoning the       *)
(* engine mid-run is the process-death model: nothing runs after step k.  *)
(* ==================================================================== *)

let build_engine ~repo ~wt ~ledger_path =
  let theory = pipeline_theory () in
  let ledger = Ledger.create ~path:ledger_path in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let channels = Channel.open_all theory in
  let chase =
    Chase.create ~theory ~ledger ~committed ~channels ~worktree_root:wt
      ~ports:[ Chase.Port.open_ ~name:"main" ]
      ~executors:
        [
          binding worker [ ok_reply "r" ];
          binding summarizer [ ok_reply "s" ];
        ]
      ~backstops:Speculate.Backstops.default ~switches:[]
      ~merges:Retire.Merge_registry.empty
      ~seed:[ task_seed "t1" ] ()
  in
  (chase, ledger)

let%expect_test "F5: killing the run after any number of steps leaks nothing" =
  (* Measure the healthy run's step count once. *)
  let steps =
    with_fixture (fun ~repo ~wt ~ledger_path ->
        let chase, _ = build_engine ~repo ~wt ~ledger_path in
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
    with_fixture (fun ~repo ~wt ~ledger_path ->
        let chase, ledger = build_engine ~repo ~wt ~ledger_path in
        for _ = 1 to k do
          ignore (Chase.step chase : [ `Progressed | `Quiescent ])
        done;
        let settlements = Chase.settlements chase in
        let tuples = Retire.Committed.tuples (Chase.committed chase) in
        let violations =
          abort_invariant_violations ~ledger ~settlements ~tuples
            ~seeds:[ "task/task#0" ] ~repo ~wt
        in
        Printf.printf "kill@%d: retired=[%s] tuples=[%s] %s\n" k
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
          | vs -> "VIOLATIONS: " ^ String.concat " / " vs))
  done;
  [%expect
    {|
    steps to quiescence: 6
    kill@0: retired=[] tuples=[task/task#0] ok
    kill@1: retired=[] tuples=[task/task#0] ok
    kill@2: retired=[] tuples=[task/task#0] ok
    kill@3: retired=[] tuples=[task/task#0] ok
    kill@4: retired=[] tuples=[task/task#0] ok
    kill@5: retired=[node#0] tuples=[task/task#0; result/result#0] ok
    kill@6: retired=[node#0; node#1] tuples=[task/task#0; result/result#0; summary/summary#0] ok
    |}]
