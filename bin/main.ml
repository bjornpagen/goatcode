(* goat — the CLI wrapper around the Goatcode library.

   Thin by ruling: theories compile to executables that link the library and
   call [Run.exec]; [goat run] is a convenience runner around exactly that,
   holding no semantics of its own. [report]/[explain]/[replay] are ledger
   readers ([Report.summarize], [Report.explain], [Run.replay]); [plan] seeds
   the one-statement bootstrap theory whose single node is the planner
   template emitting a theory through the meta-catalog, runs admission on
   the emission (a rejected emission returns to the planner ONCE,
   stateless-with-diagnostics, as a second planning run — the
   admission-repair lane), and prints the admitted roster plus the
   run-it-yourself guidance — it does NOT run the emitted theory (its
   seed surface is undesigned; [~seed:[]] would fire nothing and print
   success vacuously — docs/architecture/70-api.md § the CLI, OPEN: the
   plan-to-run seed surface).

   The exit-code contract (every command; an operator at a shell never
   parses stdout to learn whether the command went wrong):
   - 0 — success. For [plan]: the bootstrap (planning) run quiesced with
     no faulted node and no violated law (squashes alone are speculation's
     normal business, not errors) and the emission passed admission.
   - 1 — any typed error path: config parse/bind errors, admission
     rejection, run-level misuse, a missing ledger or node, an
     existing-ledger collision ([refuse_existing_ledger] — a ledger is
     one run's journal, never appended to, never truncated), a coherence
     divergence under [replay], the planner emitting no theory, or a
     final settled map carrying a faulted node or violated law.
   - 2 — argv did not parse (usage).
   [goat run] delegates to the theory executable and returns the child's
   exit code — the same contract, owed by the linked binary. *)

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
      "  goat replay <ledger>            # ledger-coherence audit";
      "  goat version";
      "";
      "exit codes: 0 success; 1 typed error (config, admission, faulted";
      "nodes, violated laws, coherence divergence); 2 usage";
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
  | Ledger.Squash_cause.Reissue_loser -> "reissue loser"
  | Ledger.Squash_cause.No_producer -> "no producer"
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

(* The settled map is the answer (run.mli), and the exit code is its
   terminal rendering: any faulted node or violated law is a non-zero
   exit. Squashes alone are not errors — they are speculation's normal
   business (reissue losers, upstream squash), and the retired survivors
   are the work. *)
let exit_of_settled (settled : Run.settled) =
  let faulted =
    List.exists
      (fun (_, (r : Run.node_report)) ->
        match r.Run.settlement with
        | Ledger.Settlement.Faulted _ -> true
        | Ledger.Settlement.Retired | Ledger.Settlement.Squashed _ -> false)
      settled.Run.nodes
  in
  let violated =
    List.exists
      (fun (v : Theory.Law.verdict) -> not v.Theory.Law.satisfied)
      settled.Run.laws
  in
  if faulted || violated then 1 else 0

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
  (match st.decisions with
  | [] -> ()
  | decisions ->
      print_endline "scheduler decisions:";
      List.iter
        (fun (at, action, reason) ->
          Printf.printf "  [%s] %s (%s)\n" (render_timestamp at) action reason)
        decisions);
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
  (match st.escapes with
  | [] -> ()
  | escapes ->
      print_endline
        "footprint escapes (grow the declaration to cover these reads):";
      List.iter
        (fun (tool, address) ->
          Printf.printf "  %s via %s\n"
            (Ledger.Address.to_string address)
            tool)
        escapes);
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
(* Top-level keys: repo, committed_branch, ledger_path (required       *)
(* strings); port (default executor port, default "agents");           *)
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
   [provider] field at BIND time — an unknown provider or a missing API
   key is a config error before any node runs, never a mid-chase
   surprise. Both lanes are direct API calls behind the harness-owned
   tool loop (agent.mli owns the no-shell-out ruling), and both post
   through [Fiber.http_post]: the engine runs every node as a fiber, so
   the POST is the [Http_post] suspension the scheduler overlaps — N
   provider turns in flight on one domain (chase.mli [create]). *)
