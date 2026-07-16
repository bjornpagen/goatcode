(* Falsifiers for migration row 7 — hygiene and recovery
   (docs/architecture/README.md § design of record vs shipped engine,
   row 7; docs/architecture/20-medium.md § squash without isolation —
   the crash story; § the escape surfaces; docs/architecture/50-api.md
   F5, re-aimed):

   - Boot = crash recovery. [Run.start]'s open path re-derives the
     frontier from the re-opened ledger ([Ledger.create] never
     truncates) and converges the tree before any node runs: a crashed
     run's dead residue converges to its committed top, a crashed run's
     live in-flight draft survives with torn cache bytes converged back
     to the draft (the reissue's overwrite, never a retreat, owns its
     future), and a clean boot converges nothing. One recovery path —
     the same code a clean open runs.

   - The unexplained-bytes sweep. At quiescence the tree is diffed
     against the frontier: bytes no store event explains are attributed
     to the effect events whose ledger window covers them and surfaced
     as the violation-only [unexplained_bytes] verdict — exactly like
     footprint escapes, never a fault, and the stray bytes stay in the
     tree (a witness the declaration must grow to cover, never
     deleted). Dead store residue is the hygiene class: the same pass
     converges it and surfaces nothing; a store-explained sibling is
     the in-test covered control.

   Rigged executors only ([Agent.Rigged]); no network, no model, no
   sleeps. *)

open Goatcode
module R = Agent.Rigged

(* ------------------------------------------------------------------ *)
(* Fixture helpers (the shapes test_squash uses).                      *)

let sh cmd =
  let status = Sys.command (cmd ^ " >/dev/null 2>&1") in
  if status <> 0 then failwith ("command failed: " ^ cmd)

let git ~repo args =
  sh (Printf.sprintf "git -C %s %s" (Filename.quote repo) args)

let write_file path contents =
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc contents)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let sh_out cmd =
  let tmp = Filename.temp_file "goat_recovery" ".out" in
  let status =
    Sys.command (Printf.sprintf "%s >%s 2>/dev/null" cmd (Filename.quote tmp))
  in
  let out = if status = 0 then Some (read_file tmp) else None in
  (try Sys.remove tmp with Sys_error _ -> ());
  out

