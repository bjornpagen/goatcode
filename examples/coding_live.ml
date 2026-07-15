(* coding_live — the live coding smoke: a from-scratch coding task in a
   fresh repository, run by Run.exec against the live Anthropic lane.
   Three stages exercise the surfaces haiku_live does not: an implementer
   agent writes a small Python project (code plus its test file), a
   SHELL GATE runs the test file (the effect lane: machine lock, Effect
   event, exit-status-as-data), and the host judges the gate's exit
   status off the settled map — a failing test run is a tuple, not a
   fault; the host decides it is an error.

   Self-contained: everything lives under ./.goat/fizzbuzz-repo, created
   by the operator (goat never runs git for you):

     mkdir -p .goat/fizzbuzz-repo
     git -C .goat/fizzbuzz-repo init -q
     git -C .goat/fizzbuzz-repo commit --allow-empty -m "root"
     export ANTHROPIC_API_KEY=sk-ant-...
     ./_build/default/examples/coding_live.exe

   Expect: both nodes retired, disjoint writes satisfied, the gate tuple
   carrying exit_status 0, and fizzbuzz.py + test_fizzbuzz.py on the
   goat-committed branch. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Relations.                                                          *)
(* ------------------------------------------------------------------ *)

let spec_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("description", `String "An operator's prose specification of the work.");
      ( "properties",
        `Assoc
          [
            ( "text",
              `Assoc
                [
                  ("type", `String "string");
                  ("description", `String "The specification, verbatim.");
                ] );
          ] );
      ("required", `List [ `String "text" ]);
      ("additionalProperties", `Bool false);
    ]

let implementation_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String
          "One implementation of the specified project. Every listed file \
           MUST be written into the shared tree with the write_file tool \
           before this tuple is emitted; the tuple records what was \
           written." );
      ( "properties",
        `Assoc
          [
            ( "paths",
              `Assoc
                [
                  ("type", `String "array");
                  ("minItems", `Int 2);
                  ( "description",
                    `String
                      "Worktree-relative paths of every file written, \
                       including the test file." );
                  ( "items",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "One written file's path.");
                      ] );
                ] );
            ( "summary",
              `Assoc
                [
                  ("type", `String "string");
                  ( "description",
                    `String "One or two sentences on what was implemented." );
                ] );
            ( "spec",
              `Assoc
                [
                  ("type", `String "string");
                  ("format", `String "ref:spec");
                  ( "description",
                    `String
                      "The wire id of the spec tuple this implements." );
                ] );
          ] );
      ( "required",
        `List [ `String "paths"; `String "summary"; `String "spec" ] );
      ("additionalProperties", `Bool false);
    ]

(* The gate's head: exactly the payload Agent.shell_gate emits. *)
let test_run_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String "One test-gate run: exit status and captured output." );
      ( "properties",
        `Assoc
          [
            ( "exit_status",
              `Assoc
                [
                  ("type", `String "integer");
                  ("description", `String "The gate command's exit status.");
                ] );
            ( "output",
              `Assoc
                [
                  ("type", `String "string");
                  ("description", `String "Captured stdout and stderr.");
                ] );
          ] );
      ("required", `List [ `String "exit_status"; `String "output" ]);
      ("additionalProperties", `Bool false);
    ]

let spec_rel = Theory.Relation.dynamic ~name:"spec" ~schema:spec_schema

let implementation_rel =
  Theory.Relation.dynamic ~name:"implementation" ~schema:implementation_schema

let test_run_rel =
  Theory.Relation.dynamic ~name:"test_run" ~schema:test_run_schema

(* ------------------------------------------------------------------ *)
(* Statements.                                                         *)
(* ------------------------------------------------------------------ *)

let pin =
  {
    Theory.Pin.provider = "anthropic";
    model = "claude-opus-4-8";
    sampling = [];
    options = [];
  }

let implementer =
  Theory.Executor.Agent_template
    {
      name = "implementer";
      pin;
      preamble =
        "You are the implementer. Build exactly the small project the \
         specification asks for, stdlib only, no external dependencies. \
         Write every file into the shared tree with the write_file tool. \
         The test file must be directly runnable (plain asserts, exit 0 \
         on success, non-zero on failure) — it is executed by an \
         automated gate, so it must not require pytest or any runner. \
         Before emitting your tuple, RUN your test file with run_command \
         and fix what fails; do not emit until it exits 0.";
      read_globs = [];
      write_globs = [ "**" ];
      effects =
        [
          Theory.Executor.Effect.Idempotent
            {
              tool = "run_command";
              why = "build/test commands in the shared tree, freely re-runnable";
            };
        ];
    }

let gate =
  Theory.Executor.Shell_gate
    {
      name = "test_gate";
      command = [ "python3"; "test_fizzbuzz.py" ];
      (* The declared build-artifact resource the gate's effect lock
         scopes to (30-scheduling.md § gates on the shared tree): the
         interpreter's bytecode cache is the one artifact this test run
         touches. *)
      resource = "pycache";
    }

let statements =
  [
    Theory.Spawn.v ~name:"implement" ~for_:"spec"
      ~exists:("implementation", Theory.Window.nodes 1)
      ~by:implementer ();
    Theory.Spawn.v ~name:"run_tests" ~for_:"implementation"
      ~exists:("test_run", Theory.Window.nodes 1)
      ~by:gate ();
  ]

