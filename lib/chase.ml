(* The chase engine: eager start, read-time operand binding, ports,
   settlement, quiescence (docs/architecture/40-scheduling.md;
   docs/architecture/10-theory.md § chase semantics). chase.mli is the
   contract; this file owns only private machinery.

   Engine shape: one process, one domain, and every node is a fiber on the
   [Fiber] substrate — a scheduling action is one [step]. Fire (body match
   -> node), run ready fibers (each to its next suspension), dispatch
   (port admission -> spawn -> the fiber binds operands at its own reads),
   retire (dependency order, via [Retire.step]; landings wake exactly the
   fibers parked on the addresses that moved), transport pump (curl-multi
   completions when nothing else is ready — where N provider calls overlap
   on one domain), then stall resolution. The engine ships typed signals
   and appends every decision to the ledger; no retry exists below it. *)

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

(* One entry in the engine's body-match feed: seeds (payload rendered
   through the relation's own codec at [create]) and codec-proven heads
   alike. Heads enter at their producer's COMPLETION — parsed, uncommitted
   store-buffer state — so data-generated instances start at
   materialization, before the producer retires
   (docs/architecture/40-scheduling.md § eager start;
   docs/architecture/30-channels.md § store-to-load forwarding). Whether
   the entry is committed is never cached here: the committed lookup is
   the one source of that truth. *)
type tuple_entry = {
  relation : string;
  id : string;
  payload : Yojson.Safe.t;
  strata : (string * int) list;
      (* Engine-minted generation counts per generation-bounded relation
         along this tuple's derivation chain — the runtime half of the
         stratified-admission exemption (docs/architecture/10-theory.md
         § feedback is forward). Seeds are generation zero. *)
  producer : Ledger.node Id.t option;
      (* [Some n]: entered the feed from node [n]'s parsed, uncommitted
         heads — the store buffer a pre-commit read snoops. [None]: a
         seed, committed at run open. *)
  carried : Ledger.hypothesis Id.t list;
      (* Hypotheses along this tuple's derivation chain, inherited into
         every firing that consumes it. Discharge events, not this list,
         decide retirement blocking — a discharged inheritance is inert
         (docs/architecture/40-scheduling.md § read-time binding). *)
  confidence : float;
      (* Chain confidence at this tuple: the product of the producing
         chain's hypothesis confidences. Seeds and committed state are
         1.0; each snooped read multiplies its own link onto this
         (docs/architecture/40-scheduling.md § backstops). *)
}

(* One firing of a dependency statement: a node, pre-settlement. *)
type instance = {
  node : Ledger.node Id.t;
  spawn : Theory.Spawn.t;
  binding : executor_binding;
  fired_key : string * string;
      (* (statement, consumed tuple id): the once-per-body-match guard. *)
  provenance : Ledger.Provenance.t;
      (* The firing record's provenance, carried so a tuple-window head's
         late existentials append under the same firing. *)
  consumed : tuple_entry list;
  minted : (string * string) list;
      (* (relation, id) head existentials filled at firing time. *)
  minted_ids : tuple_realm Id.t list;
  shape : Speculate.Shape.t;
  cls : Priority.cls;
  seq : int; (* FIFO tiebreak within a priority class. *)
}

(* A node whose executor finished and whose heads passed the boundary
   parse: awaiting retirement in dependency order. *)
type completed = {
  inst : instance;
  heads : Retire.head_tuple list;
  late_minted : tuple_realm Id.t list;
      (* Existentials minted at parse time for tuple-window heads. *)
}

(* Channel ends the scheduler holds, packed with their declarations so the
   typed operations recover the payload type: one writer end per relation
   (retire publishes; invalidations fan out over every channel, each
   edge's footprint filtering), one reader end per consumer edge (drained
   at the consumer's yields) (docs/architecture/30-channels.md
   § delivery). *)
type any_tx = Any_tx : 'a Theory.Relation.t * 'a Channel.tx -> any_tx
type any_rx = Any_rx : 'a Theory.Relation.t * 'a Channel.rx -> any_rx

(* One dispatched node's fiber, in the engine's books. [reaped] marks
   settlements the engine already reacted to. Nothing filesystem-shaped
   is owned: stores land in the shared tree, squash is a settlement
   append, and dead bytes are hygiene
   ([Retire.Frontier.materialize]). *)
type fiber_entry = {
  f_inst : instance;
  handle : unit Fiber.handle;
  mutable reaped : bool;
}

