(* The append-only event log and the shared spatial vocabulary.

   Signatures are normative (ledger.mli); semantics come from
   docs/architecture/30-channels.md (the ledger, event taxonomy, mechanized
   witnesses), 40-scheduling.md (settlement, the predictor),
   50-commit.md (generations advance on semantic change only) and
   80-validation.md (replay determinism, the speculation counters).

   v0 durability is a single-writer append-only file of Marshal-framed
   events (30-channels.md § OPEN items).  Marshal is the one format that
   round-trips abstract ['realm Id.t] values — Id deliberately exposes no
   [of_string], so a textual journal could not be re-parsed into typed
   events without a backdoor.  A torn tail record (crash mid-append) is
   dropped on read: the suffix never happened, which is exactly the
   abort-by-construction posture (falsifier F5). *)

type node = |
type hypothesis = |

(* Realm names, for the engine's minters (docs/architecture/50-commit.md
   § provisional identity).  Not exported; the run wires them. *)
let _node_realm = "node"
let _hypothesis_realm = "hypothesis"

module Timestamp = struct
  (* Seconds since the epoch, assigned at append.  Appends are clamped
     monotone non-decreasing so ledger order and time order never disagree —
     the replay falsifier compares decision traces against this stream and
     a backwards clock would make "computed from event timestamps"
     (30-channels.md § the ledger) lie. *)
  type t = float

  let compare = Float.compare
  let to_seconds t = t
  let pp ppf t = Format.fprintf ppf "%.6f" t
end

module Usage = struct
  type t = { tokens_in : int; tokens_out : int }

  let zero = { tokens_in = 0; tokens_out = 0 }

  let add a b =
    {
      tokens_in = a.tokens_in + b.tokens_in;
      tokens_out = a.tokens_out + b.tokens_out;
    }

  let total u = u.tokens_in + u.tokens_out
end

module Address = struct
  type t =
    | File of string
    | Tuple of { relation : string; id : string }
    | Contract of string
    | Resource of string

  let rank = function
    | File _ -> 0
    | Tuple _ -> 1
    | Contract _ -> 2
    | Resource _ -> 3

  let compare a b =
    match (a, b) with
    | File a, File b -> String.compare a b
    | Tuple a, Tuple b -> (
        match String.compare a.relation b.relation with
        | 0 -> String.compare a.id b.id
        | c -> c)
    | Contract a, Contract b -> String.compare a b
    | Resource a, Resource b -> String.compare a b
    | (File _ | Tuple _ | Contract _ | Resource _), _ ->
        Int.compare (rank a) (rank b)

  let equal a b = compare a b = 0

  let to_string = function
    | File path -> "file:" ^ path
    | Tuple { relation; id } -> "tuple:" ^ relation ^ "/" ^ id
    | Contract relation -> "contract:" ^ relation
    | Resource name -> "resource:" ^ name

  let pp ppf a = Format.pp_print_string ppf (to_string a)
end

module Generation = struct
  (* A per-address counter.  Only the commit layer calls [next], and only on
     semantic change (50-commit.md § law 2) — the ledger stores whatever the
     commit layer decided; it never advances anything itself. *)
  type t = int

  let zero = 0
  let next g = g + 1
  let equal = Int.equal
  let compare = Int.compare
  let pp ppf g = Format.fprintf ppf "g%d" g
end

module Content_hash = struct
  (* Stdlib [Digest] (MD5): content identity for witness comparison, not a
     security boundary — the witness needs no trust boundary of its own
     because it is captured by observation (30-channels.md § mechanized
     witnesses). *)
  type t = Digest.t

  let of_string s = Digest.string s
  let equal = String.equal
  let compare = String.compare
  let to_hex = Digest.to_hex
  let pp ppf h = Format.pp_print_string ppf (to_hex h)
end

module Delta_ref = struct
  (* An opaque locator for an out-of-line payload.  The exact blob scheme is
     OPEN (30-channels.md § OPEN items); v0 carries the locator as a string
     (a worktree-relative path or blob key). *)
  type t = string

  let v s = s
  let to_string r = r
  let pp ppf r = Format.pp_print_string ppf r
end

