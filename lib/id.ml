(* Phantom-typed identifiers. The contract is id.mli; the governing docs are
   docs/architecture/10-theory.md (mint/ref slots), 10-theory.md (failure
   surface: agent-invented refs die at the codec boundary), and 30-scheduling.md
   (provisional identity: mint at firing, bind at retirement, die on squash).

   Representation: an id is (realm, ordinal). The wire rendering is
   "realm#ordinal"; since realm names never end in "#<digits>" the encoding
   is injective (the last '#' delimits a decimal ordinal, which contains no
   '#'), so the wire string alone is a faithful key for provenance lookups.
   The phantom parameter has no runtime component — conjuring a ['realm t]
   is free, and the only two sites that do it are [mint] (the engine, which
   owns the realm) and [Registry.resolve] (which has just checked the string
   against mint provenance for exactly that realm). *)

type 'realm t = { realm : string; ordinal : int }

let equal a b = Int.equal a.ordinal b.ordinal && String.equal a.realm b.realm

let compare a b =
  match String.compare a.realm b.realm with
  | 0 -> Int.compare a.ordinal b.ordinal
  | c -> c

let to_string { realm; ordinal } = Printf.sprintf "%s#%d" realm ordinal
let pp fmt id = Format.pp_print_string fmt (to_string id)

module Registry = struct
  type state = Provisional | Committed

  type entry = { realm : string; ordinal : int; mutable state : state }
  (* Provenance of one mint: enough to re-conjure the typed id in [resolve]
     without ever parsing the wire string (there is no of_string, not even
     privately). *)

  type t = {
    entries : (string, entry) Hashtbl.t;
        (* wire string -> mint provenance. Absent = never minted by this
           run, or minted provisionally and dropped by a squash; both are
           [`Unknown_id] at the boundary and neither can ever resolve. *)
    counters : (string, int ref) Hashtbl.t;
        (* realm -> next provisional ordinal. The supply lives in the
           registry, not the minter, so a realm has exactly one id supply
           per run regardless of how many capability handles exist —
           colliding minters for one realm are unconstructible rather than
           checked. Counters never rewind, so a dropped id's string is
           never re-minted. *)
  }

  let create () =
    { entries = Hashtbl.create 64; counters = Hashtbl.create 16 }

  (* Engine-side supply; not in the .mli, reachable only via Minter/mint. *)
  let supply reg ~realm =
    match Hashtbl.find_opt reg.counters realm with
    | Some c -> c
    | None ->
        let c = ref 0 in
        Hashtbl.add reg.counters realm c;
        c

  let record reg ~realm ~ordinal key =
    (* Keys never repeat: the per-realm counter is monotonic and the
       (realm, ordinal) -> string encoding is injective. *)
    Hashtbl.add reg.entries key { realm; ordinal; state = Provisional }

  let resolve (reg : t) ~realm s =
    match Hashtbl.find_opt reg.entries s with
    | Some entry when String.equal entry.realm realm ->
        (* [s] was minted by this run's minter for [realm]; the phantom the
           caller conjures is the one we just checked. *)
        Ok { realm = entry.realm; ordinal = entry.ordinal }
    | Some _ (* minted, but by another realm's minter: a cross-relation ref
                confusion attempted in agent output — same rejection as an
                invented id, and the codec's diagnostic names the expected
                relation. *)
    | None ->
        Error (`Unknown_id s)

  let status reg id =
    match Hashtbl.find_opt reg.entries (to_string id) with
    | None -> None
    | Some { state = Provisional; _ } -> Some `Provisional
    | Some { state = Committed; _ } -> Some `Committed

  let bind reg id =
    match Hashtbl.find_opt reg.entries (to_string id) with
    | Some ({ state = Provisional; _ } as entry) ->
        entry.state <- Committed;
        Ok ()
    | Some { state = Committed; _ } -> Error `Already_bound
    | None ->
        (* Not wire-reachable: [bind] takes a typed id, so the only way here
           is an engine bug (binding a squashed node's id, or an id from a
           different run's registry). Retirement and squash are mutually
           exclusive per node, so this is a protocol violation, not a case. *)
        invalid_arg
          (Printf.sprintf "Id.Registry.bind: %s is not a live id of this run"
             (to_string id))

  let drop_provisional reg ids =
    List.iter
      (fun id ->
        let key = to_string id in
        match Hashtbl.find_opt reg.entries key with
        | Some { state = Provisional; _ } -> Hashtbl.remove reg.entries key
        | Some { state = Committed; _ } ->
            (* A committed id belongs to a retired node; squashing it is an
               engine bug, and forgetting it would orphan committed tuples. *)
            invalid_arg
              (Printf.sprintf
                 "Id.Registry.drop_provisional: %s is already committed" key)
        | None ->
            (* Already dropped (idempotent squash replay) — nothing to do. *)
            ())
      ids
end

module Minter = struct
  type 'realm t = { registry : Registry.t; realm : string }

  let create ~registry ~realm =
    (* Open the realm's supply eagerly: creation, not first mint, is what
       opens the id space (id.mli). *)
    ignore (Registry.supply registry ~realm : int ref);
    { registry; realm }
end

let mint (m : 'realm Minter.t) =
  let c = Registry.supply m.Minter.registry ~realm:m.Minter.realm in
  let ordinal = !c in
  incr c;
  let id = { realm = m.Minter.realm; ordinal } in
  Registry.record m.Minter.registry ~realm:id.realm ~ordinal (to_string id);
  id