let with_fixture f =
  let tmp = Filename.temp_dir "goatcode_recovery" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
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
(* A one-statement theory: task --work--> result. The worker's grant
   carries the idempotent run_command effect — the sweep's subject.     *)

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
  Theory.Relation.v ~name
    (Contract.v ~name ~schema:schema_json ~codec:json_codec)

let task_rel = relation "task"
let result_rel = relation "result"

let pin =
  { Theory.Pin.provider = "rigged"; model = "fake"; sampling = []; options = [] }

let worker ~effects =
  Theory.Executor.Agent_template
    {
      name = "worker";
      pin;
      preamble = "produce the result tuple";
      read_globs = [];
      write_globs = [ "**" ];
      effects;
    }

let theory ~effects =
  match
    Theory.declare
      ~relations:
        [ Theory.Relation.Packed task_rel; Theory.Relation.Packed result_rel ]
      ~statements:
        [
          Theory.Spawn.v ~name:"work" ~for_:"task"
            ~exists:("result", Theory.Window.nodes 1)
            ~by:(worker ~effects) ();
        ]
      ~laws:[]
  with
  | Ok t -> t
  | Error errs ->
      failwith
        ("theory rejected: "
        ^ String.concat "; " (List.map Theory.Admission.to_string errs))

let run_command_effect =
  Theory.Executor.Effect.Idempotent
    {
      tool = "run_command";
      why = "freely re-runnable shell in the shared tree (the sweep's subject)";
    }

let binding ~effects script =
  {
    Chase.executor = Theory.Executor.id (worker ~effects);
    runtime = R.executor ~script;
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
let ok_reply note = R.Reply (Printf.sprintf {|{"note":%S}|} note)

let write_tool path content =
  R.Call_tool
    {
      name = "write_file";
      input = `Assoc [ ("path", `String path); ("content", `String content) ];
    }

let print_laws (laws : Theory.Law.verdict list) =
  match laws with
  | [] -> print_endline "laws: none"
  | vs ->
      List.iter
        (fun (v : Theory.Law.verdict) ->
          Printf.printf "law %s satisfied=%b offenders=[%s]\n" v.Theory.Law.law
            v.satisfied
            (String.concat "; " v.offenders))
        vs

(* A file store, the way the engine's tool path lands one: the blob into
   the object database first, the shared tree second, the Store event
   (carrying the oid) third — used to rig the crashed run's journal. *)
let store ~ledger ~repo ~node rel contents =
  let tmp = Filename.temp_file "goat_recovery_store" ".tmp" in
  write_file tmp contents;
  let oid =
    match
      sh_out
        (Printf.sprintf "git -C %s hash-object -w -- %s" (Filename.quote repo)
           (Filename.quote tmp))
    with
    | Some printed -> String.trim printed
    | None -> failwith ("hash-object refused " ^ rel)
  in
  (try Sys.remove tmp with Sys_error _ -> ());
  write_file (Filename.concat repo rel) contents;
  match Ledger.Delta_ref.blob oid with
  | None -> failwith ("hash-object printed no oid for " ^ rel)
  | Some delta ->
      ignore
        (Ledger.append ledger ~node
           (Ledger.Event.Store
              { tool = "write_file"; address = Ledger.Address.File rel; delta })
          : Ledger.Event.t)

(* ==================================================================== *)
(* Boot = crash recovery (50-api.md F5, re-aimed; 20-medium.md § the     *)
(* crash story). A crashed run's journal holds: a retired landing (f.txt *)
(* committed at v1), a squashed writer's dead draft clobbering it in the *)
(* tree, and an unsettled writer's live draft (g.txt) whose tree bytes   *)
(* the crash tore. No settlement direction exists to classify — boot     *)
(* re-derives the frontier from the ledger and converges: dead residue   *)
(* to the committed top, torn cache bytes back to the live draft. The    *)
(* recovery path IS [Run.start]'s ordinary open path, and it appends     *)
(* nothing.                                                              *)
(* ==================================================================== *)

let%expect_test "row 7: boot over a crashed run's ledger converges the tree \
                 to the re-derived frontier" =
  with_fixture (fun ~repo ~ledger_path ->
      let ledger = Ledger.create ~path:ledger_path in
      let registry = Id.Registry.create () in
      let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
      let nodes : Ledger.node Id.Minter.t =
        Id.Minter.create ~registry ~realm:"node"
      in
      let statement =
        match Theory.statements (theory ~effects:[]) with
        | (sid, _) :: _ -> sid
        | [] -> failwith "theory has no statements"
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
      (* c0 lands f.txt = v1 as committed content. *)
      let c0 = Id.mint nodes in
      fired c0 "t0";
      store ~ledger ~repo ~node:c0 "f.txt" "v1\n";
      (match
         Retire.step ~committed ~ledger ~registry
           ~merges:Retire.Merge_registry.empty ~node:c0
           ~witness:(Witness.observed ledger ~node:c0)
           ~heads:[]
       with
      | Ok () -> ()
      | Error _ -> failwith "baseline retire refused");
      (* p clobbers f.txt in the tree and squashes — dead residue. *)
      let p = Id.mint nodes in
      fired p "t1";
      store ~ledger ~repo ~node:p "f.txt" "dead draft\n";
      ignore
        (Ledger.append ledger ~node:p
           (Ledger.Event.Settled
              (Ledger.Settlement.Squashed Ledger.Squash_cause.Reissue_loser))
          : Ledger.Event.t);
      (* q stores g.txt and never settles — in flight when the process
         dies; the crash also tears g.txt's cache bytes. *)
      let q = Id.mint nodes in
      fired q "t2";
      store ~ledger ~repo ~node:q "g.txt" "in-flight draft\n";
      write_file (Filename.concat repo "g.txt") "torn crash residue";
      (* The crash: nothing settles, nothing converges. *)
      Printf.printf "pre-boot f.txt: %S\n"
        (read_file (Filename.concat repo "f.txt"));
      Printf.printf "pre-boot g.txt: %S\n"
        (read_file (Filename.concat repo "g.txt"));
      let events_before = List.length (Ledger.Replay.events ledger) in
      (* Boot: the host's ordinary open path, over the same journal. *)
      (match
         Run.start ~theory:(theory ~effects:[]) ~seed:[]
           ~config:
             (config ~repo ~ledger_path
                ~executors:[ binding ~effects:[] [] ])
       with
      | Error _ -> print_endline "unexpected host misuse"
      | Ok handle ->
          Printf.printf "boot f.txt (dead residue converged): %S\n"
            (read_file (Filename.concat repo "f.txt"));
          Printf.printf "boot g.txt (torn bytes back to the live draft): %S\n"
            (read_file (Filename.concat repo "g.txt"));
          (* Recovery appends nothing: the only run-open appends are the
             pin records every open writes ([Pin_bump], predictor
             bookkeeping) — no store, no settlement, no invalidation;
             materialize moved no coordinate. *)
          let appended =
            List.filteri
              (fun i _ -> i >= events_before)
              (Ledger.Replay.events (Run.ledger handle))
          in
          Printf.printf "recovery appended nothing (pin records only): %b\n"
            (List.for_all
               (fun (e : Ledger.Event.t) ->
                 match e.kind with
                 | Ledger.Event.Pin_bump _ -> true
                 | _ -> false)
               appended));
      [%expect
        {|
        pre-boot f.txt: "dead draft\n"
        pre-boot g.txt: "torn crash residue"
        boot f.txt (dead residue converged): "v1\n"
        boot g.txt (torn bytes back to the live draft): "in-flight draft\n"
        recovery appended nothing (pin records only): true
        |}])

(* ==================================================================== *)
(* The unexplained-bytes sweep (20-medium.md § the escape surfaces). One *)
(* node writes mine.txt through the store path (the covered control) and *)
(* strays stray.txt through run_command — invisible to store events. At  *)
(* quiescence the sweep convicts exactly the stray path, attributes it   *)
(* to the effect event's window, and deletes nothing: the bytes are the  *)
(* witness the declaration must grow to cover. The escapee still         *)
(* retires — a filter, never a wall.                                     *)
(* ==================================================================== *)

let%expect_test "row 7: bytes only an effect explains surface as the \
                 unexplained_bytes verdict; store-explained bytes surface \
                 nothing" =
  with_fixture (fun ~repo ~ledger_path ->
      let effects = [ run_command_effect ] in
      let script =
        [
          write_tool "mine.txt" "granted store\n";
          R.Call_tool
            {
              name = "run_command";
              input =
                `Assoc
                  [ ("command", `String "printf 'stray bytes\\n' > stray.txt") ];
            };
          ok_reply "done";
        ]
      in
      let config =
        config ~repo ~ledger_path ~executors:[ binding ~effects script ]
      in
      match Run.exec ~theory:(theory ~effects) ~seed:[ task_seed "t1" ] ~config with
      | Error _ -> print_endline "unexpected host misuse"
      | Ok settled ->
          List.iter
            (fun (n, (report : Run.node_report)) ->
              Printf.printf "%s: %s\n" (Id.to_string n)
                (match report.settlement with
                | Ledger.Settlement.Retired -> "retired"
                | Ledger.Settlement.Faulted _ -> "faulted"
                | Ledger.Settlement.Squashed _ -> "squashed"))
            settled.nodes;
          print_laws settled.laws;
          Printf.printf "stray bytes stay in the tree (a witness, never \
                         deleted): %b\n"
            (Sys.file_exists (Filename.concat repo "stray.txt"));
          Printf.printf "the covered sibling is committed content: %s\n"
            (match
               sh_out
                 (Printf.sprintf "git -C %s show goat:mine.txt"
                    (Filename.quote repo))
             with
            | Some c -> Printf.sprintf "%S" c
            | None -> "<absent>");
          Printf.printf "replay: %s\n"
            (match Run.replay settled.ledger with
            | Ok () -> "coherent"
            | Error ds -> Printf.sprintf "%d divergences" (List.length ds));
          [%expect
            {|
            node#0: retired
            law unexplained_bytes satisfied=false offenders=[file:stray.txt unexplained; effect window: node#0 run_command(machine)]
            stray bytes stay in the tree (a witness, never deleted): true
            the covered sibling is committed content: "granted store\n"
            replay: coherent
            |}])

(* ==================================================================== *)
(* The hygiene half, engine-level: a faulted writer's fresh-file draft   *)
(* is dead residue — the quiescence sweep converges it away (top Absent  *)
(* → the file goes) and surfaces NOTHING: dead-event bytes are explained *)
(* garbage, never an escape. The in-test sensitivity control is the      *)
(* previous falsifier: the same sweep, same run shape, convicts a path   *)
(* no store event explains.                                              *)
(* ==================================================================== *)

let%expect_test "row 7: a dead writer's bytes are hygiene at quiescence — \
                 converged, never surfaced" =
  with_fixture (fun ~repo ~ledger_path ->
      let script = [ write_tool "dead.txt" "doomed\n"; R.Fault "injected" ] in
      let config =
        config ~repo ~ledger_path ~executors:[ binding ~effects:[] script ]
      in
      match Run.exec ~theory:(theory ~effects:[]) ~seed:[ task_seed "t1" ] ~config with
      | Error _ -> print_endline "unexpected host misuse"
      | Ok settled ->
          List.iter
            (fun (n, (report : Run.node_report)) ->
              Printf.printf "%s: %s\n" (Id.to_string n)
                (match report.settlement with
                | Ledger.Settlement.Retired -> "retired"
                | Ledger.Settlement.Faulted _ -> "faulted"
                | Ledger.Settlement.Squashed _ -> "squashed"))
            settled.nodes;
          print_laws settled.laws;
          Printf.printf "dead bytes converged away at quiescence: %b\n"
            (not (Sys.file_exists (Filename.concat repo "dead.txt")));
          Printf.printf "tuples: [%s]\n"
            (String.concat "; "
               (List.map
                  (fun (t : Retire.Committed.tuple) ->
                    t.Retire.Committed.relation ^ "/" ^ t.Retire.Committed.id)
                  settled.tuples));
          [%expect
            {|
            node#0: faulted
            laws: none
            dead bytes converged away at quiescence: true
            tuples: [task/task#0]
            |}])
