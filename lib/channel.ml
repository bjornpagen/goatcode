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
let covers_address (declared : Ledger.Address.t) (concrete : Ledger.Address.t) =
  match (declared, concrete) with
  | File pattern, File path -> glob_match pattern path
  | Tuple { relation = dr; id = di }, Tuple { relation = cr; id = ci } ->
      String.equal dr cr && (String.equal di any_id || String.equal di ci)
  | Contract a, Contract b -> String.equal a b
  | Resource a, Resource b -> String.equal a b
  | (File _ | Tuple _ | Contract _ | Resource _), _ -> false

(* The one cover judgment, two callers: delivery ([Invalidation.passes])
   and the footprint-escape judge at retire (channel.mli [covers]). *)
let covers ~footprint concrete =
  List.exists
    (fun declared -> covers_address declared concrete)
    (Ledger.Footprint.to_list footprint)

module Invalidation = struct
  type t = {
    address : Ledger.Address.t;
    new_generation : Ledger.Generation.t;
    producer : Ledger.node Id.t;
    delta_ref : Ledger.Delta_ref.t;
  }

  let passes ~footprint t = covers ~footprint t.address
end

(* ------------------------------------------------------------------ *)
(* Channel state.

   One channel's committed-tuple log is shared by its unique writer end and
   every reader end, all obtained by independent registry lookups keyed by
   relation name. The name-keyed table cannot carry the payload type, so
   each log is packed with the payload witness of the admitted relation it
   was opened for ([Theory.Relation.witness], minted once per declaration),
   and [tx]/[rx] recover the type by [Type.Id.provably_equal] against the
   presented relation's own witness. A relation value that merely shares
   the name — a re-declaration at any payload type — refutes the equality
   and is refused at the lookup; the wrongly-typed channel end is
   unconstructible, and no cast exists anywhere in this file. *)

(* One consumer edge's subscription: allocated at [open_all] — before any
   node runs — so deliveries buffer for a consumer that has not started
   (the buffered-socket state; 30-channels.md § pre-opened channels). *)
type sub = {
  fp : Ledger.Footprint.t; (* compiled delivery filter *)
  pending : Invalidation.t Queue.t; (* footprint-filtered, drained at yield *)
  mutable cursor : int; (* committed tuples already drained *)
}

(* One relation's committed-tuple log, witness-packed: the witness is the
   only key that unpacks it back to a typed log. *)
type log = Log : 'a Type.Id.t * ('a Id.t * 'a) Dynarray.t -> log

(* One relation in motion: the committed-tuple log plus every subscribed
   edge, keyed by consuming statement (one edge per statement per relation
   in v0's single-relation bodies). *)
type chan = { log : log; subs : (string, sub) Hashtbl.t }
type registry = { chans : (string, chan) Hashtbl.t }

type 'a tx =
  | Tx of { log : ('a Id.t * 'a) Dynarray.t; subs : (string, sub) Hashtbl.t }

type 'a rx = Rx of { log : ('a Id.t * 'a) Dynarray.t; sub : sub }

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
        {
          log = Log (Theory.Relation.witness r, Dynarray.create ());
          subs = Hashtbl.create 4;
        })
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

(* The witness judgment: the presented relation's own witness against the
   witness the log was opened with. [provably_equal] refines only for the
   very declaration admission saw — a same-named re-declaration, whatever
   its payload type, lands in [None]. *)
let typed_log (type a) (relation : a Theory.Relation.t) chan ~caller :
    (a Id.t * a) Dynarray.t =
  let (Log (witness, log)) = chan.log in
  match Type.Id.provably_equal witness (Theory.Relation.witness relation) with
  | Some Type.Equal -> log
  | None ->
      invalid_arg
        (Printf.sprintf
           "Channel.%s: relation %S is not the declaration this registry was \
            opened for"
           caller
           (Theory.Relation.name relation))

let tx registry relation =
  let chan = find_chan registry (Theory.Relation.name relation) ~caller:"tx" in
  Tx { log = typed_log relation chan ~caller:"tx"; subs = chan.subs }

let rx registry relation ~(edge : Theory.Edge.t) =
  let name = Theory.Relation.name relation in
  if not (String.equal edge.reads name) then
    invalid_arg
      (Printf.sprintf "Channel.rx: edge %s reads %S, not %S"
         (Theory.Statement.to_string edge.statement)
         edge.reads name);
  let chan = find_chan registry name ~caller:"rx" in
  let log = typed_log relation chan ~caller:"rx" in
  match Hashtbl.find_opt chan.subs (Theory.Statement.to_string edge.statement) with
  | Some sub -> Rx { log; sub }
  | None ->
      invalid_arg
        (Printf.sprintf
           "Channel.rx: edge %s on %S was not subscribed at admission"
           (Theory.Statement.to_string edge.statement)
           name)

(* ------------------------------------------------------------------ *)
(* Producer side (engine-only by possession of [_ tx]). *)

let publish (Tx t) ~id payload = Dynarray.add_last t.log (id, payload)

let invalidate (Tx t) (inv : Invalidation.t) =
  (* Fan out to every subscribed edge whose declared footprint the address
     intersects. Each edge owns its queue, so table order is irrelevant;
     within one edge, delivery order is send order. *)
  Hashtbl.iter
    (fun _ sub ->
      if Invalidation.passes ~footprint:sub.fp inv then
        Queue.push inv sub.pending)
    t.subs

(* ------------------------------------------------------------------ *)
(* Consumer side: check-on-yield drains. *)

let pull_tuples (Rx r) =
  let len = Dynarray.length r.log in
  let drained =
    List.init (len - r.sub.cursor) (fun k ->
        Dynarray.get r.log (r.sub.cursor + k))
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
