(* Speculation: hypotheses, drift classification, the survival-counter
   predictor, and the backstops.

   Speculation is default-on; the per-shape off switch requires a churn
   measurement obtainable only from a ledger, so a bare switch is
   unconstructible (docs/architecture/40-scheduling.md § speculation is
   default-on; falsifier F15). Drift routing is a policy table — data, in
   one place — per doc rule 8. *)

module Shape = struct
  type t = {
    statement : Theory.Statement.id;
    executor : Theory.Executor.id;
    pin : string;
  }

  let compare a b =
    let c = Theory.Statement.compare a.statement b.statement in
    if c <> 0 then c
    else
      let c = Theory.Executor.id_compare a.executor b.executor in
      if c <> 0 then c else String.compare a.pin b.pin

  let equal a b = compare a b = 0

  let to_string t =
    Printf.sprintf "%s/%s@%s"
      (Theory.Statement.to_string t.statement)
      (Theory.Executor.id_to_string t.executor)
      t.pin
end

module Hypothesis = struct
  type source =
    | Issued_contract of {
        relation : string;
        schema : Contract.Schema_hash.t;
      }
    | Store_buffer of {
        producer : Ledger.node Id.t;
        snapshot : Ledger.Content_hash.t;
      }

  type t = {
    id : Ledger.hypothesis Id.t;
    consumer : Ledger.node Id.t;
    address : Ledger.Address.t;
    source : source;
    content : Ledger.Content_hash.t;
    confidence : float;
  }
end

module Drift = struct
  type cls =
    | Schema_identical
    | Additive of { diff : Contract.Diff.t }
    | Breaking_narrow of {
        diff : Contract.Diff.t;
        touched : Contract.Path.t list;
      }
    | Breaking_broad of { diff : Contract.Diff.t; refired : bool }
    | Producer_squashed

  (* The evidence drops here: [Ledger.Drift.cls] is the class as ledger
     events carry it (payloads never ride inline in events). *)
  let tag = function
    | Schema_identical -> Ledger.Drift.Schema_identical
    | Additive _ -> Ledger.Drift.Additive
    | Breaking_narrow _ -> Ledger.Drift.Breaking_narrow
    | Breaking_broad _ -> Ledger.Drift.Breaking_broad
    | Producer_squashed -> Ledger.Drift.Producer_squashed

  (* The routing policy, one total match (doc rule 8). [table] below is its
     rendering as inspectable data; deriving the table from the match keeps
     one supply, so the twins cannot drift apart. *)
  let route_of_tag = function
    | Ledger.Drift.Schema_identical -> Ledger.Drift.Discharge_silently
    | Ledger.Drift.Additive -> Ledger.Drift.Reconcile_note
    | Ledger.Drift.Breaking_narrow -> Ledger.Drift.Reconcile_delta
    | Ledger.Drift.Breaking_broad -> Ledger.Drift.Flush_subtree
    | Ledger.Drift.Producer_squashed -> Ledger.Drift.Flush_subtree

  let all_tags =
    [
      Ledger.Drift.Schema_identical;
      Ledger.Drift.Additive;
      Ledger.Drift.Breaking_narrow;
      Ledger.Drift.Breaking_broad;
      Ledger.Drift.Producer_squashed;
    ]

  let table = List.map (fun t -> (t, route_of_tag t)) all_tags
  let route cls = route_of_tag (tag cls)

  (* A consumed path is touched when it and a diff path lie on one
     root-to-leaf line: a change at a parent reshapes every read beneath
     it, and a change at a child reshapes a read of the parent. *)
  let touches consumed_path diff_path =
    let rec prefix a b =
      match (a, b) with
      | [], _ -> true
      | _, [] -> false
      | x :: a', y :: b' -> String.equal x y && prefix a' b'
    in
    prefix consumed_path diff_path || prefix diff_path consumed_path

  let classify ~landing ~consumed =
    match landing with
    | `Producer_squashed -> Producer_squashed
    | `Refired diff ->
        (* The producer's statement itself re-fired: broad by definition,
           whatever the diff says (40-scheduling.md § drift routing). *)
        Breaking_broad { diff; refired = true }
    | `Landed diff -> (
        if Contract.Diff.is_empty diff then Schema_identical
        else if Contract.Diff.additive_only diff then Additive { diff }
        else
          let diff_paths = Contract.Diff.touched_paths diff in
          let touched =
            List.filter
              (fun c -> List.exists (touches c) diff_paths)
              consumed
          in
          match touched with
          | [] ->
              (* Breaking changes only to paths this consumer's observed
                 witness never read: additive from this consumer's
                 perspective (per-consumer refinement, falsifier F8). *)
              Additive { diff }
          | _ :: _ ->
              if 2 * List.length touched > List.length consumed then
                Breaking_broad { diff; refired = false }
              else Breaking_narrow { diff; touched })

  (* Tuple-content drift in the schema-diff vocabulary, so one classifier
     parses both: a field the landing gained is [Added], one it lost is
     [Removed], one whose value changed is [Retyped] carrying both
     renderings as evidence. Records recurse (dotted paths); any other
     shape mismatch is a change at that path. *)
  let payload_diff ~was ~landed =
    let render j =
      let s = Yojson.Safe.to_string j in
      if String.length s <= 40 then s else String.sub s 0 37 ^ "..."
    in
    let rec walk path (was : Yojson.Safe.t) (landed : Yojson.Safe.t) =
      match (was, landed) with
      | `Assoc a, `Assoc b ->
          let removed =
            List.filter_map
              (fun (f, _) ->
                if List.mem_assoc f b then None
                else Some (Contract.Diff.Removed (path @ [ f ])))
              a
          in
          let added =
            List.filter_map
              (fun (f, _) ->
                if List.mem_assoc f a then None
                else Some (Contract.Diff.Added (path @ [ f ])))
              b
          in
          let changed =
            List.concat_map
              (fun (f, v) ->
                match List.assoc_opt f b with
                | Some v' -> walk (path @ [ f ]) v v'
                | None -> [])
              a
          in
          removed @ added @ changed
      | v, v' when Yojson.Safe.equal v v' -> []
      | v, v' ->
          [ Contract.Diff.Retyped { path; was = render v; now = render v' } ]
    in
    walk [] was landed

  let disposition_of = function
    | Ledger.Drift.Discharge_silently | Ledger.Drift.Reconcile_note ->
        `Continue
    | Ledger.Drift.Reconcile_delta -> `Patch_then_continue
    | Ledger.Drift.Flush_subtree -> `Stop_cleanly

  type note = {
    address : Ledger.Address.t;
    cls : cls;
    delta : Ledger.Delta_ref.t option;
    disposition : [ `Continue | `Patch_then_continue | `Stop_cleanly ];
  }
end

module Lifecycle = struct
  (* taken -> discharged | drifted{cls} | squashed: the sum is the state
     machine; [landing] is the refresher's one judgment and the only
     transition that needs content (a squash settles without judging). *)
  type t =
    | Taken
    | Discharged
    | Drifted of { cls : Drift.cls }
    | Squashed

  let landing ~snooped ~consumed ~landed =
    if Yojson.Safe.equal snooped landed then Discharged
    else
      match
        Drift.classify
          ~landing:(`Landed (Drift.payload_diff ~was:snooped ~landed))
          ~consumed
      with
      (* A rendering-only difference (key order) parses as an empty diff:
         the landing IS the hypothesis, semantically — discharge. *)
      | Drift.Schema_identical -> Discharged
      | cls -> Drifted { cls }
end

(* The nodes a shape fired, from the ledger's firing events. Firing
   provenance records the statement; the executor and pin are properties of
   the statement's [by] clause in the admitted theory, so within one run the
   statement identifies the shape. *)
let shape_nodes ledger (shape : Shape.t) =
  List.filter_map
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Fired { provenance; _ }
        when Theory.Statement.equal provenance.Ledger.Provenance.statement
               shape.Shape.statement ->
          e.node
      | _ -> None)
    (Ledger.Replay.events ledger)

