(* goat — the CLI wrapper around the Goatcode library.

   Thin by ruling: theories compile to executables that link the library and
   call [Run.exec]; [goat run] is a convenience runner around exactly that,
   holding no semantics of its own. [report]/[explain]/[replay] are ledger
   readers ([Report.summarize], [Report.explain], [Run.replay]); [plan] seeds
   the one-statement bootstrap theory whose single node is the planner
   template emitting a theory through the meta-catalog, then runs admission
   and, on success, the emitted theory — the full loop in one command
   (docs/architecture/70-api.md § the CLI). *)

open Goatcode

let version = "0.1.0-dev"

let usage_text =
  String.concat "\n"
    [
      "goat " ^ version;
      "";
      "usage:";
      "  goat run <theory.exe> --seed <seed.json> --config <run.toml>";
      "  goat plan <spec> --config <run.toml>";
      "  goat report <ledger>            # Report.summarize";
      "  goat explain <ledger> <node>    # one node's story";
      "  goat replay <ledger>            # replay-determinism check";
      "  goat version";
    ]

let ( let* ) = Result.bind

(* ------------------------------------------------------------------ *)
(* Command parsing: argv parses into a sum type or a typed complaint.  *)
(* ------------------------------------------------------------------ *)

type command =
  | Run of { theory_exe : string; seed : string; config : string }
      (** goat run <theory.exe> --seed seed.json --config run.toml *)
  | Plan of { spec : string; config : string }
      (** goat plan "<spec>" --config run.toml *)
  | Report of { ledger : string }  (** goat report <ledger> *)
  | Explain of { ledger : string; node : string }
      (** goat explain <ledger> <node> *)
  | Replay of { ledger : string }  (** goat replay <ledger> *)
  | Version

type parse_error = { complaint : string option }
(** [None] is the bare-invocation case: usage text alone, no scolding. *)

(* Split arguments into positionals and [--key value] flag pairs. *)
let split_flags args =
  let is_flag a = String.length a > 2 && String.starts_with ~prefix:"--" a in
  let rec go pos flags = function
    | [] -> Ok (List.rev pos, List.rev flags)
    | k :: v :: rest when is_flag k -> go pos ((k, v) :: flags) rest
    | [ k ] when is_flag k ->
        Error { complaint = Some ("missing value for " ^ k) }
    | a :: rest -> go (a :: pos) flags rest
  in
  go [] [] args

let required_flag flags key ~command =
  match List.assoc_opt key flags with
  | Some v -> Ok v
  | None ->
      Error { complaint = Some (Printf.sprintf "goat %s requires %s" command key) }

let parse = function
  | [] -> Error { complaint = None }
  | "run" :: rest -> (
      let* pos, flags = split_flags rest in
      match pos with
      | [ theory_exe ] ->
          let* seed = required_flag flags "--seed" ~command:"run" in
          let* config = required_flag flags "--config" ~command:"run" in
          Ok (Run { theory_exe; seed; config })
      | _ -> Error { complaint = Some "goat run takes exactly one <theory.exe>" })
  | "plan" :: rest -> (
      let* pos, flags = split_flags rest in
      match pos with
      | [ spec ] ->
          let* config = required_flag flags "--config" ~command:"plan" in
          Ok (Plan { spec; config })
      | _ -> Error { complaint = Some "goat plan takes exactly one <spec>" })
  | [ "report"; ledger ] -> Ok (Report { ledger })
  | [ "explain"; ledger; node ] -> Ok (Explain { ledger; node })
  | [ "replay"; ledger ] -> Ok (Replay { ledger })
  | [ "version" ] | [ "--version" ] -> Ok Version
  | cmd :: _ ->
      Error { complaint = Some ("unknown or malformed command: " ^ cmd) }

(* ------------------------------------------------------------------ *)
(* Rendering: every printed value comes off a typed representation.    *)
(* ------------------------------------------------------------------ *)

let render_timestamp at = Format.asprintf "%a" Ledger.Timestamp.pp at

let render_fault_origin = function
  | Ledger.Fault.Executor_error -> "executor error"
  | Ledger.Fault.Repair_exhausted -> "repair exhausted"
  | Ledger.Fault.Context_exhausted -> "context exhausted"

