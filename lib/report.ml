(* Reading a run: pull surfaces, every one a ledger query, none on any hot
   path (docs/architecture/70-api.md § reading a run).

   Everything here is derived from the ledger's observed events or the
   settled map — never self-report. Honest-measurement discipline:
   wasted-token accounting is gross (squashed nodes' bills count in full),
   overlap is measured (hypothesis lifetime actually overlapped), and the
   token ceiling binding is surfaced as the anomaly flag it is
   (docs/architecture/80-validation.md § honest measurement). *)

type speculation_account = {
  tokens_under_hypotheses : int;
  tokens_squashed : int;
  overlap_bought_s : float;
  per_shape : (Speculate.Shape.t * Speculate.Counters.t) list;
}

type summary = {
  wall_clock_s : float;
  total_work_s : float;
  realized_parallelism : float;
  critical_path : Ledger.node Id.t list;
  port_queues : (string * float) list;
  speculation : speculation_account;
  token_ceiling_bound : bool;
}

type scoreboard = {
  ports : (string * int * int) list;
  in_flight_hypotheses : (Ledger.hypothesis Id.t * float) list;
  ledger_appends_per_s : float;
}

type story = {
  node : Ledger.node Id.t;
  fired_because : string;
  decisions : (Ledger.Timestamp.t * string * string) list;
  drift_notes : (Ledger.Timestamp.t * string * string) list;
  witness : Witness.triple list;
  escapes : (string * Ledger.Address.t) list;
  settlement : Ledger.Settlement.t;
  timing : Ledger.Telemetry.timing;
  usage : Ledger.Usage.t;
}

(* {2 Shared helpers} *)

let sec = Ledger.Timestamp.to_seconds
let node_key (n : Ledger.node Id.t) = Id.to_string n
let hyp_key (h : Ledger.hypothesis Id.t) = Id.to_string h

(* The token-ceiling counter, when a decision records the ceiling among the
   numbers it consulted ([Ledger.Event.Decision] counters are free-form by
   design; the lifecycle itself is typed — [Ledger.Decision]). *)
let counter_token_ceiling = "token_ceiling"

let tuple_key (relation, id) = relation ^ "\000" ^ id

let find_list tbl key =
  match Hashtbl.find_opt tbl key with Some l -> l | None -> []

(* Earliest and latest ledger timestamps, by [Timestamp.compare] — append
   order is not assumed even though the ledger is append-only. *)
let time_bounds (events : Ledger.Event.t list) =
  match events with
  | [] -> None
  | e :: rest ->
      Some
        (List.fold_left
           (fun (mn, mx) (ev : Ledger.Event.t) ->
             ( (if Ledger.Timestamp.compare ev.at mn < 0 then ev.at else mn),
               if Ledger.Timestamp.compare ev.at mx > 0 then ev.at else mx ))
           (e.Ledger.Event.at, e.at)
           rest)

let wall_clock_of events =
  match time_bounds events with
  | None -> 0.
  | Some (mn, mx) -> sec mx -. sec mn

(* Per-node settle events: node key -> (id, timestamp). *)
let settle_times (events : Ledger.Event.t list) =
  let tbl = Hashtbl.create 64 in
  List.iter
    (fun (e : Ledger.Event.t) ->
      match (e.node, e.kind) with
      | Some n, Ledger.Event.Settled _ ->
          Hashtbl.replace tbl (node_key n) (n, e.at)
      | _ -> ())
    events;
  tbl

(* Firing provenance per node, and the producer of every minted tuple. *)
let firings (events : Ledger.Event.t list) =
  let fired = Hashtbl.create 64 in
  (* node key -> (id, at, provenance) *)
  let producer = Hashtbl.create 64 in
  (* tuple key -> producing node id *)
  List.iter
    (fun (e : Ledger.Event.t) ->
      match (e.node, e.kind) with
      | Some n, Ledger.Event.Fired { provenance; minted } ->
          Hashtbl.replace fired (node_key n) (n, e.at, provenance);
          List.iter
            (fun t -> Hashtbl.replace producer (tuple_key t) n)
            minted
      | _ -> ())
    events;
  (fired, producer)

(* {2 The critical path}

   The chain that {e was} the wall clock: start at the latest-settling
   node and walk backward, at each step through the latest-settling
   producer of the node's consumed tuples, until a node whose operands
   were all seed tuples (no producer in this run). Returned in
   dependency order, ending at the last settler. *)
let critical_path events =
  let settles = settle_times events in
  let fired, producer = firings events in
  let last_settler =
    Hashtbl.fold
      (fun _ (n, at) best ->
        match best with
        | None -> Some (n, at)
        | Some (_, bt) ->
            if Ledger.Timestamp.compare at bt > 0 then Some (n, at) else best)
      settles None
  in
  match last_settler with
  | None -> []
  | Some (start, _) ->
      let visited = Hashtbl.create 16 in
      let rec walk acc n =
        let key = node_key n in
        if Hashtbl.mem visited key then acc
        else begin
          Hashtbl.replace visited key ();
          let acc = n :: acc in
          match Hashtbl.find_opt fired key with
          | None -> acc
          | Some (_, _, (prov : Ledger.Provenance.t)) ->
              let producers =
                List.filter_map
                  (fun t -> Hashtbl.find_opt producer (tuple_key t))
                  prov.consumed
              in
              let latest =
                List.fold_left
                  (fun best p ->
                    match Hashtbl.find_opt settles (node_key p) with
                    | None -> best
                    | Some (_, at) -> (
                        match best with
                        | None -> Some (p, at)
                        | Some (_, bt) ->
                            if Ledger.Timestamp.compare at bt > 0 then
                              Some (p, at)
                            else best))
                  None producers
              in
              (match latest with None -> acc | Some (p, _) -> walk acc p)
        end
      in
      walk [] start

(* {2 Port queue accounting}

   Queue time is recovered from the scheduler's own lifecycle markers: a
   [Queued] decision opens a node's wait on a port, the matching
   [Admitted] (or [Dispatched]) closes it. A node queued and never
   admitted (squashed while queued) waits until its settlement, or the
   run's last event. *)
let port_queue_times events =
  let settles = settle_times events in
  let last_ts =
    match time_bounds events with None -> 0. | Some (_, mx) -> sec mx
  in
  let pending = Hashtbl.create 32 in
  (* node key -> (port, enqueue ts) *)
  let sums = Hashtbl.create 8 in
  let add port dt =
    let prev = match Hashtbl.find_opt sums port with Some s -> s | None -> 0. in
    Hashtbl.replace sums port (prev +. Float.max 0. dt)
  in
  List.iter
    (fun (e : Ledger.Event.t) ->
      match (e.node, e.kind) with
      | ( Some n,
          Ledger.Event.Decision { action = Ledger.Decision.Queued { port }; _ }
        ) ->
          Hashtbl.replace pending (node_key n) (port, e.at)
      | ( Some n,
          Ledger.Event.Decision
            {
              action = Ledger.Decision.Admitted _ | Ledger.Decision.Dispatched;
              _;
            } ) -> (
          match Hashtbl.find_opt pending (node_key n) with
          | Some (port, t0) ->
              add port (sec e.at -. sec t0);
              Hashtbl.remove pending (node_key n)
          | None -> ())
      | _ -> ())
    events;
  Hashtbl.iter
    (fun key (port, t0) ->
      let end_ =
        match Hashtbl.find_opt settles key with
        | Some (_, at) -> sec at
        | None -> last_ts
      in
      add port (end_ -. sec t0))
    pending;
  Hashtbl.fold (fun port s acc -> (port, s) :: acc) sums []
  |> List.sort (fun (pa, a) (pb, b) ->
         match Float.compare b a with 0 -> String.compare pa pb | c -> c)

(* {2 Hypothesis bookkeeping, streamed in ledger order}

   A node's hypothesis set is its inherited set (firing provenance) plus
   every hypothesis its own reads took. Spend counts as
   under-hypotheses while at least one member is undischarged. Overlap
   is measured, per discharged hypothesis: taken-to-discharged is the
   wall clock the consumer worked ahead instead of suspending. *)
type hyp_facts = {
  hf_tokens_under : int;
  hf_overlap_s : float;
  hf_taken : (string * (Ledger.hypothesis Id.t * string * float)) list;
      (* hyp key -> (id, consumer node key, confidence), ledger order *)
  hf_discharged : (string, unit) Hashtbl.t;
  hf_inherited : (string, string list) Hashtbl.t;
      (* node key -> inherited hypothesis keys *)
}

let hypothesis_facts (events : Ledger.Event.t list) =
  let inherited = Hashtbl.create 64 in
  let own = Hashtbl.create 64 in
  let discharged = Hashtbl.create 64 in
  let taken_at = Hashtbl.create 64 in
  let taken = ref [] in
  let tokens_under = ref 0 in
  let overlap = ref 0. in
  List.iter
    (fun (e : Ledger.Event.t) ->
      match (e.node, e.kind) with
      | Some n, Ledger.Event.Fired { provenance; _ } ->
          Hashtbl.replace inherited (node_key n)
            (List.map hyp_key provenance.hypotheses)
      | Some n, Ledger.Event.Hypothesis_taken { hypothesis; confidence; _ }
        ->
          let hk = hyp_key hypothesis in
          Hashtbl.replace own (node_key n) (hk :: find_list own (node_key n));
          Hashtbl.replace taken_at hk e.at;
          taken := (hk, (hypothesis, node_key n, confidence)) :: !taken
      | _, Ledger.Event.Hypothesis_discharged { hypothesis } ->
          let hk = hyp_key hypothesis in
          Hashtbl.replace discharged hk ();
          (match Hashtbl.find_opt taken_at hk with
          | Some t0 -> overlap := !overlap +. Float.max 0. (sec e.at -. sec t0)
          | None -> ())
      | Some n, Ledger.Event.Agent_turn { usage } ->
          let hyps =
            find_list inherited (node_key n) @ find_list own (node_key n)
          in
          if List.exists (fun hk -> not (Hashtbl.mem discharged hk)) hyps
          then tokens_under := !tokens_under + Ledger.Usage.total usage
      | _ -> ())
    events;
  {
    hf_tokens_under = !tokens_under;
    hf_overlap_s = !overlap;
    hf_taken = List.rev !taken;
    hf_discharged = discharged;
    hf_inherited = inherited;
  }

(* {2 Shape enumeration}

   The ledger's shape-bearing events ([Pin_bump], [Switch_thrown]) carry
   the typed (statement, executor) identities, so a shape key is read
   straight off the event — never rebuilt from a wire string. A shape gets
   a breakdown row when a pin or switch event names it AND its statement
   fired in this run; the row's counters live in
   {!Speculate.Counters.of_ledger} once the key exists to ask with. *)
let shapes_of (events : Ledger.Event.t list) : Speculate.Shape.t list =
  let fired = Hashtbl.create 16 in
  (* statement wire string -> (), for the fired-in-this-run filter *)
  List.iter
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Fired { provenance; _ } ->
          Hashtbl.replace fired
            (Theory.Statement.to_string provenance.statement)
            ()
      | _ -> ())
    events;
  let latest_pin = Hashtbl.create 16 in
  (* (statement, executor) wire pair -> pin, last one wins in ledger order *)
  let pair_key statement executor =
    ( Theory.Statement.to_string statement,
      Theory.Executor.id_to_string executor )
  in
  let keys = ref [] in
  let remember statement executor pin =
    keys := (statement, executor, pin) :: !keys
  in
  List.iter
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Pin_bump { statement; executor; pin } ->
          Hashtbl.replace latest_pin (pair_key statement executor) pin;
          remember statement executor pin
      | Ledger.Event.Switch_thrown { statement; executor; _ } ->
          let pin =
            match Hashtbl.find_opt latest_pin (pair_key statement executor) with
            | Some pin -> pin
            | None -> ""
          in
          remember statement executor pin
      | _ -> ())
    events;
  let seen = Hashtbl.create 16 in
  List.rev !keys
  |> List.filter_map (fun (statement, executor, pin) ->
         let skey = Theory.Statement.to_string statement in
         let dedup = (skey, Theory.Executor.id_to_string executor, pin) in
         if Hashtbl.mem seen dedup || not (Hashtbl.mem fired skey) then None
         else begin
           Hashtbl.replace seen dedup ();
           Some Speculate.Shape.{ statement; executor; pin }
         end)