let laws = [ Theory.Law.Disjoint_writes { name = "disjoint" } ]

(* ------------------------------------------------------------------ *)
(* Run configuration.                                                  *)
(* ------------------------------------------------------------------ *)

let live_runtime () =
  Agent.agent ~stop:[]
    ~provider:(Agent.Provider.anthropic ~post:Fiber.http_post ())

let config =
  {
    Run.repo = ".goat/fizzbuzz-repo";
    committed_branch = "goat-committed";
    ledger_path = ".goat/ledger-coding.bin";
    ports = [ Chase.Port.open_ ~name:"agents" ];
    executors =
      [
        {
          Chase.executor = Theory.Executor.id implementer;
          runtime = live_runtime ();
          fallback = None;
          repair_budget = Agent.Repair_budget.v 3;
          port = "agents";
        };
        {
          Chase.executor = Theory.Executor.id gate;
          runtime = Agent.shell_gate;
          fallback = None;
          repair_budget = Agent.Repair_budget.v 1;
          port = "agents";
        };
      ];
    backstops = Speculate.Backstops.default;
    switches = [];
    merges = Retire.Merge_registry.empty;
  }

let render_settlement = function
  | Ledger.Settlement.Retired -> "retired"
  | Ledger.Settlement.Faulted f ->
      Printf.sprintf "faulted (%s)" f.Ledger.Fault.message
  | Ledger.Settlement.Squashed _ -> "squashed"

let () =
  (match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | Some key when not (String.equal key "") -> ()
  | Some _ | None ->
      prerr_endline
        "coding_live: ANTHROPIC_API_KEY is not set (export it and rerun)";
      exit 1);
  let theory =
    match
      Theory.declare
        ~relations:
          [
            Theory.Relation.Packed spec_rel;
            Theory.Relation.Packed implementation_rel;
            Theory.Relation.Packed test_run_rel;
          ]
        ~statements ~laws
    with
    | Ok t -> t
    | Error errs ->
        List.iter
          (fun e ->
            Printf.eprintf "admission: %s\n" (Theory.Admission.to_string e))
          errs;
        exit 1
  in
  let seed =
    [
      Theory.Tuple.v spec_rel
        (`Assoc
          [
            ( "text",
              `String
                "Create a tiny Python project: fizzbuzz.py, a CLI that \
                 takes one integer argument N and prints the fizzbuzz \
                 sequence from 1 to N (Fizz for multiples of 3, Buzz for \
                 multiples of 5, FizzBuzz for both, the number \
                 otherwise), one item per line; and test_fizzbuzz.py, a \
                 directly runnable test file (plain asserts, no pytest) \
                 that exercises the fizzbuzz logic and exits 0 when all \
                 tests pass." );
          ]);
    ]
  in
  match Run.exec ~theory ~seed ~config with
  | Error (Run.Missing_path { field; path }) ->
      Printf.eprintf "coding_live: config field %s names a missing path: %s\n"
        field path;
      exit 1
  | Error (Run.Unbound_executor { executor }) ->
      Printf.eprintf "coding_live: unbound executor %s\n" executor;
      exit 1
  | Error (Run.Unknown_port { executor; port }) ->
      Printf.eprintf "coding_live: executor %s names unknown port %s\n"
        executor port;
      exit 1
  | Ok settled ->
      List.iter
        (fun (node, (r : Run.node_report)) ->
          Printf.printf "node %s: %s (run %.3fs, %d tokens)\n"
            (Id.to_string node)
            (render_settlement r.Run.settlement)
            r.Run.timing.Ledger.Telemetry.run_s
            (Ledger.Usage.total r.Run.usage))
        settled.Run.nodes;
      List.iter
        (fun (t : Retire.Committed.tuple) ->
          Printf.printf "tuple %s: %s\n" t.relation
            (Yojson.Safe.to_string t.payload))
        settled.Run.tuples;
      List.iter
        (fun (v : Theory.Law.verdict) ->
          Printf.printf "law %s: %s\n" v.Theory.Law.law
            (if v.Theory.Law.satisfied then "satisfied" else "violated"))
        settled.Run.laws;
      let faulted =
        List.exists
          (fun (_, (r : Run.node_report)) ->
            match r.Run.settlement with
            | Ledger.Settlement.Faulted _ -> true
            | _ -> false)
          settled.Run.nodes
      in
      let violated =
        List.exists
          (fun (v : Theory.Law.verdict) -> not v.Theory.Law.satisfied)
          settled.Run.laws
      in
      (* The map is the answer, and the host judges it: the gate's exit
         status is data on the test_run tuple — THIS host rules a
         non-zero status an error. *)
      let tests_green =
        List.exists
          (fun (t : Retire.Committed.tuple) ->
            String.equal t.relation "test_run"
            &&
            match t.payload with
            | `Assoc fields -> (
                match List.assoc_opt "exit_status" fields with
                | Some (`Int 0) -> true
                | _ -> false)
            | _ -> false)
          settled.Run.tuples
      in
      if not tests_green then prerr_endline "coding_live: the gate is red";
      exit (if faulted || violated || not tests_green then 1 else 0)