let render_squash_cause = function
  | Ledger.Squash_cause.Dead_hypothesis h -> "dead hypothesis " ^ Id.to_string h
  | Ledger.Squash_cause.Upstream_fault n -> "upstream fault " ^ Id.to_string n
  | Ledger.Squash_cause.Upstream_squash n -> "upstream squash " ^ Id.to_string n
  | Ledger.Squash_cause.Operator_abort -> "operator abort"

let render_settlement = function
  | Ledger.Settlement.Retired -> "retired"
  | Ledger.Settlement.Faulted f ->
      Printf.sprintf "faulted (%s: %s)"
        (render_fault_origin f.Ledger.Fault.origin)
        f.Ledger.Fault.message
  | Ledger.Settlement.Squashed cause ->
      Printf.sprintf "squashed (%s)" (render_squash_cause cause)

let render_misuse = function
  | Run.Missing_path { field; path } ->
      Printf.sprintf "config field %s names a missing path: %s" field path
  | Run.Unbound_executor { executor } ->
      Printf.sprintf
        "the theory names executor %s but the run config does not bind it"
        executor
  | Run.Unknown_port { executor; port } ->
      Printf.sprintf
        "executor %s names port %s, which the port table does not declare"
        executor port

let render_diagnostics (d : Contract.Repair.diagnostics) =
  let complaints =
    List.map
      (fun (c : Contract.Repair.complaint) ->
        Printf.sprintf "  at %s: expected %s, got %s"
          (Contract.Path.to_string c.path)
          c.expected c.got)
      d.complaints
  in
  let refusal = if d.refusal then [ "  (the reply carried refusal markers)" ] else [] in
  String.concat "\n"
    (("the emitted tuple failed the boundary parse:" :: complaints) @ refusal)

let print_settled (settled : Run.settled) =
  List.iter
    (fun (node, (r : Run.node_report)) ->
      let { Ledger.Telemetry.blocked_s; queued_s; run_s } = r.timing in
      Printf.printf
        "node %s: %s (blocked %.3fs, queued %.3fs, run %.3fs, %d tokens)\n"
        (Id.to_string node)
        (render_settlement r.settlement)
        blocked_s queued_s run_s
        (Ledger.Usage.total r.usage))
    settled.nodes;
  List.iter
    (fun (v : Theory.Law.verdict) ->
      Printf.printf "law %s: %s%s\n" v.law
        (if v.satisfied then "satisfied" else "violated")
        (match v.offenders with
        | [] -> ""
        | o -> " (offenders: " ^ String.concat ", " o ^ ")"))
    settled.laws

let print_summary (s : Report.summary) =
  Printf.printf "wall clock             %.3fs\n" s.wall_clock_s;
  Printf.printf "total work             %.3fs\n" s.total_work_s;
  Printf.printf "realized parallelism   %.2fx\n" s.realized_parallelism;
  (match s.critical_path with
  | [] -> ()
  | path ->
      Printf.printf "critical path          %s\n"
        (String.concat " -> " (List.map Id.to_string path)));
  List.iter
    (fun (port, queued_s) ->
      Printf.printf "port %-18s %.3fs queued\n" port queued_s)
    s.port_queues;
  let a : Report.speculation_account = s.speculation in
  Printf.printf
    "speculation            %d tokens under hypotheses, %d squashed (gross), %.3fs overlap bought\n"
    a.tokens_under_hypotheses a.tokens_squashed a.overlap_bought_s;
  List.iter
    (fun (shape, (c : Speculate.Counters.t)) ->
      Printf.printf
        "  %s: survival %.2f, reconcile %.1f tok, flush %.1f tok, overlap %.3fs, suspended %.3fs (%d samples)\n"
        (Speculate.Shape.to_string shape)
        c.survival c.reconcile_cost c.flush_cost c.overlap_s c.suspended_reads_s
        c.samples)
    a.per_shape;
  if s.token_ceiling_bound then
    print_endline
      "token ceiling bound: yes (an anomaly with a named cause, never a cost-control success)"

