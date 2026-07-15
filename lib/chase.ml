(* The chase engine: eager start, read-time operand binding, ports,
   settlement, quiescence (docs/architecture/40-scheduling.md;
   docs/architecture/10-theory.md § chase semantics). chase.mli is the
   contract; this file owns only private machinery.

   v0 engine shape: one process, synchronous dispatch — a scheduling action
   is one [step]. Fire (body match -> node), dispatch (port admission ->
   executor run -> boundary parse), retire (dependency order, via
   [Retire.step]), then stall resolution. The engine ships typed signals and
   appends every decision to the ledger; no retry exists below it. *)

module Port = struct
  (* The house posture is no limits: a bound exists only with its forcing
     bottleneck named — an undocumented bound is unwritable by construction
     (docs/architecture/40-scheduling.md § ports and priority). *)
  type capacity = Open | Bounded of { limit : int; bottleneck : string }

  type t = { name : string; capacity : capacity }

  let open_ ~name = { name; capacity = Open }

  let bounded ~name ~limit ~bottleneck =
    { name; capacity = Bounded { limit; bottleneck } }

  let name t = t.name

  let limit t =
    match t.capacity with Open -> None | Bounded { limit; _ } -> Some limit
end

module Priority = struct
  type cls = Resumed_witnessed | Eager_or_speculative

  (* Witnessed work is never displaced by speculative work; FIFO within
     class is the caller's affair (the admission comparator). *)
  let rank = function Resumed_witnessed -> 0 | Eager_or_speculative -> 1
  let compare a b = Int.compare (rank a) (rank b)
end

module Read = struct
  type outcome =
    | Witnessed of {
        generation : Ledger.Generation.t;
        content : Ledger.Content_hash.t;
      }
    | Hypothesis of Speculate.Hypothesis.t
    | Suspended
end

module Settlement = Ledger.Settlement

type executor_binding = {
  executor : Theory.Executor.id;
  runtime : Agent.Executor.t;
  fallback : Agent.Executor.t option;
  repair_budget : Agent.Repair_budget.t;
  port : string;
}

(* One phantom realm for every relation-tuple minter the engine holds. The
   registry distinguishes realms by their names; a relation's true payload
   phantom is conjured only where a typed payload value exists (seed
   publishing, below). *)
type tuple_realm

(* One entry in the engine's body-match feed. [payload] is [None] only for
   typed seed tuples, whose payloads ride the channel layer (published
   typed at [create]) — see the deviation note in the module summary. *)
type tuple_entry = {
  relation : string;
  id : string;
  payload : Yojson.Safe.t option;
}

(* One firing of a dependency statement: a node, pre-settlement. *)
type instance = {
  node : Ledger.node Id.t;
  spawn : Theory.Spawn.t;
  binding : executor_binding;
  fired_key : string * string;
      (* (statement, consumed tuple id): the once-per-body-match guard. *)
  consumed : tuple_entry list;
  minted : (string * string) list;
      (* (relation, id) head existentials filled at firing time. *)
  minted_ids : tuple_realm Id.t list;
  shape : Speculate.Shape.t;
  mutable cls : Priority.cls;
  seq : int; (* FIFO tiebreak within a priority class. *)
}

(* A node whose executor finished and whose heads passed the boundary
   parse: awaiting retirement in dependency order. *)
type completed = {
  inst : instance;
  heads : Retire.head_tuple list;
  worktree : Retire.Worktree.t;
  late_minted : tuple_realm Id.t list;
      (* Existentials minted at parse time for tuple-window heads. *)
}

type t = {
  theory : Theory.admitted;
  ledger : Ledger.t;
  committed_state : Retire.Committed.t;
  channels : Channel.registry;
  worktree_root : string;
  ports : (string * Port.t) list;
  executors : executor_binding list;
  backstops : Speculate.Backstops.t;
  switches : Speculate.Switch.t list;
  merges : Retire.Merge_registry.t;
  registry : Id.Registry.t;
  node_minter : Ledger.node Id.Minter.t;
  hyp_minter : Ledger.hypothesis Id.Minter.t;
  tuple_minters : (string, tuple_realm Id.Minter.t) Hashtbl.t;
  predictor : Speculate.Predictor.t;
  mutable seq : int;
  mutable tuples : tuple_entry list; (* the body-match feed *)
  mutable fired : (string * string) list; (* consumed (statement, tuple) *)
  mutable reissues : ((string * string) * int) list;
  mutable queue : instance list; (* fired, not yet admitted to a port *)
  mutable parked : instance list; (* suspended reads: cost nothing *)
  mutable retire_queue : completed list;
  mutable settled : (Ledger.node Id.t * Settlement.t) list;
  mutable undischarged : Ledger.hypothesis Id.t list;
}

(* {2 Small helpers} *)

let addr_of (e : tuple_entry) =
  Ledger.Address.Tuple { relation = e.relation; id = e.id }

let content_of (e : tuple_entry) =
  Ledger.Content_hash.of_string
    (match e.payload with Some p -> Yojson.Safe.to_string p | None -> e.id)

let operand_json (e : tuple_entry) : Yojson.Safe.t =
  let base = [ ("relation", `String e.relation); ("id", `String e.id) ] in
  `Assoc (match e.payload with Some p -> base @ [ ("payload", p) ] | None -> base)

let operands_text consumed =
  Yojson.Safe.to_string (`List (List.map operand_json consumed))