type t = {
  theory : Theory.admitted;
  ledger : Ledger.t;
  committed_state : Retire.Committed.t;
  channels : Channel.registry;
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
  txs : (string * any_tx) list; (* relation name -> writer end *)
  rxs : (string * any_rx) list; (* statement -> its consumer edge's end *)
  sched : Fiber.t;
      (* The substrate: every dispatched node runs as one fiber; parked
         reads and in-flight transfers live in ITS tables, not here
         (docs/architecture/40-scheduling.md § read-time binding). *)
  mutable fiber_nodes : (Fiber.id * fiber_entry) list; (* spawn order *)
  mutable seq : int;
  mutable tuples : tuple_entry list; (* the body-match feed *)
  mutable fired : (string * string) list; (* consumed (statement, tuple) *)
  mutable reissues : ((string * string) * int) list;
  mutable queue : instance list; (* fired, not yet admitted to a port *)
  mutable retire_queue : completed list;
  mutable settled : (Ledger.node Id.t * Settlement.t) list;
  mutable undischarged : (Speculate.Hypothesis.t * Yojson.Safe.t) list;
      (* Taken, not yet settled, each with the snooped payload the
         refresher diffs against the landing. *)
  mutable ceiling_announced : bool;
      (* The token ceiling's binding is announced once per episode: an
         anomaly with a named cause, never a per-step drumbeat. *)
}

(* {2 Small helpers} *)

let addr_of (e : tuple_entry) =
  Ledger.Address.Tuple { relation = e.relation; id = e.id }

let content_of (e : tuple_entry) =
  Ledger.Content_hash.of_string (Yojson.Safe.to_string e.payload)

let operand_json (e : tuple_entry) : Yojson.Safe.t =
  `Assoc
    [
      ("relation", `String e.relation);
      ("id", `String e.id);
      ("payload", e.payload);
    ]

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

(* The engine hands a consumer the whole operand tuple, so its consumed
   paths are the payload's top-level fields — the per-consumer refinement's
   input for engine reads (field-level read tracking is the executor tool
   loop's affair) (docs/architecture/40-scheduling.md § drift routing). *)
let top_paths (payload : Yojson.Safe.t) : Contract.Path.t list =
  match payload with
  | `Assoc fields -> List.map (fun (f, _) -> [ f ]) fields
  | _ -> [ [] ]

let decide t ~node action ~reason ~counters =
  ignore
    (Ledger.append t.ledger ~node (Ledger.Event.Decision { action; reason; counters })
      : Ledger.Event.t)

(* Squashed nodes take their pending hypotheses and their uncommitted
   store-buffer feed entries with them: nothing downstream may fire from,
   or wait on, state whose owner died. *)
let drop_speculative_state t nodes =
  t.undischarged <-
    List.filter
      (fun ((h : Speculate.Hypothesis.t), _) ->
        not (List.exists (Id.equal h.Speculate.Hypothesis.consumer) nodes))
      t.undischarged;
  t.tuples <-
    List.filter
      (fun e ->
        match e.producer with
        | Some p -> not (List.exists (Id.equal p) nodes)
        | None -> true)
      t.tuples

let tuple_minter t relation =
  match Hashtbl.find_opt t.tuple_minters relation with
  | Some m -> m
  | None ->
      let m : tuple_realm Id.Minter.t =
        Id.Minter.create ~registry:t.registry ~realm:relation
      in
      Hashtbl.add t.tuple_minters relation m;
      m

(* The head-existential supply: the one route to a head-relation id, and it
   appends the firing record that carries the mint — so every minted id
   traces to its firing in the ledger by construction (squash, dependency
   order, and replay all walk that trace). Nodes windows mint here at fire
   time; tuple windows mint here at the boundary parse, when the
   data-generated width exists — their fire-time record carries no mints
   yet ([count = 0]) and is the issue-order trace
   (docs/architecture/10-theory.md § provenance is total). *)
let record_firing t ~node ~provenance ~relation ~count =
  let ids = List.init count (fun _ -> Id.mint (tuple_minter t relation)) in
  let minted = List.map (fun id -> (relation, Id.to_string id)) ids in
  ignore
    (Ledger.append t.ledger ~node (Ledger.Event.Fired { provenance; minted })
      : Ledger.Event.t);
  (ids, minted)

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

(* Remove a squashed set from every engine table. A dead node's live fiber
   is discontinued NOW, with the settlement's own cause: its stack unwinds,
   an in-flight transfer is abandoned, and the fiber cannot run further —
   squash is a state, never a convention (fiber.mli;
   docs/architecture/20-medium.md § squash without isolation). Its tree
   bytes stay where they landed: provenance-dead by derivation, hygiene's
   to converge, witnessable into committed state by no one (falsifier
   FL2). Callers settle the nodes before purging. *)
let purge t nodes ~cause =
  let dead n = List.exists (Id.equal n) nodes in
  t.queue <- List.filter (fun i -> not (dead i.node)) t.queue;
  t.retire_queue <-
    List.filter (fun c -> not (dead c.inst.node)) t.retire_queue;
  List.iter
    (fun (fid, entry) ->
      if
        (not entry.reaped)
        && dead entry.f_inst.node
        && Option.is_none (Fiber.result entry.handle)
      then begin
        entry.reaped <- true;
        Fiber.squash t.sched fid ~cause
      end)
    t.fiber_nodes

(* A node's own failure: the fault is raw, never wrapped; the transitive
   dependents squash with provenance-walk precision (Retire owns the walk)
   (docs/architecture/40-scheduling.md § settlement). *)
let settle_fault t (inst : instance) fault =
  settle t inst.node (Settlement.Faulted fault) ~seal:true;
  Id.Registry.drop_provisional t.registry inst.minted_ids;
  drop_speculative_state t [ inst.node ];
  let cause = Ledger.Squash_cause.Upstream_fault inst.node in
  let dependents =
    List.filter
      (fun n -> not (Id.equal n inst.node))
      (Retire.squash_set t.ledger ~cause)
  in
  match dependents with
  | [] -> ()
  | _ :: _ ->
      Retire.squash ~ledger:t.ledger ~registry:t.registry ~cause;
      List.iter
        (fun n -> settle t n (Settlement.Squashed cause) ~seal:false)
        dependents;
      drop_speculative_state t dependents;
      purge t dependents ~cause

(* {2 Read-time operand binding}
   The unit of waiting is the read (docs/architecture/40-scheduling.md
   § read-time binding). Committed operands witness. An uncommitted
   operand is a producer's parsed, unretired store buffer: the read takes
   a store-buffer hypothesis — speculation proper, default-on — unless the
   shape's off switch is thrown or chain confidence falls below the floor,
   in which cases the fiber parks until the landing. The issued-contract
   arm (an operand missing from every buffer, guessed from its contract)
   is the recorded shape for when dispatch overlaps firing. *)

(* Hypothesis-taking is universal across executor classes: every carrier
   binds one. An agent's payload rides its prompt with the drift contract
   and its snooped tool reads are tracked at the resolver; a pure
   function's operand JSON is its entire input; a shell gate runs
   OPTIMISTICALLY — no quiesce point — because its real inputs are tree
   files whose in-flight state its dispatch-time frontier snapshot turns
   into store-buffer hypotheses on exactly the writers it may have read
   ([gate_snapshot] in [node_body]), so a pre-landing dispatch is honest
   speculation, never a hidden divergence. The pre-flat-org gate parked
   here instead (a live trace 2026-07-15 caught a gate judging a tree its
   operands never reached — under per-node isolation the draft was NOT in
   the gate's tree); with one shared tree the draft is exactly what the
   gate sees, and the snapshot is what makes seeing it discharge-or-drift
   (docs/architecture/30-scheduling.md § gates on the shared tree;
   falsifier FL6). *)
let read_operand t ~consumer ~shape (entry : tuple_entry) : Read.outcome =
  let address = addr_of entry in
  match Retire.Committed.generation t.committed_state address with
  | Some generation ->
      Read.Witnessed { generation; content = content_of entry }
  | None -> (
      let confidence =
        entry.confidence *. Speculate.Backstops.link_confidence
      in
      let hypothesizable =
        (not (speculation_off t shape))
        && confidence >= t.backstops.confidence_floor
      in
      match entry.producer with
      | Some producer when hypothesizable ->
          Read.Hypothesis
            {
              Speculate.Hypothesis.id = Id.mint t.hyp_minter;
              consumer;
              address;
              source =
                Speculate.Hypothesis.Store_buffer
                  { producer; snapshot = content_of entry };
              content = content_of entry;
              confidence;
            }
      | Some _ ->
          (* Speculation off for this read: wait for the landing. *)
          Read.Suspended
      | None -> (
          match Theory.schema_hash t.theory ~relation:entry.relation with
          | Some schema when hypothesizable ->
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
          | Some _ | None -> Read.Suspended))

(* The substrate's read-time binding policy (fiber.mli [create ~read]):
   [Some] answers the fiber's read now — witnessed or hypothesis; [None]
   parks exactly this fiber on exactly this address until a landing wakes
   it. The policy sees which fiber asks, so the per-consumer judgment
   (shape switch, chain confidence) stays here, with the mount. *)
let policy_read t fid address =
  match List.find_opt (fun (f, _) -> Fiber.id_equal f fid) t.fiber_nodes with
  | None -> None
  | Some (_, entry) -> (
      let inst = entry.f_inst in
      match
        List.find_opt
          (fun e -> Ledger.Address.equal (addr_of e) address)
          inst.consumed
      with
      | None -> None
      | Some e -> (
          match read_operand t ~consumer:inst.node ~shape:inst.shape e with
          | Read.Witnessed { generation; content } ->
              Some (Fiber.Operand.Witnessed { generation; content })
          | Read.Hypothesis h -> Some (Fiber.Operand.Hypothesis h)
          | Read.Suspended ->
              decide t ~node:inst.node Ledger.Decision.Suspended
                ~reason:"read blocked with no hypothesis source" ~counters:[];
              None))

(* A stop-cleanly drift note delivered at a fiber's yield: the handler
   discontinued the fiber (it performed nothing further), and the engine
   settles the abandoned attempt so its body match can reissue against
   the state that stopped it — bounded, exactly like any other reissue
   (docs/architecture/40-scheduling.md § drift routing, § settlement). *)
let stop_cleanly_settle t (inst : instance) (note : Speculate.Drift.note) =
  let count =
    match List.assoc_opt inst.fired_key t.reissues with
    | Some n -> n
    | None -> 0
  in
  decide t ~node:inst.node Ledger.Decision.Flush_subtree
    ~reason:
      ("stop-cleanly drift note at "
      ^ Ledger.Address.to_string note.Speculate.Drift.address)
    ~counters:[ ("reissues", float_of_int count) ];
  Id.Registry.drop_provisional t.registry inst.minted_ids;
  settle t inst.node
    (Settlement.Squashed Ledger.Squash_cause.Reissue_loser)
    ~seal:true;
  drop_speculative_state t [ inst.node ];
  if count < 3 then begin
    let key = inst.fired_key in
    t.fired <- List.filter (fun k -> not (k = key)) t.fired;
    t.reissues <- (key, count + 1) :: List.remove_assoc key t.reissues
  end

(* React to fiber settlements the engine has not seen yet. A [Returned]
   body did its own completion bookkeeping; an engine-initiated squash was
   settled by its initiator; the two settlements only the substrate can
   deliver — a stop-cleanly discontinue and the fiber's own fault (its
   raise, or a rogue effect contained as a value) — are handled here. *)
let reap t =
  List.iter
    (fun ((_ : Fiber.id), entry) ->
      if not entry.reaped then
        match Fiber.result entry.handle with
        | None -> ()
        | Some settlement -> (
            entry.reaped <- true;
            match settlement with
            | Fiber.Returned () -> ()
            | Fiber.Stopped (Fiber.Squashed _) -> ()
            | Fiber.Stopped (Fiber.Stopped_cleanly note) ->
                stop_cleanly_settle t entry.f_inst note
            | Fiber.Faulted fault -> settle_fault t entry.f_inst fault))
    t.fiber_nodes

(* Run every ready fiber to its next suspension — park, in-flight
   transfer, or settlement — WITHOUT touching the transport: reaching for
   completions here would serialize the very calls the substrate overlaps.
   The transport is driven only by [pump_transport], when nothing else in
   the engine can progress. *)
let drain t =
  while Fiber.has_ready t.sched do
    ignore (Fiber.step t.sched : [ `Progressed | `Quiescent ])
  done;
  reap t

(* {2 Drift classification and check-on-yield delivery}
   Drift class is judged per consumer, against what this consumer
   provably read; the routing itself is the policy table
   ([Speculate.Drift.table]) — classification here only PARSES the move
   into the table's domain (docs/architecture/40-scheduling.md § drift
   routing). *)

let committed_payload t ~relation ~id =
  List.find_map
    (fun (tu : Retire.Committed.tuple) ->
      if
        String.equal tu.Retire.Committed.relation relation
        && String.equal tu.Retire.Committed.id id
      then Some tu.Retire.Committed.payload
      else None)
    (Retire.Committed.tuples t.committed_state)