let print_story (st : Report.story) =
  Printf.printf "node %s\n" (Id.to_string st.node);
  Printf.printf "fired because: %s\n" st.fired_because;
  (match st.drift_notes with
  | [] -> print_endline "drift notes: none"
  | notes ->
      print_endline "drift notes:";
      List.iter
        (fun (at, cls, route) ->
          Printf.printf "  [%s] %s -> %s\n" (render_timestamp at) cls route)
        notes);
  (match st.witness with
  | [] -> print_endline "witness: empty (no observed reads)"
  | triples ->
      print_endline "witness (observed reads only):";
      List.iter
        (fun (t : Witness.triple) ->
          Printf.printf "  %s @ %s (%s)\n"
            (Ledger.Address.to_string t.address)
            (Format.asprintf "%a" Ledger.Generation.pp t.generation)
            (Ledger.Content_hash.to_hex t.content))
        triples);
  Printf.printf "settlement: %s\n" (render_settlement st.settlement);
  let { Ledger.Telemetry.blocked_s; queued_s; run_s } = st.timing in
  Printf.printf "timing: blocked %.3fs, queued %.3fs, run %.3fs\n" blocked_s
    queued_s run_s;
  Printf.printf "usage: %d tokens in, %d tokens out\n"
    st.usage.Ledger.Usage.tokens_in st.usage.Ledger.Usage.tokens_out

(* ------------------------------------------------------------------ *)
(* Reconstructing a settled map from a bare ledger.                    *)
(*                                                                     *)
(* report/explain receive only a ledger path (70-api § the CLI), while *)
(* the readers take [Run.settled]. Settlements, timings, usage, law    *)
(* verdicts, and hypotheses are all ledger-derived; committed tuple    *)
(* payloads live on the committed branch, not in the ledger, so the    *)
(* reconstruction carries an empty tuple set — no summary or story     *)
(* field reads it.                                                     *)
(* ------------------------------------------------------------------ *)

let settled_of_ledger ledger : Run.settled =
  let events = Ledger.Replay.events ledger in
  let hypotheses_of node =
    List.filter_map
      (fun (e : Ledger.Event.t) ->
        match (e.node, e.kind) with
        | Some n, Ledger.Event.Hypothesis_taken { hypothesis; _ }
          when Id.equal n node ->
            Some hypothesis
        | _ -> None)
      events
  in
  let nodes =
    List.filter_map
      (fun (e : Ledger.Event.t) ->
        match (e.node, e.kind) with
        | Some node, Ledger.Event.Settled settlement ->
            let timing =
              match Ledger.Telemetry.timing ledger node with
              | Some t -> t
              | None ->
                  { Ledger.Telemetry.blocked_s = 0.; queued_s = 0.; run_s = 0. }
            in
            Some
              ( node,
                {
                  Run.settlement;
                  timing;
                  usage = Ledger.Telemetry.usage ledger node;
                  hypotheses = hypotheses_of node;
                } )
        | _ -> None)
      events
  in
  let laws =
    List.filter_map
      (fun (e : Ledger.Event.t) ->
        match e.kind with
        | Ledger.Event.Law_verdict { law; satisfied } ->
            Some { Theory.Law.law; satisfied; offenders = [] }
        | _ -> None)
      events
  in
  { Run.nodes; tuples = []; laws; ledger }

(* The only honest wire-string → node id conversion available to a
   ledger reader: an id counts iff some ledger event carries it. *)
let node_of_string ledger s =
  Ledger.Replay.events ledger
  |> List.find_map (fun (e : Ledger.Event.t) ->
         match e.node with
         | Some n when String.equal (Id.to_string n) s -> Some n
         | _ -> None)