let executor_name (e : Theory.Executor.t) =
  match e with
  | Theory.Executor.Agent_template { name; _ } -> name
  | Theory.Executor.Pure_fn { name } -> name
  | Theory.Executor.Shell_gate { name; _ } -> name

(* The preamble is the one hand-written artifact; pure functions and shell
   gates carry only their names (their "prompt" is mechanical). *)
let preamble_of (e : Theory.Executor.t) =
  match e with
  | Theory.Executor.Agent_template { preamble; _ } -> preamble
  | Theory.Executor.Pure_fn { name } -> name
  | Theory.Executor.Shell_gate { name; _ } -> name

let pin_of (e : Theory.Executor.t) =
  match Theory.Executor.pin e with
  | Some pin -> pin
  | None ->
      (* Non-agent executors run on the host: a stable, engine-supplied
         pin so shape keys and ledger events stay total. *)
      {
        Theory.Pin.provider = "host";
        model = executor_name e;
        sampling = [];
        options = [];
      }

let pin_key_of (e : Theory.Executor.t) = Theory.Pin.key (pin_of e)

let source_label = function
  | Speculate.Hypothesis.Issued_contract { relation; _ } ->
      "issued-contract:" ^ relation
  | Speculate.Hypothesis.Store_buffer { producer; _ } ->
      "store-buffer:" ^ Id.to_string producer

let speculation_off t shape =
  List.exists
    (fun sw -> Speculate.Shape.equal (Speculate.Switch.shape sw) shape)
    t.switches

let tuple_minter t relation =
  match Hashtbl.find_opt t.tuple_minters relation with
  | Some m -> m
  | None ->
      let m : tuple_realm Id.Minter.t =
        Id.Minter.create ~registry:t.registry ~realm:relation
      in
      Hashtbl.add t.tuple_minters relation m;
      m

(* Every node settles exactly once; [seal] appends the ledger settlement
   event for the paths where no lower layer already sealed it
   ([Retire.step] and [Retire.squash] seal their own). *)
let settle t node settlement ~seal =
  if not (List.exists (fun (n, _) -> Id.equal n node) t.settled) then begin
    if seal then
      ignore
        (Ledger.append t.ledger ~node (Ledger.Event.Settled settlement)
          : Ledger.Event.t);
    t.settled <- (node, settlement) :: t.settled
  end

let purge t nodes =
  let dead n = List.exists (Id.equal n) nodes in
  t.queue <- List.filter (fun i -> not (dead i.node)) t.queue;
  t.parked <- List.filter (fun i -> not (dead i.node)) t.parked;
  t.retire_queue <-
    List.filter (fun c -> not (dead c.inst.node)) t.retire_queue

(* A node's own failure: the fault is raw, never wrapped; the transitive
   dependents squash with provenance-walk precision (Retire owns the walk)
   (docs/architecture/40-scheduling.md § settlement). *)
let settle_fault t (inst : instance) worktree fault =
  settle t inst.node (Settlement.Faulted fault) ~seal:true;
  (match worktree with Some w -> Retire.Worktree.drop w | None -> ());
  Id.Registry.drop_provisional t.registry inst.minted_ids;
  let cause = Ledger.Squash_cause.Upstream_fault inst.node in
  let dependents =
    List.filter
      (fun n -> not (Id.equal n inst.node))
      (Retire.squash_set t.ledger ~cause)
  in
  match dependents with
  | [] -> ()
  | _ :: _ ->
      let worktrees =
        List.filter_map
          (fun c ->
            if List.exists (Id.equal c.inst.node) dependents then
              Some (c.inst.node, c.worktree)
            else None)
          t.retire_queue
      in
      Retire.squash ~ledger:t.ledger ~registry:t.registry ~worktrees ~cause;
      List.iter
        (fun n -> settle t n (Settlement.Squashed cause) ~seal:false)
        dependents;
      purge t dependents

