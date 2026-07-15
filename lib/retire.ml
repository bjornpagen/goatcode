(* Retirement: how speculative state becomes committed state, and how
   everything else becomes nothing (docs/architecture/30-scheduling.md
   § retirement order and the landing).

   Git is the storage engine, not a metaphor: the committed tree is a
   branch, retirements are commits (one per node, dependency-ordered,
   message = node provenance), the object database is the blob store, and
   this module is the only writer of the committed branch. The landing is
   built from the ledger — the write set from Store events, the bytes
   from the object database's blobs, never from any tree. Squash is the
   settlement append — no compensating action is representable here;
   dead tree bytes are Frontier.materialize's hygiene. *)

module E = Ledger.Event

(* ------------------------------------------------------------------ *)
(* Process and filesystem helpers: the git boundary.                   *)

let sh_quiet cmd = ignore (Sys.command (cmd ^ " >/dev/null 2>&1"))
let sh_ok cmd = Sys.command (cmd ^ " >/dev/null 2>&1") = 0

let rec mkdirs dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdirs parent;
    try Sys.mkdir dir 0o755 with Sys_error _ -> ()
  end

let write_file path contents =
  mkdirs (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc contents)

(* ------------------------------------------------------------------ *)
(* Generic helpers.                                                    *)

(* Order-preserving dedup: keeps the first occurrence, so every derived
   ordering is replay-stable. *)
let dedup ~eq xs =
  List.rev
    (List.fold_left
       (fun acc x -> if List.exists (eq x) acc then acc else x :: acc)
       [] xs)

let pair_equal (r, i) (r', i') = String.equal r r' && String.equal i i'
let node_matches n = function Some m -> Id.equal n m | None -> false
let events ledger = Ledger.Replay.events ledger

(* ------------------------------------------------------------------ *)

module Committed = struct
  type tuple = {
    relation : string;
    id : string;
    payload : Yojson.Safe.t;
    generation : Ledger.Generation.t;
  }

  module Address_map = Map.Make (struct
    type t = Ledger.Address.t

    let compare = Ledger.Address.compare
  end)

  type entry = {
    gen : Ledger.Generation.t;
    content : Ledger.Content_hash.t option;
        (* [None] = the committed state is a deletion; the address keeps
           its generation but no triple can hold against it *)
    last_delta : Ledger.Delta_ref.t option;
  }

  type t = {
    repo : string;
    branch : string;
    mutable entries : entry Address_map.t;
    mutable tuple_set : tuple list;
    mutable write_log :
      (Ledger.node Id.t * Ledger.Address.t * Ledger.Content_hash.t option)
      list;
        (* every committed write in base coordinates — the content the
           writer's witness proves it derived from ([None] = a blind
           write): the conflict judge's sibling write-sets and the
           [disjoint] law's footprint index. Two writes to one address
           from one base are a clobber by construction; serialized
           writers cannot collide because the later one witnessed the
           earlier landing (50-commit.md § retirement order). *)
  }

  let open_ ~repo ~branch =
    (* The committed branch stays checked out in [repo]; the engine holds
       the only writer lock, so this checkout is uncontended. *)
    if
      not
        (sh_ok
           (Printf.sprintf "git -C %s checkout -q %s" (Filename.quote repo)
              (Filename.quote branch)))
    then
      sh_quiet
        (Printf.sprintf "git -C %s checkout -q -b %s" (Filename.quote repo)
           (Filename.quote branch));
    {
      repo;
      branch;
      entries = Address_map.empty;
      tuple_set = [];
      write_log = [];
    }

  let generation t address =
    Option.map (fun e -> e.gen) (Address_map.find_opt address t.entries)

  (* The commit-point lookup [Witness.holds] judges against: absence is a
     real case, never a sentinel generation. *)
  let state t address =
    match Address_map.find_opt address t.entries with
    | None -> Witness.Committed_state.Absent
    | Some { gen; content = Some content; _ } ->
        Witness.Committed_state.Landed { generation = gen; content }
    | Some { gen; content = None; _ } ->
        Witness.Committed_state.Deleted { generation = gen }

  let tuples t = t.tuple_set

  (* Run inputs are facts, not work product: a seed enters committed state
     at run open, at the primordial generation, with the same recorded
     content a retired head tuple would carry — so where-filters, law
     universes, and consumer reads judge seeds exactly like retired
     tuples. No node wrote it: the write log (the disjoint law's index)
     records nothing, and retirement remains the only writer of
     node-produced committed state
     (docs/architecture/70-api.md § running). *)
  let seed t ~relation ~id ~payload =
    let address = Ledger.Address.Tuple { relation; id } in
    t.entries <-
      Address_map.add address
        {
          gen = Ledger.Generation.zero;
          content =
            Some (Ledger.Content_hash.of_string (Yojson.Safe.to_string payload));
          last_delta = None;
        }
        t.entries;
    t.tuple_set <-
      t.tuple_set
      @ [ { relation; id; payload; generation = Ledger.Generation.zero } ]

  (* -------- internal surface (hidden by retire.mli) -------- *)

  let last_delta t address =
    Option.bind (Address_map.find_opt address t.entries) (fun e ->
        e.last_delta)

  let write_log t = t.write_log
  let abs_path t rel = Filename.concat t.repo rel
  let root t = t.repo
  let set_tuples t ts = t.tuple_set <- ts

  (* Advance an address's generation (law 2 already judged by the caller:
     only semantically-changed addresses reach here). A fresh address
     starts at [zero] — landing exactly what a snooper witnessed leaves
     that witness holding (falsifier F7); [content] is what makes the
     landing distinguishable from the pre-commit state a snooper of a
     DIFFERENT draft witnessed there. [base] is the writer's read point —
     the disjoint law's coordinate. [floor] is the ledger-recovered
     coordinate ([recovered_floor]): when the map is amnesiac about the
     address — boot after a crash opens it empty — the landing advances
     from the floor, never from zero, so no coordinate the ledger already
     published can be retreated below (falsifier FL4). *)
  let advance t ~node ~address ~fresh ~floor ~content ~base ~delta =
    let gen =
      match Address_map.find_opt address t.entries with
      | Some e -> Ledger.Generation.next e.gen
      | None -> (
          match floor with
          | Some g -> Ledger.Generation.next g
          | None ->
              if fresh then Ledger.Generation.zero
              else Ledger.Generation.next Ledger.Generation.zero)
    in
    t.entries <-
      Address_map.add address { gen; content; last_delta = delta } t.entries;
    t.write_log <- t.write_log @ [ (node, address, base) ];
    gen

  (* Byte-exact command output: captured whole, never line-split. *)
  let sh_bytes cmd =
    let tmp = Filename.temp_file "goatcode_retire" ".out" in
    let status =
      Sys.command
        (Printf.sprintf "%s >%s 2>/dev/null" cmd (Filename.quote tmp))
    in
    let content =
      if status = 0 then
        Some (In_channel.with_open_bin tmp In_channel.input_all)
      else None
    in
    (try Sys.remove tmp with Sys_error _ -> ());
    content

  (* One landed blob's bytes, pulled out of the object database — the
     retire step's read of record (20-medium.md § the blob store: readers
     of the oid include the retire step's landing). [None] = the object
     store does not hold the named oid — unreachable through the tool
     path, which writes the blob before any event names it. *)
  let blob_content t oid =
    sh_bytes
      (Printf.sprintf "git -C %s cat-file blob %s" (Filename.quote t.repo)
         (Filename.quote oid))

  (* The committed prior of one path — the branch tip's bytes, the law-2
     comparand. Never the checkout: the working tree is writable by
     neighbors under the flat org, so tree bytes carry no authority over
     what is committed (30-scheduling.md § one ref: the committed state
     is ledger coordinates plus git objects). [None] = the branch does
     not hold the path (a fresh address), or no branch exists (the bare
     committed mode the unit suites run on). *)
  let branch_content t rel =
    sh_bytes
      (Printf.sprintf "git -C %s show %s" (Filename.quote t.repo)
         (Filename.quote (t.branch ^ ":" ^ rel)))

  (* The commit's tree entry for one landed path comes straight from the
     store event's oid ([update-index --cacheinfo]), never from
     working-tree bytes — the pathspec-limited commit built from the
     ledger's blobs (30-scheduling.md § retirement order and the landing,
     step 3). The checkout file is written separately, as cache fill; a
     neighbor's later in-flight bytes on the same path can dirty the
     checkout, never the commit. *)
  let stage_blob t ~rel_path ~oid =
    sh_quiet
      (Printf.sprintf "git -C %s update-index --add --cacheinfo %s"
         (Filename.quote t.repo)
         (Filename.quote ("100644," ^ oid ^ "," ^ rel_path)))

  let stage_removal t ~rel_path =
    sh_quiet
      (Printf.sprintf "git -C %s update-index --force-remove -- %s"
         (Filename.quote t.repo) (Filename.quote rel_path))

  (* One retirement = one commit on the committed branch, message = node
     provenance (50-commit.md § durability boundary). *)
  let commit_retirement t ~message =
    sh_quiet
      (Printf.sprintf "git -C %s checkout -q %s" (Filename.quote t.repo)
         (Filename.quote t.branch));
    sh_quiet
      (Printf.sprintf
         "git -C %s -c user.name=goatcode -c user.email=goatcode@localhost \
          commit -q --allow-empty -m %s"
         (Filename.quote t.repo) (Filename.quote message))