module Footprint = struct
  module Set = Stdlib.Set.Make (Address)

  type t = Set.t

  let empty = Set.empty
  let of_list = Set.of_list
  let to_list = Set.elements
  let mem fp a = Set.mem a fp
  let union = Set.union
  let inter = Set.inter
  let is_empty = Set.is_empty
end

module Provenance = struct
  type t = {
    statement : Theory.Statement.id;
    consumed : (string * string) list;
    hypotheses : hypothesis Id.t list;
  }
end

module Fault = struct
  type origin = Executor_error | Repair_exhausted | Context_exhausted
  type t = { origin : origin; message : string }
end

module Squash_cause = struct
  type t =
    | Dead_hypothesis of hypothesis Id.t
    | Upstream_fault of node Id.t
    | Upstream_squash of node Id.t
    | Operator_abort
end

module Settlement = struct
  type t = Retired | Faulted of Fault.t | Squashed of Squash_cause.t
end

module Event = struct
  type kind =
    | Load of {
        tool : string;
        observed : (Address.t * Generation.t * Content_hash.t) list;
      }
    | Store of { tool : string; address : Address.t; delta : Delta_ref.t }
    | Effect of { tool : string; resource : string; idempotent : bool }
    | Agent_turn of { usage : Usage.t }
    | Fired of { provenance : Provenance.t; minted : (string * string) list }
    | Hypothesis_taken of {
        hypothesis : hypothesis Id.t;
        address : Address.t;
        source : string;
        content : Content_hash.t;
        confidence : float;
      }
    | Hypothesis_discharged of { hypothesis : hypothesis Id.t }
    | Invalidation_sent of {
        address : Address.t;
        new_generation : Generation.t;
      }
    | Drift_note of { address : Address.t; cls : string; route : string }
    | Repair_attempt of { attempt : int; refusal : bool }
    | Settled of Settlement.t
    | Decision of {
        action : string;
        reason : string;
        counters : (string * float) list;
      }
    | Pin_bump of { statement : string; executor : string; pin : string }
    | Switch_thrown of {
        statement : string;
        executor : string;
        churn : float;
      }
    | Law_verdict of { law : string; satisfied : bool }
    | Correction of { subject : string; cause : string }

  type t = { node : node Id.t option; at : Timestamp.t; kind : kind }
end

(* ------------------------------------------------------------------ *)
(* The log itself: single-writer append-only file, mirrored in memory
   for the four readers (all readers are pull-only queries; no logger
   rides the dispatch path).                                           *)
(* ------------------------------------------------------------------ *)