(* {2 Read-time operand binding}
   The unit of waiting is the read (docs/architecture/40-scheduling.md
   § read-time binding). In the synchronous v0 engine a fired instance's
   body tuple is always present in the feed, so reads witness; the
   hypothesis and suspension arms are the recorded shape of the mechanism
   (consulting the per-shape switch and the confidence floor) and become
   reachable when dispatch overlaps producers. *)

let read_operand t ~consumer ~shape (entry : tuple_entry) : Read.outcome =
  let address = addr_of entry in
  match Retire.Committed.generation t.committed_state address with
  | Some generation ->
      Read.Witnessed { generation; content = content_of entry }
  | None ->
      if
        List.exists
          (fun e ->
            String.equal e.relation entry.relation
            && String.equal e.id entry.id)
          t.tuples
      then
        (* A run input (seed) or an uncommitted producer tuple: readable
           now, at its pre-commit generation. *)
        Read.Witnessed
          { generation = Ledger.Generation.zero; content = content_of entry }
      else begin
        (* Missing. Hypothesizable iff a contract is issued for the
           relation, the shape's off switch is not thrown, and chain
           confidence clears the floor; otherwise the fiber parks. *)
        let confidence = 1.0 in
        match Theory.schema_hash t.theory ~relation:entry.relation with
        | Some schema
          when (not (speculation_off t shape))
               && confidence >= t.backstops.confidence_floor ->
            Read.Hypothesis
              {
                Speculate.Hypothesis.id = Id.mint t.hyp_minter;
                consumer;
                address;
                source =
                  Speculate.Hypothesis.Issued_contract
                    { relation = entry.relation; schema };
                content = content_of entry;
                confidence;
              }
        | Some _ | None -> Read.Suspended
      end

(* {2 The boundary parse}
   Theory exposes no per-relation codec (contracts are packaged at
   declaration; admission keeps only the parsed wire schema), so the
   engine's reply parse runs on the raw-JSON lane: JSON extraction plus the
   cardinality-window check — exactly the shape [Retire.head_tuple]
   carries. Nothing invalid crosses; failures feed the repair loop. *)

let is_refusal text =
  not (String.exists (fun c -> Char.equal c '{' || Char.equal c '[') text)