(* Parse one moved address into a drift class, for the consumer that read
   [consumed_entries] as operands and [witnessed_files] through its tools:
   a moved tuple operand diffs snooped-against-landed payloads ([pulled]
   carries landings the consumer's own channel pull just delivered; the
   committed set answers for the rest); a moved file the consumer read is
   judged against everything it read; an address outside its reads is
   additive from this consumer's perspective. *)
let classify_move t ~(consumed_entries : tuple_entry list) ~witnessed_files
    ~(pulled : (string * string * Yojson.Safe.t) list)
    (address : Ledger.Address.t) : Speculate.Drift.cls =
  match address with
  | Ledger.Address.Tuple { relation; id } -> (
      let operand =
        List.find_opt
          (fun e -> String.equal e.relation relation && String.equal e.id id)
          consumed_entries
      in
      match operand with
      | Some entry ->
          let landed =
            match
              List.find_map
                (fun (rel, tid, payload) ->
                  if String.equal rel relation && String.equal tid id then
                    Some payload
                  else None)
                pulled
            with
            | Some payload -> payload
            | None -> (
                match committed_payload t ~relation ~id with
                | Some payload -> payload
                | None -> entry.payload)
          in
          Speculate.Drift.classify
            ~landing:
              (`Landed
                 (Speculate.Drift.payload_diff ~was:entry.payload ~landed))
            ~consumed:(top_paths entry.payload)
      | None ->
          (* Moved state this consumer never read: additive from its
             perspective, whatever moved. *)
          Speculate.Drift.classify
            ~landing:
              (`Landed
                 [ Contract.Diff.Added [ Ledger.Address.to_string address ] ])
            ~consumed:[])
  | Ledger.Address.File path ->
      if List.exists (String.equal path) witnessed_files then
        Speculate.Drift.classify
          ~landing:
            (`Landed
               [
                 Contract.Diff.Retyped
                   { path = [ path ]; was = "witnessed"; now = "landed" };
               ])
          ~consumed:(List.map (fun p -> [ p ]) witnessed_files)
      else
        Speculate.Drift.classify
          ~landing:(`Landed [ Contract.Diff.Added [ path ] ])
          ~consumed:[]
  | Ledger.Address.Contract _ | Ledger.Address.Resource _ ->
      Speculate.Drift.classify
        ~landing:
          (`Landed [ Contract.Diff.Added [ Ledger.Address.to_string address ] ])
        ~consumed:[]

let witnessed_files_of t node =
  List.filter_map
    (fun ((a : Ledger.Address.t), _, _) ->
      match a with Ledger.Address.File p -> Some p | _ -> None)
    (Ledger.Witness_index.reads t.ledger node)

(* The footprint-escape judge: every load the node's event stream proves,
   judged against its edge's compiled delivery filter ([Channel.footprint],
   the declared half; [Channel.covers], the cover judgment delivery already
   uses). A load outside the filter means the node consulted state whose
   invalidations its subscription will never carry — the declaration must
   grow to cover it. Loads only: a store is the node's own work product,
   and write overlaps are the disjoint law's domain
   (docs/architecture/30-channels.md § footprint filtering). One escape
   per address; the first tool that touched it is named. *)
let footprint_escapes t (inst : instance) =
  let key =
    Theory.Statement.to_string inst.provenance.Ledger.Provenance.statement
  in
  match List.assoc_opt key t.rxs with
  | None -> []
  | Some (Any_rx (_, rx)) ->
      let declared = Channel.footprint rx in
      List.fold_left
        (fun escapes (e : Ledger.Event.t) ->
          match (e.Ledger.Event.node, e.Ledger.Event.kind) with
          (* The gate snapshot never escapes: v0 charges a gate with its
             WHOLE grant — the one tree its command ranges over — so an
             in-flight top the snapshot witnessed is in-footprint by
             construction, and there is no finer declaration for the
             author to grow (30-scheduling.md § gates on the shared
             tree). *)
          | Some _, Ledger.Event.Load { tool = "chase.gate-snapshot"; _ } ->
              escapes
          | Some n, Ledger.Event.Load { tool; observed }
            when Id.equal n inst.node ->
              List.fold_left
                (fun escapes (address, _, _) ->
                  if
                    Channel.covers ~footprint:declared address
                    || List.exists
                         (fun (_, a) -> Ledger.Address.equal a address)
                         escapes
                  then escapes
                  else (tool, address) :: escapes)
                escapes observed
          | _ -> escapes)
        []
        (Ledger.Replay.events t.ledger)
      |> List.rev

let note_drift t ~node ~address ~delta cls =
  let route = Speculate.Drift.route cls in
  ignore
    (Ledger.append t.ledger ~node
       (Ledger.Event.Drift_note
          { address; cls = Speculate.Drift.tag cls; route })
      : Ledger.Event.t);
  {
    Speculate.Drift.address;
    cls;
    delta;
    disposition = Speculate.Drift.disposition_of route;
  }

(* The consumer's REAL [on_yield]: drain the edge's footprint-filtered
   invalidation queue at the fiber's suspension points, pull what landed,
   and hand back typed drift notes carrying the routing the table already
   decided — check-on-yield, never a mid-flight interrupt
   (docs/architecture/30-channels.md § delivery, § invalidate, don't
   update). *)
let on_yield_of t (inst : instance) : unit -> Speculate.Drift.note list =
  let key = Theory.Statement.to_string inst.provenance.Ledger.Provenance.statement in
  match List.assoc_opt key t.rxs with
  | None -> fun () -> []
  | Some (Any_rx (r, rx)) ->
      let relation = Theory.Relation.name r in
      fun () ->
        (* The pull half: drain the committed tuples the channel delivered
           since this edge's cursor — the notes below are judged against
           pulled landings, not stale snapshots. *)
        let pulled =
          List.map
            (fun (id, payload) ->
              ( relation,
                Id.to_string id,
                Theory.Tuple.payload_json (Theory.Tuple.v r payload) ))
            (Channel.pull_tuples rx)
        in
        List.map
          (fun (inv : Channel.Invalidation.t) ->
            let cls =
              classify_move t ~consumed_entries:inst.consumed
                ~witnessed_files:(witnessed_files_of t inst.node) ~pulled
                inv.Channel.Invalidation.address
            in
            note_drift t ~node:inst.node
              ~address:inv.Channel.Invalidation.address
              ~delta:(Some inv.Channel.Invalidation.delta_ref) cls)
          (Channel.pull_invalidations rx)

(* {2 The boundary parse}
   One boundary, one supply: the head contract lowers its cardinality
   window into the wire schema (a tuples window becomes the array root
   with the window as [minItems]/[maxItems]), the SAME value is handed to
   the invocation and parsed against ([Contract.Codec.by_schema] with ref
   resolution against mint provenance) — so the bound is unwritable at the
   decode boundary, shape and refs are codec-proven, and nothing
   downstream re-checks either. Failures are repair diagnostics for the
   shared lane (docs/architecture/20-contracts.md § failure surface;
   docs/architecture/10-theory.md § statement grammar). *)

let window_schema (window : Theory.Window.t) (ws : Contract.Wire_schema.t) :
    Contract.Wire_schema.t =
  match window with
  | Theory.Window.Nodes _ -> ws
  | Theory.Window.Tuples { min; max } ->
      {
        ws with
        Contract.Wire_schema.root =
          Contract.Wire_schema.Array
            {
              items = ws.Contract.Wire_schema.root;
              min_items = Some min;
              max_items = Some max;
              doc = "";
            };
      }

(* Codec-proven payloads become head tuples; a tuple window's existentials
   fill here, when the data-generated width exists, through the one
   minting route ([record_firing]). *)
let heads_of t (inst : instance) (json : Yojson.Safe.t) :
    Retire.head_tuple list * tuple_realm Id.t list =
  let head_rel, window = inst.spawn.Theory.Spawn.exists in
  match (window, json) with
  | Theory.Window.Nodes _, payload ->
      (* The existential was filled at firing time. *)
      ( List.map2
          (fun (relation, id) payload -> { Retire.relation; id; payload })
          inst.minted [ payload ],
        [] )
  | Theory.Window.Tuples _, `List payloads ->
      let ids, minted =
        record_firing t ~node:inst.node ~provenance:inst.provenance
          ~relation:head_rel ~count:(List.length payloads)
      in
      ( List.map2
          (fun (relation, id) payload -> { Retire.relation; id; payload })
          minted payloads,
        ids )
  | Theory.Window.Tuples _, _ ->
      (* Unreachable: the array-rooted window schema admits only arrays. *)
      assert false

(* {2 The invocation lane}
   Freeform generation, boundary parse, then the repair loop — the SHARED
   lane ([Agent.invoke_parsed]): one repair-loop implementation for the
   engine and the host API alike (docs/architecture/60-agents.md § the
   primary lane, § the fallback lane). *)

let invoke_lane :
    type s.
    t ->
    instance ->
    hyps:(Speculate.Hypothesis.t * string) list ->
    on_yield:(unit -> Speculate.Drift.note list) ->
    grant:s Agent.Grant.t ->
    (Retire.head_tuple list * tuple_realm Id.t list, Ledger.Fault.t) result =
 fun t inst ~hyps ~on_yield ~grant ->
  let head_rel, window = inst.spawn.Theory.Spawn.exists in
  match Theory.wire_schema t.theory ~relation:head_rel with
  | None ->
      Error
        {
          Ledger.Fault.origin = Ledger.Fault.Executor_error;
          message = "no admitted wire schema for head relation " ^ head_rel;
        }
  | Some head_schema ->
      let schema = window_schema window head_schema in
      let boundary = Contract.Codec.by_schema schema in
      let preamble = preamble_of inst.spawn.Theory.Spawn.by in
      let pin = pin_of inst.spawn.Theory.Spawn.by in
      let prompt =
        Agent.Prompt.assemble ~preamble ~schema
          ~operands:(operands_text inst.consumed) ~hypotheses:hyps ~grant
      in
      let invocation =
        {
          Agent.Invocation.prompt;
          schema;
          grant;
          pin;
          (* The ONE shared tree: reads resolve and stores land in the
             run's repo — never the harness process cwd (agent.mli
             § Invocation). *)
          repo = Retire.Committed.root t.committed_state;
          (* The resolver consults the frontier — files join the
             vocabulary the chase already speaks for tuples: a fresh
             derivation per lookup, since settlements move tops
             (20-medium.md § store-to-load forwarding; retire.mli
             § Frontier). Tool loads of committed tops witness the real
             committed generation (B7). *)
          frontier =
            (fun address ->
              Retire.Frontier.top
                (Retire.Frontier.of_ledger t.ledger
                   ~committed:t.committed_state)
                address);
          (* A read served from another node's in-flight store is a
             tracked store-buffer hypothesis on exactly that writer — the
             tracker, not any mount, is what makes ambient sensing honest
             (falsifier FL2). Deduped per (address, content): re-reading
             an unchanged draft takes no second hypothesis. *)
          snoop =
            (fun ~address ~producer ~content ->
              let duplicate =
                List.exists
                  (fun ((h : Speculate.Hypothesis.t), _) ->
                    Id.equal h.Speculate.Hypothesis.consumer inst.node
                    && Ledger.Address.equal h.Speculate.Hypothesis.address
                         address
                    && Ledger.Content_hash.equal h.Speculate.Hypothesis.content
                         content)
                  t.undischarged
              in
              if duplicate then []
              else begin
                let h =
                  {
                    Speculate.Hypothesis.id = Id.mint t.hyp_minter;
                    consumer = inst.node;
                    address;
                    source =
                      Speculate.Hypothesis.Store_buffer
                        { producer; snapshot = content };
                    content;
                    confidence = Speculate.Backstops.link_confidence;
                  }
                in
                t.undischarged <- (h, `Null) :: t.undischarged;
                [
                  Ledger.Event.Hypothesis_taken
                    {
                      hypothesis = h.Speculate.Hypothesis.id;
                      address;
                      source = source_label h.Speculate.Hypothesis.source;
                      content;
                      confidence = h.Speculate.Hypothesis.confidence;
                    };
                ]
              end);
          (* The gate's effect-lock scope, threaded from the declaration
             (30-scheduling.md § gates on the shared tree: the lock
             serializes gates per build-artifact resource). *)
          gate_resource =
            (match inst.spawn.Theory.Spawn.by with
            | Theory.Executor.Shell_gate { resource; _ } -> Some resource
            | Theory.Executor.Agent_template _ | Theory.Executor.Pure_fn _ ->
                None);
        }
      in
      let parse text =
        Result.map (heads_of t inst)
          (Contract.Codec.parse boundary ~registry:t.registry text)
      in
      Agent.invoke_parsed ~executor:inst.binding.runtime
        ?fallback:inst.binding.fallback ~parse ~invocation
        ~budget:inst.binding.repair_budget ~ledger:t.ledger ~node:inst.node
        ~on_yield

(* The footprint grant, from the template's declarations. The status
   phantom is chosen at the call site: hypothesis-free dispatches carry the
   committed index, hypothesis-carrying ones the speculative index — and
   the effect list is built PER INDEX from the template's declarations
   ([idempotent_effects] constructs at either index; non-idempotent
   declarations exist only in [committed_effects], so a speculative grant
   carrying one is unconstructible, F12/F15). There is no per-node
   coordinate and no mount table: reads and writes range over the ONE
   shared tree, and the resolver consults the frontier — everything
   in-grant is snoopable, automatically (20-medium.md § store-to-load
   forwarding; README.md § design of record vs shipped engine, row 4). *)
let template_effects (by : Theory.Executor.t) =
  match by with
  | Theory.Executor.Agent_template { effects; _ } -> effects
  | Theory.Executor.Pure_fn _ | Theory.Executor.Shell_gate _ -> []

let idempotent_effects by : _ Agent.Grant.Effect_tool.t list =
  List.filter_map
    (function
      | Theory.Executor.Effect.Idempotent { tool; why } ->
          Some
            (Agent.Grant.Effect_tool.idempotent ~name:tool
               (Agent.Grant.Idempotence.declare ~tool ~why))
      | Theory.Executor.Effect.Non_idempotent _ -> None)
    (template_effects by)

let committed_effects by :
    Agent.Grant.committed Agent.Grant.Effect_tool.t list =
  idempotent_effects by
  @ List.filter_map
      (function
        | Theory.Executor.Effect.Non_idempotent { tool } ->
            Some (Agent.Grant.Effect_tool.non_idempotent ~name:tool)
        | Theory.Executor.Effect.Idempotent _ -> None)
      (template_effects by)
let grant_of (type s) (inst : instance)
    ~(effects : s Agent.Grant.Effect_tool.t list) : s Agent.Grant.t =
  let read_globs, write_globs, shell_gates =
    match inst.spawn.Theory.Spawn.by with
    | Theory.Executor.Agent_template { read_globs; write_globs; _ } ->
        (read_globs, write_globs, [])
    | Theory.Executor.Pure_fn _ -> ([], [], [])
    | Theory.Executor.Shell_gate { command; _ } -> ([], [], [ command ])
  in
  { Agent.Grant.read_globs; write_globs; shell_gates; effects }

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

(* A queued instance is hypothesis-carrying when one of its operands would
   bind speculatively at the read: fired against a producer's uncommitted
   store buffer. *)
let hypothesis_carrying t (inst : instance) =
  List.exists
    (fun e ->
      Option.is_some e.producer
      && Option.is_none (Retire.Committed.generation t.committed_state (addr_of e)))
    inst.consumed

(* Port-admission order: resumed-witnessed before eager-or-speculative;
   among hypothesis-carrying candidates the predictor orders higher
   survival first; FIFO everywhere else — an eager start with witnessed
   operands is never re-ranked by a survival counter
   (docs/architecture/40-scheduling.md § ports and priority). *)
let admission_order t =
  List.stable_sort
    (fun a b ->
      let c = Priority.compare a.cls b.cls in
      if c <> 0 then c
      else
        let c =
          if hypothesis_carrying t a && hypothesis_carrying t b then
            Speculate.Predictor.compare_for_port t.predictor a.shape b.shape
          else 0
        in
        if c <> 0 then c else Int.compare a.seq b.seq)
    t.queue

(* Head tuples enter the body-match feed at their producer's COMPLETION,
   as snoopable store-buffer state: data-generated instances start at
   materialization, before the producer retires
   (docs/architecture/40-scheduling.md § eager start). The entry carries
   the derivation's strata (pointwise max over the consumed operands, one
   deeper where the head relation is generation-bounded), the hypotheses
   the chain now rides on, and the chain confidence. *)
let feed_heads t (inst : instance)
    ~(own_hyps : (Speculate.Hypothesis.t * Yojson.Safe.t) list)
    (heads : Retire.head_tuple list) =
  let stratum_max acc (rel, n) =
    match List.assoc_opt rel acc with
    | Some m when m >= n -> acc
    | Some _ | None -> (rel, n) :: List.remove_assoc rel acc
  in
  let inherited =
    List.fold_left
      (fun acc (e : tuple_entry) -> List.fold_left stratum_max acc e.strata)
      [] inst.consumed
  in
  let head_strata relation =
    match Theory.generations t.theory ~relation with
    | None -> inherited
    | Some _ ->
        let n =
          match List.assoc_opt relation inherited with Some n -> n | None -> 0
        in
        (relation, n + 1) :: List.remove_assoc relation inherited
  in
  let carried =
    let own = List.map (fun ((h : Speculate.Hypothesis.t), _) -> h.id) own_hyps in
    List.fold_left
      (fun acc h -> if List.exists (Id.equal h) acc then acc else h :: acc)
      inst.provenance.Ledger.Provenance.hypotheses own
  in
  let confidence =
    List.fold_left
      (fun acc ((h : Speculate.Hypothesis.t), _) ->
        acc *. h.Speculate.Hypothesis.confidence)
      1.0 own_hyps
  in
  t.tuples <-
    t.tuples
    @ List.map
        (fun (h : Retire.head_tuple) ->
          {
            relation = h.relation;
            id = h.id;
            payload = h.payload;
            strata = head_strata h.relation;
            producer = Some inst.node;
            carried;
            confidence;
          })
        heads

(* One node, as one fiber body. Every operand binds at the fiber's own
   [Fiber.read]: the policy answers witnessed or hypothesis, or the read
   parks THIS fiber mid-flight on exactly the missing address, resuming
   when a landing wakes it with the committed operand — the whole-instance
   parking list, its wholesale requeue on any retirement, and the
   re-dispatch re-read are gone (docs/architecture/40-scheduling.md
   § read-time binding). The executor's yields perform [Fiber.Yield]
   (delivery is the fiber's [on_yield], mounted at spawn), and its
   provider turns may perform [Http_post] — the suspension the scheduler
   overlaps. There is no store buffer to own or drop: stores land in the
   shared tree at store time, squash is the settlement append, and dead
   bytes are the hygiene sweep's ([Retire.Frontier.materialize]) — never
   a finalizer's (README.md § design of record vs shipped engine,
   row 4). *)
let node_body t (inst : instance) () =
  let outcomes =
    List.map
      (fun entry ->
        let outcome =
          match Fiber.read (addr_of entry) with
          | Fiber.Operand.Witnessed { generation; content } ->
              Read.Witnessed { generation; content }
          | Fiber.Operand.Hypothesis h -> Read.Hypothesis h
        in
        (entry, outcome))
      inst.consumed
  in
  begin
    decide t ~node:inst.node Ledger.Decision.Dispatched
      ~reason:"operands bound" ~counters:[];
    let hyp_pairs =
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
              (* The snooped read enters the observed witness at the
                 producer's uncommitted generation — what makes the
                 speculation honest, and what retires it for free when
                 the landing is exactly the snapshot (falsifier F7)
                 (docs/architecture/30-channels.md § store-to-load
                 forwarding). *)
              ignore
                (Ledger.append t.ledger ~node:inst.node
                   (Ledger.Event.Load
                      {
                        tool = "chase.snoop";
                        observed =
                          [
                            ( h.Speculate.Hypothesis.address,
                              Ledger.Generation.zero,
                              h.Speculate.Hypothesis.content );
                          ];
                      })
                  : Ledger.Event.t);
              t.undischarged <- (h, entry.payload) :: t.undischarged;
              Some (h, entry)
          | _ -> None)
        outcomes
    in
    let hyps =
      List.map
        (fun (h, entry) -> (h, Yojson.Safe.to_string (operand_json entry)))
        hyp_pairs
    in
    (* Witnessed committed reads enter the observed witness — captured
       by observation at the engine's own read, never self-report. *)
    List.iter
      (fun (entry, o) ->
        match o with
        | Read.Witnessed { generation; content } ->
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
    (* Gate honesty on the shared tree (30-scheduling.md § gates on the
       shared tree; migration row 6; falsifier FL6): a gate run observes
       the whole tree, neighbors' in-flight edits included, so gate
       dispatch snapshots the frontier over the grant — every address
       whose top is [In_flight] yields a [Store_buffer] hypothesis on
       exactly that writer plus a witness triple at the uncommitted
       coordinate. v0's footprint grain is the gate's whole grant,
       conservative: the gate is charged with having read every in-flight
       address it COULD see (its command line ranges over the one tree it
       runs in; the file-grain tracing upgrade is the recorded OPEN
       item). The verdict is thereby speculative evidence until every
       observed writer lands as observed: the hypotheses ride the verdict
       tuple's provenance like any head's, and the refresher
       discharges-or-drifts each one at its producer's landing — no
       quiesce point, and an identical landing retires the verdict for
       free (the gate-shaped F7). *)
    let gate_snapshot =
      match inst.spawn.Theory.Spawn.by with
      | Theory.Executor.Agent_template _ | Theory.Executor.Pure_fn _ -> []
      | Theory.Executor.Shell_gate _ ->
          let frontier =
            Retire.Frontier.of_ledger t.ledger ~committed:t.committed_state
          in
          List.filter_map
            (fun (address, (d : Retire.Frontier.in_flight)) ->
              (* A node's own draft claims nothing (the self-witness
                 ruling); gates hold no store tools, so this arm is the
                 rule stated, not a path taken. *)
              if Id.equal d.Retire.Frontier.writer inst.node then None
              else begin
                let h =
                  {
                    Speculate.Hypothesis.id = Id.mint t.hyp_minter;
                    consumer = inst.node;
                    address;
                    source =
                      Speculate.Hypothesis.Store_buffer
                        {
                          producer = d.Retire.Frontier.writer;
                          snapshot = d.Retire.Frontier.content;
                        };
                    content = d.Retire.Frontier.content;
                    confidence = Speculate.Backstops.link_confidence;
                  }
                in
                ignore
                  (Ledger.append t.ledger ~node:inst.node
                     (Ledger.Event.Hypothesis_taken
                        {
                          hypothesis = h.Speculate.Hypothesis.id;
                          address;
                          source = source_label h.Speculate.Hypothesis.source;
                          content = h.Speculate.Hypothesis.content;
                          confidence = h.Speculate.Hypothesis.confidence;
                        })
                    : Ledger.Event.t);
                (* The observed read, at the producer's uncommitted
                   coordinate — what retires the verdict for free when
                   the landing is exactly the snapshot. *)
                ignore
                  (Ledger.append t.ledger ~node:inst.node
                     (Ledger.Event.Load
                        {
                          tool = "chase.gate-snapshot";
                          observed =
                            [
                              ( address,
                                Ledger.Generation.zero,
                                h.Speculate.Hypothesis.content );
                            ];
                        })
                    : Ledger.Event.t);
                t.undischarged <- (h, `Null) :: t.undischarged;
                Some (h, `Null)
              end)
            (Retire.Frontier.in_flight_tops frontier)
    in
    (* The executor's yield suspension IS the fiber's [Yield]
       instruction: delivery rides the handler (the closure mounted at
       spawn), and a stop-cleanly disposition discontinues instead of
       returning — the fiber cannot run further, by construction. *)
    let on_yield () = Fiber.yield () in
    let result =
      match (hyps, gate_snapshot) with
      | [], [] ->
          invoke_lane t inst ~hyps ~on_yield
            ~grant:
              (grant_of inst
                 ~effects:(committed_effects inst.spawn.Theory.Spawn.by)
                : Agent.Grant.committed Agent.Grant.t)
      | _, _ ->
          invoke_lane t inst ~hyps ~on_yield
            ~grant:
              (grant_of inst
                 ~effects:(idempotent_effects inst.spawn.Theory.Spawn.by)
                : Agent.Grant.speculative Agent.Grant.t)
    in
    match result with
    | Ok (heads, late_minted) ->
        feed_heads t inst
          ~own_hyps:
            (List.map (fun (h, (e : tuple_entry)) -> (h, e.payload)) hyp_pairs
            @ gate_snapshot)
          heads;
        t.retire_queue <- t.retire_queue @ [ { inst; heads; late_minted } ]
    | Error fault -> settle_fault t inst fault
  end

let dispatch_node t (inst : instance) =
  match port_capacity t inst with
  | Error message ->
      settle_fault t inst
        { Ledger.Fault.origin = Ledger.Fault.Executor_error; message }
  | Ok () ->
      let handle =
        Fiber.spawn t.sched
          ~name:(Id.to_string inst.node)
          ~on_yield:(on_yield_of t inst)
          (node_body t inst)
      in
      t.fiber_nodes <-
        t.fiber_nodes
        @ [ (Fiber.id handle, { f_inst = inst; handle; reaped = false }) ];
      (* Run the spawned fiber now, to its first suspension or settlement:
         dispatch stays one scheduling action, and an in-flight provider
         call returns control here — the overlap window. *)
      drain t

let try_dispatch t =
  match admission_order t with
  | [] -> false
  | ordered -> (
      (* The token-ceiling backstop: at the ceiling, admit only witnessed
         work until discharges catch up
         (docs/architecture/40-scheduling.md § backstops). *)
      let run_tokens = Ledger.Usage.total (Ledger.Telemetry.run_usage t.ledger) in
      let ceiling_hit =
        (not (List.is_empty t.undischarged))
        && run_tokens >= t.backstops.token_ceiling
      in
      (* Announced once per binding episode: an anomaly with its numbers
         attached, never a per-step drumbeat. *)
      if ceiling_hit && not t.ceiling_announced then begin
        t.ceiling_announced <- true;
        ignore
          (Ledger.append t.ledger
             (Ledger.Event.Decision
                {
                  action = Ledger.Decision.Ceiling_bound;
                  reason =
                    "token ceiling bound under undischarged hypotheses: \
                     admitting witnessed work only";
                  counters =
                    [
                      ("token_ceiling", float_of_int t.backstops.token_ceiling);
                      ("run_tokens", float_of_int run_tokens);
                      ( "undischarged",
                        float_of_int (List.length t.undischarged) );
                    ];
                })
            : Ledger.Event.t)
      end;
      if not ceiling_hit then t.ceiling_announced <- false;
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
          decide t ~node:inst.node
            (Ledger.Decision.Admitted { port = inst.binding.port })
            ~reason:"port slot won" ~counters:[];
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
   (docs/architecture/50-commit.md § final-state judgment).

   [Some counted] carries the EVIDENCE — the tuples that crossed the
   bound — because the firing consumes them: the count is read against
   the body-match feed, which includes parsed-but-unretired store
   buffers, so a count-gated firing can launch inside a producer's
   parse-to-retire window. Pre-fix that dependence was invisible — the
   firing recorded only its body operand, constructed no hypotheses, and
   a drifting counted producer would never squash it (live trace
   2026-07-15: an integrator fired 130ms before its third producer
   retired, read a pre-landing tree, and nothing in the ledger knew).
   Counted tuples flow into the instance's consumed set, where the
   EXISTING operand machinery makes the dependence real in every layer:
   witnessed reads for committed ones, store-buffer hypotheses for
   in-flight ones (discharge, squash-on-drift, overlap accounting), and
   parking for executors that cannot bind a hypothesis. *)
let filter_satisfied t (spawn : Theory.Spawn.t) (body : tuple_entry) :
    tuple_entry list option =
  match spawn.Theory.Spawn.where with
  | None -> Some []
  | Some (Theory.Filter.Count { over; link; where_equals; cmp; bound }) ->
      let counted (e : tuple_entry) =
        String.equal e.relation over
        &&
        match e.payload with
        | `Assoc fields ->
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
      let matched = List.filter counted t.tuples in
      if cmp_holds cmp (List.length matched) bound then Some matched
      else None

(* The generation-stratum bound: a statement minting into a bounded head
   refuses the firing that would exceed the bound — the loop's terminal
   generation. This is the runtime half of the admission exemption for
   stratified feedback (docs/architecture/10-theory.md § feedback is
   forward); without it an admitted spiral would fire forever on data that
   keeps demanding another generation. *)
let within_stratum_bound t (spawn : Theory.Spawn.t) (body : tuple_entry) =
  let head = fst spawn.Theory.Spawn.exists in
  match Theory.generations t.theory ~relation:head with
  | None -> true
  | Some bound -> (
      match List.assoc_opt head body.strata with
      | None -> true (* generation zero: minting reaches generation one *)
      | Some n -> n < bound)

let find_fireable t =
  List.find_map
    (fun (sid, spawn) ->
      let stmt = Theory.Statement.to_string sid in
      List.find_map
        (fun entry ->
          if
            String.equal entry.relation spawn.Theory.Spawn.for_
            && (not (List.mem (stmt, entry.id) t.fired))
            && within_stratum_bound t spawn entry
          then
            match filter_satisfied t spawn entry with
            | Some counted ->
                (* A self-counting body never consumes itself twice. *)
                let counted =
                  List.filter
                    (fun (e : tuple_entry) ->
                      not
                        (String.equal e.relation entry.relation
                        && String.equal e.id entry.id))
                    counted
                in
                Some (sid, spawn, entry, counted)
            | None -> None
          else None)
        t.tuples)
    (Theory.statements t.theory)

let executor_binding_for t (spawn : Theory.Spawn.t) =
  let eid = Theory.Executor.id spawn.Theory.Spawn.by in
  List.find_opt (fun b -> Theory.Executor.id_equal b.executor eid) t.executors

(* One firing = one node ([n nodes] windows fire [n]); head mint slots fill
   with fresh existentials — the rename
   (docs/architecture/10-theory.md § statement grammar). *)
let fire t sid (spawn : Theory.Spawn.t) (entry : tuple_entry)
    ~(counted : tuple_entry list) =
  let stmt = Theory.Statement.to_string sid in
  let key = (stmt, entry.id) in
  t.fired <- key :: t.fired;
  let head_rel, window = spawn.Theory.Spawn.exists in
  let consumed_entries = entry :: counted in
  let provenance =
    {
      Ledger.Provenance.statement = sid;
      consumed =
        List.map
          (fun (e : tuple_entry) -> (e.relation, e.id))
          consumed_entries;
      (* Downstream firings inherit the consumed chain's hypotheses: the
         squash walk and the retirement discharge check both read them
         from here (docs/architecture/40-scheduling.md § read-time
         binding). Counted tuples are consumed, so their chains inherit
         too — deduplicated, since counted siblings can share ancestry. *)
      hypotheses =
        List.fold_left
          (fun acc h ->
            if List.exists (Id.equal h) acc then acc else acc @ [ h ])
          []
          (List.concat_map (fun (e : tuple_entry) -> e.carried)
             consumed_entries);
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
          record_firing t ~node ~provenance ~relation:head_rel
            ~count:
              (match window with
              | Theory.Window.Nodes _ -> 1
              | Theory.Window.Tuples _ ->
                  0 (* width is data-generated: minted at the parse *))
        in
        t.seq <- t.seq + 1;
        let inst =
          {
            node;
            spawn;
            binding;
            fired_key = key;
            provenance;
            consumed = consumed_entries;
            minted;
            minted_ids;
            shape;
            cls;
            seq = t.seq;
          }
        in
        decide t ~node (Ledger.Decision.Queued { port = binding.port })
          ~reason:"instance fired"
          ~counters:
            (match spawn.Theory.Spawn.where with
            | Some (Theory.Filter.Count { over; _ }) ->
                [ ("counted:" ^ over, float_of_int (List.length counted)) ]
            | None -> []);
        t.queue <- t.queue @ [ inst ]
      done

let try_fire t =
  match find_fireable t with
  | None -> false
  | Some (sid, spawn, entry, counted) ->
      fire t sid spawn entry ~counted;
      true

(* {2 Retirement and its rejections} *)

(* Abandon one completed attempt: drop the provisional ids and the
   uncommitted store-buffer heads; seal the squash with its cause; squash
   whatever snooped or consumed the dead state (its events are
   provenance-dead — nothing derived from them may retire; the tree bytes
   are hygiene's); optionally un-consume the body match so the instance
   re-fires against the state that remains. *)
let abandon t (c : completed) ~action ~reason ~cause ~count ~refire =
  decide t ~node:c.inst.node action ~reason
    ~counters:[ ("reissues", float_of_int count) ];
  Id.Registry.drop_provisional t.registry (c.inst.minted_ids @ c.late_minted);
  settle t c.inst.node (Settlement.Squashed cause) ~seal:true;
  t.retire_queue <-
    List.filter (fun c' -> not (Id.equal c'.inst.node c.inst.node)) t.retire_queue;
  drop_speculative_state t [ c.inst.node ];
  let dcause = Ledger.Squash_cause.Upstream_squash c.inst.node in
  (match Retire.squash_set t.ledger ~cause:dcause with
  | [] -> ()
  | dependents ->
      Retire.squash ~ledger:t.ledger ~registry:t.registry ~cause:dcause;
      List.iter
        (fun n -> settle t n (Settlement.Squashed dcause) ~seal:false)
        dependents;
      drop_speculative_state t dependents;
      purge t dependents ~cause:dcause);
  if refire then begin
    let key = c.inst.fired_key in
    t.fired <- List.filter (fun k -> not (k = key)) t.fired;
    t.reissues <- (key, count + 1) :: List.remove_assoc key t.reissues
  end

let reissue_or_stop t (c : completed) ~action ~cause ~reason =
  let count =
    match List.assoc_opt c.inst.fired_key t.reissues with
    | Some n -> n
    | None -> 0
  in
  (* Bounded serialization: a body match reissues at most three times, so a
     livelocked witness cannot spin the scheduler forever. *)
  abandon t c ~action ~reason ~cause ~count ~refire:(count < 3);
  true

(* {2 Publish on retire}
   Retirement is the only writer of committed state, and the channel layer
   is its delivery surface. Head tuples re-enter through the relation's
   own codec — the typed log receives a value of the very type the channel
   was opened for, ids resolved against mint provenance — and moved
   generations fan out as payload-free invalidations over every channel,
   each subscribed edge's declared footprint filtering
   (docs/architecture/30-channels.md § invalidate, don't update,
   § footprint filtering). *)

let publish_heads t (c : completed) =
  List.iter
    (fun (h : Retire.head_tuple) ->
      match List.assoc_opt h.relation t.txs with
      | None -> () (* unreachable: heads parse against admitted relations *)
      | Some (Any_tx (r, tx)) -> (
          match
            ( Id.Registry.resolve t.registry ~realm:h.relation h.id,
              Theory.Relation.payload_of_json r ~registry:t.registry h.payload
            )
          with
          | Ok id, Ok payload -> Channel.publish tx ~id payload
          | Error (`Unknown_id _), _ | _, Error _ ->
              (* heads are codec-proven against this very relation, so
                 both parses held once already; a foreign realm's echo has
                 nothing to publish *)
              ()))
    c.heads

(* An invalidation's delta ref carries the payload's content address
   where one exists: a moved file's ref is the retiring node's own store
   event's blob oid — the exact bytes a consumer pulls through the ref
   (docs/architecture/20-medium.md § event taxonomy: readers of the oid
   include consumers pulling deltas through invalidations). Tuple and
   contract addresses have no blob; their refs stay typed coordinate
   locators. Every landed file delta originates in a Store event now that
   the landing is built from the event stream (README.md § design of
   record vs shipped engine, row 2) — the path-shaped fallback survives
   only for hand-laid ledgers whose invalidations name un-stored
   addresses. *)
let delta_locator t ~node (address : Ledger.Address.t) =
  match address with
  | Ledger.Address.File path -> (
      let stored =
        List.fold_left
          (fun acc (e : Ledger.Event.t) ->
            match (e.Ledger.Event.kind, e.Ledger.Event.node) with
            | Ledger.Event.Store { address = a; delta; _ }, Some n
              when Id.equal n node && Ledger.Address.equal a address ->
                Some delta
            | _ -> acc)
          None
          (Ledger.Replay.events t.ledger)
      in
      match stored with
      | Some delta -> delta
      | None -> Ledger.Delta_ref.locator path)
  | Ledger.Address.Tuple { relation; id } ->
      Ledger.Delta_ref.locator (relation ^ "/" ^ id)
  | Ledger.Address.Contract name | Ledger.Address.Resource name ->
      Ledger.Delta_ref.locator name

let fan_invalidations t ~node =
  List.iter
    (fun (e : Ledger.Event.t) ->
      match (e.Ledger.Event.kind, e.Ledger.Event.node) with
      | Ledger.Event.Invalidation_sent { address; new_generation }, Some n
        when Id.equal n node ->
          let inv =
            {
              Channel.Invalidation.address;
              new_generation;
              producer = node;
              delta_ref = delta_locator t ~node address;
            }
          in
          (* Every channel fans; the edge footprints decide delivery — a
             sub on one relation's channel legitimately subscribes to file
             globs and ref-target relations beyond it. *)
          List.iter (fun (_, Any_tx (_, tx)) -> Channel.invalidate tx inv) t.txs
      | _ -> ())
    (Ledger.Replay.events t.ledger)

(* {2 The hypothesis refresher}
   Runs at the producer's landing, over every pending hypothesis on an
   address the landing covers: identical content discharges silently —
   correct speculation costs zero (falsifier F7) — and a differing landing
   parses into a drift class the policy table routes. Reconcile, in v0,
   is reissue-with-the-diagnostics (mid-flight patching is the recorded
   convergence — a completed attempt cannot patch, and an in-flight one
   receives the note at its next yield; the drift note carries what
   changed); flush squashes the consumer's subtree
   (docs/architecture/40-scheduling.md § read-time binding, § drift
   routing). *)

let discharge_hypothesis t (h : Speculate.Hypothesis.t) =
  ignore
    (Ledger.append t.ledger ~node:h.Speculate.Hypothesis.consumer
       (Ledger.Event.Hypothesis_discharged
          { hypothesis = h.Speculate.Hypothesis.id })
      : Ledger.Event.t);
  t.undischarged <-
    List.filter
      (fun ((h' : Speculate.Hypothesis.t), _) ->
        not (Id.equal h'.Speculate.Hypothesis.id h.Speculate.Hypothesis.id))
      t.undischarged

(* Route one drifted hypothesis by the policy table: a completed consumer
   reissues or flushes per the class; a parked or in-flight one keeps the
   pending hypothesis blocking its retirement (the stall backstop owns
   the rest). *)
let route_drifted_hypothesis t (h : Speculate.Hypothesis.t) cls =
  let (_ : Speculate.Drift.note) =
    note_drift t ~node:h.Speculate.Hypothesis.consumer
      ~address:h.Speculate.Hypothesis.address ~delta:None cls
  in
  let consumer_attempt =
    List.find_opt
      (fun c' -> Id.equal c'.inst.node h.Speculate.Hypothesis.consumer)
      t.retire_queue
  in
  match consumer_attempt with
  | None -> ()
  | Some c' -> (
      let reason =
        "hypothesis drifted at "
        ^ Ledger.Address.to_string h.Speculate.Hypothesis.address
      in
      match Speculate.Drift.route cls with
      | Ledger.Drift.Discharge_silently -> discharge_hypothesis t h
      | Ledger.Drift.Reconcile_note | Ledger.Drift.Reconcile_delta ->
          ignore
            (reissue_or_stop t c' ~action:Ledger.Decision.Serialize_reissue
               ~cause:Ledger.Squash_cause.Reissue_loser ~reason
              : bool)
      | Ledger.Drift.Flush_subtree ->
          ignore
            (reissue_or_stop t c' ~action:Ledger.Decision.Flush_subtree
               ~cause:
                 (Ledger.Squash_cause.Dead_hypothesis
                    h.Speculate.Hypothesis.id)
               ~reason
              : bool))

let refresh_hypotheses t (c : completed) =
  let landed_of (address : Ledger.Address.t) =
    List.find_map
      (fun (h : Retire.head_tuple) ->
        if
          Ledger.Address.equal address
            (Ledger.Address.Tuple { relation = h.relation; id = h.id })
        then Some h.payload
        else None)
      c.heads
  in
  List.iter
    (fun ((h : Speculate.Hypothesis.t), snooped) ->
      match landed_of h.Speculate.Hypothesis.address with
      | None -> ()
      | Some landed -> (
          match
            Speculate.Lifecycle.landing ~snooped
              ~consumed:(top_paths snooped) ~landed
          with
          | Speculate.Lifecycle.Discharged -> discharge_hypothesis t h
          | Speculate.Lifecycle.Drifted { cls } ->
              route_drifted_hypothesis t h cls
          | Speculate.Lifecycle.Taken | Speculate.Lifecycle.Squashed ->
              (* not in [Lifecycle.landing]'s image *)
              ()))
    t.undischarged;
  (* File-shaped hypotheses — the resolver's tracked snoops of the shared
     tree (falsifier FL2): the landing judgment is content identity
     against the retiring producer's committed top. Identical discharges
     silently (the file-shaped free commit, F7's law at the file grain);
     a differing landing parses into the drift table's domain exactly
     like a tuple drift — classified per consumer, against everything it
     provably read ([classify_move]). The top is read through the
     frontier so a fixture-committed byte-null landing still discharges
     (the committed half falls back to the one ref's tip, retire.mli
     § Frontier); an address another writer's draft now shadows
     discharges when that writer's base is the predicted content — it
     witnessed the landing this hypothesis predicted. *)
  List.iter
    (fun ((h : Speculate.Hypothesis.t), _) ->
      match (h.Speculate.Hypothesis.address, h.Speculate.Hypothesis.source) with
      | ( Ledger.Address.File _,
          Speculate.Hypothesis.Store_buffer { producer; _ } )
        when Id.equal producer c.inst.node -> (
          let top =
            Retire.Frontier.top
              (Retire.Frontier.of_ledger t.ledger ~committed:t.committed_state)
              h.Speculate.Hypothesis.address
          in
          let drift () =
            route_drifted_hypothesis t h
              (classify_move t ~consumed_entries:[]
                 ~witnessed_files:
                   (witnessed_files_of t h.Speculate.Hypothesis.consumer)
                 ~pulled:[] h.Speculate.Hypothesis.address)
          in
          match top with
          | Retire.Frontier.Committed
              (Witness.Committed_state.Landed { content; _ })
            when Ledger.Content_hash.equal content
                   h.Speculate.Hypothesis.content ->
              discharge_hypothesis t h
          | Retire.Frontier.In_flight { base = Some base; _ }
            when Ledger.Content_hash.equal base h.Speculate.Hypothesis.content
            ->
              discharge_hypothesis t h
          | Retire.Frontier.Committed Witness.Committed_state.Absent
          | Retire.Frontier.In_flight _ ->
              (* no landed coordinate to judge yet: the hypothesis keeps
                 blocking; the stall backstop owns the rest *)
              ()
          | Retire.Frontier.Committed _ -> drift ())
      | _ -> ())
    t.undischarged

let retire_success t (c : completed) =
  (* Footprint escapes surface at retire, before anything downstream of
     the landing runs: each observed load outside the edge's compiled
     delivery filter is a typed event on the retiring node. Its readers
     are the [footprint_cover] verdict ([judge], below) and
     [Report.explain] (docs/architecture/30-channels.md § footprint
     filtering). *)
  List.iter
    (fun (tool, address) ->
      ignore
        (Ledger.append t.ledger ~node:c.inst.node
           (Ledger.Event.Footprint_escape { tool; address })
          : Ledger.Event.t))
    (footprint_escapes t c.inst);
  (* Retire.step sealed the ledger; the engine records the settlement.
     The heads entered the body-match feed at completion (store-buffer
     forwarding); the committed lookup now answers for them. *)
  settle t c.inst.node Settlement.Retired ~seal:false;
  t.retire_queue <-
    List.filter (fun c' -> not (Id.equal c'.inst.node c.inst.node)) t.retire_queue;
  (* Retirement is the only writer of committed state, and the channel
     layer is its delivery surface: committed heads publish on their
     relations' typed logs; the landing's moved generations fan out as
     invalidations, each edge's declared footprint filtering
     (docs/architecture/30-channels.md § pre-opened channels,
     § invalidate, don't update). *)
  publish_heads t c;
  fan_invalidations t ~node:c.inst.node;
  (* The refresher judges the landing against every hypothesis it
     covers. *)
  refresh_hypotheses t c;
  (* The landing committed these addresses: wake exactly the fibers parked
     on them — never the whole parked population — each resuming with the
     witnessed operand at the next ready-queue turn. A woken fiber holds
     its admitted slot (it is witnessed work by construction: the wake key
     IS the committed address), so no re-queue and no re-admission exist
     to gate (docs/architecture/40-scheduling.md § read-time binding;
     fiber.mli [wake]). *)
  List.iter
    (fun (h : Retire.head_tuple) ->
      let address = Ledger.Address.Tuple { relation = h.relation; id = h.id } in
      match Retire.Committed.generation t.committed_state address with
      | None -> ()
      | Some generation ->
          let waiting =
            List.filter
              (fun (_, a) -> Ledger.Address.equal a address)
              (Fiber.parked t.sched)
          in
          if not (List.is_empty waiting) then begin
            List.iter
              (fun (fid, _) ->
                match
                  List.find_opt
                    (fun (f, _) -> Fiber.id_equal f fid)
                    t.fiber_nodes
                with
                | Some (_, entry) ->
                    decide t ~node:entry.f_inst.node Ledger.Decision.Resumed
                      ~reason:"operand space changed" ~counters:[]
                | None -> ())
              waiting;
            let content =
              Ledger.Content_hash.of_string (Yojson.Safe.to_string h.payload)
            in
            ignore
              (Fiber.wake t.sched ~key:address
                 (Fiber.Operand.Witnessed { generation; content })
                : int)
          end)
    c.heads

let handle_rejection t (c : completed) (rejection : Retire.rejection) =
  match rejection with
  | Retire.Undischarged hyps -> (
      match hyps with
      | [] ->
          abandon t c ~action:Ledger.Decision.Flush_subtree
            ~reason:"undischarged-hypotheses signal carried no hypotheses"
            ~cause:Ledger.Squash_cause.Operator_abort ~count:0 ~refire:false;
          true
      | h :: _ ->
          (* Reached only at stall: nothing can fire or dispatch, so the
             hypothesis's producer can never land — the hypothesis is dead
             and exactly its derivation subtree squashes: the settlement
             append, nothing filesystem-shaped (dead tree bytes are
             hygiene's). *)
          let cause = Ledger.Squash_cause.Dead_hypothesis h in
          decide t ~node:c.inst.node Ledger.Decision.Flush_subtree
            ~reason:"undischarged hypothesis has no remaining producer"
            ~counters:
              [ ("undischarged", float_of_int (List.length t.undischarged)) ];
          let set = Retire.squash_set t.ledger ~cause in
          Retire.squash ~ledger:t.ledger ~registry:t.registry ~cause;
          settle t c.inst.node (Settlement.Squashed cause) ~seal:false;
          List.iter
            (fun n -> settle t n (Settlement.Squashed cause) ~seal:false)
            set;
          t.retire_queue <-
            List.filter
              (fun c' -> not (Id.equal c'.inst.node c.inst.node))
              t.retire_queue;
          drop_speculative_state t (c.inst.node :: set);
          purge t set ~cause;
          true)
  | Retire.Witness_moved moves ->
      (* The drift-routing table's rejection-site consumer: parse each
         moved address into its class per THIS consumer, record the typed
         note, and route by the table — reconcile routes reissue the
         attempt against the moved state; any flush row flushes the
         subtree (docs/architecture/40-scheduling.md § drift routing). *)
      let witnessed_files = witnessed_files_of t c.inst.node in
      let classified =
        List.map
          (fun (m : Retire.generation_moved) ->
            let cls =
              classify_move t ~consumed_entries:c.inst.consumed
                ~witnessed_files ~pulled:[] m.address
            in
            let (_ : Speculate.Drift.note) =
              note_drift t ~node:c.inst.node ~address:m.address
                ~delta:(Some m.delta_ref) cls
            in
            cls)
          moves
      in
      let flush =
        List.exists
          (fun cls -> Speculate.Drift.route cls = Ledger.Drift.Flush_subtree)
          classified
      in
      let reason =
        "witness moved: "
        ^ String.concat ", "
            (List.map
               (fun (m : Retire.generation_moved) ->
                 Ledger.Address.to_string m.address)
               moves)
      in
      if flush then
        reissue_or_stop t c ~action:Ledger.Decision.Flush_subtree
          ~cause:Ledger.Squash_cause.Reissue_loser ~reason
      else
        reissue_or_stop t c ~action:Ledger.Decision.Serialize_reissue
          ~cause:Ledger.Squash_cause.Reissue_loser ~reason
  | Retire.Conflict conflict ->
      let reason =
        "write-set conflict with sibling "
        ^ Id.to_string conflict.Retire.Conflict.sibling
      in
      reissue_or_stop t c ~action:Ledger.Decision.Serialize_reissue
        ~cause:Ledger.Squash_cause.Reissue_loser ~reason

(* Inclusion re-judgment at retire (docs/architecture/10-theory.md
   § inclusions): the boundary proved every ref against mint provenance,
   and retire re-judges against final state — between the parse and this
   commit point a referent's producer can squash, dropping the provisional
   id the ref names, and a dangling ref must not enter committed state.
   Live now that dispatch overlaps producers on the fiber substrate: a
   consumer can complete while the producer whose provisional ids its
   heads reference is abandoned. *)
let rec ref_strings path (json : Yojson.Safe.t) =
  match (path, json) with
  | [], `String s -> [ s ]
  | [], _ -> []
  | "[]" :: rest, `List elements -> List.concat_map (ref_strings rest) elements
  | field :: rest, `Assoc kvs -> (
      match List.assoc_opt field kvs with
      | Some v -> ref_strings rest v
      | None -> [])
  | _ :: _, _ -> []

let dangling_refs t (heads : Retire.head_tuple list) =
  List.concat_map
    (fun (h : Retire.head_tuple) ->
      match Theory.slots t.theory ~relation:h.relation with
      | None -> []
      | Some slots ->
          List.concat_map
            (fun (s : Theory.Slot.t) ->
              match s.Theory.Slot.kind with
              | Theory.Slot.Mint | Theory.Slot.Value -> []
              | Theory.Slot.Ref target ->
                  List.filter_map
                    (fun v ->
                      match
                        Id.Registry.resolve t.registry ~realm:target v
                      with
                      | Ok _ -> None
                      | Error (`Unknown_id s) -> Some s)
                    (ref_strings
                       (String.split_on_char '.' s.Theory.Slot.field)
                       h.Retire.payload))
            slots)
    heads

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
            match dangling_refs t c.heads with
            | _ :: _ as dangling ->
                (* A referent's producer squashed after the parse: the
                   node's output names dead identity and can never
                   commit — reissue against the state that remains. *)
                reissue_or_stop t c
                  ~action:Ledger.Decision.Serialize_reissue
                  ~cause:Ledger.Squash_cause.Reissue_loser
                  ~reason:
                    ("dangling ref after producer squash: "
                    ^ String.concat ", " dangling)
            | [] -> (
                let witness = Witness.observed t.ledger ~node:c.inst.node in
                match
                  Retire.step ~committed:t.committed_state ~ledger:t.ledger
                    ~registry:t.registry ~merges:t.merges ~node:c.inst.node
                    ~witness ~heads:c.heads
                with
                | Ok () ->
                    retire_success t c;
                    true
                | Error rejection -> go ((c, rejection) :: rejected) rest))
      in
      go [] ordered

(* A parked read with no remaining producer can never be served: settle it
   so the run quiesces instead of hanging. Reached only when nothing can
   fire, run, dispatch, retire, or complete — the fiber is discontinued
   (its stack unwinds; Fun.protect finalizers run), never merely
   forgotten. *)
let resolve_parked t =
  match Fiber.parked t.sched with
  | [] -> false
  | (fid, _) :: _ -> (
      match
        List.find_opt (fun (f, _) -> Fiber.id_equal f fid) t.fiber_nodes
      with
      | None -> false (* unreachable: every parked fiber is a dispatched node *)
      | Some (_, entry) ->
          let inst = entry.f_inst in
          decide t ~node:inst.node Ledger.Decision.Abort_suspended
            ~reason:"suspended read has no remaining producer" ~counters:[];
          Id.Registry.drop_provisional t.registry inst.minted_ids;
          settle t inst.node
            (Settlement.Squashed Ledger.Squash_cause.No_producer)
            ~seal:true;
          entry.reaped <- true;
          Fiber.squash t.sched fid ~cause:Ledger.Squash_cause.No_producer;
          true)

(* {2 The public surface} *)

(* Seed tuples are typed at construction — codec-proven by construction.
   Each one enters like any committed tuple: the engine mints its id
   against the relation's realm (bound at once — a seed is committed
   identity), publishes it typed on the channel layer, enters it into
   committed state at the primordial generation, and feeds the body match
   its codec-rendered payload, so where-filters match seed fields, agents
   read seed data, and law judgment counts seeded referents
   (docs/architecture/70-api.md § running). *)
let seed_entry t (tu : Theory.Tuple.t) : tuple_entry =
  match tu with
  | Theory.Tuple.Packed (rel, payload) as packed ->
      let relation = Theory.Relation.name rel in
      (* A payload-phantom minter: the id supply lives in the registry (one
         per realm), so this shares the relation's ordinal space with
         [tuple_minter]'s. *)
      let minter = Id.Minter.create ~registry:t.registry ~realm:relation in
      let id = Id.mint minter in
      (match Id.Registry.bind t.registry id with
      | Ok () | Error `Already_bound -> ());
      let tx = Channel.tx t.channels rel in
      Channel.publish tx ~id payload;
      let json = Theory.Tuple.payload_json packed in
      Retire.Committed.seed t.committed_state ~relation ~id:(Id.to_string id)
        ~payload:json;
      {
        relation;
        id = Id.to_string id;
        payload = json;
        strata = [];
        producer = None;
        carried = [];
        confidence = 1.0;
      }

(* The default transport, forced only at the first [Http_post] a fiber
   performs: rigged runs never touch it, and no curl-multi stack exists
   until a live provider call needs one. *)
let lazy_live_transport () =
  let live = lazy (Fiber.Transport.live ()) in
  {
    Fiber.Transport.submit =
      (fun req -> (Lazy.force live).Fiber.Transport.submit req);
    poll = (fun ~block -> (Lazy.force live).Fiber.Transport.poll ~block);
  }

let create ~theory ~ledger ~committed ~channels ?transport ~ports ~executors
    ~backstops ~switches ~merges ~seed () =
  let registry = Id.Registry.create () in
  let transport =
    match transport with Some tr -> tr | None -> lazy_live_transport ()
  in
  (* The scheduler's channel ends, all opened before any node runs: the
     writer end per relation (retire publishes; invalidations fan out) and
     one reader end per consumer edge (drained at that consumer's yields)
     (docs/architecture/30-channels.md § pre-opened channels). *)
  let txs =
    List.map
      (fun (Theory.Relation.Packed r) ->
        (Theory.Relation.name r, Any_tx (r, Channel.tx channels r)))
      (Theory.relations theory)
  in
  let rxs =
    List.filter_map
      (fun (edge : Theory.Edge.t) ->
        List.find_map
          (fun (Theory.Relation.Packed r) ->
            if String.equal (Theory.Relation.name r) edge.Theory.Edge.reads
            then
              Some
                ( Theory.Statement.to_string edge.Theory.Edge.statement,
                  Any_rx (r, Channel.rx channels r ~edge) )
            else None)
          (Theory.relations theory))
      (Theory.edges theory)
  in
  (* The knot: the substrate's read policy consults the engine, and the
     engine holds the substrate. The reference is written exactly once,
     immediately below, before any fiber can exist. *)
  let tref = ref None in
  let sched =
    Fiber.create
      ~read:(fun fid address ->
        match !tref with
        | None -> None
        | Some t -> policy_read t fid address)
      ~transport ()
  in
  let t =
    {
      theory;
      ledger;
      committed_state = committed;
      channels;
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
      txs;
      rxs;
      sched;
      fiber_nodes = [];
      seq = 0;
      tuples = [];
      fired = [];
      reissues = [];
      queue = [];
      retire_queue = [];
      settled = [];
      undischarged = [];
      ceiling_announced = false;
    }
  in
  tref := Some t;
  (* Each shape's initial pin, recorded at run open: predictor history is
     keyed by the typed (statement, executor, pin) identities the ledger
     carries — survival history is per pin
     (docs/architecture/60-agents.md § model pins). *)
  List.iter
    (fun ((sid : Theory.Statement.id), (spawn : Theory.Spawn.t)) ->
      ignore
        (Ledger.append ledger
           (Ledger.Event.Pin_bump
              {
                statement = sid;
                executor = Theory.Executor.id spawn.Theory.Spawn.by;
                pin = pin_key_of spawn.Theory.Spawn.by;
              })
          : Ledger.Event.t))
    (Theory.statements theory);
  t.tuples <- List.map (seed_entry t) seed;
  t

(* Woken fibers resume before anything new is admitted: resumed witnessed
   work is never displaced by fresh eager work
   (docs/architecture/40-scheduling.md § ports and priority). *)
let run_ready t =
  if Fiber.has_ready t.sched then begin
    drain t;
    true
  end
  else false

(* Transfers are in flight and nothing else can progress: block on the
   transport for completions (the substrate delivers them in the
   transport's scripted/libcurl order — deterministic under a rigged
   transport), then run the resumed fibers. *)
let pump_transport t =
  if Fiber.has_ready t.sched || Fiber.quiescent t.sched then false
  else begin
    ignore (Fiber.step t.sched : [ `Progressed | `Quiescent ]);
    drain t;
    true
  end

let step t =
  if try_fire t then `Progressed
  else if run_ready t then `Progressed
  else if try_dispatch t then `Progressed
  else if try_retire t then `Progressed
  else if pump_transport t then `Progressed
  else if resolve_parked t then `Progressed
  else `Quiescent

let rec run_to_quiescence t =
  match step t with `Progressed -> run_to_quiescence t | `Quiescent -> ()

let quiescent t =
  Option.is_none (find_fireable t)
  && List.is_empty t.queue
  && List.is_empty t.retire_queue
  && Fiber.quiescent t.sched
  && List.is_empty (Fiber.parked t.sched)

let settlements t = List.rev t.settled
let committed t = t.committed_state

(* The retire-time half of footprint filtering, read at quiescence: the
   escape events the retire path appended, folded into one run-level
   verdict. Only a violation lands — an escape-free run has nothing to
   surface, and this is not a declared law with a satisfied case to
   report (no structure nothing consumes). The offender strings name the
   node and the escaped address: what the theory author reads to grow the
   declaration (docs/architecture/30-channels.md § footprint
   filtering). *)
let footprint_cover_verdict t =
  let offenders =
    List.filter_map
      (fun (e : Ledger.Event.t) ->
        match (e.Ledger.Event.node, e.Ledger.Event.kind) with
        | Some n, Ledger.Event.Footprint_escape { address; _ } ->
            Some
              (Id.to_string n ^ " read " ^ Ledger.Address.to_string address)
        | _ -> None)
      (Ledger.Replay.events t.ledger)
  in
  match offenders with
  | [] -> []
  | offenders ->
      [ { Theory.Law.law = "footprint_cover"; satisfied = false; offenders } ]

let judge t =
  if quiescent t then
    Ok
      (Retire.judge ~theory:t.theory ~committed:t.committed_state
         ~ledger:t.ledger
      @ footprint_cover_verdict t)
  else Error `Not_quiescent