type sink =
  | Append of out_channel  (** Opened by {!create}: the single writer. *)
  | Read_only  (** Opened by {!load}: the CLI's report/explain/replay entry. *)

type t = {
  path : string;
  sink : sink;
  mutable rev_events : Event.t list;  (* newest first *)
  mutable last_at : float;  (* monotone clamp for append stamps *)
}

let read_events path : Event.t list =
  (* Returns newest-first.  A torn tail (crash mid-append) raises inside
     Marshal; the suffix is dropped — abort by construction (F5). *)
  if not (Sys.file_exists path) then []
  else begin
    let ic = open_in_bin path in
    let rec loop acc =
      match (Marshal.from_channel ic : Event.t) with
      | event -> loop (event :: acc)
      | exception End_of_file -> acc
      | exception Failure _ -> acc
    in
    let events = loop [] in
    close_in ic;
    events
  end

let last_stamp = function [] -> 0. | (e : Event.t) :: _ -> e.at

let create ~path =
  let rev_events = read_events path in
  let oc = open_out_gen [ Open_append; Open_creat; Open_binary ] 0o644 path in
  { path; sink = Append oc; rev_events; last_at = last_stamp rev_events }

let load ~path =
  let rev_events = read_events path in
  { path; sink = Read_only; rev_events; last_at = last_stamp rev_events }

let append t ?node kind =
  match t.sink with
  | Read_only ->
      invalid_arg
        (Printf.sprintf
           "Ledger.append: %s was opened read-only (Ledger.load)" t.path)
  | Append oc ->
      (* The one wall-clock read in the system: timestamps enter scheduler
         decisions only through the ledger (80-validation.md § replay
         determinism).  Clamped so append order and time order agree. *)
      let at = Float.max (Unix.gettimeofday ()) t.last_at in
      t.last_at <- at;
      let event = { Event.node; at; kind } in
      Marshal.to_channel oc event [];
      flush oc;
      t.rev_events <- event :: t.rev_events;
      event

(* ------------------------------------------------------------------ *)
(* The four named readers                                              *)
(* ------------------------------------------------------------------ *)

module Replay = struct
  let events t = List.rev t.rev_events
end

(* Shared query helpers (private). *)

let events_of_node t node =
  List.filter
    (fun (e : Event.t) ->
      match e.node with Some n -> Id.equal n node | None -> false)
    (Replay.events t)

let sum_usage events =
  List.fold_left
    (fun acc (e : Event.t) ->
      match e.kind with
      | Event.Agent_turn { usage } -> Usage.add acc usage
      | _ -> acc)
    Usage.zero events

module Telemetry = struct
  type timing = { blocked_s : float; queued_s : float; run_s : float }

  (* The taxonomy has no dedicated lifecycle constructors; the scheduler
     records lifecycle transitions as [Decision] events with these actions
     ("every scheduler decision with its reason" —
     40-scheduling.md § drift routing).  The decomposition is:
       queued  = time between "queued" and the matching "admitted"
       blocked = time between "suspended" and the matching "resumed"
       run     = the node's span minus both. *)
  let queued_action = "queued"
  let admitted_action = "admitted"
  let suspended_action = "suspended"
  let resumed_action = "resumed"

  let timing t node =
    match events_of_node t node with
    | [] -> None
    | first :: _ as events ->
        let start = first.Event.at in
        let settled_at =
          List.find_map
            (fun (e : Event.t) ->
              match e.kind with Event.Settled _ -> Some e.at | _ -> None)
            events
        in
        let fin =
          match settled_at with
          | Some at -> at
          | None ->
              List.fold_left
                (fun acc (e : Event.t) -> Float.max acc e.at)
                start events
        in
        let close since stop acc =
          match since with
          | Some opened when stop > opened -> acc +. (stop -. opened)
          | _ -> acc
        in
        let blocked, queued, suspended_since, queued_since =
          List.fold_left
            (fun (blocked, queued, suspended_since, queued_since)
                 (e : Event.t) ->
              match e.kind with
              | Event.Decision { action; _ }
                when String.equal action suspended_action ->
                  (blocked, queued, Some e.at, queued_since)
              | Event.Decision { action; _ }
                when String.equal action resumed_action ->
                  (close suspended_since e.at blocked, queued, None,
                   queued_since)
              | Event.Decision { action; _ }
                when String.equal action queued_action ->
                  (blocked, queued, suspended_since, Some e.at)
              | Event.Decision { action; _ }
                when String.equal action admitted_action ->
                  (blocked, close queued_since e.at queued, suspended_since,
                   None)
              | _ -> (blocked, queued, suspended_since, queued_since))
            (0., 0., None, None) events
        in
        let blocked_s = close suspended_since fin blocked in
        let queued_s = close queued_since fin queued in
        let run_s = Float.max 0. (fin -. start -. blocked_s -. queued_s) in
        Some { blocked_s; queued_s; run_s }

  let usage t node = sum_usage (events_of_node t node)
  let run_usage t = sum_usage (Replay.events t)
end

module Predictor_history = struct
  type sample = {
    survived : bool;
    reconcile_tokens : int;
    flush_tokens : int;
    overlap_s : float;
  }

  (* A node belongs to a (statement, executor, pin) shape iff its [Fired]
     statement matches and the most recent [Pin_bump] for that statement —
     in append order, before the firing — names that executor and pin.
     A pin bump therefore resets the shape's history by construction
     (survival history is per pin, 60-agents.md § model pins), and a shape
     with no recorded pin has no samples: it reads as fresh, which is what
     [Speculate.Predictor.survival = None] means.  The run records each
     shape's initial pin as a [Pin_bump] at open.

     One sample = one hypothesis lifecycle on a node of the shape:
       survived         — a [Hypothesis_discharged] with the same id exists
                          (discharged unchanged / fired, 80-validation.md).
       reconcile_tokens — agent-turn tokens between the first [Drift_note]
                          at the hypothesis's address and its discharge
                          (or the node's end): the drift-routed reconcile.
       flush_tokens     — the node's gross token bill when it settled
                          [Squashed] (wasted-token accounting is gross,
                          never net — 80-validation.md § honest
                          measurement); 0 otherwise.
       overlap_s        — hypothesis-taken to discharge: the wall clock the
                          consumer ran ahead on the guess. *)
  let samples t ~statement ~executor ~pin =
    let all = Replay.events t in
    let shaped_nodes =
      let _, nodes =
        List.fold_left
          (fun (pins, nodes) (e : Event.t) ->
            match e.kind with
            | Event.Pin_bump { statement = s; executor = x; pin = p } ->
                ((s, (x, p)) :: pins, nodes)
            | Event.Fired { provenance; _ } -> (
                let s =
                  Theory.Statement.to_string provenance.Provenance.statement
                in
                if not (String.equal s statement) then (pins, nodes)
                else
                  match (List.assoc_opt s pins, e.node) with
                  | Some (x, p), Some n
                    when String.equal x executor && String.equal p pin ->
                      (pins, n :: nodes)
                  | _ -> (pins, nodes))
            | _ -> (pins, nodes))
          ([], []) all
      in
      List.rev nodes
    in
    let samples_of_node node =
      let events =
        List.filter
          (fun (e : Event.t) ->
            match e.node with Some n -> Id.equal n node | None -> false)
          all
      in
      let node_tokens = Usage.total (sum_usage events) in
      let squashed =
        List.exists
          (fun (e : Event.t) ->
            match e.kind with
            | Event.Settled (Settlement.Squashed _) -> true
            | _ -> false)
          events
      in
      let end_at =
        List.fold_left (fun acc (e : Event.t) -> Float.max acc e.at) 0. events
      in
      let taken =
        List.filter_map
          (fun (e : Event.t) ->
            match e.kind with
            | Event.Hypothesis_taken { hypothesis; address; _ } ->
                Some (hypothesis, address, e.at)
            | _ -> None)
          events
      in
      List.map
        (fun (hypothesis, address, taken_at) ->
          let discharge_at =
            List.find_map
              (fun (e : Event.t) ->
                match e.kind with
                | Event.Hypothesis_discharged { hypothesis = h }
                  when Id.equal h hypothesis ->
                    Some e.at
                | _ -> None)
              events
          in
          let drift_at =
            List.find_map
              (fun (e : Event.t) ->
                match e.kind with
                | Event.Drift_note { address = a; _ }
                  when Address.equal a address ->
                    Some e.at
                | _ -> None)
              events
          in
          let reconcile_tokens =
            match drift_at with
            | None -> 0
            | Some from ->
                let until = Option.value discharge_at ~default:end_at in
                List.fold_left
                  (fun acc (e : Event.t) ->
                    match e.kind with
                    | Event.Agent_turn { usage }
                      when e.at >= from && e.at <= until ->
                        acc + Usage.total usage
                    | _ -> acc)
                  0 events
          in
          let survived = Option.is_some discharge_at in
          let overlap_s =
            match discharge_at with
            | Some at -> Float.max 0. (at -. taken_at)
            | None -> 0.
          in
          {
            survived;
            reconcile_tokens;
            flush_tokens = (if squashed then node_tokens else 0);
            overlap_s;
          })
        taken
    in
    List.concat_map samples_of_node shaped_nodes
end

module Witness_index = struct
  (* Witness = observed events only: the read-set is assembled from the
     node's own [Load] events, never from any self-report (30-channels.md
     § mechanized witnesses; falsifier F6). *)
  let reads t node =
    List.concat_map
      (fun (e : Event.t) ->
        match e.kind with Event.Load { observed; _ } -> observed | _ -> [])
      (events_of_node t node)

  (* The store footprint, for the [disjoint] EGD.  Effects are excluded:
     they are lock-guarded machine resources, not worktree writes, and the
     disjoint-writes law is judged over committed paths (50-commit.md
     § retirement order). *)
  let writes t node =
    Footprint.of_list
      (List.filter_map
         (fun (e : Event.t) ->
           match e.kind with
           | Event.Store { address; _ } -> Some address
           | _ -> None)
         (events_of_node t node))
end