let parse_heads t (inst : instance) text :
    (Retire.head_tuple list * tuple_realm Id.t list, string) result =
  let head_rel, window = inst.spawn.Theory.Spawn.exists in
  match Yojson.Safe.from_string (String.trim text) with
  | exception Yojson.Json_error msg -> Error ("reply is not JSON: " ^ msg)
  | json ->
      let payloads =
        match (window, json) with
        | Theory.Window.Nodes _, `List [ payload ] -> Ok [ payload ]
        | Theory.Window.Nodes _, (`Assoc _ as payload) -> Ok [ payload ]
        | Theory.Window.Nodes _, _ ->
            Error "expected exactly one head tuple object"
        | Theory.Window.Tuples { min; max }, (`Assoc _ as payload) ->
            if min <= 1 && 1 <= max then Ok [ payload ]
            else
              Error
                (Printf.sprintf
                   "cardinality window %d..%d violated by a single tuple" min
                   max)
        | Theory.Window.Tuples { min; max }, `List elements ->
            let n = List.length elements in
            if n < min || n > max then
              Error
                (Printf.sprintf "cardinality window %d..%d violated: %d tuples"
                   min max n)
            else Ok elements
        | Theory.Window.Tuples _, _ -> Error "expected a head tuple array"
      in
      Result.map
        (fun payloads ->
          match window with
          | Theory.Window.Nodes _ ->
              (* The existential was filled at firing time. *)
              ( List.map2
                  (fun (relation, id) payload ->
                    { Retire.relation; id; payload })
                  inst.minted payloads,
                [] )
          | Theory.Window.Tuples _ ->
              (* Width is data-generated within the window: existentials
                 fill when the width exists. *)
              let ids =
                List.map (fun _ -> Id.mint (tuple_minter t head_rel)) payloads
              in
              ( List.map2
                  (fun hid payload ->
                    { Retire.relation = head_rel; id = Id.to_string hid; payload })
                  ids payloads,
                ids ))
        payloads

(* {2 The invocation lane}
   Freeform generation, boundary parse, then the repair loop — the SHARED
   lane ([Agent.invoke_parsed]): one repair-loop implementation for the
   engine and the host API alike (docs/architecture/60-agents.md § the
   primary lane, § the fallback lane). The head parse is still the
   engine's own [parse_heads]; its migration onto [Contract.Codec] is the
   recorded B1 rewiring. *)

let invoke_lane :
    type s.
    t ->
    instance ->
    hyps:(Speculate.Hypothesis.t * string) list ->
    grant:s Agent.Grant.t ->
    (Retire.head_tuple list * tuple_realm Id.t list, Ledger.Fault.t) result =
 fun t inst ~hyps ~grant ->
  let head_rel, _window = inst.spawn.Theory.Spawn.exists in
  match Theory.wire_schema t.theory ~relation:head_rel with
  | None ->
      Error
        {
          Ledger.Fault.origin = Ledger.Fault.Executor_error;
          message = "no admitted wire schema for head relation " ^ head_rel;
        }
  | Some schema ->
      let preamble = preamble_of inst.spawn.Theory.Spawn.by in
      let pin = pin_of inst.spawn.Theory.Spawn.by in
      let prompt =
        Agent.Prompt.assemble ~preamble ~schema
          ~operands:(operands_text inst.consumed) ~hypotheses:hyps ~grant
      in
      let invocation = { Agent.Invocation.prompt; schema; grant; pin } in
      let parse text =
        match parse_heads t inst text with
        | Ok heads -> Ok heads
        | Error complaint ->
            Error
              {
                Contract.Repair.raw_reply = text;
                complaints =
                  [
                    {
                      Contract.Repair.path = [];
                      expected = "head tuples against the wire schema";
                      got = complaint;
                    };
                  ];
                refusal = is_refusal text;
              }
      in
      Agent.invoke_parsed ~executor:inst.binding.runtime
        ?fallback:inst.binding.fallback ~parse ~invocation
        ~budget:inst.binding.repair_budget ~ledger:t.ledger ~node:inst.node
        ~on_yield:(fun () -> [])

(* The footprint grant, from the template's declarations. The status
   phantom is chosen at the call site: hypothesis-free dispatches carry the
   committed index, hypothesis-carrying ones the speculative index. *)
let grant_of (type s) (inst : instance) (worktree : Retire.Worktree.t) :
    s Agent.Grant.t =
  let read_globs, shell_gates =
    match inst.spawn.Theory.Spawn.by with
    | Theory.Executor.Agent_template { read_globs; _ } -> (read_globs, [])
    | Theory.Executor.Pure_fn _ -> ([], [])
    | Theory.Executor.Shell_gate { command; _ } -> ([], [ command ])
  in
  {
    Agent.Grant.read_globs;
    worktree_root = Retire.Worktree.path worktree;
    snoop_mounts = [];
    shell_gates;
    effects = [];
  }

(* {2 Ports and dispatch} *)

let port_capacity t (inst : instance) =
  match List.assoc_opt inst.binding.port t.ports with
  | None -> Error ("undeclared port: " ^ inst.binding.port)
  | Some p -> (
      match p.Port.capacity with
      | Port.Open -> Ok ()
      | Port.Bounded { limit; bottleneck } ->
          if limit >= 1 then Ok ()
          else
            Error
              (Printf.sprintf "port %s has no capacity (limit %d; bottleneck: %s)"
                 (Port.name p) limit bottleneck))

(* Port-admission order: resumed-witnessed before eager-or-speculative;
   among hypothesis-carrying candidates the predictor orders higher
   survival first; FIFO within remaining ties. *)
let admission_order t =
  List.stable_sort
    (fun a b ->
      let c = Priority.compare a.cls b.cls in
      if c <> 0 then c
      else
        let c =
          match (a.cls, b.cls) with
          | Priority.Eager_or_speculative, Priority.Eager_or_speculative ->
              Speculate.Predictor.compare_for_port t.predictor a.shape b.shape
          | _ -> 0
        in
        if c <> 0 then c else Int.compare a.seq b.seq)
    t.queue

let dispatch_node t (inst : instance) =
  match port_capacity t inst with
  | Error message ->
      settle_fault t inst None
        { Ledger.Fault.origin = Ledger.Fault.Executor_error; message }
  | Ok () -> (
      (* Read-time binding of every operand. *)
      let outcomes =
        List.map
          (fun entry ->
            (entry, read_operand t ~consumer:inst.node ~shape:inst.shape entry))
          inst.consumed
      in
      let suspended =
        List.exists
          (fun (_, o) -> match o with Read.Suspended -> true | _ -> false)
          outcomes
      in
      if suspended then
        (* The fiber parks, costing nothing; it resumes when the operand
           space next changes (a retirement). *)
        t.parked <- t.parked @ [ inst ]
      else begin
        let hyps =
          List.filter_map
            (fun (entry, o) ->
              match o with
              | Read.Hypothesis h ->
                  ignore
                    (Ledger.append t.ledger ~node:inst.node
                       (Ledger.Event.Hypothesis_taken
                          {
                            hypothesis = h.Speculate.Hypothesis.id;
                            address = h.address;
                            source = source_label h.source;
                            content = h.content;
                            confidence = h.confidence;
                          })
                      : Ledger.Event.t);
                  t.undischarged <-
                    h.Speculate.Hypothesis.id :: t.undischarged;
                  Some (h, Yojson.Safe.to_string (operand_json entry))
              | _ -> None)
            outcomes
        in
        (* Witnessed committed reads enter the observed witness — captured
           by observation at the engine's own read, never self-report. *)
        List.iter
          (fun (entry, o) ->
            match o with
            | Read.Witnessed { generation; content }
              when Option.is_some
                     (Retire.Committed.generation t.committed_state
                        (addr_of entry)) ->
                ignore
                  (Ledger.append t.ledger ~node:inst.node
                     (Ledger.Event.Load
                        {
                          tool = "chase.operand";
                          observed = [ (addr_of entry, generation, content) ];
                        })
                    : Ledger.Event.t)
            | _ -> ())
          outcomes;
        let worktree =
          Retire.Worktree.create ~root:t.worktree_root ~node:inst.node
        in
        let result =
          match hyps with
          | [] ->
              invoke_lane t inst ~hyps
                ~grant:
                  (grant_of inst worktree
                    : Agent.Grant.committed Agent.Grant.t)
          | _ :: _ ->
              invoke_lane t inst ~hyps
                ~grant:
                  (grant_of inst worktree
                    : Agent.Grant.speculative Agent.Grant.t)
        in
        match result with
        | Ok (heads, late_minted) ->
            t.retire_queue <-
              t.retire_queue @ [ { inst; heads; worktree; late_minted } ]
        | Error fault -> settle_fault t inst (Some worktree) fault
      end)

let try_dispatch t =
  match admission_order t with
  | [] -> false
  | ordered -> (
      (* The token-ceiling backstop: at the ceiling, admit only witnessed
         work until discharges catch up
         (docs/architecture/40-scheduling.md § backstops). *)
      let ceiling_hit =
        (not (List.is_empty t.undischarged))
        && Ledger.Usage.total (Ledger.Telemetry.run_usage t.ledger)
           >= t.backstops.token_ceiling
      in
      let admissible inst =
        (not ceiling_hit)
        ||
        match inst.cls with
        | Priority.Resumed_witnessed -> true
        | Priority.Eager_or_speculative -> false
      in
      match List.find_opt admissible ordered with
      | None -> false
      | Some inst ->
          t.queue <- List.filter (fun i -> not (Id.equal i.node inst.node)) t.queue;
          dispatch_node t inst;
          true)

(* {2 Firing: the chase proper} *)

let cmp_holds (cmp : Theory.Filter.cmp) n bound =
  match cmp with
  | Theory.Filter.Lt -> n < bound
  | Theory.Filter.Le -> n <= bound
  | Theory.Filter.Eq -> n = bound
  | Theory.Filter.Ge -> n >= bound
  | Theory.Filter.Gt -> n > bound

(* The v0 [where] grammar: a count over one relation linked one hop away.
   A readiness filter for the scheduler; the final law judgment still runs
   (docs/architecture/50-commit.md § final-state judgment). *)
let filter_satisfied t (spawn : Theory.Spawn.t) (body : tuple_entry) =
  match spawn.Theory.Spawn.where with
  | None -> true
  | Some (Theory.Filter.Count { over; link; where_equals; cmp; bound }) ->
      let counted (e : tuple_entry) =
        String.equal e.relation over
        &&
        match e.payload with
        | Some (`Assoc fields) ->
            (match List.assoc_opt link fields with
            | Some (`String v) -> String.equal v body.id
            | _ -> false)
            && List.for_all
                 (fun (f, v) ->
                   match List.assoc_opt f fields with
                   | Some v' -> Yojson.Safe.equal v v'
                   | None -> false)
                 where_equals
        | _ -> false
      in
      cmp_holds cmp (List.length (List.filter counted t.tuples)) bound

let find_fireable t =
  List.find_map
    (fun (sid, spawn) ->
      let stmt = Theory.Statement.to_string sid in
      List.find_map
        (fun entry ->
          if
            String.equal entry.relation spawn.Theory.Spawn.for_
            && (not (List.mem (stmt, entry.id) t.fired))
            && filter_satisfied t spawn entry
          then Some (sid, spawn, entry)
          else None)
        t.tuples)
    (Theory.statements t.theory)

let executor_binding_for t (spawn : Theory.Spawn.t) =
  let eid = Theory.Executor.id spawn.Theory.Spawn.by in
  List.find_opt (fun b -> Theory.Executor.id_equal b.executor eid) t.executors

(* One firing = one node ([n nodes] windows fire [n]); head mint slots fill
   with fresh existentials — the rename
   (docs/architecture/10-theory.md § statement grammar). *)
let fire t sid (spawn : Theory.Spawn.t) (entry : tuple_entry) =
  let stmt = Theory.Statement.to_string sid in
  let key = (stmt, entry.id) in
  t.fired <- key :: t.fired;
  let head_rel, window = spawn.Theory.Spawn.exists in
  let provenance =
    {
      Ledger.Provenance.statement = sid;
      consumed = [ (entry.relation, entry.id) ];
      hypotheses = [];
    }
  in
  match executor_binding_for t spawn with
  | None ->
      (* A run-configuration hole is the node's own fault, never a
         run-level rejection. *)
      let node = Id.mint t.node_minter in
      ignore
        (Ledger.append t.ledger ~node
           (Ledger.Event.Fired { provenance; minted = [] })
          : Ledger.Event.t);
      settle t node
        (Settlement.Faulted
           {
             Ledger.Fault.origin = Ledger.Fault.Executor_error;
             message =
               "no executor binding for "
               ^ Theory.Executor.id_to_string
                   (Theory.Executor.id spawn.Theory.Spawn.by);
           })
        ~seal:true
  | Some binding ->
      let shape =
        {
          Speculate.Shape.statement = sid;
          executor = Theory.Executor.id spawn.Theory.Spawn.by;
          pin = pin_key_of spawn.Theory.Spawn.by;
        }
      in
      let cls =
        if List.mem_assoc key t.reissues then Priority.Resumed_witnessed
        else Priority.Eager_or_speculative
      in
      let node_count =
        match window with
        | Theory.Window.Nodes n -> n
        | Theory.Window.Tuples _ -> 1
      in
      for _ = 1 to node_count do
        let node = Id.mint t.node_minter in
        let minted_ids, minted =
          match window with
          | Theory.Window.Nodes _ ->
              let hid = Id.mint (tuple_minter t head_rel) in
              ([ hid ], [ (head_rel, Id.to_string hid) ])
          | Theory.Window.Tuples _ -> ([], [])
        in
        ignore
          (Ledger.append t.ledger ~node
             (Ledger.Event.Fired { provenance; minted })
            : Ledger.Event.t);
        t.seq <- t.seq + 1;
        let inst =
          {
            node;
            spawn;
            binding;
            fired_key = key;
            consumed = [ entry ];
            minted;
            minted_ids;
            shape;
            cls;
            seq = t.seq;
          }
        in
        t.queue <- t.queue @ [ inst ]
      done

let try_fire t =
  match find_fireable t with
  | None -> false
  | Some (sid, spawn, entry) ->
      fire t sid spawn entry;
      true

(* {2 Retirement and its rejections} *)

let retire_success t (c : completed) =
  (* Retire.step sealed the ledger; the engine records the settlement and
     feeds the committed heads back into the body-match feed. *)
  settle t c.inst.node Settlement.Retired ~seal:false;
  t.retire_queue <-
    List.filter (fun c' -> not (Id.equal c'.inst.node c.inst.node)) t.retire_queue;
  t.tuples <-
    t.tuples
    @ List.map
        (fun (h : Retire.head_tuple) ->
          { relation = h.relation; id = h.id; payload = Some h.payload })
        c.heads;
  (* The operand space changed: resume suspended reads. *)
  List.iter (fun i -> i.cls <- Priority.Resumed_witnessed) t.parked;
  t.queue <- t.queue @ t.parked;
  t.parked <- []