module Counters = struct
  type t = {
    survival : float;
    reconcile_cost : float;
    flush_cost : float;
    overlap_s : float;
    suspended_reads_s : float;
    samples : int;
  }

  let mean = function
    | [] -> 0.
    | xs -> List.fold_left ( +. ) 0. xs /. float_of_int (List.length xs)

  let of_ledger ledger (shape : Shape.t) =
    let samples =
      Ledger.Predictor_history.samples ledger
        ~statement:shape.Shape.statement ~executor:shape.Shape.executor
        ~pin:shape.Shape.pin
    in
    let n = List.length samples in
    let survivors =
      List.filter
        (fun (s : Ledger.Predictor_history.sample) -> s.survived)
        samples
    in
    let survival =
      if n = 0 then 0.
      else float_of_int (List.length survivors) /. float_of_int n
    in
    (* Mean tokens per event, over the samples in which the event
       occurred: a hypothesis that never drifted contributes no reconcile,
       a hypothesis never flushed contributes no flush. *)
    let mean_positive f =
      mean
        (List.filter_map
           (fun (s : Ledger.Predictor_history.sample) ->
             let v = f s in
             if v > 0 then Some (float_of_int v) else None)
           samples)
    in
    let reconcile_cost =
      mean_positive (fun (s : Ledger.Predictor_history.sample) ->
          s.reconcile_tokens)
    in
    let flush_cost =
      mean_positive (fun (s : Ledger.Predictor_history.sample) ->
          s.flush_tokens)
    in
    let overlap_s =
      mean
        (List.map
           (fun (s : Ledger.Predictor_history.sample) -> s.overlap_s)
           survivors)
    in
    (* Read-suspension time: the blocked component of the shape's nodes'
       telemetry — a suspended fiber is parked at a read with no
       hypothesis source (40-scheduling.md § read-time binding). *)
    let suspended_reads_s =
      List.fold_left
        (fun acc node ->
          match Ledger.Telemetry.timing ledger node with
          | None -> acc
          | Some t -> acc +. t.Ledger.Telemetry.blocked_s)
        0.
        (shape_nodes ledger shape)
    in
    { survival; reconcile_cost; flush_cost; overlap_s; suspended_reads_s;
      samples = n }
