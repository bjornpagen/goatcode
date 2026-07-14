(* Channels: pre-opened, unidirectional, invalidation-carrying.
   Semantics: docs/architecture/30-channels.md; contract: channel.mli.

   Unidirectionality is by construction: [_ tx] wraps only the producer
   operations, [_ rx] only one edge's cursor and queue, and nothing in this
   file converts between them (falsifier F11). The only party that ever
   holds both ends of anything is the scheduler, and it holds them as two
   separate values obtained by two separate calls. *)

(* ------------------------------------------------------------------ *)
(* Declared-footprint pattern matching.

   A footprint plays two roles in the system: observed footprints (what a
   tool call actually touched) contain concrete addresses, and declared
   footprints (an edge's compiled delivery filter) contain patterns — file
   globs in [Address.File], and the [any_id] wildcard in [Address.Tuple]
   ids, meaning "every tuple of this relation" (a consumer cannot know at
   admission which ids its refs will name). [Invalidation.passes] is the
   pattern-cover judgment; concrete-vs-concrete degenerates to equality, so
   observed footprints work unchanged
   (docs/architecture/30-channels.md § footprint filtering). *)

(* Glob matching for file paths: [*] matches within one path segment,
   [**] matches across segments ([a/**/b] also matches [a/b]), [?] matches
   one non-[/] character. A pattern with no wildcards is plain equality. *)
let glob_match pattern path =
  let np = String.length pattern and ns = String.length path in
  let rec go i j =
    if i >= np then j >= ns
    else
      match pattern.[i] with
      | '*' when i + 1 < np && pattern.[i + 1] = '*' ->
          (* [**]: any sequence, '/' included; swallow a trailing '/' so
             the empty expansion of [a/**/b] yields [a/b], not [a//b]. *)
          let i' =
            if i + 2 < np && pattern.[i + 2] = '/' then i + 3 else i + 2
          in
          let rec widen k = go i' k || (k < ns && widen (k + 1)) in
          widen j
      | '*' ->
          let rec widen k =
            go (i + 1) k || (k < ns && path.[k] <> '/' && widen (k + 1))
          in
          widen j
      | '?' -> j < ns && path.[j] <> '/' && go (i + 1) (j + 1)
      | c -> j < ns && path.[j] = c && go (i + 1) (j + 1)
  in
  go 0 0

(* The tuple-id wildcard a compiled edge footprint uses to subscribe to a
   whole relation. *)
let any_id = "*"

(* Does one declared address cover one concrete address? *)
let covers (declared : Ledger.Address.t) (concrete : Ledger.Address.t) =
  match (declared, concrete) with
  | File pattern, File path -> glob_match pattern path
  | Tuple { relation = dr; id = di }, Tuple { relation = cr; id = ci } ->
      String.equal dr cr && (String.equal di any_id || String.equal di ci)
  | Contract a, Contract b -> String.equal a b
  | Resource a, Resource b -> String.equal a b
  | (File _ | Tuple _ | Contract _ | Resource _), _ -> false

module Invalidation = struct
  type t = {
    address : Ledger.Address.t;
    new_generation : Ledger.Generation.t;
    producer : Ledger.node Id.t;
    delta_ref : Ledger.Delta_ref.t;
  }

  let passes ~footprint t =
    List.exists
      (fun declared -> covers declared t.address)
      (Ledger.Footprint.to_list footprint)
end

(* ------------------------------------------------------------------ *)
(* Type-erased tuple storage.

   One channel's committed-tuple log is shared by its unique writer end and
   every reader end, all obtained by independent registry lookups keyed by
   relation name. OCaml offers no way to carry the payload type through
   that name-keyed table (the [Theory.Relation.t] the caller holds is
   abstract and exposes no type witness), so the log erases its elements
   and this module is the single, contained recovery point.

   Soundness invariant: admission rejects [Duplicate_relation], so within
   one admitted theory a relation name determines its payload type; every
   [tx]/[rx] instantiation against one channel therefore names the same
   ['a] the channel was opened for, and [unpack] re-reads a cell at exactly
   the type [pack] stored it at. *)
module Tuple_cell : sig
  type t

  val pack : 'a Id.t -> 'a -> t
  val unpack : t -> 'a Id.t * 'a
end = struct
  type t = Obj.t

  let pack id payload = Obj.repr (id, payload)
  let unpack = Obj.obj
end

(* ------------------------------------------------------------------ *)
(* Channel state. *)

(* One consumer edge's subscription: allocated at [open_all] — before any
   node runs — so deliveries buffer for a consumer that has not started
   (the buffered-socket state; 30-channels.md § pre-opened channels). *)
type sub = {
  fp : Ledger.Footprint.t; (* compiled delivery filter *)
  pending : Invalidation.t Queue.t; (* footprint-filtered, drained at yield *)
  mutable cursor : int; (* committed tuples already drained *)
}

(* One relation in motion: the committed-tuple log plus every subscribed
   edge, keyed by consuming statement (one edge per statement per relation
   in v0's single-relation bodies). *)
type chan = {
  log : Tuple_cell.t Dynarray.t;
  subs : (string, sub) Hashtbl.t;
}

type registry = { chans : (string, chan) Hashtbl.t }
type 'a tx = Tx of chan
type 'a rx = Rx of { chan : chan; sub : sub }

(* ------------------------------------------------------------------ *)
(* Footprint compilation.

   The theory author never writes routing: an edge's filter is derived from
   its contract — the relation it reads, the ref-slot targets it
   dereferences — plus the executor's file-glob grant. Tuple entries use
   [any_id] (ids are minted at firing time, unknowable at admission);
   contract addresses ride along so schema drift of a consumed relation
   reaches its consumers as drift notes
   (30-channels.md § footprint filtering). *)
let compile_footprint theory (edge : Theory.Edge.t) =
  let file_grants =
    List.map (fun g -> Ledger.Address.File g) edge.read_globs
  in
  let relation_addrs name =
    [
      Ledger.Address.Tuple { relation = name; id = any_id };
      Ledger.Address.Contract name;
    ]
  in
  let ref_targets =
    match Theory.slots theory ~relation:edge.reads with
    | None -> []
    | Some slots ->
        List.filter_map
          (fun (slot : Theory.Slot.t) ->
            match slot.kind with
            | Theory.Slot.Ref target
              when List.exists (String.equal slot.field) edge.ref_fields ->
                Some target
            | Theory.Slot.Ref _ | Theory.Slot.Mint | Theory.Slot.Value ->
                None)
          slots
  in
  Ledger.Footprint.of_list
    (file_grants
    @ relation_addrs edge.reads
    @ List.concat_map relation_addrs ref_targets)

(* ------------------------------------------------------------------ *)
(* Opening. *)

let open_all theory =
  let chans = Hashtbl.create 16 in
  List.iter
    (fun (Theory.Relation.Packed r) ->
      Hashtbl.replace chans (Theory.Relation.name r)
        { log = Dynarray.create (); subs = Hashtbl.create 4 })
    (Theory.relations theory);
  (* Subscribe every consumer edge now, before any node runs: an
     invalidation fanned out before the consumer's first read must be
     waiting in its queue, not dropped (socket activation). *)
  List.iter
    (fun (edge : Theory.Edge.t) ->
      match Hashtbl.find_opt chans edge.reads with
      | None ->
          (* Unreachable for an admitted theory: admission resolves every
             statement's body relation (Unknown_relation). *)
          ()
      | Some chan ->
          let key = Theory.Statement.to_string edge.statement in
          if not (Hashtbl.mem chan.subs key) then
            Hashtbl.replace chan.subs key
              {
                fp = compile_footprint theory edge;
                pending = Queue.create ();
                cursor = 0;
              })
    (Theory.edges theory);
  { chans }

(* Registry lookups take relations and edges of the admitted theory the
   registry was opened for; anything else is an engine bug, not a runtime
   condition, hence [Invalid_argument] rather than an error type the .mli
   does not offer. *)
let find_chan registry relation ~caller =
  match Hashtbl.find_opt registry.chans relation with
  | Some chan -> chan
  | None ->
      invalid_arg
        (Printf.sprintf
           "Channel.%s: relation %S was not opened at admission" caller
           relation)

let tx registry relation = Tx (find_chan registry (Theory.Relation.name relation) ~caller:"tx")

let rx registry relation ~(edge : Theory.Edge.t) =
  let name = Theory.Relation.name relation in
  if not (String.equal edge.reads name) then
    invalid_arg
      (Printf.sprintf "Channel.rx: edge %s reads %S, not %S"
         (Theory.Statement.to_string edge.statement)
         edge.reads name);
  let chan = find_chan registry name ~caller:"rx" in
  match Hashtbl.find_opt chan.subs (Theory.Statement.to_string edge.statement) with
  | Some sub -> Rx { chan; sub }
  | None ->
      invalid_arg
        (Printf.sprintf
           "Channel.rx: edge %s on %S was not subscribed at admission"
           (Theory.Statement.to_string edge.statement)
           name)

(* ------------------------------------------------------------------ *)
(* Producer side (engine-only by possession of [_ tx]). *)

let publish (Tx chan) ~id payload =
  Dynarray.add_last chan.log (Tuple_cell.pack id payload)

let invalidate (Tx chan) (inv : Invalidation.t) =
  (* Fan out to every subscribed edge whose declared footprint the address
     intersects. Each edge owns its queue, so table order is irrelevant;
     within one edge, delivery order is send order. *)
  Hashtbl.iter
    (fun _ sub ->
      if Invalidation.passes ~footprint:sub.fp inv then
        Queue.push inv sub.pending)
    chan.subs

(* ------------------------------------------------------------------ *)
(* Consumer side: check-on-yield drains. *)

let pull_tuples (Rx r) =
  let len = Dynarray.length r.chan.log in
  let drained =
    List.init (len - r.sub.cursor) (fun k ->
        Tuple_cell.unpack (Dynarray.get r.chan.log (r.sub.cursor + k)))
  in
  r.sub.cursor <- len;
  drained

let pull_invalidations (Rx r) =
  let rec drain acc =
    match Queue.take_opt r.sub.pending with
    | None -> List.rev acc
    | Some inv -> drain (inv :: acc)
  in
  drain []

let footprint (Rx r) = r.sub.fp