(* Abandon one completed attempt: drop the worktree and the provisional
   ids, seal the squash, optionally un-consume the body match so the
   instance re-fires (serialize: reissue the loser against the winner's
   state — the v0 route for every conflict). *)
let abandon t (c : completed) ~action ~reason ~count ~refire =
  ignore
    (Ledger.append t.ledger ~node:c.inst.node
       (Ledger.Event.Decision
          { action; reason; counters = [ ("reissues", float_of_int count) ] })
      : Ledger.Event.t);
  Retire.Worktree.drop c.worktree;
  Id.Registry.drop_provisional t.registry (c.inst.minted_ids @ c.late_minted);
  settle t c.inst.node
    (Settlement.Squashed Ledger.Squash_cause.Operator_abort)
    ~seal:true;
  t.retire_queue <-
    List.filter (fun c' -> not (Id.equal c'.inst.node c.inst.node)) t.retire_queue;
  if refire then begin
    let key = c.inst.fired_key in
    t.fired <- List.filter (fun k -> not (k = key)) t.fired;
    t.reissues <- (key, count + 1) :: List.remove_assoc key t.reissues
  end

let reissue_or_stop t (c : completed) ~action ~reason =
  let count =
    match List.assoc_opt c.inst.fired_key t.reissues with
    | Some n -> n
    | None -> 0
  in
  (* Bounded serialization: a body match reissues at most three times, so a
     livelocked witness cannot spin the scheduler forever. *)
  abandon t c ~action ~reason ~count ~refire:(count < 3);
  true

