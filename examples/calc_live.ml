(* calc_live — the speculation/message-passing stress: a diamond-shaped
   swarm builds a calculator CLI in a fresh repository.

       spec ──> module_spec x3 ──> module x3 ──┐  (3 agents, PARALLEL)
       spec ──[count(module per spec) >= 3]──> integration  (agent)
       integration ──> final_run                            (shell gate)

   What this exercises that haiku_live/coding_live do not:
   - data-generated fanout: ONE statement, three firings (three
     module_spec seeds), three provider calls overlapping on one domain;
   - fan-in through the v0 where-grammar: the integrate statement fires
     off a COUNT over the module relation — and the count consults the
     body-match feed, which includes parsed-but-unretired store buffers,
     so the integrator can fire while its producers are still landing;
   - the integrator's true dependence on upstream FILES (it must read
     the three modules before writing calc.py) versus the witness, which
     only sees its committed spec operand — the seam this example exists
     to observe;
   - the gate-parking capability rule, downstream of an agent that fired
     off a counter.

   Setup, self-contained under ./.goat/calc-repo:

     mkdir -p .goat/calc-repo
     git -C .goat/calc-repo init -q
     git -C .goat/calc-repo commit --allow-empty -m "root"
     export ANTHROPIC_API_KEY=sk-ant-...
     ./_build/default/examples/calc_live.exe *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Relations.                                                          *)
(* ------------------------------------------------------------------ *)

let str_field ?format ~desc () =
  `Assoc
    (List.concat
       [
         [ ("type", `String "string"); ("description", `String desc) ];
         (match format with
         | Some f -> [ ("format", `String f) ]
         | None -> []);
       ])

let obj ~desc ~required fields : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("description", `String desc);
      ("properties", `Assoc fields);
      ("required", `List (List.map (fun f -> `String f) required));
      ("additionalProperties", `Bool false);
    ]

let spec_schema =
  obj ~desc:"The project specification." ~required:[ "text" ]
    [ ("text", str_field ~desc:"The specification, verbatim." ()) ]

let module_spec_schema =
  obj
    ~desc:
      "One module's contract: its file, its test file, and the exact \
       interface it must expose."
    ~required:[ "name"; "file"; "test_file"; "interface"; "spec" ]
    [
      ("name", str_field ~desc:"The module's name." ());
      ("file", str_field ~desc:"Worktree-relative path of the module." ());
      ( "test_file",
        str_field ~desc:"Worktree-relative path of the module's tests." () );
      ( "interface",
        str_field
          ~desc:
            "The exact public interface the module must expose, verbatim."
          () );
      ( "spec",
        str_field ~format:"ref:spec"
          ~desc:"The wire id of the project spec." () );
    ]

let module_schema =
  obj
    ~desc:
      "One implemented module. Both files MUST be written into the \
       shared tree with the write_file tool before this tuple is emitted."
    ~required:[ "file"; "test_file"; "summary"; "module_spec"; "spec" ]
    [
      ("file", str_field ~desc:"The module file written." ());
      ("test_file", str_field ~desc:"The test file written." ());
      ( "summary",
        str_field ~desc:"One sentence on what was implemented." () );
      ( "module_spec",
        str_field ~format:"ref:module_spec"
          ~desc:"The wire id of the module_spec this implements." () );
      ( "spec",
        str_field ~format:"ref:spec"
          ~desc:
            "The wire id of the project spec — copy it from your \
             module_spec operand's spec field."
          () );
    ]

let integration_schema =
  obj
    ~desc:
      "The integration: calc.py wiring the three modules into a CLI, \
       plus its integration test. Both files MUST be written into the \
       shared tree with the write_file tool before this tuple is emitted."
    ~required:[ "files"; "summary"; "spec" ]
    [
      ( "files",
        `Assoc
          [
            ("type", `String "array");
            ("minItems", `Int 2);
            ( "description",
              `String "Worktree-relative paths of every file written." );
            ( "items",
              `Assoc
                [
                  ("type", `String "string");
                  ("description", `String "One written file's path.");
                ] );
          ] );
      ( "summary",
        str_field ~desc:"One or two sentences on the integration." () );
      ( "spec",
        str_field ~format:"ref:spec"
          ~desc:"The wire id of the project spec (your operand)." () );
    ]

