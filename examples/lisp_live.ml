(* lisp_live — build a Lisp. The deep-chain census workload, live: four
   agents implement a Scheme-flavored mini-Lisp in Python IN PARALLEL
   against interface contracts pinned as seed data, an integrator wires
   the REPL off a count filter (firing against in-flight store buffers),
   and a shell gate runs the whole test suite as the final judge.

       spec ──> module_spec x4 ──> module x4 ──┐   (4 agents, PARALLEL)
       spec ──[count(module per spec) >= 4]──> integration  (agent)
       integration ──> final_run                            (shell gate)

   What this stresses beyond calc_live: a 4-wide fanout whose contracts
   genuinely interlock (the evaluator calls the core library through a
   pinned calling convention; the integrator composes all four), the
   classic representation traps pinned as data (Python bool <: int vs
   number?, only-#f-is-falsy, module shadowing avoided by naming the
   builtins module core.py), and a lazily-imported cross-module edge so
   each implementer's own tests never depend on a sibling's landing.

   Setup, self-contained under ./.goat/lisp-repo:

     mkdir -p .goat/lisp-repo
     git -C .goat/lisp-repo init -q
     git -C .goat/lisp-repo commit --allow-empty -m "root"
     export ANTHROPIC_API_KEY=sk-ant-...
     ./_build/default/examples/lisp_live.exe

   Verify on the committed side (never exit codes alone):

     git -C .goat/lisp-repo show goat-committed:lisp.py
     git clone -q -b goat-committed .goat/lisp-repo /tmp/lisp-verify
     python3 /tmp/lisp-verify/lisp.py -e "(define (fact n) (if (< n 2) 1 (* n (fact (- n 1))))) (fact 10)"  *)

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
      "The integration: lisp.py wiring the four modules into an \
       interpreter CLI, plus its integration test. Both files MUST be \
       written into the shared tree with the write_file tool before \
       this tuple is emitted."
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
        "You are a module implementer on a team building a mini-Lisp \
         interpreter in Python, in parallel. Implement EXACTLY the \
         interface your module_spec operand states — other agents are \
         implementing the other modules against the same contracts \
         right now, so any deviation breaks the integration. Stdlib \
         only. Write your module file and its test file into the \
         shared tree with the write_file tool. The test file must be \
         directly runnable (plain asserts, exit 0 on success, no \
         pytest) and must exercise only YOUR module's contract — never \
         a sibling module. Before emitting your tuple, RUN your test \
         file with run_command and fix what fails; do not emit until \
         it exits 0.";
      read_globs = [];
      write_globs = [ "*.py" ];
      effects =
        [
          Theory.Executor.Effect.Idempotent
            {
              tool = "run_command";
              why = "test commands in the shared tree, freely re-runnable";
            };
        ];
    }

let integrator =
  Theory.Executor.Agent_template
    {
      name = "integrator";
      pin;
      preamble =
        "You are the integrator. Four modules (reader.py, core.py, \
         evaluator.py, printer.py) have been implemented by other \
         agents against pinned contracts. FIRST read each module file \
         with the read_file tool to see its actual interface — do not \
         guess. Then write lisp.py: a CLI for the mini-Lisp. \
         `python3 lisp.py -e \"<src>\"` evaluates every top-level form \
         in one fresh global environment and prints the LAST form's \
         value via printer.to_string, then exits 0. \
         `python3 lisp.py <file.lisp>` does the same for a file's \
         contents. No arguments starts a REPL: read one line, evaluate \
         all its forms, print the last value, repeat until EOF. Any \
         error (reader, evaluator, unbound symbol, division by zero) \
         prints a message to stderr and exits 1 (the REPL instead \
         prints the error and continues). Also write test_lisp.py: a \
         directly runnable integration test (plain asserts, no pytest, \
         exit 0 on success) that shells out to `python3 lisp.py -e ...` \
         with subprocess and checks REAL programs end to end — at \
         minimum: arithmetic with precedence via nesting, a recursive \
         factorial through define, a closure made by a function \
         returning a lambda, let scoping, quote and list operations \
         (car/cdr/cons through the printer), and/or short-circuit, and \
         one error case asserting a non-zero exit. Report honestly in \
         your summary if any module file was missing or unreadable \
         when you looked.";
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
          "python3 test_reader.py && python3 test_core.py && python3 \
           test_evaluator.py && python3 test_printer.py && python3 \
           test_lisp.py";
        ];
      resource = "pycache";
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
             bound = 4;
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
        name = "four_modules_per_spec";
        over = "module";
        group_by = "spec";
        bound = Theory.Law.Exactly 4;
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
    Run.repo = ".goat/lisp-repo";
    committed_branch = "goat-committed";
    ledger_path = ".goat/ledger-lisp.bin";
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
(* Seeds: the language is pinned as DATA — the value representation,
   the calling convention, and every interface — so four parallel
   implementers and one integrator compose without ever seeing each
   other. The traps are pinned too (bool <: int; only #f is falsy;
   core.py not builtins.py), because a contract that leaves a trap
   unpinned is a contract that fires the repair lane later.            *)