let require_key ~provider ~variable =
  match Sys.getenv_opt variable with
  | Some key when not (String.equal key "") -> Ok ()
  | Some _ | None ->
      Error
        (Printf.sprintf
           "a pin routes to provider %S but %s is not set in the \
            environment (export %s=... and rerun)"
           provider variable variable)

let provider_runtime (pin : Theory.Pin.t) =
  match pin.provider with
  | "anthropic" ->
      let* () = require_key ~provider:"anthropic" ~variable:"ANTHROPIC_API_KEY" in
      Ok
        (Agent.agent ~stop:[]
           ~provider:(Agent.Provider.anthropic ~post:Fiber.http_post ()))
  | "openai" ->
      let* () = require_key ~provider:"openai" ~variable:"OPENAI_API_KEY" in
      Ok
        (Agent.agent ~stop:[]
           ~provider:(Agent.Provider.openai ~post:Fiber.http_post ()))
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

let run_config_of ~path ~(file : Config_file.t) ~theory =
  let require key =
    match List.assoc_opt key file.Config_file.scalars with
    | Some (Config_file.Str s) -> Ok s
    | Some _ ->
        Error (Printf.sprintf "%s: key %S must be a string" path key)
    | None ->
        Error (Printf.sprintf "%s: missing required string key %S" path key)
  in
  let* repo = require "repo" in
  let* committed_branch = require "committed_branch" in
  (* A retired key is refused by name, never silently ignored: an old
     config carrying it gets the migration pointer, not a run whose
     stated layout the engine no longer honors (README.md § design of
     record vs shipped engine, row 5). *)
  let* () =
    match List.assoc_opt "worktree_root" file.Config_file.scalars with
    | None -> Ok ()
    | Some _ ->
        Error
          (Printf.sprintf
             "%s: key \"worktree_root\" is retired — nodes dispatch \
              against the one shared tree (repo); delete the key"
             path)
  in
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
      {
        name = "planner";
        pin;
        preamble = planner_preamble;
        read_globs = [];
        write_globs = [];
        effects = [];
      }
  in
  let statement =
    (* One theory per spec is a firing count, not a tuple array: [1 nodes]
       keeps the planner's contract the bare meta-theory object (a tuples
       window would lower to a one-element array schema —
       10-theory.md § statement grammar). *)
    Theory.Spawn.v ~name:"plan" ~for_:"spec"
      ~exists:("theory", Theory.Window.nodes 1)
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

(* A ledger is ONE run's replayable journal: node identity is per run,
   so a second run appended to an existing file would make [goat replay]
   report false divergences. The CLI refuses the collision up front —
   fix-forward: the operator picks a fresh path; the existing journal is
   never truncated. CLI layer only: library callers and tests manage
   their own paths. *)
