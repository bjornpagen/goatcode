(* Observed witnesses: the read-set a node can prove, assembled from its own
   ledger events (witness.mli is the contract; docs/architecture/30-scheduling.md
   § the generation-witness protocol; docs/architecture/20-medium.md
   § mechanized witnesses).

   Representation before control flow: a witness IS a set of observed
   triples — nothing else is representable, and the only constructor
   ([observed]) reads the ledger's witness index, so a fabricated witness is
   unconstructible in this module's clients (falsifier F6: no [of_list]). *)

type triple = {
  address : Ledger.Address.t;
  generation : Ledger.Generation.t;
  content : Ledger.Content_hash.t;
}

module Triple_set = Set.Make (struct
  type t = triple

  (* Lexicographic (address, generation, content): set identity is the whole
     observed triple, so the same address legitimately appears at two
     generations if the node really read it twice across a producer's store
     advance — the witness records what was observed, it never smooths. *)
  let compare a b =
    match Ledger.Address.compare a.address b.address with
    | 0 -> (
        match Ledger.Generation.compare a.generation b.generation with
        | 0 -> Ledger.Content_hash.compare a.content b.content
        | c -> c)
    | c -> c
end)

(* The set carries identity (what was observed); [reads] carries the
   ledger's append order (when it was observed) — the one fact a set must
   discard and [observed_content]'s latest-read judgment needs: two reads
   of one address at one generation with differing contents (snoops of an
   evolving draft both enter at [Generation.zero]) are ordered by the
   ledger, never by hash order. *)
type t = { set : Triple_set.t; reads : triple list }

let observed ledger ~node =
  let reads =
    List.map
      (fun (address, generation, content) -> { address; generation; content })
      (Ledger.Witness_index.reads ledger node)
  in
  {
    set = List.fold_left (fun acc tr -> Triple_set.add tr acc) Triple_set.empty reads;
    reads;
  }

(* Elements in set order: deterministic for replay, independent of the
   interleaving the load events happened to arrive in. *)
let triples t = Triple_set.elements t.set

let addresses t =
  Ledger.Footprint.of_list
    (Triple_set.fold (fun tr acc -> tr.address :: acc) t.set [])

let consumed_paths t ~contract_of =
  Triple_set.fold
    (fun tr acc ->
      match contract_of tr.address with
      | Some path -> path :: acc
      | None -> acc)
    t.set []
  |> List.sort_uniq String.compare

(* The latest observed read wins: a node that legitimately read an address
   twice across a producer's store advance derived its output from the
   fresher content, and that is the base its own write of the address
   advanced from. "Latest" is ledger order ([reads]), never set order —
   set order would let the lexicographically larger content hash of two
   equal-generation snoops shadow the read the node actually derived
   from (30-scheduling.md § retirement order, step 2: the base is the
   content the writer's witness proves it derived from). *)
let observed_content t address =
  List.fold_left
    (fun acc tr ->
      if Ledger.Address.equal tr.address address then Some tr.content else acc)
    None t.reads

module Committed_state = struct
  type t =
    | Absent
    | Landed of {
        generation : Ledger.Generation.t;
        content : Ledger.Content_hash.t;
      }
    | Deleted of { generation : Ledger.Generation.t }
end

type stale = {
  address : Ledger.Address.t;
  witnessed : Ledger.Generation.t;
  current : Committed_state.t;
}

(* Law 3: commit iff EVERY witnessed triple still describes the committed
   state — and the judged thing is the artifact (law 1), the content hash,
   never the generation number: law 2 makes generation equality a shadow of
   content identity, but a fresh landing and a pre-commit read share the
   first generation and only their content tells them apart. Absence is a
   real case: a triple witnessed at [Generation.zero] against [Absent]
   holds (a pre-commit read nothing has landed over) — UNLESS its content
   resolves only to a dead coordinate ([dead]): a squashed producer's
   fresh-file bytes share the pre-commit read's coordinates exactly
   (Absent, generation zero), so absence alone cannot tell garbage from
   a legitimate fixture read, and the content-judged backstop 20-medium.md
   § squash without isolation promises ("bytes whose producing store event
   is dead ... are garbage nothing can witness into committed state") is
   this judgment. A committed-generation triple against [Absent] is
   inconsistent and stale. Soundness, never freshness: nothing here asks
   whether a better input existed (law 4). Nothing routes here — the stale
   list is raw material for [Retire.Witness_moved]; the scheduler owns
   what happens next. *)
let holds t ~committed ~dead =
  let stales =
    Triple_set.fold
      (fun tr acc ->
        let current = committed tr.address in
        let held =
          match current with
          | Committed_state.Absent ->
              Ledger.Generation.equal tr.generation Ledger.Generation.zero
              && not (dead tr.address tr.content)
          | Committed_state.Landed { content; _ } ->
              Ledger.Content_hash.equal tr.content content
          | Committed_state.Deleted _ -> false
        in
        if held then acc
        else
          { address = tr.address; witnessed = tr.generation; current } :: acc)
      t.set []
  in
  match stales with [] -> Ok () | _ :: _ -> Error (List.rev stales)
