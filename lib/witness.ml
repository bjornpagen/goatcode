(* Observed witnesses: the read-set a node can prove, assembled from its own
   ledger events (witness.mli is the contract; docs/architecture/50-commit.md
   § the generation-witness protocol; docs/architecture/30-channels.md
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

type t = Triple_set.t

let observed ledger ~node =
  Ledger.Witness_index.reads ledger node
  |> List.fold_left
       (fun acc (address, generation, content) ->
         Triple_set.add { address; generation; content } acc)
       Triple_set.empty

(* Elements in set order: deterministic for replay, independent of the
   interleaving the load events happened to arrive in. *)
let triples t = Triple_set.elements t

let addresses t =
  Ledger.Footprint.of_list
    (Triple_set.fold (fun tr acc -> tr.address :: acc) t [])

let consumed_paths t ~contract_of =
  Triple_set.fold
    (fun tr acc ->
      match contract_of tr.address with
      | Some path -> path :: acc
      | None -> acc)
    t []
  |> List.sort_uniq String.compare

type stale = {
  address : Ledger.Address.t;
  witnessed : Ledger.Generation.t;
  current : Ledger.Generation.t;
}

(* Law 3: commit iff EVERY witnessed (address, generation) is still the
   committed generation — a generation check only; law 2 (only semantic
   change advances a generation) is what makes generation equality mean
   content identity. An address with no committed generation is judged at
   [Generation.zero], the primordial (never-written) state: a triple
   witnessed at zero against absent committed state holds; anything else
   witnessed there is stale. Soundness, never freshness: nothing here asks
   whether a better input existed (law 4). Nothing routes here — the stale
   list is raw material for [Retire.Witness_moved]; the scheduler owns what
   happens next. *)
let holds t ~committed =
  let stales =
    Triple_set.fold
      (fun tr acc ->
        let current =
          match committed tr.address with
          | Some g -> g
          | None -> Ledger.Generation.zero
        in
        if Ledger.Generation.equal tr.generation current then acc
        else
          { address = tr.address; witnessed = tr.generation; current } :: acc)
      t []
  in
  match stales with [] -> Ok () | _ :: _ -> Error (List.rev stales)