let refuse_existing_ledger ~command path =
  if Sys.file_exists path then begin
    Printf.eprintf
      "goat %s: refusing to write ledger %s — the path already exists, and \
       a ledger is one run's replayable journal (a second run in the same \
       file would make goat replay report false divergences). Choose a \
       fresh ledger path; the existing file is never truncated.\n"
      command path;
    false
  end
  else true

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
  | [] -> (
      (* The one config key this wrapper reads: the ledger-collision
         refusal belongs at the CLI (above); everything else is the
         linked binary's own bind-time judgment. *)
      match Config_file.load config with
      | Error msg ->
          Printf.eprintf "goat run: %s\n" msg;
          1
      | Ok file -> (
          match Config_file.str file "ledger_path" with
          | Some p when not (refuse_existing_ledger ~command:"run" p) -> 1
          | Some _ | None ->
              Sys.command
                (Filename.quote_command theory_exe
                   [ "--seed"; seed; "--config"; config ])))

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
        (* The honest claim (run.mli [replay]): the coherence audit passed —
           the clock, settlement, retire order, and drift routes the trace
           makes re-derivable all reproduce. Full re-execution is the
           recorded OPEN item (80-validation.md § replay determinism). *)
        print_endline
          "replay: coherent (clock, settlement, retire order, and drift \
           routes reproduce from the recorded trace)";
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

(* The planner lane: bootstrap run, meta-catalog parse, the same
   admission judgment a hand-written theory faces, then the roster and
   the run-it-yourself guidance — never a vacuous run of the emission
   (70-api § the CLI).

   The bootstrap (planning) run journals at [ledger_path ^ ".plan"] —
   [ledger_path] itself stays free for the emitted theory's own run
   (each ledger is one run's replayable journal: node identity is per
   run; interleaving two runs in one file would make [goat replay]
   report false divergences). *)

(* One planning attempt: bootstrap run against [spec_text], journaled at
   [plan_ledger], then meta parse and admission on the emission. *)
let plan_attempt ~file ~config_path ~plan_ledger ~spec_text =
  let prepared =
    let* bootstrap, seed =
      plan_bootstrap ~spec:spec_text ~pin:(planner_pin_of file)
    in
    let* config = run_config_of ~path:config_path ~file ~theory:bootstrap in
    Ok (bootstrap, seed, { config with Run.ledger_path = plan_ledger })
  in
  match prepared with
  | Error msg -> `Config_error msg
  | Ok (bootstrap, seed, config) -> (
      match Run.exec ~theory:bootstrap ~seed ~config with
      | Error misuse -> `Misuse misuse
      | Ok settled -> (
          match
            List.find_opt
              (fun (t : Retire.Committed.tuple) ->
                String.equal t.relation "theory")
              settled.tuples
          with
          | None -> `No_theory settled
          | Some tuple -> (
              match
                Contract.Codec.parse_json
                  (Contract.codec (Theory.Meta.contract ()))
                  ~registry:(Id.Registry.create ())
                  tuple.payload
              with
              | Error diagnostics -> `Bad_meta diagnostics
              | Ok meta -> (
                  match Theory.Meta.admit meta with
                  | Error errs -> `Inadmissible (settled, tuple.payload, errs)
                  | Ok emitted -> `Admitted (settled, emitted)))))