let ceiling_bound (events : Ledger.Event.t list) =
  List.exists
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Decision { action = Ledger.Decision.Ceiling_bound; _ } ->
          true
      | Ledger.Event.Decision { counters; _ } ->
          List.mem_assoc counter_token_ceiling counters
      | _ -> false)
    events

(* {2 summarize} *)

let summarize (settled : Run.settled) : summary =
  let events = Ledger.Replay.events settled.ledger in
  let wall_clock_s = wall_clock_of events in
  let total_work_s =
    List.fold_left
      (fun acc (_, (r : Run.node_report)) ->
        acc +. r.timing.Ledger.Telemetry.run_s)
      0. settled.nodes
  in
  let realized_parallelism =
    if wall_clock_s > 0. then total_work_s /. wall_clock_s else 0.
  in
  let hf = hypothesis_facts events in
  let tokens_squashed =
    (* Gross: a squashed node's whole bill counts, salvageable or not
       (docs/architecture/80-validation.md § honest measurement). *)
    List.fold_left
      (fun acc (_, (r : Run.node_report)) ->
        match r.settlement with
        | Ledger.Settlement.Squashed _ -> acc + Ledger.Usage.total r.usage
        | Ledger.Settlement.Retired | Ledger.Settlement.Faulted _ -> acc)
      0 settled.nodes
  in
  let per_shape =
    List.map
      (fun shape -> (shape, Speculate.Counters.of_ledger settled.ledger shape))
      (shapes_of events)
  in
  {
    wall_clock_s;
    total_work_s;
    realized_parallelism;
    critical_path = critical_path events;
    port_queues = port_queue_times events;
    speculation =
      {
        tokens_under_hypotheses = hf.hf_tokens_under;
        tokens_squashed;
        overlap_bought_s = hf.hf_overlap_s;
        per_shape;
      };
    token_ceiling_bound = ceiling_bound events;
  }