(* ------------------------------------------------------------------ *)
(* run.toml: the CLI's config subset, parsed line-by-line.             *)
(*                                                                     *)
(* Top-level keys: repo, committed_branch, worktree_root, ledger_path  *)
(* (required strings); port (default executor port, default "agents"); *)
(* token_ceiling, confidence_floor (backstop overrides);               *)
(* repair_attempts; planner_provider, planner_model (the plan pin).    *)
(* [[ports]] tables declare the port table: name, and — only together, *)
(* per [Chase.Port.bounded] — limit + bottleneck.                      *)
(*                                                                     *)
(* Deliberately absent: switches (a speculation off switch requires a  *)
(* ledger-derived churn measurement and is unconstructible from config *)
(* text — doc rule 8; 70-api § running) and merges (v0 ships the       *)
(* registry empty; 50-commit § OPEN items).                            *)
(* ------------------------------------------------------------------ *)

module Config_file = struct
  type value = Str of string | Int of int | Float of float | Bool of bool

  type port_decl = {
    pname : string option;
    plimit : int option;
    pbottleneck : string option;
  }

  type t = { scalars : (string * value) list; ports : port_decl list }

  let strip_comment line =
    let b = Buffer.create (String.length line) in
    let rec go i in_str =
      if i < String.length line then begin
        let c = line.[i] in
        if (not in_str) && Char.equal c '#' then ()
        else begin
          Buffer.add_char b c;
          go (i + 1) (if Char.equal c '"' then not in_str else in_str)
        end
      end
    in
    go 0 false;
    Buffer.contents b

  let parse_value raw =
    let n = String.length raw in
    if n >= 2 && Char.equal raw.[0] '"' && Char.equal raw.[n - 1] '"' then
      Ok (Str (String.sub raw 1 (n - 2)))
    else if String.equal raw "true" then Ok (Bool true)
    else if String.equal raw "false" then Ok (Bool false)
    else
      match int_of_string_opt raw with
      | Some i -> Ok (Int i)
      | None -> (
          match float_of_string_opt raw with
          | Some f -> Ok (Float f)
          | None -> Error (Printf.sprintf "unparseable value: %s" raw))

  let empty_port = { pname = None; plimit = None; pbottleneck = None }

  let load path : (t, string) result =
    match In_channel.with_open_text path In_channel.input_all with
    | exception Sys_error msg -> Error msg
    | contents ->
        let flush section ports =
          match section with `Top -> ports | `Port p -> p :: ports
        in
        let rec go lineno section scalars ports = function
          | [] ->
              Ok
                {
                  scalars = List.rev scalars;
                  ports = List.rev (flush section ports);
                }
          | raw :: rest -> (
              let line = String.trim (strip_comment raw) in
              if String.equal line "" then
                go (lineno + 1) section scalars ports rest
              else if String.equal line "[[ports]]" then
                go (lineno + 1) (`Port empty_port) scalars
                  (flush section ports) rest
              else if Char.equal line.[0] '[' then
                Error
                  (Printf.sprintf
                     "%s:%d: unsupported section %s (this config subset knows \
                      top-level keys and [[ports]])"
                     path lineno line)
              else
                match String.index_opt line '=' with
                | None ->
                    Error
                      (Printf.sprintf "%s:%d: expected key = value" path lineno)
                | Some i -> (
                    let key = String.trim (String.sub line 0 i) in
                    let rawv =
                      String.trim
                        (String.sub line (i + 1) (String.length line - i - 1))
                    in
                    match parse_value rawv with
                    | Error e -> Error (Printf.sprintf "%s:%d: %s" path lineno e)
                    | Ok v -> (
                        match section with
                        | `Top ->
                            go (lineno + 1) `Top ((key, v) :: scalars) ports rest
                        | `Port p -> (
                            match (key, v) with
                            | "name", Str s ->
                                go (lineno + 1)
                                  (`Port { p with pname = Some s })
                                  scalars ports rest
                            | "limit", Int n ->
                                go (lineno + 1)
                                  (`Port { p with plimit = Some n })
                                  scalars ports rest
                            | "bottleneck", Str s ->
                                go (lineno + 1)
                                  (`Port { p with pbottleneck = Some s })
                                  scalars ports rest
                            | _ ->
                                Error
                                  (Printf.sprintf
                                     "%s:%d: unknown or mistyped [[ports]] key \
                                      %s (name/limit/bottleneck)"
                                     path lineno key)))))
        in
        go 1 `Top [] [] (String.split_on_char '\n' contents)

  let str t key =
    match List.assoc_opt key t.scalars with Some (Str s) -> Some s | _ -> None

  let int_ t key =
    match List.assoc_opt key t.scalars with Some (Int i) -> Some i | _ -> None

  let float_ t key =
    match List.assoc_opt key t.scalars with
    | Some (Float f) -> Some f
    | Some (Int i) -> Some (float_of_int i)
    | _ -> None
end

(* ------------------------------------------------------------------ *)
(* Building a Run.config for the planner lane.                         *)
(* ------------------------------------------------------------------ *)

let port_of_decl (d : Config_file.port_decl) =
  match d.pname with
  | None -> Error "[[ports]] entry is missing name"
  | Some name -> (
      match (d.plimit, d.pbottleneck) with
      | None, _ -> Ok (Chase.Port.open_ ~name)
      | Some limit, Some bottleneck ->
          Ok (Chase.Port.bounded ~name ~limit ~bottleneck)
      | Some _, None ->
          Error
            (Printf.sprintf
               "port %s: a limit requires its documented bottleneck named \
                (Chase.Port.bounded)"
               name))

let rec map_result f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = map_result f rest in
      Ok (y :: ys)

(* The runtime behind an agent template's pin: dispatched on the pin's
   [provider] field at BIND time — an unknown provider is a config error
   before any node runs, never a mid-run surprise. Both lanes are direct
   API calls behind the harness-owned tool loop (agent.mli owns the
   no-shell-out ruling). *)
let provider_runtime (pin : Theory.Pin.t) =
  match pin.provider with
  | "anthropic" ->
      Ok (Agent.agent ~stop:[] ~provider:(Agent.Provider.anthropic ()))
  | "openai" ->
      Ok (Agent.agent ~stop:[] ~provider:(Agent.Provider.openai ()))
  | other ->
      Error
        (Printf.sprintf
           "pin names unknown provider %S (expected \"anthropic\" or \
            \"openai\")"
           other)

(* Bind every executor the theory names to runtimes: agent templates to
   the direct provider lane their pin routes to, shell gates to the gate
   runner. Pure functions stay unbound — the CLI carries no host-function
   registry, so a theory that names one surfaces as the typed
   [Run.Unbound_executor] misuse, never as a fake runtime. *)
let bindings_of ~theory ~port ~repair_attempts =
  let* bindings =
    Theory.statements theory
    |> List.filter_map (fun (_, (s : Theory.Spawn.t)) ->
           match s.by with
           | Theory.Executor.Pure_fn _ -> None
           | Theory.Executor.Agent_template { pin; _ } ->
               Some
                 (let* runtime = provider_runtime pin in
                  Ok
                    {
                      Chase.executor = Theory.Executor.id s.by;
                      runtime;
                      fallback = None;
                      repair_budget = Agent.Repair_budget.v repair_attempts;
                      port;
                    })
           | Theory.Executor.Shell_gate _ ->
               Some
                 (Ok
                    {
                      Chase.executor = Theory.Executor.id s.by;
                      runtime = Agent.shell_gate;
                      fallback = None;
                      repair_budget = Agent.Repair_budget.v 1;
                      port;
                    }))
    |> map_result Fun.id
  in
  Ok
    (List.fold_left
       (fun acc (b : Chase.executor_binding) ->
         if
           List.exists
             (fun (b' : Chase.executor_binding) ->
               Theory.Executor.id_equal b'.executor b.executor)
             acc
         then acc
         else b :: acc)
       [] bindings
    |> List.rev)

let run_config_of ~(file : Config_file.t) ~theory =
  let require key =
    match Config_file.str file key with
    | Some s -> Ok s
    | None ->
        Error (Printf.sprintf "run.toml: missing required string key %S" key)
  in
  let* repo = require "repo" in
  let* committed_branch = require "committed_branch" in
  let* worktree_root = require "worktree_root" in
  let* ledger_path = require "ledger_path" in
  let default_port =
    Option.value (Config_file.str file "port") ~default:"agents"
  in
  let* declared_ports = map_result port_of_decl file.ports in
  let ports =
    if
      List.exists
        (fun p -> String.equal (Chase.Port.name p) default_port)
        declared_ports
    then declared_ports
    else declared_ports @ [ Chase.Port.open_ ~name:default_port ]
  in
  let backstops =
    match
      (Config_file.int_ file "token_ceiling", Config_file.float_ file "confidence_floor")
    with
    | Some token_ceiling, Some confidence_floor ->
        { Speculate.Backstops.token_ceiling; confidence_floor }
    | ceiling, floor ->
        let d = Speculate.Backstops.default in
        {
          Speculate.Backstops.token_ceiling =
            Option.value ceiling ~default:d.token_ceiling;
          confidence_floor = Option.value floor ~default:d.confidence_floor;
        }
  in
  let repair_attempts =
    Option.value (Config_file.int_ file "repair_attempts") ~default:3
  in
  let* executors = bindings_of ~theory ~port:default_port ~repair_attempts in
  Ok
    {
      Run.repo;
      committed_branch;
      worktree_root;
      ledger_path;
      ports;
      executors;
      backstops;
      switches = [];
      (* Unconstructible from config text: throwing one requires
         ledger-derived churn evidence (Speculate.Switch.throw). *)
      merges = Retire.Merge_registry.empty (* v0 ships empty by ruling. *);
    }

(* ------------------------------------------------------------------ *)
(* The planner bootstrap theory: one statement, spec -> theory.        *)
(* ------------------------------------------------------------------ *)

(* Stance and method, never shape — shape derives from the meta-catalog
   contract (docs/architecture/60-agents.md § prompt assembly, § the
   planner). *)
let planner_preamble =
  String.concat " "
    [
      "You are the planner. Your operand is an operator's prose";
      "specification of work to orchestrate. Emit exactly one theory:";
      "relations with clear payloads and ref slots, spawn statements whose";
      "fanout is data-generated (a statement, never a loop), agent";
      "templates with deliberate model pins, and retire laws that compile";
      "to countable final-state judgments. Your output passes the same";
      "admission judgment as a hand-written theory: keep the dependency";
      "graph weakly acyclic and every payload inside the LLM-safe schema";
      "subset. If admission diagnostics come back, repair the named";
      "offense and nothing else.";
    ]

let planner_pin_of (file : Config_file.t) =
  {
    Theory.Pin.provider =
      Option.value (Config_file.str file "planner_provider")
        ~default:"anthropic";
    model =
      (* Pins name the model explicitly — the lane is a direct API call,
         so there is no ambient default to inherit. The planner pins the
         strongest available model (60-agents.md § provider routing). *)
      Option.value (Config_file.str file "planner_model")
        ~default:"claude-fable-5";
    sampling = [];
    options = [];
  }

let spec_schema =
  `Assoc
    [
      ("type", `String "object");
      ( "description",
        `String "An operator's prose specification of the work to orchestrate."
      );
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

let render_admission_errors errs =
  String.concat "\n"
    (List.map (fun e -> "admission: " ^ Theory.Admission.to_string e) errs)

(* The one-statement bootstrap: a dynamic [spec] relation (there is no
   OCaml payload type for operator prose), the meta-catalog [theory]
   relation, and a single planner spawn between them. *)
let plan_bootstrap ~spec ~pin =
  let spec_rel = Theory.Relation.dynamic ~name:"spec" ~schema:spec_schema in
  let theory_rel = Theory.Relation.v ~name:"theory" (Theory.Meta.contract ()) in
  let by =
    Theory.Executor.Agent_template
      { name = "planner"; pin; preamble = planner_preamble; read_globs = [] }
  in
  let statement =
    Theory.Spawn.v ~name:"plan" ~for_:"spec"
      ~exists:("theory", Theory.Window.exactly 1)
      ~by ()
  in
  match
    Theory.declare
      ~relations:
        [ Theory.Relation.Packed spec_rel; Theory.Relation.Packed theory_rel ]
      ~statements:[ statement ] ~laws:[]
  with
  | Error errs -> Error (render_admission_errors errs)
  | Ok admitted ->
      Ok (admitted, [ Theory.Tuple.v spec_rel (`Assoc [ ("text", `String spec) ]) ])

(* ------------------------------------------------------------------ *)
(* Command bodies. Each returns the process exit code.                 *)
(* ------------------------------------------------------------------ *)

(* Theories compile to executables that link the library and call
   [Run.exec]; run spawns exactly that, holding no semantics of its
   own. The child's exit code is the answer. *)
let cmd_run ~theory_exe ~seed ~config =
  let missing =
    List.filter
      (fun (_, path) -> not (Sys.file_exists path))
      [ ("<theory.exe>", theory_exe); ("--seed", seed); ("--config", config) ]
  in
  match missing with
  | (field, path) :: _ ->
      Printf.eprintf "goat run: %s path does not exist: %s\n" field path;
      1
  | [] ->
      Sys.command
        (Filename.quote_command theory_exe
           [ "--seed"; seed; "--config"; config ])

let cmd_report ~ledger_path =
  if not (Sys.file_exists ledger_path) then begin
    Printf.eprintf "goat report: no ledger at %s\n" ledger_path;
    1
  end
  else begin
    let ledger = Ledger.load ~path:ledger_path in
    print_summary (Report.summarize (settled_of_ledger ledger));
    0
  end

let cmd_explain ~ledger_path ~node =
  if not (Sys.file_exists ledger_path) then begin
    Printf.eprintf "goat explain: no ledger at %s\n" ledger_path;
    1
  end
  else
    let ledger = Ledger.load ~path:ledger_path in
    match node_of_string ledger node with
    | None ->
        Printf.eprintf "goat explain: the ledger carries no node %s\n" node;
        1
    | Some id -> (
        match Report.explain (settled_of_ledger ledger) ~node:id with
        | None ->
            Printf.eprintf "goat explain: the run never fired node %s\n" node;
            1
        | Some story ->
            print_story story;
            0)

let cmd_replay ~ledger_path =
  if not (Sys.file_exists ledger_path) then begin
    Printf.eprintf "goat replay: no ledger at %s\n" ledger_path;
    1
  end
  else
    match Run.replay (Ledger.load ~path:ledger_path) with
    | Ok () ->
        print_endline "replay: deterministic (every recorded decision reproduced)";
        0
    | Error divergences ->
        List.iter
          (fun (d : Run.divergence) ->
            Printf.printf "divergence at %s:\n  recorded: %s\n  replayed: %s\n"
              (render_timestamp d.at) d.recorded d.replayed)
          divergences;
        Printf.eprintf
          "replay: %d divergence(s) — some decision consulted unrecorded state\n"
          (List.length divergences);
        1

(* The full planner loop: bootstrap run, meta-catalog parse, the same
   admission judgment a hand-written theory faces, then the emitted
   theory — one command, the admission-repair cycle visible in the
   ledger like any other repair (70-api § the CLI). *)
let cmd_plan ~spec ~config_path =
  if not (Sys.file_exists config_path) then begin
    Printf.eprintf "goat plan: config path does not exist: %s\n" config_path;
    1
  end
  else
    let prepared =
      let* file = Config_file.load config_path in
      let* bootstrap, seed = plan_bootstrap ~spec ~pin:(planner_pin_of file) in
      let* config = run_config_of ~file ~theory:bootstrap in
      Ok (file, bootstrap, seed, config)
    in
    match prepared with
    | Error msg ->
        Printf.eprintf "goat plan: %s\n" msg;
        1
    | Ok (file, bootstrap, seed, config) -> (
        match Run.exec ~theory:bootstrap ~seed ~config with
        | Error misuse ->
            Printf.eprintf "goat plan: %s\n" (render_misuse misuse);
            1
        | Ok settled -> (
            match
              List.find_opt
                (fun (t : Retire.Committed.tuple) ->
                  String.equal t.relation "theory")
                settled.tuples
            with
            | None ->
                prerr_endline
                  "goat plan: the planner emitted no theory tuple; bootstrap \
                   settlements follow";
                print_settled settled;
                1
            | Some tuple -> (
                match
                  Contract.Codec.parse_json
                    (Contract.codec (Theory.Meta.contract ()))
                    ~registry:(Id.Registry.create ())
                    tuple.payload
                with
                | Error diagnostics ->
                    Printf.eprintf "goat plan: %s\n"
                      (render_diagnostics diagnostics);
                    1
                | Ok meta -> (
                    match Theory.Meta.admit meta with
                    | Error errs ->
                        Printf.eprintf "goat plan: the emitted theory failed \
                                        admission\n%s\n"
                          (render_admission_errors errs);
                        1
                    | Ok emitted -> (
                        match run_config_of ~file ~theory:emitted with
                        | Error msg ->
                            Printf.eprintf "goat plan: %s\n" msg;
                            1
                        | Ok config' -> (
                            (* The emitted theory carries its own spawn
                               structure; its seed relations, if any, are
                               the operator's next move — the bootstrap
                               spec tuple was consumed by the planner. *)
                            match
                              Run.exec ~theory:emitted ~seed:[] ~config:config'
                            with
                            | Error misuse ->
                                Printf.eprintf "goat plan: %s\n"
                                  (render_misuse misuse);
                                1
                            | Ok settled' ->
                                print_settled settled';
                                0))))))

(* ------------------------------------------------------------------ *)
(* Entry.                                                              *)
(* ------------------------------------------------------------------ *)

let () =
  let code =
    match parse (List.tl (Array.to_list Sys.argv)) with
    | Ok (Run { theory_exe; seed; config }) -> cmd_run ~theory_exe ~seed ~config
    | Ok (Plan { spec; config }) -> cmd_plan ~spec ~config_path:config
    | Ok (Report { ledger }) -> cmd_report ~ledger_path:ledger
    | Ok (Explain { ledger; node }) -> cmd_explain ~ledger_path:ledger ~node
    | Ok (Replay { ledger }) -> cmd_replay ~ledger_path:ledger
    | Ok Version ->
        print_endline ("goat " ^ version);
        0
    | Error { complaint } ->
        Option.iter (fun c -> Printf.eprintf "goat: %s\n" c) complaint;
        prerr_endline usage_text;
        2
    in
  exit code
