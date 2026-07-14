(* Boundary falsifiers (docs/architecture/80-validation.md § the falsifier
   discipline):

   - F10 — repair-lane boundedness. A permanently-invalid rigged executor
     faults after exactly the configured repair budget; nothing invalid
     ever crosses the codec boundary (60-agents.md § the primary lane,
     20-contracts.md § failure surface).
   - F11 — unidirectionality. No API surface, tool grant, or channel
     operation lets a node write to any relation its statement doesn't
     mint into; the adversarial sweep drives planner-shaped garbage at
     admission and wire-shaped garbage at the codec, asserting no panic
     and no write (30-channels.md, 20-contracts.md).
   - F12 — effect gating. A speculative node's tool surface contains no
     non-idempotent effect tool, under every template configuration this
     suite can generate (30-channels.md § event taxonomy, 60-agents.md
     § tool grants).

   Rigged executors only; no live model call, no live provider lane, no
   network, no sleeps. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Shared helpers.                                                     *)

let contains hay needle =
  let n = String.length hay and m = String.length needle in
  let rec go i =
    i + m <= n && (String.equal (String.sub hay i m) needle || go (i + 1))
  in
  m > 0 && go 0

let origin_string = function
  | Ledger.Fault.Executor_error -> "Executor_error"
  | Ledger.Fault.Repair_exhausted -> "Repair_exhausted"
  | Ledger.Fault.Context_exhausted -> "Context_exhausted"

let show_result = function
  | Ok v -> Printf.printf "Ok %S\n" v
  | Error { Ledger.Fault.origin; message = _ } ->
      Printf.printf "Error %s\n" (origin_string origin)

(* The head contract for the F10 lane: one relation, one string field.
   The codec is strict — exactly one field, exactly a string — so every
   scripted Invalid step really is invalid at the boundary. *)
let verdict_schema_json : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("description", `String "One verdict tuple.");
      ( "properties",
        `Assoc
          [
            ( "verdict",
              `Assoc
                [
                  ("type", `String "string");
                  ("description", `String "The judged outcome.");
                ] );
          ] );
      ("required", `List [ `String "verdict" ]);
      ("additionalProperties", `Bool false);
    ]

let wire_schema =
  match Contract.Wire_schema.parse verdict_schema_json with
  | Ok s -> s
  | Error _ -> failwith "test schema must parse into the LLM-safe subset"

let verdict_codec : string Contract.Codec.t =
  Contract.Codec.v
    ~of_json:(function
      | `Assoc [ ("verdict", `String s) ] -> s
      | _ -> failwith "expected exactly {\"verdict\": <string>}")
    ~to_json:(fun s -> `Assoc [ ("verdict", `String s) ])

let pin =
  { Theory.Pin.provider = "rigged"; model = "none"; sampling = []; options = [] }

(* F12's positive half rides along on every F10 invocation: the grant is
   the speculative index, so the invocation carries a tool surface the
   type system already screened for non-idempotent effects. *)
let speculative_grant : Agent.Grant.speculative Agent.Grant.t =
  {
    Agent.Grant.read_globs = [ "src/**/*.ml" ];
    worktree_root = "/tmp/goat-test-worktree";
    snoop_mounts = [];
    shell_gates = [];
    effects =
      [
        Agent.Grant.Effect_tool.idempotent ~name:"cache_write"
          (Agent.Grant.Idempotence.declare ~tool:"cache_write"
             ~why:"content-keyed cache write");
      ];
  }

let invocation grant =
  {
    Agent.Invocation.prompt =
      Agent.Prompt.assemble ~preamble:"You judge findings." ~schema:wire_schema
        ~operands:"(no witnessed operands)" ~hypotheses:[] ~grant;
    schema = wire_schema;
    grant;
    pin;
  }

type env = {
  ledger : Ledger.t;
  registry : Id.Registry.t;
  node : Ledger.node Id.t;
}

let env () =
  let ledger = Ledger.create ~path:(Filename.temp_file "goat-ledger-" ".bin") in
  let registry = Id.Registry.create () in
  let node = Id.mint (Id.Minter.create ~registry ~realm:"node") in
  { ledger; registry; node }

(* Counts real executor invocations, so "faults after exactly the budget"
   is asserted on dispatches, not inferred from the script. *)