let handle_rejection t (c : completed) (rejection : Retire.rejection) =
  match rejection with
  | Retire.Undischarged hyps -> (
      match hyps with
      | [] ->
          abandon t c ~action:Ledger.Decision.Flush_subtree
            ~reason:"undischarged-hypotheses signal carried no hypotheses"
            ~count:0 ~refire:false;
          true
      | h :: _ ->
          (* Reached only at stall: nothing can fire or dispatch, so the
             hypothesis's producer can never land — the hypothesis is dead
             and exactly its derivation subtree squashes. *)
          let cause = Ledger.Squash_cause.Dead_hypothesis h in
          ignore
            (Ledger.append t.ledger ~node:c.inst.node
               (Ledger.Event.Decision
                  {
                    action = Ledger.Decision.Flush_subtree;
                    reason =
                      "undischarged hypothesis has no remaining producer";
                    counters =
                      [
                        ( "undischarged",
                          float_of_int (List.length t.undischarged) );
                      ];
                  })
              : Ledger.Event.t);
          let set = Retire.squash_set t.ledger ~cause in
          Retire.squash ~ledger:t.ledger ~registry:t.registry
            ~worktrees:[ (c.inst.node, c.worktree) ]
            ~cause;
          settle t c.inst.node (Settlement.Squashed cause) ~seal:false;
          List.iter
            (fun n -> settle t n (Settlement.Squashed cause) ~seal:false)
            set;
          t.undischarged <-
            List.filter
              (fun h' -> not (List.exists (Id.equal h') hyps))
              t.undischarged;
          t.retire_queue <-
            List.filter
              (fun c' -> not (Id.equal c'.inst.node c.inst.node))
              t.retire_queue;
          purge t set;
          true)
  | Retire.Witness_moved moves ->
      let reason =
        "witness moved: "
        ^ String.concat ", "
            (List.map
               (fun (m : Retire.generation_moved) ->
                 Ledger.Address.to_string m.address)
               moves)
      in
      reissue_or_stop t c ~action:Ledger.Decision.Serialize_reissue ~reason
  | Retire.Conflict conflict ->
      let reason =
        "write-set conflict with sibling "
        ^ Id.to_string conflict.Retire.Conflict.sibling
      in
      reissue_or_stop t c ~action:Ledger.Decision.Serialize_reissue ~reason

