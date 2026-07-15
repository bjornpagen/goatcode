(* haiku_live — the live smoke: a hand-declared two-agent pipeline run by
   Run.exec against the live Anthropic lane. This is the "compile the
   emitted theory against the library" shape the CLI's run-it-yourself
   guidance names, written out once as a worked example: dynamic relations
   (JSON payloads with schemas, the same entry the planner uses), two
   spawn statements chained through a ref slot, one countable retire law,
   and live executor bindings over Fiber.http_post.

   Self-contained like examples/run.toml: everything it touches lives
   under ./.goat/ — the demo repo must exist (goat never runs git for
   you):

     mkdir -p .goat/demo-repo
     git -C .goat/demo-repo init -q
     git -C .goat/demo-repo commit --allow-empty -m "goat demo root"
     export ANTHROPIC_API_KEY=sk-ant-...
     ./_build/default/examples/haiku_live.exe

   Expect: both nodes retired, the law satisfied, docs/haiku.md and
   docs/haiku-review.md on the goat-committed branch of the demo repo,
   and a ledger at .goat/ledger-live.bin for the readers. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Relations. Payload shape lives in the schema — descriptions are the
   prose the model reads (contracts are one supply); ref slots are the
   [format: "ref:<relation>"] fields.                                   *)
(* ------------------------------------------------------------------ *)

let spec_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String "An operator's prose specification of the work." );
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

let haiku_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String
          "One written haiku. The file MUST be written into the worktree \
           with the write_file tool before this tuple is emitted; the \
           tuple records what was written." );
      ( "properties",
        `Assoc
          [
            ( "path",
              `Assoc
                [
                  ("type", `String "string");
                  ( "description",
                    `String
                      "Worktree-relative path of the written file: \
                       docs/haiku.md" );
                ] );
            ( "text",
              `Assoc
                [
                  ("type", `String "string");
                  ("description", `String "The haiku itself, three lines.");
                ] );
            ( "spec",
              `Assoc
                [
                  ("type", `String "string");
                  ("format", `String "ref:spec");
                  ( "description",
                    `String
                      "The wire id of the spec tuple this haiku answers." );
                ] );
          ] );
      ("required", `List [ `String "path"; `String "text"; `String "spec" ]);
      ("additionalProperties", `Bool false);
    ]

let review_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String
          "One review of a haiku. The review file MUST be written into \
           the worktree with the write_file tool before this tuple is \
           emitted." );
      ( "properties",
        `Assoc
          [
            ( "path",
              `Assoc
                [
                  ("type", `String "string");
                  ( "description",
                    `String
                      "Worktree-relative path of the written review: \
                       docs/haiku-review.md" );
                ] );
            ( "verdict",
              `Assoc
                [
                  ("type", `String "string");
                  ("enum", `List [ `String "approve"; `String "revise" ]);
                  ("description", `String "The reviewer's verdict.");
                ] );
            ( "haiku",
              `Assoc
                [
                  ("type", `String "string");
                  ("format", `String "ref:haiku");
                  ( "description",
                    `String "The wire id of the haiku tuple under review." );
                ] );
          ] );
      ( "required",
        `List [ `String "path"; `String "verdict"; `String "haiku" ] );
      ("additionalProperties", `Bool false);
    ]

let spec_rel = Theory.Relation.dynamic ~name:"spec" ~schema:spec_schema
let haiku_rel = Theory.Relation.dynamic ~name:"haiku" ~schema:haiku_schema

let review_rel =
  Theory.Relation.dynamic ~name:"review" ~schema:review_schema

(* ------------------------------------------------------------------ *)
(* Statements. Preambles carry stance and method, never shape — shape
   derives from the contracts above.                                   *)
(* ------------------------------------------------------------------ *)

let pin =
  {
    Theory.Pin.provider = "anthropic";
    model = "claude-opus-4-8";
    sampling = [];
    options = [];
  }

let writer =
  Theory.Executor.Agent_template
    {
      name = "haiku_writer";
      pin;
      preamble =
        "You are the haiku writer. Compose one original haiku (5-7-5) on \
         the requested subject and write it to the requested file in your \
         worktree with the write_file tool. Keep the file minimal: a \
         markdown title line and the haiku.";
      read_globs = [];
      effects = [];
    }

let reviewer =
  Theory.Executor.Agent_template
    {
      name = "haiku_reviewer";
      pin;
      preamble =
        "You are the haiku reviewer. Read the haiku under review from the \
         committed tree, judge its form (syllable shape, imagery, \
         subject fit), and write a short review to the requested file in \
         your worktree with the write_file tool: a markdown title, two or \
         three sentences of judgment, and your verdict.";
      read_globs = [ "docs/*" ];
      effects = [];
    }

let statements =
  [
    Theory.Spawn.v ~name:"write_haiku" ~for_:"spec"
      ~exists:("haiku", Theory.Window.nodes 1)
      ~by:writer ();
    Theory.Spawn.v ~name:"review_haiku" ~for_:"haiku"
      ~exists:("review", Theory.Window.nodes 1)
      ~by:reviewer ();
  ]

let laws =
  [
    Theory.Law.Count
      {
        name = "one_review_per_haiku";
        over = "review";
        group_by = "haiku";
        bound = Theory.Law.Exactly 1;
      };
  ]

(* ------------------------------------------------------------------ *)
(* Run configuration: the live lane behind the same fiber transport the
   CLI binds (provider turns overlap on one domain).                    *)
(* ------------------------------------------------------------------ *)

let live_runtime () =
  Agent.agent ~stop:[]
    ~provider:(Agent.Provider.anthropic ~post:Fiber.http_post ())

let binding by =
  {
    Chase.executor = Theory.Executor.id by;
    runtime = live_runtime ();
    fallback = None;
    repair_budget = Agent.Repair_budget.v 3;
    port = "agents";
  }

let config =
  {
    Run.repo = ".goat/demo-repo";
    committed_branch = "goat-committed";
    worktree_root = ".goat/demo-repo/.goat-worktrees";
    ledger_path = ".goat/ledger-live.bin";
    ports = [ Chase.Port.open_ ~name:"agents" ];
    executors = [ binding writer; binding reviewer ];
    backstops = Speculate.Backstops.default;
    switches = [];
    merges = Retire.Merge_registry.empty;
  }

(* ------------------------------------------------------------------ *)
(* Rendering: minimal, mirrors the CLI's settled-map printout.          *)
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
        "haiku_live: ANTHROPIC_API_KEY is not set (export it and rerun)";
      exit 1);
  let theory =
    match
      Theory.declare
        ~relations:
          [
            Theory.Relation.Packed spec_rel;
            Theory.Relation.Packed haiku_rel;
            Theory.Relation.Packed review_rel;
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
                "Write docs/haiku.md: one haiku about speculative \
                 execution. Then a second agent reviews it and writes \
                 docs/haiku-review.md." );
          ]);
    ]
  in
  match Run.exec ~theory ~seed ~config with
  | Error (Run.Missing_path { field; path }) ->
      Printf.eprintf "haiku_live: config field %s names a missing path: %s\n"
        field path;
      exit 1
  | Error (Run.Unbound_executor { executor }) ->
      Printf.eprintf "haiku_live: unbound executor %s\n" executor;
      exit 1
  | Error (Run.Unknown_port { executor; port }) ->
      Printf.eprintf "haiku_live: executor %s names unknown port %s\n"
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
      exit (if faulted || violated then 1 else 0)