end

(* The committed coordinate survives as ledger state (30-scheduling.md
   § one ref): every non-fresh landing published its new generation as an
   Invalidation_sent event, so the highest one recorded for an address is
   a floor no later landing may retreat below. In-run the committed map
   carries the exact coordinate and this floor is redundant; at boot after
   a crash the map opens empty, and the floor is what keeps the reissued
   producer's landing strictly above everything the ledger already
   published (falsifier FL4 — monotonicity is judged over the ledger
   because the tree carries no authority to retreat). *)
let recovered_floor ledger address =
  List.fold_left
    (fun acc (e : E.t) ->
      match e.kind with
      | E.Invalidation_sent { address = a; new_generation }
        when Ledger.Address.equal a address -> (
          match acc with
          | Some g when Ledger.Generation.compare g new_generation >= 0 -> acc
          | Some _ | None -> Some new_generation)
      | _ -> acc)
    None (events ledger)

module Frontier = struct
  (* The ledger's derived view of every address's live top, composed over
     committed state (20-medium.md § validity is a ledger coordinate).
     The working tree is a cache of this view; bytes whose producing
     store event is dead have no live coordinate and are garbage nothing
     can witness into committed state. *)

  type in_flight = {
    writer : Ledger.node Id.t;
    content : Ledger.Content_hash.t;
    base : Ledger.Content_hash.t option;
  }

  type top =
    | Committed of Witness.Committed_state.t
    | In_flight of in_flight

  (* An in-flight top keeps its blob oid so [materialize] can pull the
     draft's bytes from the object database without re-scanning events. *)
  type draft = {
    writer : Ledger.node Id.t;
    content : Ledger.Content_hash.t;
    base : Ledger.Content_hash.t option;
    oid : string;
  }

  type t = {
    ledger : Ledger.t;
    committed : Committed.t;
    drafts : (Ledger.Address.t * draft) list;
        (* the live in-flight top per address, snapshot at derivation *)
    swept : string list;
        (* every file path any store event ever named — dead or live —
           the address universe [materialize] converges *)
  }

  let of_ledger ledger ~committed =
    let evs = events ledger in
    let settled =
      List.filter_map
        (fun (e : E.t) ->
          match e.kind with
          | E.Settled s -> Option.map (fun n -> (n, s)) e.node
          | _ -> None)
        evs
    in
    (* Liveness is a derived judgment, not a second supply: a store event
       is live iff its node is unsettled or retired. The squash settlement
       is the one appended fact; every coordinate under a squashed or
       faulted node is provenance-dead by derivation — no per-event kill
       marks, no tombstones (20-medium.md § validity is a ledger
       coordinate). *)
    let liveness n =
      match List.find_opt (fun (m, _) -> Id.equal m n) settled with
      | None -> `In_flight
      | Some (_, Ledger.Settlement.Retired) -> `Retired
      | Some (_, (Ledger.Settlement.Faulted _ | Ledger.Settlement.Squashed _))
        ->
          `Dead
    in
    let base_of writer address =
      Witness.observed_content (Witness.observed ledger ~node:writer) address
    in
    let drafts, swept =
      List.fold_left
        (fun (drafts, swept) (e : E.t) ->
          match (e.kind, e.node) with
          | E.Store { address; delta; _ }, Some n -> (
              let swept =
                match address with
                | Ledger.Address.File rel -> rel :: swept
                | Ledger.Address.Tuple _ | Ledger.Address.Contract _
                | Ledger.Address.Resource _ ->
                    swept
              in
              let drop drafts =
                List.filter
                  (fun (a, _) -> not (Ledger.Address.equal a address))
                  drafts
              in
              match liveness n with
              | `Dead ->
                  (* provenance-dead: the event moves no top *)
                  (drafts, swept)
              | `Retired ->
                  (* subsumed: the landing is committed state, so the top
                     falls back to the committed half *)
                  (drop drafts, swept)
              | `In_flight -> (
                  match Ledger.Delta_ref.oid delta with
                  | Some oid -> (
                      match Committed.blob_content committed oid with
                      | None ->
                          (* the object store does not hold the named oid —
                             unreachable through the tool path, which
                             writes the blob before the event *)
                          (drafts, swept)
                      | Some bytes ->
                          ( drop drafts
                            @ [
                                ( address,
                                  {
                                    writer = n;
                                    content =
                                      Ledger.Content_hash.of_string bytes;
                                    base = base_of n address;
                                    oid;
                                  } );
                              ],
                            swept ))
                  | None ->
                      (* a draft deletion: byte-less, and existence (or
                         absence) of uncommitted state is not a witnessable
                         claim in v0 — the top stays the committed prior
                         until the deletion lands at retire (20-medium.md
                         § event taxonomy) *)
                      (drop drafts, swept)))
          | _ -> (drafts, swept))
        ([], []) evs
    in
    { ledger; committed; drafts; swept = List.sort_uniq String.compare swept }

  (* The committed half of one address's top. In-run {!Committed.state}
     carries the exact coordinate; when it answers [Absent] the one ref's
     tip and the ledger's invalidation trail are consulted — the committed
     state survives as ledger coordinates plus git objects
     (30-scheduling.md § one ref), so a boot-opened (amnesiac) map still
     yields the true top, and a seeded tree file no landing ever moved
     tops as its own committed bytes rather than [Absent]. *)
  let committed_state t address =
    match Committed.state t.committed address with
    | Witness.Committed_state.Absent -> (
        match address with
        | Ledger.Address.File rel -> (
            match Committed.branch_content t.committed rel with
            | Some bytes ->
                Witness.Committed_state.Landed
                  {
                    generation =
                      Option.value
                        (recovered_floor t.ledger address)
                        ~default:Ledger.Generation.zero;
                    content = Ledger.Content_hash.of_string bytes;
                  }
            | None -> (
                match recovered_floor t.ledger address with
                | Some generation ->
                    (* the branch does not hold the path but the address
                       has a published coordinate: a committed deletion *)
                    Witness.Committed_state.Deleted { generation }
                | None -> Witness.Committed_state.Absent))
        | Ledger.Address.Tuple _ | Ledger.Address.Contract _
        | Ledger.Address.Resource _ ->
            Witness.Committed_state.Absent)
    | state -> state

  let top t address =
    match
      List.find_opt (fun (a, _) -> Ledger.Address.equal a address) t.drafts
    with
    | Some (_, d) ->
        In_flight { writer = d.writer; content = d.content; base = d.base }
    | None -> Committed (committed_state t address)

  (* The gate snapshot's universe (30-scheduling.md § gates on the shared
     tree): every live in-flight top, in derivation order — deterministic,
     so the snapshot's hypothesis mints replay stably. *)
  let in_flight_tops t =
    List.map
      (fun (address, (d : draft)) ->
        (address, { writer = d.writer; content = d.content; base = d.base }))
      t.drafts

  (* Converge the tree to the frontier: write each address's live top,
     delete files whose top is Absent or Deleted. Checkout semantics —
     no coordinate moves, nothing appends; run at boot, after a crash, and
     as the hygiene sweep (20-medium.md § squash without isolation:
     overwrite-on-reissue primary, this lazy convergence the backstop).
     Byte-compare before every write keeps the converged tree untouched —
     idempotence observable, not asserted. *)
  let materialize t ~repo =
    List.iter
      (fun rel ->
        let target = Filename.concat repo rel in
        let current =
          if Sys.file_exists target then
            Some (In_channel.with_open_bin target In_channel.input_all)
          else None
        in
        let converge bytes =
          match bytes with
          | None ->
              (* no byte source (the bare committed mode the unit suites
                 run on): the tree keeps its cache fill *)
              ()
          | Some b ->
              if not (match current with Some c -> String.equal c b | None -> false)
              then write_file target b
        in
        let address = Ledger.Address.File rel in
        match
          List.find_opt (fun (a, _) -> Ledger.Address.equal a address) t.drafts
        with
        | Some (_, d) ->
            (* a live draft IS the top: hygiene never clobbers in-flight
               work with committed content *)
            converge (Committed.blob_content t.committed d.oid)
        | None -> (
            match committed_state t address with
            | Witness.Committed_state.Landed _ ->
                (* committed bytes come off the one ref's tip — the tree
                   carries no authority, so the branch is the source
                   (30-scheduling.md § one ref) *)
                converge (Committed.branch_content t.committed rel)
            | Witness.Committed_state.Absent
            | Witness.Committed_state.Deleted _ ->
                if Option.is_some current then
                  try Sys.remove target with Sys_error _ -> ()))
      t.swept