let counting calls (inner : Agent.Executor.t) =
  let run :
      type s.
      s Agent.Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:(unit -> Speculate.Drift.note list) ->
      (Agent.Executor.reply, Ledger.Fault.t) result =
   fun inv ~ledger ~node ~on_yield ->
    incr calls;
    inner.Agent.Executor.run inv ~ledger ~node ~on_yield
  in
  { Agent.Executor.run }

let run_invoke ?fallback ~budget ~env:e exec =
  Agent.invoke ~executor:exec ?fallback ~codec:verdict_codec
    ~registry:e.registry
    ~invocation:(invocation speculative_grant)
    ~budget:(Agent.Repair_budget.v budget) ~ledger:e.ledger ~node:e.node
    ~on_yield:(fun () -> [])

let repair_attempts e =
  List.filter_map
    (fun (ev : Ledger.Event.t) ->
      match ev.kind with
      | Ledger.Event.Repair_attempt { attempt; refusal } ->
          Some (Printf.sprintf "(%d,%b)" attempt refusal)
      | _ -> None)
    (Ledger.Replay.events e.ledger)

let print_attempts e =
  Printf.printf "repair attempts:%s\n"
    (match repair_attempts e with
    | [] -> " none"
    | l -> " " ^ String.concat " " l)

(* ------------------------------------------------------------------ *)
(* F10 — repair-lane boundedness.                                      *)

let%expect_test "F10: a permanently-invalid executor faults after exactly \
                 the budget" =
  let e = env () in
  let calls = ref 0 in
  (* Ten invalid replies on the script: far more than the budget, so an
     engine that keeps retrying past exhaustion would consume more steps
     and count more calls. *)
  let script =
    List.init 10 (fun i ->
        Agent.Rigged.Invalid (Printf.sprintf "{\"wrong\": %d}" i))
  in
  let exec = counting calls (Agent.Rigged.executor ~script) in
  show_result (run_invoke ~budget:3 ~env:e exec);
  Printf.printf "executor invocations: %d\n" !calls;
  print_attempts e;
  [%expect {|
    Error Repair_exhausted
    executor invocations: 4
    repair attempts: (1,false) (2,false) (3,false)
    |}]

let%expect_test "F10: the reply one step past the budget is never consulted" =
  let e = env () in
  let calls = ref 0 in
  let script =
    [
      Agent.Rigged.Invalid "{\"wrong\": 0}";
      Agent.Rigged.Invalid "{\"wrong\": 1}";
      Agent.Rigged.Invalid "{\"wrong\": 2}";
      Agent.Rigged.Invalid "{\"wrong\": 3}";
      Agent.Rigged.Reply "{\"verdict\": \"late\"}";
    ]
  in
  let exec = counting calls (Agent.Rigged.executor ~script) in
  (* Budget 3: initial dispatch + 3 budgeted repairs = the four Invalid
     steps, and the valid fifth reply must be beyond reach. *)
  show_result (run_invoke ~budget:3 ~env:e exec);
  (* Steps are consumed in order across invocations of the same executor
     value (agent.mli § Rigged), so if the faulted invoke consumed exactly
     four steps, a fresh zero-budget invoke lands on the valid reply. *)
  show_result (run_invoke ~budget:0 ~env:e exec);
  Printf.printf "executor invocations: %d\n" !calls;
  [%expect {|
    Error Repair_exhausted
    Ok "late"
    executor invocations: 5
    |}]