let try_retire t =
  match t.retire_queue with
  | [] -> false
  | cs ->
      (* Dependency order: a node's producers retire before it does
         (docs/architecture/50-commit.md § retirement order). *)
      let candidates = List.map (fun c -> c.inst.node) cs in
      let order = Retire.dependency_order t.ledger ~candidates in
      let ordered =
        let in_order =
          List.filter_map
            (fun n -> List.find_opt (fun c -> Id.equal c.inst.node n) cs)
            order
        in
        let missing =
          List.filter
            (fun c ->
              not
                (List.exists
                   (fun c' -> Id.equal c'.inst.node c.inst.node)
                   in_order))
            cs
        in
        in_order @ missing
      in
      let rec go rejected = function
        | [] -> (
            (* Every candidate was refused: the run is stalled on typed
               retire signals; route the first one. *)
            match List.rev rejected with
            | (c, rejection) :: _ -> handle_rejection t c rejection
            | [] -> false)
        | c :: rest -> (
            let witness = Witness.observed t.ledger ~node:c.inst.node in
            match
              Retire.step ~committed:t.committed_state ~ledger:t.ledger
                ~registry:t.registry ~merges:t.merges ~node:c.inst.node
                ~worktree:c.worktree ~witness ~heads:c.heads
            with
            | Ok () ->
                retire_success t c;
                true
            | Error rejection -> go ((c, rejection) :: rejected) rest)
      in
      go [] ordered