(* ------------------------------------------------------------------ *)

let representation =
  "VALUE REPRESENTATION (shared by every module, verbatim): Lisp \
   values are Python values — integers are Python int, floats are \
   Python float, booleans are Python True/False (written #t/#f), \
   symbols are Python str, lists are Python list. There is no separate \
   nil: the empty list is []. TRUTHINESS: only False is falsy; 0, 0.0, \
   and [] are all truthy. NUMBERS: a Python bool is NOT a number — \
   every numeric predicate and operation must reject/exclude bools \
   explicitly (isinstance(x, bool) is checked BEFORE isinstance(x, \
   (int, float)))."

let module_spec_seed ~name ~file ~test_file ~interface =
  Theory.Tuple.v module_spec_rel
    (`Assoc
      [
        ("name", `String name);
        ("file", `String file);
        ("test_file", `String test_file);
        ("interface", `String (interface ^ "\n\n" ^ representation));
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
              "A Scheme-flavored mini-Lisp interpreter in Python: \
               lisp.py evaluates programs (define, lambda with lexical \
               closures, if, quote, let, set!, begin, and/or) over \
               ints, floats, booleans, symbols, and lists, with a core \
               library of arithmetic, comparison, and list operations. \
               Built from four modules with pinned interfaces, each \
               with its own tests, plus an integration test that runs \
               real programs (recursive factorial, closures) through \
               the CLI." );
        ]);
    module_spec_seed ~name:"reader" ~file:"reader.py"
      ~test_file:"test_reader.py"
      ~interface:
        "def read_program(src: str) -> list — parses Lisp source into \
         a Python list of ALL top-level forms (possibly empty). Atoms: \
         integers ('42', '-7') to int; floats ('3.14', '-0.5') to \
         float; '#t'/'#f' to True/False; everything else \
         non-structural to str (symbols — '+', 'foo', 'set!', '<=' \
         are all symbols). Lists: '(' ... ')' to Python list, nested \
         arbitrarily. Quote sugar: 'X reads as the list ['quote', X]. \
         Whitespace (including newlines) separates tokens; ';' starts \
         a comment running to end of line. Raises ValueError on \
         unbalanced parentheses or a lone quote. No other public \
         functions are required.";
    module_spec_seed ~name:"core" ~file:"core.py" ~test_file:"test_core.py"
      ~interface:
        "CORE: dict — maps builtin name (str) to a Python callable \
         taking EXACTLY ONE argument: a Python list of \
         already-evaluated Lisp values — and returning a Lisp value. \
         (The module is named core.py, NOT builtins.py, to avoid \
         shadowing Python's stdlib builtins module.) Names and pinned \
         semantics: '+' sums any number of numbers (empty sum is 0); \
         '*' multiplies (empty product is 1); '-' with one arg negates, \
         with more subtracts left to right; '/' true division left to \
         right, at least one arg, ZeroDivisionError propagates; '=', \
         '<', '>', '<=', '>=' chain across all args and return \
         True/False ('(< 1 2 3)' is True); 'abs', 'min', 'max' as in \
         Python over numbers; 'cons' takes [head, tail] where tail \
         must be a list, returns [head] + tail; 'car' returns the \
         first element (ValueError on empty or non-list); 'cdr' \
         returns the rest as a new list (ValueError on empty or \
         non-list); 'list' returns its args as a list; 'length' of a \
         list; 'append' concatenates any number of lists; 'null?' \
         True iff []; 'pair?' True iff a non-empty list; 'number?' \
         True iff int or float BUT NOT bool; 'symbol?' True iff str; \
         'boolean?' True iff bool; 'not' returns True iff the \
         argument is False (everything else gives False); 'eq?' \
         structural equality via Python == (but two bools/numbers of \
         different types follow Python ==). Numeric builtins raise \
         ValueError when given a non-number (bools included).";
    module_spec_seed ~name:"evaluator" ~file:"evaluator.py"
      ~test_file:"test_evaluator.py"
      ~interface:
        "class Env — __init__(self, bindings: dict, parent=None); \
         lookup(self, name: str) — innermost binding, raises \
         NameError naming the symbol if unbound; define(self, name: \
         str, value) — binds in THIS frame; set(self, name: str, \
         value) — rebinds in the innermost frame where name is bound, \
         NameError if nowhere.\n\
         def evaluate(form, env) -> value — evaluates one form: ints, \
         floats, and bools are self-evaluating; a str is a symbol \
         looked up in env; a list is a special form or an \
         application. Special forms (head is the symbol): (quote X) \
         returns X unevaluated; (if C T) and (if C T E) — only False \
         is falsy, missing else yields False; (define NAME EXPR) binds \
         in the current frame and returns NAME as a symbol; (define \
         (NAME PARAMS...) BODY...) is sugar for (define NAME (lambda \
         (PARAMS...) BODY...)); (set! NAME EXPR); (lambda (PARAMS...) \
         BODY...) — a lexical closure over env, body evaluated in \
         sequence, last value returned; (begin FORMS...) — sequence, \
         last value; (let ((N E)...) BODY...) — evaluates every E in \
         the OUTER env, then binds all in one new frame; (and \
         FORMS...) / (or FORMS...) — short-circuit, and returns the \
         first falsy value or the last (empty: True), or returns the \
         first truthy value or the last (empty: False). Anything else \
         is application: evaluate head then args left to right; a \
         Python callable is called with ONE argument, the list of \
         evaluated args; a closure is applied by binding params in a \
         fresh frame whose parent is the closure's captured env. \
         ValueError on malformed special forms or wrong arity.\n\
         def make_global_env() -> Env — a fresh Env over a COPY of \
         core.CORE, no parent. IMPORTANT: import core lazily, INSIDE \
         make_global_env (the sibling module may not exist yet while \
         you are being written), and your OWN test file must not call \
         make_global_env or import core — construct Env instances \
         directly with small hand-rolled bindings dicts (e.g. {'+': \
         lambda args: sum(args)}) so your tests exercise only your \
         module.";
    module_spec_seed ~name:"printer" ~file:"printer.py"
      ~test_file:"test_printer.py"
      ~interface:
        "def to_string(value) -> str — renders a Lisp value for \
         display: True is '#t', False is '#f' (check bool BEFORE int); \
         ints via str ('7', '-3'); floats via repr ('3.0', '0.5'); \
         symbols as themselves; lists as '(' + space-joined rendered \
         elements + ')' — '()' when empty — recursively; anything \
         callable as '#<procedure>'.";
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
        "lisp_live: ANTHROPIC_API_KEY is not set (export it and rerun)";
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
      Printf.eprintf "lisp_live: config field %s names a missing path: %s\n"
        field path;
      exit 1
  | Error (Run.Unbound_executor { executor }) ->
      Printf.eprintf "lisp_live: unbound executor %s\n" executor;
      exit 1
  | Error (Run.Unknown_port { executor; port }) ->
      Printf.eprintf "lisp_live: executor %s names unknown port %s\n"
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
      if not tests_green then prerr_endline "lisp_live: the gate is red";
      exit (if faulted || violated || not tests_green then 1 else 0)