let%expect_test "F10: recovery strictly inside the budget crosses only the \
                 parsed tuple" =
  let script () =
    [
      Agent.Rigged.Invalid "{\"oops\": truncated";
      Agent.Rigged.Invalid "{\"verdict\": 42}";
      Agent.Rigged.Reply "{\"verdict\": \"ok\"}";
    ]
  in
  (* Two failures then a valid reply: budget 2 admits it... *)
  let e = env () in
  show_result (run_invoke ~budget:2 ~env:e (Agent.Rigged.executor ~script:(script ())));
  print_attempts e;
  (* ...and budget 1, one short, faults without ever seeing it. *)
  let e' = env () in
  show_result
    (run_invoke ~budget:1 ~env:e' (Agent.Rigged.executor ~script:(script ())));
  print_attempts e';
  [%expect {|
    Ok "ok"
    repair attempts: (1,false) (2,false)
    Error Repair_exhausted
    repair attempts: (1,false)
    |}]

let%expect_test "F10: budget zero repairs nothing" =
  let e = env () in
  let calls = ref 0 in
  let exec =
    counting calls
      (Agent.Rigged.executor
         ~script:[ Agent.Rigged.Invalid "{\"wrong\": true}" ])
  in
  show_result (run_invoke ~budget:0 ~env:e exec);
  Printf.printf "executor invocations: %d\n" !calls;
  print_attempts e;
  [%expect {|
    Error Repair_exhausted
    executor invocations: 1
    repair attempts: none
    |}]

let%expect_test "F10: a refusal reroutes once to the fallback lane without \
                 burning budget" =
  let e = env () in
  let primary_calls = ref 0 and fallback_calls = ref 0 in
  let primary =
    counting primary_calls
      (Agent.Rigged.executor
         ~script:[ Agent.Rigged.Refuse "I cannot produce tuples for that." ])
  in
  let fallback =
    counting fallback_calls
      (Agent.Rigged.executor
         ~script:[ Agent.Rigged.Reply "{\"verdict\": \"constrained\"}" ])
  in
  (* Budget 0: were the reroute billed against the repair budget, this
     invoke could only fault. *)
  show_result (run_invoke ~fallback ~budget:0 ~env:e primary);
  Printf.printf "primary invocations: %d, fallback invocations: %d\n"
    !primary_calls !fallback_calls;
  print_attempts e;
  [%expect {|
    Ok "constrained"
    primary invocations: 1, fallback invocations: 1
    repair attempts: (0,true)
    |}]

let%expect_test "F10: nothing invalid crosses the codec boundary" =
  (* Every reply in the corpus is invalid against the verdict contract; a
     single [Ok] anywhere is a boundary breach. Budget 0 so each invoke
     judges exactly its scripted reply. *)
  let corpus =
    [
      "";
      "prose with no json at all";
      "I cannot help with that.";
      "{";
      "[1, 2";
      "[1, 2, 3]";
      "{\"verdict\": 42}";
      "{\"verdict\": null}";
      "{\"verdict\": \"ok\", \"extra\": true}";
      "{\"nested\": {\"verdict\": \"ok\"}}";
      "```\ngarbage in a fence\n```";
      "\x00\x01\x02";
      String.concat "" (List.init 200 (fun _ -> "["))
      ^ String.concat "" (List.init 200 (fun _ -> "]"));
    ]
  in
  let crossed = ref 0 and faulted = ref 0 in
  List.iter
    (fun raw ->
      let e = env () in
      match
        run_invoke ~budget:0 ~env:e
          (Agent.Rigged.executor ~script:[ Agent.Rigged.Invalid raw ])
      with
      | Ok _ -> incr crossed
      | Error _ -> incr faulted
      | exception _ -> incr crossed)
    corpus;
  Printf.printf "invalid replies: %d, crossed the boundary: %d, faulted: %d\n"
    (List.length corpus) !crossed !faulted;
  [%expect {| invalid replies: 13, crossed the boundary: 0, faulted: 13 |}]

(* ------------------------------------------------------------------ *)
(* F11 — unidirectionality and the adversarial garbage sweep.           *)

(* A small admitted theory: two consumers read [finding]; [verdict]
   carries a ref slot back to it. The reader ends obtained below have no
   publish operation and the writer end no pull operation (channel.mli);
   what a test can still falsify at runtime is that reader-side operations
   never write anything another party observes. *)
let obj_schema ~doc props required : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("description", `String doc);
      ("properties", `Assoc props);
      ("required", `List (List.map (fun s -> `String s) required));
      ("additionalProperties", `Bool false);
    ]

let str_prop doc : Yojson.Safe.t =
  `Assoc [ ("type", `String "string"); ("description", `String doc) ]

let finding_rel =
  Theory.Relation.dynamic ~name:"finding"
    ~schema:
      (obj_schema ~doc:"A claim under review."
         [ ("claim", str_prop "The claim text.") ]
         [ "claim" ])

let verdict_rel =
  Theory.Relation.dynamic ~name:"verdict"
    ~schema:
      (obj_schema ~doc:"One refuter's judgment of one finding."
         [
           ( "finding",
             `Assoc
               [
                 ("type", `String "string");
                 ("format", `String "ref:finding");
                 ("description", `String "The judged finding.");
               ] );
           ( "refuted",
             `Assoc
               [
                 ("type", `String "boolean");
                 ("description", `String "Whether the finding fell.");
               ] );
         ]
         [ "finding"; "refuted" ])

let digest_rel =
  Theory.Relation.dynamic ~name:"digest"
    ~schema:
      (obj_schema ~doc:"A summary tuple."
         [ ("summary", str_prop "The digest text.") ]
         [ "summary" ])

let template name =
  Theory.Executor.Agent_template
    { name; pin; preamble = "You refute findings."; read_globs = [ "src/**" ] }

let boundary_theory =
  match
    Theory.declare
      ~relations:
        [
          Theory.Relation.Packed finding_rel;
          Theory.Relation.Packed verdict_rel;
          Theory.Relation.Packed digest_rel;
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"judge" ~for_:"finding"
            ~exists:("verdict", Theory.Window.nodes 3)
            ~by:(template "refuter") ();
          Theory.Spawn.v ~name:"summarize" ~for_:"finding"
            ~exists:("digest", Theory.Window.exactly 1)
            ~by:(template "summarizer") ();
        ]
      ~laws:[]
  with
  | Ok a -> a
  | Error _ -> failwith "the boundary fixture theory must admit"

let edge_named name =
  List.find
    (fun (e : Theory.Edge.t) ->
      String.equal (Theory.Statement.to_string e.statement) name)
    (Theory.edges boundary_theory)

let%expect_test "F11: tuples flow forward only; a reader end cannot disturb \
                 the channel" =
  let chans = Channel.open_all boundary_theory in
  let idreg = Id.Registry.create () in
  let fid = Id.mint (Id.Minter.create ~registry:idreg ~realm:"finding") in
  let tx = Channel.tx chans finding_rel in
  let rx_judge = Channel.rx chans finding_rel ~edge:(edge_named "judge") in
  let rx_digest = Channel.rx chans finding_rel ~edge:(edge_named "summarize") in
  Channel.publish tx ~id:fid (`Assoc [ ("claim", `String "the moon is cheese") ]);
  (match Channel.pull_tuples rx_judge with
  | [ (id, payload) ] ->
      Printf.printf "judge drained: %s %s\n" (Id.to_string id)
        (Yojson.Safe.to_string payload)
  | l -> Printf.printf "judge drained %d tuples (violation)\n" (List.length l));
  (* Draining is a cursor move on the reader's own edge, never a write to
     the channel: the same reader sees nothing new, the sibling reader
     still sees everything. *)
  Printf.printf "judge re-drain: %d\n" (List.length (Channel.pull_tuples rx_judge));
  Printf.printf "digest drain after judge drained: %d\n"
    (List.length (Channel.pull_tuples rx_digest));
  (* No invalidation was ever sent, and no reader-side operation above may
     have synthesized one. *)
  Printf.printf "pending invalidations: judge %d, digest %d\n"
    (List.length (Channel.pull_invalidations rx_judge))
    (List.length (Channel.pull_invalidations rx_digest));
  (* The edge's compiled delivery filter is inspectable and derived — the
     relation it reads, that relation's contract, its file-glob grant —
     never authored routing (30-channels.md § footprint filtering). *)
  List.iter
    (fun a -> Printf.printf "footprint: %s\n" (Ledger.Address.to_string a))
    (Ledger.Footprint.to_list (Channel.footprint rx_judge));
  [%expect {|
    judge drained: finding#0 {"claim":"the moon is cheese"}
    judge re-drain: 0
    digest drain after judge drained: 1
    pending invalidations: judge 0, digest 0
    footprint: file:src/**
    footprint: tuple:finding/*
    footprint: contract:finding
    |}]

(* The codec used for the wire-garbage sweep resolves the [finding] ref
   slot against mint provenance, per 20-contracts.md § failure surface: an
   agent-invented id must die at the boundary with a diagnostic, never
   become a tuple. *)
let verdict_ref_codec idreg : (Yojson.Safe.t Id.t * bool) Contract.Codec.t =
  Contract.Codec.v
    ~of_json:(fun j ->
      match j with
      | `Assoc kvs ->
          List.iter
            (fun (k, _) ->
              if not (List.mem k [ "finding"; "refuted" ]) then
                failwith ("unexpected field " ^ k))
            kvs;
          let finding =
            match List.assoc_opt "finding" kvs with
            | Some (`String s) -> s
            | _ -> failwith "finding: expected a ref id string"
          in
          let refuted =
            match List.assoc_opt "refuted" kvs with
            | Some (`Bool b) -> b
            | _ -> failwith "refuted: expected a boolean"
          in
          (match Id.Registry.resolve idreg ~realm:"finding" finding with
          | Ok id -> (id, refuted)
          | Error (`Unknown_id s) ->
              failwith
                (Printf.sprintf
                   "unknown finding id %S: refs must echo ids minted by this \
                    run"
                   s))
      | _ -> failwith "expected an object")
    ~to_json:(fun (id, b) ->
      `Assoc [ ("finding", `String (Id.to_string id)); ("refuted", `Bool b) ])

let%expect_test "F11: wire-shaped garbage at the codec — no panic, no write" =
  let chans = Channel.open_all boundary_theory in
  let idreg = Id.Registry.create () in
  (* No finding id is minted yet: during the sweep, every "finding#N"
     string below is an invention. The control mint happens after. *)
  let finding_minter = Id.Minter.create ~registry:idreg ~realm:"finding" in
  let nid = Id.mint (Id.Minter.create ~registry:idreg ~realm:"node") in
  let codec = verdict_ref_codec idreg in
  let corpus =
    [
      "";
      "I cannot produce a verdict.";
      "distracting prose, then nothing";
      "{";
      "{\"finding\":";
      "[]";
      "[{\"finding\": \"finding#0\", \"refuted\": true}";
      "{\"refuted\": true}";
      "{\"finding\": 3, \"refuted\": true}";
      "{\"finding\": \"finding#0\", \"refuted\": \"yes\"}";
      "{\"finding\": \"finding#0\", \"refuted\": true, \"note\": \"smuggled\"}";
      (* An invented id: never minted by this run. *)
      "{\"finding\": \"finding#999\", \"refuted\": true}";
      (* A cross-realm confusion: a real minted id, wrong relation. *)
      Printf.sprintf "{\"finding\": %S, \"refuted\": true}" (Id.to_string nid);
      "```json\n{\"finding\": \"finding#42\"}\n```";
      "\x00\x00\x00";
      String.concat "" (List.init 300 (fun _ -> "{\"finding\":"))
      ^ "0"
      ^ String.concat "" (List.init 300 (fun _ -> "}"));
    ]
  in
  let crossed = ref 0 and rejected = ref 0 and panics = ref 0 in
  List.iter
    (fun raw ->
      match Contract.Codec.parse codec ~registry:idreg raw with
      | Ok _ -> incr crossed
      | Error _ -> incr rejected
      | exception _ -> incr panics)
    corpus;
  Printf.printf "garbage inputs: %d, crossed: %d, rejected: %d, panics: %d\n"
    (List.length corpus) !crossed !rejected !panics;
  (* No write: the sweep put nothing on any channel. *)
  let rx = Channel.rx chans finding_rel ~edge:(edge_named "judge") in
  Printf.printf "tuples on the channel after the sweep: %d\n"
    (List.length (Channel.pull_tuples rx));
  Printf.printf "invalidations after the sweep: %d\n"
    (List.length (Channel.pull_invalidations rx));
  (* Control: the boundary is a filter, not a wall — a reply echoing a
     genuinely-minted id parses, and resolves to that very id. *)
  let fid = Id.mint finding_minter in
  (match
     Contract.Codec.parse codec ~registry:idreg
       (Printf.sprintf "{\"finding\": %S, \"refuted\": true}"
          (Id.to_string fid))
   with
  | Ok (id, refuted) ->
      Printf.printf "control: Ok (resolves to the minted id: %b, refuted: %b)\n"
        (Id.equal id fid) refuted
  | Error _ -> print_endline "control: rejected (violation)");
  [%expect {|
    garbage inputs: 16, crossed: 0, rejected: 16, panics: 0
    tuples on the channel after the sweep: 0
    invalidations after the sweep: 0
    control: Ok (resolves to the minted id: true, refuted: true)
    |}]

(* Planner-shaped garbage: theories arriving as wire data through the
   meta-catalog. The codec boundary and the admission judgment are the
   only two gates, and both must answer with typed values — never a panic,
   never an admitted garbage theory (60-agents.md § the planner). *)
let meta_codec = Contract.codec (Theory.Meta.contract ())

let admission_error_name = function
  | Theory.Admission.Cycle _ -> "Cycle"
  | Theory.Admission.Schema_escape _ -> "Schema_escape"
  | Theory.Admission.Unknown_relation _ -> "Unknown_relation"
  | Theory.Admission.Unknown_ref_target _ -> "Unknown_ref_target"
  | Theory.Admission.Duplicate_relation _ -> "Duplicate_relation"
  | Theory.Admission.Duplicate_statement _ -> "Duplicate_statement"
  | Theory.Admission.Unjudgeable_law _ -> "Unjudgeable_law"

let meta_relation name (schema : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String name);
      ("schema_json", `String (Yojson.Safe.to_string schema));
    ]

let meta_statement ~name ~for_ ~head : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String name);
      ("for", `String for_);
      ("where", `Null);
      ( "exists",
        `Assoc
          [
            ("relation", `String head);
            ( "window",
              `Assoc
                [
                  ("kind", `String "nodes");
                  ("min", `Null);
                  ("max", `Null);
                  ("count", `Int 1);
                ] );
          ] );
      ( "by",
        `Assoc [ ("kind", `String "pure_fn"); ("name", `String "transform") ]
      );
    ]

let meta_theory ~relations ~statements ~laws : Yojson.Safe.t =
  `Assoc
    [
      ("relations", `List relations);
      ("statements", `List statements);
      ("laws", `List laws);
    ]

let%expect_test "F11: planner-shaped garbage at admission — typed errors, \
                 nothing admitted, no panic" =
  let idreg = Id.Registry.create () in
  let drive label json =
    try
      match Contract.Codec.parse_json meta_codec ~registry:idreg json with
      | Error (d : Contract.Repair.diagnostics) ->
          Printf.printf "%s: codec rejected (refusal: %b, complaints: %d)\n"
            label d.refusal (List.length d.complaints)
      | Ok meta -> (
          match Theory.Meta.admit meta with
          | Ok _ -> Printf.printf "%s: ADMITTED\n" label
          | Error errs ->
              Printf.printf "%s: admission rejected [%s]\n" label
                (String.concat "; " (List.map admission_error_name errs)))
    with e -> Printf.printf "%s: PANIC %s\n" label (Printexc.to_string e)
  in
  let simple_payload =
    obj_schema ~doc:"A payload." [ ("x", str_prop "A value.") ] [ "x" ]
  in
  drive "relations is not a list"
    (`Assoc [ ("relations", `Int 42); ("statements", `List []); ("laws", `List []) ]);
  drive "embedded schema text is not JSON"
    (meta_theory
       ~relations:
         [
           `Assoc
             [ ("name", `String "r"); ("schema_json", `String "not json {") ];
         ]
       ~statements:[] ~laws:[]);
  drive "embedded schema escapes the safe subset"
    (meta_theory
       ~relations:
         [
           meta_relation "r"
             (`Assoc
               [ ("type", `String "object"); ("patternProperties", `Assoc []) ]);
         ]
       ~statements:[] ~laws:[]);
  drive "ref slot targets an undeclared relation"
    (meta_theory
       ~relations:
         [
           meta_relation "r"
             (obj_schema ~doc:"Dangling ref."
                [
                  ( "target",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("format", `String "ref:nowhere");
                      ] );
                ]
                [ "target" ]);
         ]
       ~statements:[] ~laws:[]);
  drive "statement over undeclared relations"
    (meta_theory
       ~relations:[ meta_relation "r" simple_payload ]
       ~statements:[ meta_statement ~name:"s" ~for_:"ghost" ~head:"r" ]
       ~laws:[]);
  drive "self-spawning statement"
    (meta_theory
       ~relations:[ meta_relation "loop" simple_payload ]
       ~statements:[ meta_statement ~name:"s" ~for_:"loop" ~head:"loop" ]
       ~laws:[]);
  drive "duplicate relation names"
    (meta_theory
       ~relations:
         [ meta_relation "dup" simple_payload; meta_relation "dup" simple_payload ]
       ~statements:[] ~laws:[]);
  drive "law grouping by a value field"
    (meta_theory
       ~relations:[ meta_relation "r" simple_payload ]
       ~statements:[]
       ~laws:
         [
           `Assoc
             [
               ("kind", `String "count");
               ("name", `String "quorum");
               ("over", `String "r");
               ("group_by", `String "x");
               ( "bound",
                 `Assoc [ ("kind", `String "at_least"); ("n", `Int 1) ] );
             ];
         ]);
  drive "compound garbage accumulates every error"
    (meta_theory
       ~relations:
         [
           meta_relation "dup" simple_payload;
           meta_relation "dup" simple_payload;
         ]
       ~statements:[ meta_statement ~name:"s" ~for_:"ghost" ~head:"loop" ]
       ~laws:[]);
  (* The planner's prose non-answer dies at the codec with the refusal
     marker set — the fallback lane's trigger, not a panic. *)
  (match
     Contract.Codec.parse meta_codec ~registry:idreg
       "As an AI, I would rather discuss theory admission in general terms."
   with
  | Error (d : Contract.Repair.diagnostics) ->
      Printf.printf "planner prose: codec rejected (refusal: %b)\n" d.refusal
  | Ok _ -> print_endline "planner prose: ADMITTED (violation)");
  (* Control: a well-formed meta-theory passes the same two gates. *)
  drive "well-formed meta-theory"
    (meta_theory
       ~relations:
         [ meta_relation "task" simple_payload; meta_relation "done" simple_payload ]
       ~statements:[ meta_statement ~name:"work" ~for_:"task" ~head:"done" ]
       ~laws:[]);
  [%expect {|
    relations is not a list: codec rejected (refusal: false, complaints: 1)
    embedded schema text is not JSON: codec rejected (refusal: false, complaints: 1)
    embedded schema escapes the safe subset: admission rejected [Schema_escape]
    ref slot targets an undeclared relation: admission rejected [Unknown_ref_target]
    statement over undeclared relations: admission rejected [Unknown_relation]
    self-spawning statement: admission rejected [Cycle]
    duplicate relation names: admission rejected [Duplicate_relation]
    law grouping by a value field: admission rejected [Unjudgeable_law]
    compound garbage accumulates every error: admission rejected [Duplicate_relation; Unknown_relation; Unknown_relation]
    planner prose: codec rejected (refusal: true)
    well-formed meta-theory: ADMITTED
    |}]

(* ------------------------------------------------------------------ *)
(* F12 — effect gating on speculative grants.                          *)

(* The speculative index admits exactly one effect-tool constructor —
   [Effect_tool.idempotent], which demands an idempotence witness. The
   sweep below generates every template configuration this suite can
   express at the speculative index and checks the rendered tool surface;
   the direct smuggle is a compile error, owned by F15's negative
   compilation probes:

     let _ : Agent.Grant.speculative Agent.Grant.Effect_tool.t =
       Agent.Grant.Effect_tool.non_idempotent ~name:"deploy"

   — [non_idempotent] returns [committed t], and [speculative] and
   [committed] are distinct abstract types with no conversion anywhere in
   the API (agent.mli § Grant). *)

let%expect_test "F12: every constructible speculative grant is free of \
                 non-idempotent effect tools" =
  let names = [ "fmt"; "install"; "cache_write" ] in
  let whys = [ "re-runnable install"; "content-keyed cache write" ] in
  let idempotent name why : Agent.Grant.speculative Agent.Grant.Effect_tool.t =
    Agent.Grant.Effect_tool.idempotent ~name
      (Agent.Grant.Idempotence.declare ~tool:name ~why)
  in
  (* Every subset of effect names, each carried under each declared-why:
     3 tools x (absent | 2 whys) = 27 effect surfaces. *)
  let rec effect_sets = function
    | [] -> [ [] ]
    | n :: rest ->
        let tails = effect_sets rest in
        tails
        @ List.concat_map
            (fun why -> List.map (fun t -> idempotent n why :: t) tails)
            whys
  in
  let glob_choices = [ []; [ "src/**" ]; [ "src/**"; "docs/*.md" ] ] in
  let gate_choices = [ []; [ [ "dune"; "build" ] ] ] in
  let snoop_choices = [ []; [ "/tmp/goat-upstream-buffer" ] ] in
  let generated = ref 0 and offenders = ref 0 in
  List.iter
    (fun effects ->
      List.iter
        (fun read_globs ->
          List.iter
            (fun shell_gates ->
              List.iter
                (fun snoop_mounts ->
                  let grant : Agent.Grant.speculative Agent.Grant.t =
                    {
                      Agent.Grant.read_globs;
                      worktree_root = "/tmp/goat-test-worktree";
                      snoop_mounts;
                      shell_gates;
                      effects;
                    }
                  in
                  incr generated;
                  (* The rendered tool surface is what the agent reads; a
                     non-idempotent effect surfacing here means the grant
                     carried one. *)
                  if contains (Agent.Grant.describe grant) "non-idempotent"
                  then incr offenders)
                snoop_choices)
            gate_choices)
        glob_choices)
    (effect_sets names);
  Printf.printf
    "speculative grants generated: %d, non-idempotent effects found: %d\n"
    !generated !offenders;
  [%expect {| speculative grants generated: 324, non-idempotent effects found: 0 |}]

let%expect_test "F12: the non-idempotent case exists only at the committed \
                 index, and both stamps render honestly" =
  (* The committed index does admit non-idempotent effects — the case
     exists, so its absence under [speculative] is the type's doing, not a
     vocabulary gap. *)
  let committed : Agent.Grant.committed Agent.Grant.t =
    {
      Agent.Grant.read_globs = [];
      worktree_root = "/tmp/goat-test-worktree";
      snoop_mounts = [];
      shell_gates = [];
      effects =
        [
          Agent.Grant.Effect_tool.non_idempotent ~name:"deploy";
          Agent.Grant.Effect_tool.idempotent ~name:"cache_write"
            (Agent.Grant.Idempotence.declare ~tool:"cache_write"
               ~why:"content-keyed cache write");
        ];
    }
  in
  print_string (Agent.Grant.describe committed);
  [%expect {|
    Writable root (your worktree, the store buffer): /tmp/goat-test-worktree
    Readable paths: none beyond your worktree.
    Effect tools:
    - deploy — effect, non-idempotent (grantable on witnessed operands only)
    - cache_write — effect, idempotent by declaration (content-keyed cache write)
    Any action outside this grant returns a typed refusal — a tool error you can read — never a silent no-op.
    |}]

(* ------------------------------------------------------------------ *)
(* The harness-owned tool loop (agent.mli § agent): every store and load
   an agent performs is a ledger event with its footprint, and an
   out-of-grant action is a typed in-band refusal that leaves no event.
   Offline via [Rigged.Call_tool]; Phase C owns the fuller tool-event
   falsifiers. *)

let%expect_test "tool loop: stores and loads are evented with footprints; \
                 out-of-grant actions refuse in-band" =
  let e = env () in
  let worktree =
    let d = Filename.temp_file "goat-wt-" "" in
    Sys.remove d;
    Unix.mkdir d 0o755;
    d
  in
  let grant : Agent.Grant.committed Agent.Grant.t =
    {
      Agent.Grant.read_globs = [ "src/**/*.ml" ];
      worktree_root = worktree;
      snoop_mounts = [];
      shell_gates = [];
      effects = [];
    }
  in
  let script =
    [
      Agent.Rigged.Call_tool
        {
          name = "write_file";
          input =
            `Assoc
              [
                ("path", `String "src/gen.ml");
                ("content", `String "let x = 1\n");
              ];
        };
      (* The node snoops its own store buffer: the draft it just wrote is
         readable back. *)
      Agent.Rigged.Call_tool
        {
          name = "read_file";
          input = `Assoc [ ("path", `String "src/gen.ml") ];
        };
      (* A '..' hop is outside every grant by construction: refused
         in-band, no event, and the invocation continues. *)
      Agent.Rigged.Call_tool
        {
          name = "read_file";
          input = `Assoc [ ("path", `String "../escape.ml") ];
        };
      Agent.Rigged.Reply "{\"verdict\": \"done\"}";
    ]
  in
  show_result
    (Agent.invoke
       ~executor:(Agent.Rigged.executor ~script)
       ?fallback:None ~codec:verdict_codec ~registry:e.registry
       ~invocation:(invocation grant)
       ~budget:(Agent.Repair_budget.v 0) ~ledger:e.ledger ~node:e.node
       ~on_yield:(fun () -> []));
  Printf.printf "draft landed in worktree: %b\n"
    (Sys.file_exists (Filename.concat worktree "src/gen.ml"));
  List.iter
    (fun (ev : Ledger.Event.t) ->
      match ev.kind with
      | Ledger.Event.Store { tool; address; delta } ->
          Printf.printf "Store %s at %s (delta %s)\n" tool
            (Ledger.Address.to_string address)
            (Ledger.Delta_ref.to_string delta)
      | Ledger.Event.Load { tool; observed } ->
          Printf.printf "Load %s observing [%s]\n" tool
            (String.concat "; "
               (List.map
                  (fun (a, _, _) -> Ledger.Address.to_string a)
                  observed))
      | Ledger.Event.Effect { tool; resource; idempotent } ->
          Printf.printf "Effect %s on %s (idempotent %b)\n" tool resource
            idempotent
      | _ -> ())
    (Ledger.Replay.events e.ledger);
  [%expect {|
    Ok "done"
    draft landed in worktree: true
    Store write_file at file:src/gen.ml (delta src/gen.ml)
    Load read_file observing [file:src/gen.ml]
    |}]