(* A parked read with no remaining producer can never be served: settle it
   so the run quiesces instead of hanging. Reached only when nothing can
   fire, dispatch, or retire. *)
let resolve_parked t =
  match t.parked with
  | [] -> false
  | inst :: rest ->
      ignore
        (Ledger.append t.ledger ~node:inst.node
           (Ledger.Event.Decision
              {
                action = Ledger.Decision.Abort_suspended;
                reason = "suspended read has no remaining producer";
                counters = [];
              })
          : Ledger.Event.t);
      Id.Registry.drop_provisional t.registry inst.minted_ids;
      settle t inst.node
        (Settlement.Squashed Ledger.Squash_cause.Operator_abort)
        ~seal:true;
      t.parked <- rest;
      true

(* {2 The public surface} *)

(* Seed tuples are typed at construction; they enter through the channel
   layer (the engine mints their ids against the relation's realm) and
   join the body-match feed. *)
let seed_entry t (tu : Theory.Tuple.t) : tuple_entry =
  match tu with
  | Theory.Tuple.Packed (rel, payload) ->
      let relation = Theory.Relation.name rel in
      let minter = Id.Minter.create ~registry:t.registry ~realm:relation in
      let id = Id.mint minter in
      let tx = Channel.tx t.channels rel in
      Channel.publish tx ~id payload;
      { relation; id = Id.to_string id; payload = None }

let create ~theory ~ledger ~committed ~channels ~worktree_root ~ports
    ~executors ~backstops ~switches ~merges ~seed =
  let registry = Id.Registry.create () in
  let t =
    {
      theory;
      ledger;
      committed_state = committed;
      channels;
      worktree_root;
      ports = List.map (fun p -> (Port.name p, p)) ports;
      executors;
      backstops;
      switches;
      merges;
      registry;
      node_minter = Id.Minter.create ~registry ~realm:"node";
      hyp_minter = Id.Minter.create ~registry ~realm:"hypothesis";
      tuple_minters = Hashtbl.create 16;
      predictor = Speculate.Predictor.of_ledger ledger;
      seq = 0;
      tuples = [];
      fired = [];
      reissues = [];
      queue = [];
      parked = [];
      retire_queue = [];
      settled = [];
      undischarged = [];
    }
  in
  t.tuples <- List.map (seed_entry t) seed;
  t

let step t =
  if try_fire t then `Progressed
  else if try_dispatch t then `Progressed
  else if try_retire t then `Progressed
  else if resolve_parked t then `Progressed
  else `Quiescent

let rec run_to_quiescence t =
  match step t with `Progressed -> run_to_quiescence t | `Quiescent -> ()

let quiescent t =
  Option.is_none (find_fireable t)
  && List.is_empty t.queue && List.is_empty t.parked
  && List.is_empty t.retire_queue

let settlements t = List.rev t.settled
let committed t = t.committed_state

let judge t =
  if quiescent t then
    Ok (Retire.judge ~theory:t.theory ~committed:t.committed_state ~ledger:t.ledger)
  else Error `Not_quiescent
