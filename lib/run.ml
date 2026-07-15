(* The host surface (docs/architecture/70-api.md).

   One entry point: [exec] accepts only [Theory.admitted] — admission
   already parsed the theory, so nothing here re-checks it. The only
   run-level rejection is host misuse (config paths that don't exist,
   executors the config doesn't bind, ports the table doesn't declare);
   node failures and law violations are entries in the settled map, never
   exceptions and never [misuse] (docs/architecture/40-scheduling.md
   § settlement, § quiescence and completion).

   The chase runs on the cooperative fiber substrate ([Fiber]): reads park
   mid-flight, provider calls overlap on one domain, squash discontinues;
   [exec] drives the scheduler to quiescence — still one process, one
   domain. [start]/[wait] expose the same run for pull-only observation
   ([Report.scoreboard] polls the ledger, never the dispatch path). *)

type config = {
  repo : string;
  committed_branch : string;
  worktree_root : string;
  ledger_path : string;
  ports : Chase.Port.t list;
  executors : Chase.executor_binding list;
  backstops : Speculate.Backstops.t;
  switches : Speculate.Switch.t list;
  merges : Retire.Merge_registry.t;
}

type misuse =
  | Missing_path of { field : string; path : string }
  | Unbound_executor of { executor : string }
  | Unknown_port of { executor : string; port : string }

type node_report = {
  settlement : Ledger.Settlement.t;
  timing : Ledger.Telemetry.timing;
  usage : Ledger.Usage.t;
  hypotheses : Ledger.hypothesis Id.t list;
}

type settled = {
  nodes : (Ledger.node Id.t * node_report) list;
  tuples : Retire.Committed.tuple list;
  laws : Theory.Law.verdict list;
  ledger : Ledger.t;
}

(* {2 Host-misuse parsing}

   The boundary parse Run owns: a config is judged once, here, and the
   success value is the assembled run itself (the [handle]) — downstream
   code never re-checks a path or a binding. *)

let directory_exists path = Sys.file_exists path && Sys.is_directory path

(* [repo] and [worktree_root] must exist as directories; [ledger_path]
   itself is created on open ([Ledger.create]), so the host error there is
   a missing parent directory. [committed_branch] is not a filesystem
   path; a bad branch surfaces from [Retire.Committed.open_], the layer
   that owns git. *)
let parse_paths (config : config) =
  let required =
    [
      ("repo", config.repo);
      ("worktree_root", config.worktree_root);
      ("ledger_path", Filename.dirname config.ledger_path);
    ]
  in
  match
    List.find_opt (fun (_, path) -> not (directory_exists path)) required
  with
  | Some (field, path) -> Error (Missing_path { field; path })
  | None -> Ok ()

let binding_for (config : config) executor =
  List.find_opt
    (fun (binding : Chase.executor_binding) ->
      Theory.Executor.id_equal binding.executor executor)
    config.executors

(* Every statement's executor must be bound by the config: the theory
   names executors; the run supplies them (chase.mli). *)
let parse_bindings ~theory (config : config) =
  let unbound =
    List.find_map
      (fun (_, (spawn : Theory.Spawn.t)) ->
        let executor = Theory.Executor.id spawn.by in
        match binding_for config executor with
        | Some _ -> None
        | None -> Some (Theory.Executor.id_to_string executor))
      (Theory.statements theory)
  in
  match unbound with
  | Some executor -> Error (Unbound_executor { executor })
  | None -> Ok ()

(* Every binding names its port; the name must exist in the port table —
   ports are declared, never defaulted (chase.mli § ports). *)
let parse_ports (config : config) =
  let known = List.map Chase.Port.name config.ports in
  let unknown =
    List.find_opt
      (fun (binding : Chase.executor_binding) ->
        not (List.mem binding.port known))
      config.executors
  in
  match unknown with
  | Some binding ->
      Error
        (Unknown_port
           {
             executor = Theory.Executor.id_to_string binding.executor;
             port = binding.port;
           })
  | None -> Ok ()

(* {2 The run} *)

type handle = {
  chase : Chase.t;
  run_ledger : Ledger.t;
  mutable outcome : settled option;
      (* [wait] memoizes: quiescence is driven once, laws are judged
         once (docs/architecture/50-commit.md § final-state judgment). *)
}

let zero_timing : Ledger.Telemetry.timing =
  { blocked_s = 0.; queued_s = 0.; run_s = 0. }

