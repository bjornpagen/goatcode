(* The fiber substrate (fiber.mli owns the design): a single-domain
   deterministic evaluator over the effect vocabulary. Continuations are
   runtime detail — every table below is printable, and no continuation is
   reachable from outside this file. *)

module Operand = struct
  type t =
    | Witnessed of {
        generation : Ledger.Generation.t;
        content : Ledger.Content_hash.t;
      }
    | Hypothesis of Speculate.Hypothesis.t
end

type _ Effect.t +=
  | Read : Ledger.Address.t -> Operand.t Effect.t
  | Yield : Speculate.Drift.note list Effect.t
  | Http_post : Http.Request.t -> (int * string, Http.error) result Effect.t

exception Squash

let read address = Effect.perform (Read address)
let yield () = Effect.perform Yield
let http_post request = Effect.perform (Http_post request)

module Transport = struct
  type token = Http.Multi.token

  type t = {
    submit : Http.Request.t -> token;
    poll : block:bool -> (token * (int * string, Http.error) result) list;
  }

  let live () =
    let multi = Http.Multi.create () in
    {
      submit = (fun req -> Http.Multi.start multi req);
      poll =
        (fun ~block ->
          (* Drain first: a transfer registers idle until the first
             [completions] performs it, so waiting before performing would
             stall the whole stack for one timeout. *)
          match Http.Multi.completions multi with
          | [] when block && Http.Multi.in_flight multi > 0 ->
              ignore (Http.Multi.wait multi ~timeout_s:0.1 : bool);
              Http.Multi.completions multi
          | completions -> completions);
    }
end

type stop =
  | Squashed of Ledger.Squash_cause.t
  | Stopped_cleanly of Speculate.Drift.note

type 'a settlement = Returned of 'a | Stopped of stop | Faulted of Ledger.Fault.t

type id = int

let id_to_string fid = "f" ^ string_of_int fid
let id_equal = Int.equal

(* One-shot custody of a continuation. The runtime's one-shot guarantee is
   dynamic ([Continuation_already_resumed] at the second resume); [take]
   makes the second use a normal [None] branch instead — the wrapper the
   public API's no-continuations rule rests on. *)
module Once : sig
  type 'a t

  val hold : ('a, unit) Effect.Deep.continuation -> 'a t
  val take : 'a t -> ('a, unit) Effect.Deep.continuation option
end = struct
  type 'a t = ('a, unit) Effect.Deep.continuation option ref

  let hold k = ref (Some k)

  let take cell =
    let k = !cell in
    cell := None;
    k
end

(* A suspended-and-ready resumption, packed so one queue carries every
   answer type in the vocabulary. *)
type ready_entry =
  | Start of id
  | Resume : id * 'a Once.t * 'a -> ready_entry