end

type generation_moved = {
  address : Ledger.Address.t;
  witnessed : Ledger.Generation.t;
  current : Ledger.Generation.t;
  delta_ref : Ledger.Delta_ref.t;
}

module Conflict = struct
  type t = {
    node : Ledger.node Id.t;
    sibling : Ledger.node Id.t;
    overlap : Ledger.Footprint.t;
  }

  type route =
    | Serialize of { loser : Ledger.node Id.t; winner : Ledger.node Id.t }
    | Merge of { merge_fn : string }
end

module Merge_registry = struct
  (* Policy reified as data: (address-class glob, merge-fn name) rows,
     registered at theory accept, consulted by the conflict judge. v0 ships
     empty — every conflict serializes (50-commit.md § OPEN items). *)
  type t = (string * string) list

  let empty = []
  let register t ~address_class ~merge_fn = (address_class, merge_fn) :: t

  let key_of_address = function
    | Ledger.Address.File path -> path
    | Ledger.Address.Tuple { relation; id } -> relation ^ "/" ^ id
    | Ledger.Address.Contract name -> name
    | Ledger.Address.Resource resource -> resource

  (* Path-pattern match: '*' within a segment, '**' across segments. *)
  let glob_match pattern subject =
    let np = String.length pattern and ns = String.length subject in
    let rec go p s =
      if p = np then s = ns
      else
        match pattern.[p] with
        | '*' when p + 1 < np && pattern.[p + 1] = '*' ->
            let rec try_from i = i <= ns && (go (p + 2) i || try_from (i + 1)) in
            try_from s
        | '*' ->
            let rec try_from i =
              (i <= ns && go (p + 1) i)
              || (i < ns && subject.[i] <> '/' && try_from (i + 1))
            in
            try_from s
        | c -> s < ns && subject.[s] = c && go (p + 1) (s + 1)
    in
    go 0 0

  let lookup t address =
    let key = key_of_address address in
    List.find_map
      (fun (cls, fn) -> if glob_match cls key then Some fn else None)
      t