(* {2 scoreboard} *)

let scoreboard (handle : Run.handle) : scoreboard =
  let ledger = Run.ledger handle in
  let events = Ledger.Replay.events ledger in
  (* Per-node port occupancy, replayed to the present: [Queued] -> pending
     on the port, [Admitted] -> active on it, settled -> gone. *)
  let state = Hashtbl.create 64 in
  (* node key -> [`Pending of port | `Active of port | `Done] *)
  let ports_seen = Hashtbl.create 8 in
  List.iter
    (fun (e : Ledger.Event.t) ->
      match (e.node, e.kind) with
      | ( Some n,
          Ledger.Event.Decision { action = Ledger.Decision.Queued { port }; _ }
        ) ->
          Hashtbl.replace ports_seen port ();
          Hashtbl.replace state (node_key n) (`Pending port)
      | ( Some n,
          Ledger.Event.Decision
            { action = Ledger.Decision.Admitted { port }; _ } ) ->
          Hashtbl.replace ports_seen port ();
          Hashtbl.replace state (node_key n) (`Active port)
      | Some n, Ledger.Event.Settled _ ->
          Hashtbl.replace state (node_key n) `Done
      | _ -> ())
    events;
  let ports =
    Hashtbl.fold (fun port () acc -> port :: acc) ports_seen []
    |> List.sort String.compare
    |> List.map (fun port ->
           let active, pending =
             Hashtbl.fold
               (fun _ st (a, p) ->
                 match st with
                 | `Active q when String.equal q port -> (a + 1, p)
                 | `Pending q when String.equal q port -> (a, p + 1)
                 | _ -> (a, p))
               state (0, 0)
           in
           (port, active, pending))
  in
  let hf = hypothesis_facts events in
  let settles = settle_times events in
  let confidence = Hashtbl.create 64 in
  List.iter
    (fun (hk, (_, _, conf)) -> Hashtbl.replace confidence hk conf)
    hf.hf_taken;
  (* Chain confidence multiplies down a speculation chain: the product of
     this hypothesis's confidence with every still-undischarged hypothesis
     its consumer inherited (a discharged ancestor is confirmed reality —
     factor 1) (docs/architecture/40-scheduling.md § backstops). *)
  let chain_product consumer_key conf =
    List.fold_left
      (fun acc hk ->
        if Hashtbl.mem hf.hf_discharged hk then acc
        else
          match Hashtbl.find_opt confidence hk with
          | Some c -> acc *. c
          | None -> acc)
      conf
      (find_list hf.hf_inherited consumer_key)
  in
  let in_flight_hypotheses =
    List.filter_map
      (fun (hk, (id, consumer_key, conf)) ->
        let discharged = Hashtbl.mem hf.hf_discharged hk in
        let consumer_settled = Hashtbl.mem settles consumer_key in
        if discharged || consumer_settled then None
        else Some (id, chain_product consumer_key conf))
      hf.hf_taken
  in
  let ledger_appends_per_s =
    let n = List.length events in
    match time_bounds events with
    | None -> 0.
    | Some (mn, mx) ->
        let span = sec mx -. sec mn in
        if span > 0. then float_of_int n /. span else 0.
  in
  { ports; in_flight_hypotheses; ledger_appends_per_s }

(* {2 explain} *)

let render_counters counters =
  counters
  |> List.map (fun (k, v) -> Printf.sprintf "%s=%g" k v)
  |> String.concat ", "

let render_fired_because ~(prov : Ledger.Provenance.t) ~counters ~taken =
  let consumed =
    prov.consumed
    |> List.map (fun (relation, id) -> relation ^ ":" ^ id)
    |> String.concat ", "
  in
  let inherited =
    prov.hypotheses |> List.map hyp_key |> String.concat ", "
  in
  let constructed =
    taken
    |> List.map (fun (id, source, confidence) ->
           Printf.sprintf "%s (source=%s, confidence=%g)" (hyp_key id) source
             confidence)
    |> String.concat ", "
  in
  Printf.sprintf
    "statement %s fired; consumed [%s]; counters consulted [%s]; hypotheses \
     inherited [%s]; hypotheses constructed [%s]"
    (Theory.Statement.to_string prov.statement)
    consumed
    (render_counters counters)
    inherited constructed

let explain (settled : Run.settled) ~(node : Ledger.node Id.t) : story option =
  let events = Ledger.Replay.events settled.ledger in
  let mine (e : Ledger.Event.t) =
    match e.node with Some n -> Id.equal n node | None -> false
  in
  let fired =
    List.find_map
      (fun (e : Ledger.Event.t) ->
        if mine e then
          match e.kind with
          | Ledger.Event.Fired { provenance; _ } -> Some (e.at, provenance)
          | _ -> None
        else None)
      events
  in
  match fired with
  | None -> None (* the run never fired this node *)
  | Some (fired_at, prov) ->
      let counters =
        (* The counters the scheduler consulted to fire this node: every
           decision recorded against it up to and INCLUDING the firing's
           own Queued decision — the queue admission is the same
           scheduling action as the Fired event, appended one tick
           later, and it is where a count-gated firing records its
           where-filter evidence. *)
        let queued_at =
          List.find_map
            (fun (e : Ledger.Event.t) ->
              if mine e then
                match e.kind with
                | Ledger.Event.Decision
                    { action = Ledger.Decision.Queued _; _ } ->
                    Some e.at
                | _ -> None
              else None)
            events
        in
        let bound =
          match queued_at with
          | Some q when Ledger.Timestamp.compare fired_at q < 0 -> q
          | _ -> fired_at
        in
        List.concat_map
          (fun (e : Ledger.Event.t) ->
            if mine e && Ledger.Timestamp.compare e.at bound <= 0 then
              match e.kind with
              | Ledger.Event.Decision { counters; _ } -> counters
              | _ -> []
            else [])
          events
      in
      let taken =
        List.filter_map
          (fun (e : Ledger.Event.t) ->
            if mine e then
              match e.kind with
              | Ledger.Event.Hypothesis_taken
                  { hypothesis; source; confidence; _ } ->
                  Some (hypothesis, source, confidence)
              | _ -> None
            else None)
          events
      in
      let decisions =
        List.filter_map
          (fun (e : Ledger.Event.t) ->
            if mine e then
              match e.kind with
              | Ledger.Event.Decision { action; reason; _ } ->
                  Some (e.at, Ledger.Decision.to_string action, reason)
              | _ -> None
            else None)
          events
      in
      let escapes =
        List.filter_map
          (fun (e : Ledger.Event.t) ->
            if mine e then
              match e.kind with
              | Ledger.Event.Footprint_escape { tool; address } ->
                  Some (tool, address)
              | _ -> None
            else None)
          events
      in
      let drift_notes =
        List.filter_map
          (fun (e : Ledger.Event.t) ->
            if mine e then
              match e.kind with
              | Ledger.Event.Drift_note { cls; route; _ } ->
                  (* Rendered here, at the reader: events carry the typed
                     forms; the story is prose. *)
                  Some
                    ( e.at,
                      Ledger.Drift.cls_to_string cls,
                      Ledger.Drift.route_to_string route )
              | _ -> None
            else None)
          events
      in
      let report =
        List.find_map
          (fun (n, r) -> if Id.equal n node then Some r else None)
          settled.nodes
      in
      let settlement =
        match report with
        | Some (r : Run.node_report) -> Some r.settlement
        | None ->
            List.find_map
              (fun (e : Ledger.Event.t) ->
                if mine e then
                  match e.kind with
                  | Ledger.Event.Settled s -> Some s
                  | _ -> None
                else None)
              events
      in
      (match settlement with
      | None -> None (* fired but never settled: no story to close *)
      | Some settlement ->
          let timing =
            match report with
            | Some (r : Run.node_report) -> r.timing
            | None -> (
                match Ledger.Telemetry.timing settled.ledger node with
                | Some t -> t
                | None ->
                    Ledger.Telemetry.
                      { blocked_s = 0.; queued_s = 0.; run_s = 0. })
          in
          let usage =
            match report with
            | Some (r : Run.node_report) -> r.usage
            | None -> Ledger.Telemetry.usage settled.ledger node
          in
          Some
            {
              node;
              fired_because = render_fired_because ~prov ~counters ~taken;
              decisions;
              drift_notes;
              witness =
                Witness.triples (Witness.observed settled.ledger ~node);
              escapes;
              settlement;
              timing;
              usage;
            })