let final_run_schema =
  obj ~desc:"The full test-gate run: exit status and captured output."
    ~required:[ "exit_status"; "output" ]
    [
      ( "exit_status",
        `Assoc
          [
            ("type", `String "integer");
            ("description", `String "The gate command's exit status.");
          ] );
      ("output", str_field ~desc:"Captured stdout and stderr." ());
    ]

let spec_rel = Theory.Relation.dynamic ~name:"spec" ~schema:spec_schema

let module_spec_rel =
  Theory.Relation.dynamic ~name:"module_spec" ~schema:module_spec_schema

let module_rel = Theory.Relation.dynamic ~name:"module" ~schema:module_schema

let integration_rel =
  Theory.Relation.dynamic ~name:"integration" ~schema:integration_schema

let final_run_rel =
  Theory.Relation.dynamic ~name:"final_run" ~schema:final_run_schema

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

let module_implementer =
  Theory.Executor.Agent_template
    {
      name = "module_implementer";
      pin;
      preamble =
        "You are a module implementer on a team building a small Python \
         project in parallel. Implement EXACTLY the interface your \
         module_spec operand states — other agents are implementing the \
         other modules against the same contracts right now, so any \
         deviation breaks the integration. Stdlib only. Write your module \
         file and its test file into the shared tree with the write_file \
         tool. The test file must be directly runnable (plain asserts, \
         exit 0 on success, no pytest) and must import only YOUR module. \
         Before emitting your tuple, RUN your test file with run_command \
         and fix what fails; do not emit until it exits 0.";
      read_globs = [];
      write_globs = [ "*.py" ];
      effects =
        [
          Theory.Executor.Effect.Idempotent
            {
              tool = "run_command";
              why = "build/test commands in the shared tree, freely re-runnable";
            };
        ];
    }

let integrator =
  Theory.Executor.Agent_template
    {
      name = "integrator";
      pin;
      preamble =
        "You are the integrator. Three modules (tokenizer.py, \
         evaluator.py, printer.py) have been implemented by other agents. \
         FIRST read each module file with the read_file tool to see its \
         actual interface — do not guess. Then write calc.py: a CLI that \
         takes one argument (an arithmetic expression), tokenizes it, \
         evaluates it, formats the result, prints it, and exits 0 \
         (errors print to stderr and exit 1). Also write test_calc.py: a \
         directly runnable integration test (plain asserts, no pytest, \
         exit 0 on success) that shells out to `python3 calc.py <expr>` \
         with subprocess and checks outputs. Report honestly in your \
         summary if any module file was missing or unreadable when you \
         looked.";
      read_globs = [ "*.py" ];
      write_globs = [ "*.py" ];
      (* No run_command here on purpose: the integration test needs the
         full module set, which may not have landed in the shared tree
         yet — running it is the downstream gate's job, after every
         module retired. *)
      effects = [];
    }

let gate =
  Theory.Executor.Shell_gate
    {
      name = "all_tests";
      command =
        [
          "sh";
          "-c";
          "python3 test_tokenizer.py && python3 test_evaluator.py && \
           python3 test_printer.py && python3 test_calc.py";
        ];
    }

let statements =
  [
    Theory.Spawn.v ~name:"implement_module" ~for_:"module_spec"
      ~exists:("module", Theory.Window.nodes 1)
      ~by:module_implementer ();
    Theory.Spawn.v ~name:"integrate" ~for_:"spec"
      ~where:
        (Theory.Filter.Count
           {
             over = "module";
             link = "spec";
             where_equals = [];
             cmp = Theory.Filter.Ge;
             bound = 3;
           })
      ~exists:("integration", Theory.Window.nodes 1)
      ~by:integrator ();
    Theory.Spawn.v ~name:"run_all_tests" ~for_:"integration"
      ~exists:("final_run", Theory.Window.nodes 1)
      ~by:gate ();
  ]

let laws =
  [
    Theory.Law.Disjoint_writes { name = "disjoint" };
    Theory.Law.Count
      {
        name = "three_modules_per_spec";
        over = "module";
        group_by = "spec";
        bound = Theory.Law.Exactly 3;
      };
  ]

(* ------------------------------------------------------------------ *)
(* Run configuration.                                                  *)
(* ------------------------------------------------------------------ *)

let live_runtime () =
  Agent.agent ~stop:[]
    ~provider:(Agent.Provider.anthropic ~post:Fiber.http_post ())

let agent_binding by =
  {
    Chase.executor = Theory.Executor.id by;
    runtime = live_runtime ();
    fallback = None;
    repair_budget = Agent.Repair_budget.v 3;
    port = "agents";
  }

let config =
  {
    Run.repo = ".goat/calc-repo";
    committed_branch = "goat-committed";
    ledger_path = ".goat/ledger-calc.bin";
    ports = [ Chase.Port.open_ ~name:"agents" ];
    executors =
      [
        agent_binding module_implementer;
        agent_binding integrator;
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

(* ------------------------------------------------------------------ *)
(* Seeds: the interface contracts are DATA — pinned here so three
   parallel implementers and one integrator can compose without ever
   seeing each other.                                                  *)
(* ------------------------------------------------------------------ *)

let module_spec_seed ~name ~file ~test_file ~interface =
  Theory.Tuple.v module_spec_rel
    (`Assoc
      [
        ("name", `String name);
        ("file", `String file);
        ("test_file", `String test_file);
        ("interface", `String interface);
        (* The spec seed is minted first: spec#0. *)
        ("spec", `String "spec#0");
      ])

let seed =
  [
    Theory.Tuple.v spec_rel
      (`Assoc
        [
          ( "text",
            `String
              "A calculator CLI in Python: calc.py evaluates one \
               arithmetic expression argument (+, -, *, /, parentheses, \
               floats) and prints the formatted result. Built from three \
               modules with pinned interfaces, each with its own tests, \
               plus an integration test." );
        ]);
    module_spec_seed ~name:"tokenizer" ~file:"tokenizer.py"
      ~test_file:"test_tokenizer.py"
      ~interface:
        "def tokenize(expr: str) -> list — lexes an arithmetic \
         expression into a flat list of tokens: float values for \
         numbers (integers and decimals), and the single-character \
         strings '+', '-', '*', '/', '(', ')' for operators and \
         parentheses. Skips whitespace. Raises ValueError on any other \
         character. Does NOT handle unary minus: '-' is always a token \
         of its own.";
    module_spec_seed ~name:"evaluator" ~file:"evaluator.py"
      ~test_file:"test_evaluator.py"
      ~interface:
        "def evaluate(tokens: list) -> float — evaluates a token list \
         as produced by tokenize(): floats are operands; '+', '-', '*', \
         '/', '(', ')' are operators/parens. Standard precedence (* / \
         over + -), left associativity, parentheses. Supports unary \
         minus before a number or '(' . Raises ValueError on malformed \
         input (trailing tokens, unbalanced parens, missing operands). \
         Division by zero raises ZeroDivisionError.";
    module_spec_seed ~name:"printer" ~file:"printer.py"
      ~test_file:"test_printer.py"
      ~interface:
        "def format_result(value: float) -> str — formats a numeric \
         result for display: values that are mathematically integers \
         print without a decimal point ('7', '-3'), everything else \
         prints via repr(float) ('0.5', '3.3333333333333335').";
  ]

(* ------------------------------------------------------------------ *)

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
        "calc_live: ANTHROPIC_API_KEY is not set (export it and rerun)";
      exit 1);
  let theory =
    match
      Theory.declare
        ~relations:
          [
            Theory.Relation.Packed spec_rel;
            Theory.Relation.Packed module_spec_rel;
            Theory.Relation.Packed module_rel;
            Theory.Relation.Packed integration_rel;
            Theory.Relation.Packed final_run_rel;
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
  match Run.exec ~theory ~seed ~config with
  | Error (Run.Missing_path { field; path }) ->
      Printf.eprintf "calc_live: config field %s names a missing path: %s\n"
        field path;
      exit 1
  | Error (Run.Unbound_executor { executor }) ->
      Printf.eprintf "calc_live: unbound executor %s\n" executor;
      exit 1
  | Error (Run.Unknown_port { executor; port }) ->
      Printf.eprintf "calc_live: executor %s names unknown port %s\n"
        executor port;
      exit 1
  | Ok settled ->
      List.iter
        (fun (node, (r : Run.node_report)) ->
          Printf.printf "node %s: %s (run %.3fs, %d tokens, %d hypotheses)\n"
            (Id.to_string node)
            (render_settlement r.Run.settlement)
            r.Run.timing.Ledger.Telemetry.run_s
            (Ledger.Usage.total r.Run.usage)
            (List.length r.Run.hypotheses))
        settled.Run.nodes;
      List.iter
        (fun (t : Retire.Committed.tuple) ->
          Printf.printf "tuple %s: %s\n" t.relation
            (Yojson.Safe.to_string t.payload))
        settled.Run.tuples;
      List.iter
        (fun (v : Theory.Law.verdict) ->
          Printf.printf "law %s: %s%s\n" v.Theory.Law.law
            (if v.Theory.Law.satisfied then "satisfied" else "violated")
            (match v.Theory.Law.offenders with
            | [] -> ""
            | o -> " (offenders: " ^ String.concat ", " o ^ ")"))
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
      let tests_green =
        List.exists
          (fun (t : Retire.Committed.tuple) ->
            String.equal t.relation "final_run"
            &&
            match t.payload with
            | `Assoc fields -> (
                match List.assoc_opt "exit_status" fields with
                | Some (`Int 0) -> true
                | _ -> false)
            | _ -> false)
          settled.Run.tuples
      in
      if not tests_green then prerr_endline "calc_live: the gate is red";
      exit (if faulted || violated || not tests_green then 1 else 0)