end

type rejection =
  | Witness_moved of generation_moved list
  | Undischarged of Ledger.hypothesis Id.t list
  | Conflict of Conflict.t

type head_tuple = { relation : string; id : string; payload : Yojson.Safe.t }

(* ------------------------------------------------------------------ *)
(* Ledger scans (the Witness_index / Replay readers, specialized).      *)

let minted_of ledger node =
  List.concat_map
    (fun (e : E.t) ->
      match e.kind with
      | E.Fired { minted; _ } when node_matches node e.node -> minted
      | _ -> [])
    (events ledger)

(* Undischarged hypotheses block retirement (40-scheduling.md § read-time
   binding): carried = the node's own takes plus everything its firing
   provenance inherited; discharged = the refresher's discharge events. *)
let undischarged_hypotheses ledger node =
  let evs = events ledger in
  let carried =
    List.concat_map
      (fun (e : E.t) ->
        match e.kind with
        | E.Fired { provenance; _ } when node_matches node e.node ->
            provenance.Ledger.Provenance.hypotheses
        | E.Hypothesis_taken { hypothesis; _ } when node_matches node e.node ->
            [ hypothesis ]
        | _ -> [])
      evs
  in
  let discharged =
    List.filter_map
      (fun (e : E.t) ->
        match e.kind with
        | E.Hypothesis_discharged { hypothesis } -> Some hypothesis
        | _ -> None)
      evs
  in
  dedup ~eq:Id.equal carried
  |> List.filter (fun h -> not (List.exists (Id.equal h) discharged))

(* The fallback source of a [Delta_ref.t] when committal recorded none for
   the address (hand-laid ledgers, tuple addresses): the store event that
   moved it (every tool call is an event, 30-channels.md § the ledger). *)
let last_store_delta ledger address =
  List.fold_left
    (fun acc (e : E.t) ->
      match e.kind with
      | E.Store { address = a; delta; _ } when Ledger.Address.equal a address
        ->
          Some delta
      | _ -> acc)
    None (events ledger)

(* ------------------------------------------------------------------ *)

let dependency_order ledger ~candidates =
  let evs = events ledger in
  let minted_by =
    List.concat_map
      (fun (e : E.t) ->
        match (e.kind, e.node) with
        | E.Fired { minted; _ }, Some n -> List.map (fun m -> (m, n)) minted
        | _ -> [])
      evs
  in
  let consumed_of n =
    List.concat_map
      (fun (e : E.t) ->
        match e.kind with
        | E.Fired { provenance; _ } when node_matches n e.node ->
            provenance.Ledger.Provenance.consumed
        | _ -> [])
      evs
  in
  let producers n =
    List.filter_map
      (fun consumed ->
        List.find_map
          (fun (pair, m) -> if pair_equal pair consumed then Some m else None)
          minted_by)
      (consumed_of n)
  in
  (* Stable layered Kahn over the candidate set only — producers outside it
     have already retired. Input order breaks ties, so the order is
     replay-stable (F14's density depends on it). *)
  let rec order acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ -> (
        let ready, blocked =
          List.partition
            (fun n ->
              List.for_all
                (fun p ->
                  Id.equal p n || not (List.exists (Id.equal p) remaining))
                (producers n))
            remaining
        in
        match ready with
        | [] ->
            (* unreachable under weak acyclicity (10-theory.md
               § termination); preserve input order rather than spin *)
            List.rev acc @ remaining
        | _ :: _ -> order (List.rev ready @ acc) blocked)
  in
  order [] candidates

(* ------------------------------------------------------------------ *)
(* The four-phase retire step.                                          *)

let moves_of ~committed ~ledger stales =
  List.filter_map
    (fun (s : Witness.stale) ->
      match s.current with
      | Witness.Committed_state.Absent ->
          (* nothing landed at the address: no generation to have moved to
             and no delta for a consumer to pull *)
          None
      | Witness.Committed_state.Landed { generation; _ }
      | Witness.Committed_state.Deleted { generation } ->
          let delta =
            match Committed.last_delta committed s.address with
            | Some d -> Some d
            | None -> last_store_delta ledger s.address
          in
          Option.map
            (fun delta_ref ->
              {
                address = s.address;
                witnessed = s.witnessed;
                current = generation;
                delta_ref;
              })
            delta)
    stales

(* Write-set intersection against siblings' committed write-sets: the
   [disjoint] EGD's violation, memory disambiguation mechanized
   (30-channels.md § mechanized witnesses). An overlapping address the node
   witnessed at its current committed generation is not a conflict — the
   node already serialized behind that sibling and the held witness (phase
   1) is the proof. An address with a declared merge function routes to
   merge instead of rejecting (empty in v0, so every conflict serializes). *)
let conflict_judgment ~committed ~ledger ~merges ~node ~witness =
  let my_writes =
    Ledger.Footprint.to_list (Ledger.Witness_index.writes ledger node)
  in
  let witnessed = Witness.addresses witness in
  let sibling_writes =
    List.fold_left
      (fun acc (n, address, _base) ->
        if Id.equal n node then acc
        else
          let rec add = function
            | [] -> [ (n, [ address ]) ]
            | (m, addrs) :: rest when Id.equal m n ->
                (m, address :: addrs) :: rest
            | row :: rest -> row :: add rest
          in
          add acc)
      []
      (Committed.write_log committed)
  in
  List.find_map
    (fun (sibling, addrs) ->
      let overlapping =
        List.filter
          (fun a ->
            List.exists (Ledger.Address.equal a) addrs
            && (not (Ledger.Footprint.mem witnessed a))
            && Option.is_none (Merge_registry.lookup merges a))
          my_writes
      in
      match overlapping with
      | [] -> None
      | overlap ->
          Some
            { Conflict.node; sibling; overlap = Ledger.Footprint.of_list overlap })
    sibling_writes

(* The node's file write set, from its Store events: the last store per
   address wins, in first-store order. Stores coalesce in the event
   stream exactly as they did in the buffer — twelve edits to one file
   forward as one landing; the buffer itself is never read at retire
   (README.md § design of record vs shipped engine, row 2). *)
let write_set ledger node =
  List.fold_left
    (fun acc (e : E.t) ->
      match e.kind with
      | E.Store { address = Ledger.Address.File rel; delta; _ }
        when node_matches node e.node ->
          let rec put = function
            | [] -> [ (rel, delta) ]
            | (r, _) :: rest when String.equal r rel -> (r, delta) :: rest
            | row :: rest -> row :: put rest
          in
          put acc
      | _ -> acc)
    [] (events ledger)

(* Phase 3a: the landing. The node's write set comes from its Store
   events, its bytes from the ledger's blobs, never from the tree
   (30-scheduling.md § retirement order and the landing, step 3): a blob
   ref's content is pulled out of the object database; a locator ref at a
   file address is the byte-less movement — a deletion, derived from the
   event stream. Generations advance only on semantic change: a last
   store byte-identical to the committed content advances nothing and
   fires nothing — the free commit, falsifier F7. Every advance records
   the landed content (what a later witness is judged against) and the
   write's base (what the disjoint law judges). *)
let apply_stores ~committed ~ledger ~node ~witness =
  let advanced =
    List.filter_map
      (fun (rel_path, delta) ->
        let repo_file = Committed.abs_path committed rel_path in
        let prior = Committed.branch_content committed rel_path in
        let address = Ledger.Address.File rel_path in
        let base = Witness.observed_content witness address in
        let floor = recovered_floor ledger address in
        match Ledger.Delta_ref.oid delta with
        | Some oid -> (
            match Committed.blob_content committed oid with
            | None ->
                (* the object store does not hold the named oid: nothing
                   can land — unreachable through the tool path, which
                   writes the blob before the event *)
                None
            | Some landed -> (
                match prior with
                | Some p when String.equal landed p ->
                    (* byte-null landing: cancellation, advances nothing
                       (law 2) *)
                    None
                | _ ->
                    (* checkout write = cache fill; the commit's entry is
                       the oid, staged below *)
                    write_file repo_file landed;
                    Committed.stage_blob committed ~rel_path ~oid;
                    let fresh =
                      Option.is_none prior && Option.is_none floor
                    in
                    let gen =
                      Committed.advance committed ~node ~address ~fresh ~floor
                        ~content:(Some (Ledger.Content_hash.of_string landed))
                        ~base ~delta:(Some delta)
                    in
                    Some (address, gen, fresh)))
        | None -> (
            match prior with
            | None -> None
            | Some _ ->
                (try Sys.remove repo_file with Sys_error _ -> ());
                Committed.stage_removal committed ~rel_path;
                let gen =
                  Committed.advance committed ~node ~address ~fresh:false
                    ~floor ~content:None ~base ~delta:(Some delta)
                in
                Some (address, gen, false)))
      (write_set ledger node)
  in
  (* The invalidation record: only a moved generation fires one; fresh
     addresses have no witnesses to invalidate. Channel fan-out belongs to
     the run layer (channel.mli § producer side); the ledger event is the
     durable fact it fans out from. *)
  List.iter
    (fun (address, gen, fresh) ->
      if not fresh then
        ignore
          (Ledger.append ledger ~node
             (E.Invalidation_sent { address; new_generation = gen })))
    advanced;
  Committed.commit_retirement committed
    ~message:("retire " ^ Id.to_string node)

(* Phase 3b: head tuples insert. A payload identical to the committed one
   is the tuple-shaped free commit: no generation advance, no event. The
   recorded content is the payload's serialization hash — the same hash the
   engine's operand reads observe, so a witness of the tuple compares
   against exactly what landed. *)
let insert_heads ~committed ~ledger ~node ~witness ~heads =
  List.iter
    (fun (h : head_tuple) ->
      let address = Ledger.Address.Tuple { relation = h.relation; id = h.id } in
      let existing =
        List.find_opt
          (fun (t : Committed.tuple) ->
            String.equal t.Committed.relation h.relation
            && String.equal t.Committed.id h.id)
          (Committed.tuples committed)
      in
      match existing with
      | Some t when Yojson.Safe.equal t.Committed.payload h.payload -> ()
      | _ ->
          let floor = recovered_floor ledger address in
          let fresh = Option.is_none existing && Option.is_none floor in
          let gen =
            Committed.advance committed ~node ~address ~fresh ~floor
              ~content:
                (Some
                   (Ledger.Content_hash.of_string
                      (Yojson.Safe.to_string h.payload)))
              ~base:(Witness.observed_content witness address)
              ~delta:None
          in
          let tuple =
            {
              Committed.relation = h.relation;
              id = h.id;
              payload = h.payload;
              generation = gen;
            }
          in
          let rest =
            List.filter
              (fun (t : Committed.tuple) ->
                not
                  (String.equal t.Committed.relation h.relation
                  && String.equal t.Committed.id h.id))
              (Committed.tuples committed)
          in
          Committed.set_tuples committed (rest @ [ tuple ]);
          if not fresh then
            ignore
              (Ledger.append ledger ~node
                 (E.Invalidation_sent { address; new_generation = gen })))
    heads

(* Phase 3c: provisional ids bind, in retirement order — dense,
   replay-stable committed id space (falsifier F14). *)
let bind_provisional ~registry ~ledger ~node ~heads =
  let pairs =
    dedup ~eq:pair_equal
      (minted_of ledger node
      @ List.map (fun (h : head_tuple) -> (h.relation, h.id)) heads)
  in
  List.iter
    (fun (relation, id) ->
      match Id.Registry.resolve registry ~realm:relation id with
      | Ok minted -> (
          match Id.Registry.bind registry minted with
          | Ok () | Error `Already_bound -> ())
      | Error (`Unknown_id _) ->
          (* heads are codec-proven, so their ids resolved once already;
             an unknown pair here is a foreign realm's echo — not ours to
             bind *)
          ())
    pairs

let step ~committed ~ledger ~registry ~merges ~node ~witness ~heads =
  (* (1) discharge check: hypotheses first, then the witness (law 3). *)
  match undischarged_hypotheses ledger node with
  | _ :: _ as undischarged -> Error (Undischarged undischarged)
  | [] -> (
      match Witness.holds witness ~committed:(Committed.state committed) with
      | Error stales -> Error (Witness_moved (moves_of ~committed ~ledger stales))
      | Ok () -> (
          (* (2) conflict judgment *)
          match conflict_judgment ~committed ~ledger ~merges ~node ~witness with
          | Some conflict -> Error (Conflict conflict)
          | None ->
              (* (3) the landing *)
              apply_stores ~committed ~ledger ~node ~witness;
              insert_heads ~committed ~ledger ~node ~witness ~heads;
              bind_provisional ~registry ~ledger ~node ~heads;
              (* (4) ledger seal: timings are derived by Telemetry from
                 event timestamps; the settlement is the closing fact *)
              ignore
                (Ledger.append ledger ~node
                   (E.Settled Ledger.Settlement.Retired));
              Ok ()))

(* ------------------------------------------------------------------ *)
(* Squash: the provenance walk (falsifier F3 — exactly the subtree).    *)

let squash_set ledger ~cause =
  let evs = events ledger in
  let fired =
    List.filter_map
      (fun (e : E.t) ->
        match e.kind with
        | E.Fired { provenance; minted } ->
            Option.map (fun n -> (n, provenance, minted)) e.node
        | _ -> None)
      evs
  in
  let taken =
    List.filter_map
      (fun (e : E.t) ->
        match e.kind with
        | E.Hypothesis_taken { hypothesis; source; _ } ->
            Option.map (fun n -> (n, hypothesis, source)) e.node
        | _ -> None)
      evs
  in
  let already_settled =
    List.filter_map
      (fun (e : E.t) ->
        match e.kind with E.Settled _ -> e.node | _ -> None)
      evs
  in
  let nodes_in_order = dedup ~eq:Id.equal (List.map (fun (n, _, _) -> n) fired) in
  let unsettled n = not (List.exists (Id.equal n) already_settled) in
  (* A node carries a hypothesis if its firing provenance inherited it or
     it took it itself. *)
  let carries n h =
    List.exists
      (fun (m, (p : Ledger.Provenance.t), _) ->
        Id.equal m n && List.exists (Id.equal h) p.hypotheses)
      fired
    || List.exists (fun (m, h', _) -> Id.equal m n && Id.equal h h') taken
  in
  let minted_pairs n =
    List.concat_map
      (fun (m, _, minted) -> if Id.equal m n then minted else [])
      fired
  in
  let consumed_pairs n =
    List.concat_map
      (fun (m, (p : Ledger.Provenance.t), _) ->
        if Id.equal m n then p.consumed else [])
      fired
  in
  let hyps_taken_by n =
    List.filter_map (fun (m, h, _) -> if Id.equal m n then Some h else None) taken
  in
  (* Derivation edges, all from provenance: consumed a tuple the producer
     minted, snooped the producer's store buffer (hypothesis source), or
     inherited a hypothesis the producer took. *)
  let depends_on ~producer n =
    (not (Id.equal producer n))
    && (List.exists
          (fun c -> List.exists (pair_equal c) (minted_pairs producer))
          (consumed_pairs n)
       || List.exists
            (fun (m, _, source) ->
              (* A snooped store-buffer read is a provenance edge
                 (30-channels.md § store-to-load forwarding). The engine's
                 dispatch path records the source as
                 "store-buffer:<producer id>" (chase.ml [source_label]);
                 hand-laid ledgers may record the bare producer id. Both
                 spell the same edge. *)
              Id.equal m n
              && (String.equal source (Id.to_string producer)
                 || String.equal source
                      ("store-buffer:" ^ Id.to_string producer)))
            taken
       || List.exists (fun h -> carries n h) (hyps_taken_by producer))
  in
  let seed =
    match cause with
    | Ledger.Squash_cause.Dead_hypothesis h ->
        List.filter (fun n -> carries n h) nodes_in_order
    | Ledger.Squash_cause.Upstream_fault upstream
    | Ledger.Squash_cause.Upstream_squash upstream ->
        (* the upstream node settles as its own fault/squash; its
           derivation subtree is what squashes here *)
        List.filter (fun n -> depends_on ~producer:upstream n) nodes_in_order
    | Ledger.Squash_cause.Reissue_loser | Ledger.Squash_cause.No_producer ->
        (* single-node settlements: the loser (or starved read) settles
           with this cause and its dependents walk under [Upstream_squash]
           of that node — these causes seed no subtree of their own *)
        []
    | Ledger.Squash_cause.Operator_abort -> nodes_in_order
  in
  let rec close set =
    let grow =
      List.filter
        (fun n ->
          (not (List.exists (Id.equal n) set))
          && List.exists (fun producer -> depends_on ~producer n) set)
        nodes_in_order
    in
    match grow with [] -> set | _ :: _ -> close (set @ grow)
  in
  let closed = close seed in
  (* Emit in first-fired ledger order (deterministic), already-settled
     nodes excluded: siblings retire undisturbed. *)
  nodes_in_order
  |> List.filter (fun n -> List.exists (Id.equal n) closed)
  |> List.filter unsettled

let squash ~ledger ~registry ~cause =
  let doomed = squash_set ledger ~cause in
  (* drop the subtree's provisional ids; nothing renumbers *)
  let pairs =
    dedup ~eq:pair_equal (List.concat_map (fun n -> minted_of ledger n) doomed)
  in
  let ids =
    List.filter_map
      (fun (relation, id) ->
        match Id.Registry.resolve registry ~realm:relation id with
        | Ok minted -> Some minted
        | Error (`Unknown_id _) -> None)
      pairs
  in
  Id.Registry.drop_provisional registry ids;
  (* settle each node exactly once, with the cause chain *)
  List.iter
    (fun n ->
      ignore
        (Ledger.append ledger ~node:n
           (E.Settled (Ledger.Settlement.Squashed cause))))
    doomed

(* ------------------------------------------------------------------ *)
(* Final-state judgment: once, at quiescence, against the merged final   *)
(* tuple set and the footprint index (50-commit.md § final-state         *)
(* judgment).                                                            *)

let field_string (payload : Yojson.Safe.t) field =
  match payload with
  | `Assoc kvs -> (
      match List.assoc_opt field kvs with
      | Some (`String s) -> Some s
      | Some (`Int i) -> Some (string_of_int i)
      | _ -> None)
  | _ -> None

let judge_count ~theory ~tuples ~name ~over ~group_by ~bound =
  let counted =
    List.filter
      (fun (t : Committed.tuple) -> String.equal t.Committed.relation over)
      tuples
  in
  let referent_of (t : Committed.tuple) =
    field_string t.Committed.payload group_by
  in
  (* The group universe: every tuple of the ref target relation — a
     referent with zero counted tuples must still be judged (a quorum
     shortfall of zero is the loudest shortfall). *)
  let target =
    Option.bind (Theory.slots theory ~relation:over) (fun slots ->
        List.find_map
          (fun (s : Theory.Slot.t) ->
            match s.kind with
            | Theory.Slot.Ref target when String.equal s.field group_by ->
                Some target
            | _ -> None)
          slots)
  in
  let universe =
    match target with
    | Some target_relation ->
        List.filter_map
          (fun (t : Committed.tuple) ->
            if String.equal t.Committed.relation target_relation then
              Some t.Committed.id
            else None)
          tuples
    | None -> List.filter_map referent_of counted
  in
  let within n =
    match bound with
    | Theory.Law.At_least k -> n >= k
    | Theory.Law.At_most k -> n <= k
    | Theory.Law.Exactly k -> n = k
  in
  let offenders =
    List.filter_map
      (fun id ->
        let n =
          List.length
            (List.filter
               (fun t ->
                 match referent_of t with
                 | Some r -> String.equal r id
                 | None -> false)
               counted)
        in
        if within n then None
        else
          Some
            (match target with
            | Some relation -> relation ^ "/" ^ id
            | None -> id))
      (dedup ~eq:String.equal universe)
  in
  {
    Theory.Law.law = name;
    satisfied = (match offenders with [] -> true | _ :: _ -> false);
    offenders;
  }

let judge_disjoint ~committed ~name =
  (* No two nodes commit writes to one address from one base: judged
     against the footprint index the retire steps recorded, in base
     coordinates. The base is the content the writer's witness proves it
     derived from ([None] = a blind write), so the clobber — two writers
     neither of whom saw the other's landing — is pair equality, while
     serialized writers cannot collide: the later one's base IS the
     earlier one's landing. This is the backstop behind the per-retire
     conflict judgment, which sees only observed store footprints. *)
  let base_equal a b =
    match (a, b) with
    | None, None -> true
    | Some x, Some y -> Ledger.Content_hash.equal x y
    | None, Some _ | Some _, None -> false
  in
  let write_log = Committed.write_log committed in
  let offenders =
    List.filter_map
      (fun (n, address, base) ->
        if
          List.exists
            (fun (m, address', base') ->
              (not (Id.equal n m))
              && Ledger.Address.equal address address'
              && base_equal base base')
            write_log
        then Some (Ledger.Address.to_string address)
        else None)
      write_log
    |> dedup ~eq:String.equal
  in
  {
    Theory.Law.law = name;
    satisfied = (match offenders with [] -> true | _ :: _ -> false);
    offenders;
  }

let judge ~theory ~committed ~ledger =
  let tuples = Committed.tuples committed in
  let verdicts =
    List.map
      (fun law ->
        match law with
        | Theory.Law.Count { name; over; group_by; bound } ->
            judge_count ~theory ~tuples ~name ~over ~group_by ~bound
        | Theory.Law.Disjoint_writes { name } -> judge_disjoint ~committed ~name)
      (Theory.laws theory)
  in
  (* Verdicts land on the settled map and in the ledger as run-level
     events — never as faults of any node. *)
  List.iter
    (fun (v : Theory.Law.verdict) ->
      ignore
        (Ledger.append ledger
           (E.Law_verdict { law = v.Theory.Law.law; satisfied = v.satisfied })))
    verdicts;
  verdicts