type view =
  | V_ready
  | V_running
  | V_parked of Ledger.Address.t
  | V_in_flight of Transport.token
  | V_settled of [ `Returned | `Stopped | `Faulted ]

type fiber = {
  fid : id;
  name : string;
  on_yield : unit -> Speculate.Drift.note list;
  body : (t -> fiber -> unit) option ref;
      (* consumed at Start; None afterwards *)
  force_stop : (stop -> unit) ref;
      (* settles the handle's typed cell as [Stopped] for a fiber whose
         handler never ran (squashed before its first instruction) — the
         one settlement path outside the handler *)
  mutable view : view;
  mutable squash_mark : stop option;
      (* set once, at the squash decision; makes squash a state: every
         later instruction discontinues, and a swallowed [Squash] still
         settles [Stopped] at return *)
}

and t = {
  read_policy : id -> Ledger.Address.t -> Operand.t option;
  transport : Transport.t;
  mutable fibers : fiber list;  (* spawn order *)
  mutable ready : ready_entry list;  (* FIFO *)
  mutable parked_tbl : (fiber * Ledger.Address.t * Operand.t Once.t) list;
      (* park order *)
  mutable in_flight_tbl :
    (Transport.token * fiber * (int * string, Http.error) result Once.t) list;
  mutable current : id option;
}

type 'a handle = { h_fid : id; cell : 'a settlement option ref }

let create ~read ~transport () =
  {
    read_policy = read;
    transport;
    fibers = [];
    ready = [];
    parked_tbl = [];
    in_flight_tbl = [];
    current = None;
  }

let fiber_of t fid = List.find (fun f -> id_equal f.fid fid) t.fibers

let enqueue t entry = t.ready <- t.ready @ [ entry ]

let take_ready t =
  match t.ready with
  | [] -> None
  | entry :: rest ->
      t.ready <- rest;
      Some entry

(* {2 Settlement and the handler} *)

let settle_view = function
  | Returned _ -> `Returned
  | Stopped _ -> `Stopped
  | Faulted _ -> `Faulted

(* The per-fiber Deep handler: the evaluator's dispatch over the
   vocabulary. It runs [fn] on the scheduler's stack; every suspension
   either answers inline ([continue]) or stores the continuation in a
   table and returns to the loop. *)
let make_body (type a) (fn : unit -> a) (cell : a settlement option ref) =
  let open Effect.Deep in
  fun t (fiber : fiber) ->
    let settle s =
      cell := Some s;
      fiber.view <- V_settled (settle_view s)
    in
    let discontinue_squashed k =
      (* The mark is already set; unwinding runs the fiber's finalizers,
         and exnc below lands the settlement. *)
      discontinue k Squash
    in
    match_with fn ()
      {
        retc =
          (fun v ->
            match fiber.squash_mark with
            | Some stop -> settle (Stopped stop)
            | None -> settle (Returned v));
        exnc =
          (fun e ->
            match (e, fiber.squash_mark) with
            | Squash, Some stop -> settle (Stopped stop)
            | Squash, None ->
                (* Unreachable through this module (the mark is set before
                   any discontinue); a fiber raising Squash itself is a
                   fault like any other raise. *)
                settle
                  (Faulted
                     {
                       Ledger.Fault.origin = Ledger.Fault.Executor_error;
                       message = "fiber raised Squash outside a squash";
                     })
            | Effect.Unhandled _, _ ->
                (* A rogue effect: contained as the node's own fault. *)
                settle
                  (Faulted
                     {
                       Ledger.Fault.origin = Ledger.Fault.Executor_error;
                       message = "unhandled effect: " ^ Printexc.to_string e;
                     })
            | e, _ ->
                settle
                  (Faulted
                     {
                       Ledger.Fault.origin = Ledger.Fault.Executor_error;
                       message = Printexc.to_string e;
                     }));
        effc =
          (fun (type b) (eff : b Effect.t) ->
            match eff with
            | Read address ->
                Some
                  (fun (k : (b, _) continuation) ->
                    match fiber.squash_mark with
                    | Some _ -> discontinue_squashed k
                    | None -> (
                        match t.read_policy fiber.fid address with
                        | Some operand -> continue k operand
                        | None ->
                            fiber.view <- V_parked address;
                            t.parked_tbl <-
                              t.parked_tbl @ [ (fiber, address, Once.hold k) ]))
            | Yield ->
                Some
                  (fun (k : (b, _) continuation) ->
                    match fiber.squash_mark with
                    | Some _ -> discontinue_squashed k
                    | None -> (
                        let notes = fiber.on_yield () in
                        let stops =
                          List.find_opt
                            (fun (n : Speculate.Drift.note) ->
                              match n.disposition with
                              | `Stop_cleanly -> true
                              | `Continue | `Patch_then_continue -> false)
                            notes
                        in
                        match stops with
                        | Some note ->
                            fiber.squash_mark <- Some (Stopped_cleanly note);
                            discontinue_squashed k
                        | None -> continue k notes))
            | Http_post request ->
                Some
                  (fun (k : (b, _) continuation) ->
                    match fiber.squash_mark with
                    | Some _ -> discontinue_squashed k
                    | None ->
                        let token = t.transport.submit request in
                        fiber.view <- V_in_flight token;
                        t.in_flight_tbl <-
                          t.in_flight_tbl @ [ (token, fiber, Once.hold k) ])
            | _ -> None);
      }

let spawn (type a) t ~name ?(on_yield = fun () -> []) (fn : unit -> a) :
    a handle =
  let fid = List.length t.fibers in
  let cell : a settlement option ref = ref None in
  let fiber =
    {
      fid;
      name;
      on_yield;
      body = ref None;
      force_stop = ref (fun _ -> ());
      view = V_ready;
      squash_mark = None;
    }
  in
  fiber.body := Some (make_body fn cell);
  (fiber.force_stop :=
     fun stop ->
       cell := Some (Stopped stop);
       fiber.view <- V_settled `Stopped);
  t.fibers <- t.fibers @ [ fiber ];
  enqueue t (Start fid);
  { h_fid = fid; cell }

let id h = h.h_fid
let result h = !(h.cell)

(* {2 Running} *)

let run_entry t entry =
  match entry with
  | Start fid -> (
      let fiber = fiber_of t fid in
      match (!(fiber.body), fiber.squash_mark) with
      | None, _ -> () (* already consumed: unreachable through the queue *)
      | Some _, Some _ ->
          (* Squashed before its first instruction (squash settled the
             cell and normally removes this entry too): nothing ran,
             nothing to unwind. *)
          fiber.body := None
      | Some body, None ->
          fiber.body := None;
          fiber.view <- V_running;
          t.current <- Some fid;
          body t fiber;
          t.current <- None)
  | Resume (fid, once, v) -> (
      let fiber = fiber_of t fid in
      match Once.take once with
      | None -> ()
      | Some k ->
          t.current <- Some fid;
          (match fiber.squash_mark with
          | Some _ -> Effect.Deep.discontinue k Squash
          | None ->
              fiber.view <- V_running;
              Effect.Deep.continue k v);
          t.current <- None)

let step t =
  match take_ready t with
  | Some entry ->
      run_entry t entry;
      `Progressed
  | None ->
      if List.is_empty t.in_flight_tbl then `Quiescent
      else begin
        let completions = t.transport.poll ~block:true in
        List.iter
          (fun (token, outcome) ->
            match
              List.find_opt
                (fun (tok, _, _) -> Int.equal tok token)
                t.in_flight_tbl
            with
            | None -> () (* abandoned by squash: dropped, a no-op *)
            | Some (_, fiber, once) ->
                t.in_flight_tbl <-
                  List.filter
                    (fun (tok, _, _) -> not (Int.equal tok token))
                    t.in_flight_tbl;
                fiber.view <- V_ready;
                enqueue t (Resume (fiber.fid, once, outcome)))
          completions;
        `Progressed
      end

let rec run_until_quiescent t =
  match step t with
  | `Progressed -> run_until_quiescent t
  | `Quiescent -> ()

let quiescent t =
  List.is_empty t.ready && List.is_empty t.in_flight_tbl

let has_ready t = not (List.is_empty t.ready)

(* {2 External wake and squash} *)

let wake t ~key operand =
  let woken, still =
    List.partition
      (fun (_, address, _) -> Ledger.Address.equal address key)
      t.parked_tbl
  in
  t.parked_tbl <- still;
  List.iter
    (fun ((fiber : fiber), _, once) ->
      fiber.view <- V_ready;
      enqueue t (Resume (fiber.fid, once, operand)))
    woken;
  List.length woken

(* Discontinue a held continuation now: finalizers run before the caller's
   squash returns, so a dropped worktree is gone when the cause chain is
   recorded. *)
let discontinue_held t fid once =
  match Once.take once with
  | None -> ()
  | Some k ->
      let saved = t.current in
      t.current <- Some fid;
      Effect.Deep.discontinue k Squash;
      t.current <- saved

let squash t fid ~cause =
  let fiber = fiber_of t fid in
  match fiber.view with
  | V_settled _ -> ()
  | _ ->
      if Option.is_none fiber.squash_mark then
        fiber.squash_mark <- Some (Squashed cause);
      (* Parked: take and discontinue. *)
      let parked_here, parked_rest =
        List.partition (fun (f, _, _) -> id_equal f.fid fid) t.parked_tbl
      in
      t.parked_tbl <- parked_rest;
      List.iter (fun (_, _, once) -> discontinue_held t fid once) parked_here;
      (* In flight: abandon the transfer, discontinue the waiter. *)
      let flying_here, flying_rest =
        List.partition (fun (_, f, _) -> id_equal f.fid fid) t.in_flight_tbl
      in
      t.in_flight_tbl <- flying_rest;
      List.iter (fun (_, _, once) -> discontinue_held t fid once) flying_here;
      (* Ready: a held resumption discontinues; an unstarted fiber settles
         without ever running (no stack exists, so no finalizers are
         owed). Its body closure is dropped with the queue entry. *)
      let mine, others =
        List.partition
          (function
            | Start f -> id_equal f fid
            | Resume (f, _, _) -> id_equal f fid)
          t.ready
      in
      t.ready <- others;
      List.iter
        (function
          | Start _ -> fiber.body := None
          | Resume (_, once, _) -> discontinue_held t fid once)
        mine;
      (* A running fiber (squash from inside its own turn) keeps the mark:
         its next instruction discontinues; a bare return still settles
         [Stopped]. Every held continuation settled above through the
         handler's exnc; what remains unsettled is a fiber whose handler
         never ran — settle its cell directly. *)
      (match fiber.view with
      | V_settled _ | V_running -> ()
      | V_ready | V_parked _ | V_in_flight _ ->
          !(fiber.force_stop)
            (match fiber.squash_mark with
            | Some stop -> stop
            | None -> Squashed cause))

(* {2 Inspection} *)

type status =
  | Ready
  | Running
  | Parked of Ledger.Address.t
  | In_flight of Transport.token
  | Settled of [ `Returned | `Stopped | `Faulted ]

let status t fid =
  let fiber = fiber_of t fid in
  match fiber.view with
  | V_ready -> Ready
  | V_running -> Running
  | V_parked a -> Parked a
  | V_in_flight tok -> In_flight tok
  | V_settled s -> Settled s

let parked t =
  List.map (fun ((f : fiber), address, _) -> (f.fid, address)) t.parked_tbl

let dump t =
  let line (f : fiber) =
    let state =
      match f.view with
      | V_ready -> "ready"
      | V_running -> "running"
      | V_parked a -> "parked-on " ^ Ledger.Address.to_string a
      | V_in_flight tok -> Printf.sprintf "in-flight #%d" tok
      | V_settled `Returned -> "settled returned"
      | V_settled `Stopped -> "settled stopped"
      | V_settled `Faulted -> "settled faulted"
    in
    Printf.sprintf "%s %s: %s" (id_to_string f.fid) f.name state
  in
  String.concat "\n" (List.map line t.fibers)