(* The admission-repair spec: the planner re-invoked
   stateless-with-diagnostics — its original operand, its own invalid
   emission, and the admission complaints, exactly the repair-lane shape
   (60-agents.md § the planner; the preamble already instructs "repair
   the named offense and nothing else"). *)
let repair_spec ~spec ~emission ~errs =
  String.concat "\n"
    ([
       spec;
       "";
       "Your previous theory emission failed admission. Repair the named \
        offenses and nothing else.";
       "Previous emission (verbatim):";
       Yojson.Safe.to_string emission;
       "Admission diagnostics:";
     ]
    @ List.map (fun e -> "- " ^ Theory.Admission.to_string e) errs)

let cmd_plan ~spec ~config_path =
  if not (Sys.file_exists config_path) then begin
    Printf.eprintf "goat plan: config path does not exist: %s\n" config_path;
    1
  end
  else
    match Config_file.load config_path with
    | Error msg ->
        Printf.eprintf "goat plan: %s\n" msg;
        1
    | Ok file -> (
        let ledger_path =
          match Config_file.str file "ledger_path" with
          | Some p -> p
          | None -> "goat-ledger" (* run_config_of rejects this case. *)
        in
        let plan_ledger = ledger_path ^ ".plan" in
        if not (refuse_existing_ledger ~command:"plan" plan_ledger) then 1
        else
        let finish ~ledgers settled emitted =
          match run_config_of ~path:config_path ~file ~theory:emitted with
          | Error msg ->
              Printf.eprintf "goat plan: %s\n" msg;
              1
          | Ok (_ : Run.config) ->
              (* Binding the emitted theory validates its executor pins
                 (providers known, keys present) at plan time; the config
                 value is discarded — [plan] does NOT run the emitted
                 theory. Its seed relations are the operator's next move
                 (the bootstrap spec tuple was consumed by the planner),
                 and the plan-to-run seed surface is undesigned: running
                 with [~seed:[]] would fire nothing and print success
                 vacuously. Admission is the honest boundary of this
                 command (70-api.md § the CLI, OPEN: the plan-to-run seed
                 surface). *)
              Printf.printf
                "planner emitted an admitted theory: %d relations, \
                 statements [%s]\n"
                (List.length (Theory.relations emitted))
                (String.concat ", "
                   (List.map
                      (fun (sid, _) -> Theory.Statement.to_string sid)
                      (Theory.statements emitted)));
              List.iter
                (fun (label, path) -> Printf.printf "%s: %s\n" label path)
                ledgers;
              Printf.printf
                "the emitted theory was NOT run (its seeds are yours to \
                 supply).\n\
                 next: compile it against the library and run with:\n\
                \  goat run <theory.exe> --seed <seed.json> --config %s\n"
                config_path;
              (* The map is the answer; the exit code is the successful
                 planning run's terminal rendering — the bootstrap run is
                 what this command ran. *)
              exit_of_settled settled
        in
        match plan_attempt ~file ~config_path ~plan_ledger ~spec_text:spec with
        | `Config_error msg ->
            Printf.eprintf "goat plan: %s\n" msg;
            1
        | `Misuse misuse ->
            Printf.eprintf "goat plan: %s\n" (render_misuse misuse);
            1
        | `No_theory settled ->
            prerr_endline
              "goat plan: the planner emitted no theory tuple; bootstrap \
               settlements follow";
            print_settled settled;
            1
        | `Bad_meta diagnostics ->
            Printf.eprintf "goat plan: %s\n" (render_diagnostics diagnostics);
            1
        | `Admitted (settled, emitted) ->
            finish ~ledgers:[ ("plan ledger", plan_ledger) ] settled emitted
        | `Inadmissible (_, emission, errs) -> (
            (* The admission-repair lane, one bounded re-invocation
               (60-agents.md § the planner): the rejected emission returns
               to the planner with its diagnostics as a fresh planning run
               journaled at [<plan_ledger>.repair] — run-granular because
               admission is judged after the bootstrap run settles (the
               head boundary proves shape, never theory semantics), and a
               CLI-side re-entry into the settled turn's repair loop would
               be a second invocation lane, the divergent copy the
               executor rebuild deleted. A second rejection is the typed
               failure. *)
            Printf.printf
              "goat plan: the emitted theory failed admission; re-invoking \
               the planner once with the diagnostics\n%s\n"
              (render_admission_errors errs);
            let repair_ledger = plan_ledger ^ ".repair" in
            if not (refuse_existing_ledger ~command:"plan" repair_ledger)
            then 1
            else
            match
              plan_attempt ~file ~config_path ~plan_ledger:repair_ledger
                ~spec_text:(repair_spec ~spec ~emission ~errs)
            with
            | `Config_error msg ->
                Printf.eprintf "goat plan: %s\n" msg;
                1
            | `Misuse misuse ->
                Printf.eprintf "goat plan: %s\n" (render_misuse misuse);
                1
            | `No_theory settled ->
                prerr_endline
                  "goat plan: the planner emitted no theory tuple on the \
                   admission repair; settlements follow";
                print_settled settled;
                1
            | `Bad_meta diagnostics ->
                Printf.eprintf "goat plan: %s\n"
                  (render_diagnostics diagnostics);
                1
            | `Inadmissible (_, _, errs') ->
                Printf.eprintf
                  "goat plan: the emitted theory failed admission again \
                   after one repair\n%s\n"
                  (render_admission_errors errs');
                1
            | `Admitted (settled, emitted) ->
                finish
                  ~ledgers:
                    [
                      ("plan ledger", plan_ledger);
                      ("admission-repair ledger", repair_ledger);
                    ]
                  settled emitted))

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