(* The hypotheses a node fired on: its [Hypothesis_taken] events, in
   ledger order. Discharge times and drift notes stay in the ledger,
   pulled by [Report.explain] — the settled map carries the stamps only
   (run.mli). *)
let hypotheses_of events node =
  List.filter_map
    (fun (event : Ledger.Event.t) ->
      match (event.node, event.kind) with
      | Some n, Ledger.Event.Hypothesis_taken { hypothesis; _ }
        when Id.equal n node ->
          Some hypothesis
      | _ -> None)
    events

let assemble ~chase ~ledger =
  let events = Ledger.Replay.events ledger in
  let nodes =
    List.map
      (fun (node, settlement) ->
        let timing =
          Option.value (Ledger.Telemetry.timing ledger node)
            ~default:zero_timing
        in
        ( node,
          {
            settlement;
            timing;
            usage = Ledger.Telemetry.usage ledger node;
            hypotheses = hypotheses_of events node;
          } ))
      (Chase.settlements chase)
  in
  let tuples = Retire.Committed.tuples (Chase.committed chase) in
  let laws =
    match Chase.judge chase with
    | Ok verdicts -> verdicts
    | Error `Not_quiescent ->
        (* Unreachable: [assemble] runs only after [run_to_quiescence]
           returned, and quiescence is that function's postcondition. *)
        assert false
  in
  { nodes; tuples; laws; ledger }

let start ~theory ~seed ~config =
  let ( let* ) = Result.bind in
  let* () = parse_paths config in
  let* () = parse_bindings ~theory config in
  let* () = parse_ports config in
  let run_ledger = Ledger.create ~path:config.ledger_path in
  let committed =
    Retire.Committed.open_ ~repo:config.repo ~branch:config.committed_branch
  in
  (* Channels pre-open before any node runs — what makes eager start
     legal (docs/architecture/30-channels.md § pre-opened channels). *)
  let channels = Channel.open_all theory in
  let chase =
    Chase.create ~theory ~ledger:run_ledger ~committed ~channels
      ~worktree_root:config.worktree_root ~ports:config.ports
      ~executors:config.executors ~backstops:config.backstops
      ~switches:config.switches ~merges:config.merges ~seed ()
  in
  Ok { chase; run_ledger; outcome = None }

let ledger handle = handle.run_ledger

let wait handle =
  match handle.outcome with
  | Some settled -> settled
  | None ->
      Chase.run_to_quiescence handle.chase;
      let settled = assemble ~chase:handle.chase ~ledger:handle.run_ledger in
      handle.outcome <- Some settled;
      settled

let exec ~theory ~seed ~config = Result.map wait (start ~theory ~seed ~config)

(* {2 Replay}

   The ledger-completeness audit (docs/architecture/80-validation.md
   § replay determinism): every scheduler decision must be reproducible
   from recorded events alone. The v0 taxonomy ([Ledger.Event.kind])
   records decisions and their inputs but not the theory value itself, so
   replay re-derives every decision the trace makes derivable and asserts
   it against what the ledger recorded:

   - the clock: timestamps enter decisions only through the ledger, so
     append order is non-decreasing;
   - settlement: every fired node settles exactly once;
   - retire order: dependency order, recomputed from firing provenance —
     a producer retires before any consumer of its minted tuples
     (docs/architecture/50-commit.md § retirement order);
   - drift routing: each recorded [Drift_note]'s route re-derived from
     the routing policy table ([Speculate.Drift.table]) applied to the
     recorded class.

   A decision that consulted unrecorded state shows up as a mismatch
   between the recorded rendering and the re-derived one. *)

type divergence = {
  at : Ledger.Timestamp.t;
  recorded : string;
  replayed : string;
}

let tuple_key (relation, id) = relation ^ "/" ^ id

let replay ledger =
  let events = Ledger.Replay.events ledger in
  let divergences = ref [] in
  let diverge ~at ~recorded ~replayed =
    divergences := { at; recorded; replayed } :: !divergences
  in
  (* The clock. *)
  let (_ : Ledger.Timestamp.t option) =
    List.fold_left
      (fun previous (event : Ledger.Event.t) ->
        (match previous with
        | Some p when Ledger.Timestamp.compare p event.at > 0 ->
            diverge ~at:event.at
              ~recorded:
                (Format.asprintf "append stamped %a after %a"
                   Ledger.Timestamp.pp event.at Ledger.Timestamp.pp p)
              ~replayed:
                "ledger timestamps are the scheduler's only clock: append \
                 order is non-decreasing"
        | _ -> ());
        Some event.at)
      None events
  in
  (* Trace indices, from recorded events alone. *)
  let fired_at = Hashtbl.create 64 in
  let consumed_by = Hashtbl.create 64 in
  let minted_by = Hashtbl.create 64 in
  let settlements = Hashtbl.create 64 in
  let retired_at = Hashtbl.create 64 in
  List.iter
    (fun (event : Ledger.Event.t) ->
      match (event.node, event.kind) with
      | Some node, Ledger.Event.Fired { provenance; minted } ->
          let n = Id.to_string node in
          Hashtbl.replace fired_at n event.at;
          Hashtbl.replace consumed_by n provenance.consumed;
          List.iter
            (fun tuple -> Hashtbl.replace minted_by (tuple_key tuple) n)
            minted
      | Some node, Ledger.Event.Settled settlement ->
          let n = Id.to_string node in
          let earlier =
            Option.value (Hashtbl.find_opt settlements n) ~default:[]
          in
          Hashtbl.replace settlements n (event.at :: earlier);
          (match settlement with
          | Ledger.Settlement.Retired -> Hashtbl.replace retired_at n event.at
          | Ledger.Settlement.Faulted _ | Ledger.Settlement.Squashed _ -> ())
      | _ -> ())
    events;
  (* Settlement: exactly once per fired node. *)
  Hashtbl.iter
    (fun node at ->
      match Hashtbl.find_opt settlements node with
      | Some [ _ ] -> ()
      | None ->
          diverge ~at
            ~recorded:(Printf.sprintf "node %s fired and never settled" node)
            ~replayed:"every fired node settles exactly once"
      | Some stamps ->
          (* [stamps] is reversed append order; head is the latest. *)
          diverge ~at:(List.hd stamps)
            ~recorded:
              (Printf.sprintf "node %s settled %d times" node
                 (List.length stamps))
            ~replayed:"every fired node settles exactly once")
    fired_at;
  (* Retire order: recomputed dependency order from provenance. *)
  Hashtbl.iter
    (fun node retire_time ->
      let consumed =
        Option.value (Hashtbl.find_opt consumed_by node) ~default:[]
      in
      List.iter
        (fun tuple ->
          match Hashtbl.find_opt minted_by (tuple_key tuple) with
          | None -> () (* A seed tuple: no producer node to order against. *)
          | Some producer when String.equal producer node -> ()
          | Some producer -> (
              match Hashtbl.find_opt retired_at producer with
              | Some producer_time
                when Ledger.Timestamp.compare producer_time retire_time <= 0
                ->
                  ()
              | Some _ | None ->
                  diverge ~at:retire_time
                    ~recorded:
                      (Printf.sprintf
                         "node %s retired before its producer %s (operand %s)"
                         node producer (tuple_key tuple))
                    ~replayed:
                      "retirement is dependency-ordered: a node's producers \
                       retire before it does"))
        consumed)
    retired_at;
  (* Drift routing: the policy table, re-applied. Events carry the typed
     class and route, so the comparison is structural — no wire string is
     ever re-parsed here. *)
  List.iter
    (fun (event : Ledger.Event.t) ->
      match event.kind with
      | Ledger.Event.Drift_note { address; cls; route } -> (
          match List.assoc_opt cls Speculate.Drift.table with
          | None ->
              diverge ~at:event.at
                ~recorded:
                  (Printf.sprintf "drift at %s recorded class %S"
                     (Ledger.Address.to_string address)
                     (Ledger.Drift.cls_to_string cls))
                ~replayed:
                  "the routing policy table has no route for this class"
          | Some expected ->
              if route <> expected then
                diverge ~at:event.at
                  ~recorded:
                    (Printf.sprintf "drift at %s (class %S) routed %S"
                       (Ledger.Address.to_string address)
                       (Ledger.Drift.cls_to_string cls)
                       (Ledger.Drift.route_to_string route))
                  ~replayed:
                    (Printf.sprintf "the routing table routes this class to %S"
                       (Ledger.Drift.route_to_string expected)))
      | _ -> ())
    events;
  match
    List.sort
      (fun a b -> Ledger.Timestamp.compare a.at b.at)
      !divergences
  with
  | [] -> Ok ()
  | divergences -> Error divergences