end

module Predictor = struct
  type t = { ledger : Ledger.t }

  let of_ledger ledger = { ledger }

  let survival t shape =
    let c = Counters.of_ledger t.ledger shape in
    if c.Counters.samples = 0 then None else Some c.Counters.survival

  (* Hypothesis-source selection. A snooped store buffer is later, richer
     reality than any issued contract (30-channels.md § store-to-load
     forwarding), so it wins by default and wherever history says this
     shape's hypotheses tend to survive. A shape whose hypotheses
     predominantly die is one whose partial artifacts churn, and its reads
     fall back to the issued contract — the interface tuple, the more
     settled source. *)
  let prefer_source t shape ~issued ~snooped =
    match survival t shape with
    | Some s when s < 0.5 -> issued
    | Some _ | None -> snooped

  (* Higher survival first; a fresh shape ranks with the optimists so its
     regime measurements get taken in (80-validation.md § honest
     measurement). Ties compare 0, so the port queue's FIFO order
     stands. *)
  let compare_for_port t a b =
    let rank shape =
      match survival t shape with None -> 1. | Some s -> s
    in
    Float.compare (rank b) (rank a)
end

module Churn = struct
  type measurement = { shape : Shape.t; lengthening_s : float }

  (* "Survival ≈ 0" made mechanical: at or below one discharge in ten.
     Measurement-owned; adjust the constant, never the requirement. *)
  let survival_ceiling = 0.1

  let measure ledger ~shape =
    let counters = Counters.of_ledger ledger shape in
    if
      counters.Counters.samples = 0
      || counters.Counters.survival > survival_ceiling
    then None
    else
      let events = Ledger.Replay.events ledger in
      let nodes = shape_nodes ledger shape in
      let of_shape id = List.exists (Id.equal id) nodes in
      (* Drift predominantly breaking-broad: a strict majority of the
         shape's delivered drift notes carry the broad class. *)
      let classes =
        List.filter_map
          (fun (e : Ledger.Event.t) ->
            match (e.kind, e.node) with
            | Ledger.Event.Drift_note { cls; _ }, Some n when of_shape n ->
                Some cls
            | _ -> None)
          events
      in
      let broad =
        List.length
          (List.filter
             (function Ledger.Drift.Breaking_broad -> true | _ -> false)
             classes)
      in
      if 2 * broad <= List.length classes then None
      else
        let squashed n =
          List.exists
            (fun (e : Ledger.Event.t) ->
              match (e.kind, e.node) with
              | ( Ledger.Event.Settled (Ledger.Settlement.Squashed _),
                  Some m ) ->
                  Id.equal m n
              | _ -> false)
            events
        in
        let timings =
          List.filter_map
            (fun n ->
              Option.map (fun t -> (n, t)) (Ledger.Telemetry.timing ledger n))
            nodes
        in
        (* Port contended: the shape's nodes spent time queued at all. *)
        let contended =
          List.exists
            (fun ((_, t) : _ * Ledger.Telemetry.timing) -> t.queued_s > 0.)
            timings
        in
        (* The lengthening: wall clock the flush-reissue cycle serialized —
           queue and run time of the shape's squashed nodes, work that
           occupied contended slots and then had to run again anyway. *)
        let lengthening_s =
          List.fold_left
            (fun acc ((n, t) : _ * Ledger.Telemetry.timing) ->
              if squashed n then acc +. t.queued_s +. t.run_s else acc)
            0. timings
        in
        if (not contended) || lengthening_s <= 0. then None
        else Some { shape; lengthening_s }

  let shape m = m.shape
  let lengthening_s m = m.lengthening_s
end

module Switch = struct
  type t = {
    evidence : Churn.measurement;
    thrown_by : [ `Operator | `Scheduler ];
  }

  let throw ~evidence ~thrown_by = { evidence; thrown_by }
  let shape t = Churn.shape t.evidence
  let evidence t = t.evidence
  let thrown_by t = t.thrown_by
end

module Backstops = struct
  type t = { token_ceiling : int; confidence_floor : float }

  (* Generous: the ceiling is runaway protection that never binds in
     normal operation; the floor bounds flush-cascade depth without
     suppressing ordinary chains (0.05 admits chains ~40 deep at 0.93
     per-link confidence). Per-run configurable. *)
  let default = { token_ceiling = 10_000_000; confidence_floor = 0.05 }

  (* The declared per-link confidence the floor's calibration assumes.
     Measurement-owned: a per-shape measured factor is the recorded
     upgrade, in the predictor's slot. *)
  let link_confidence = 0.93
end
