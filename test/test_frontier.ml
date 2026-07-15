(* Falsifiers for migration row 3 — the frontier
   (docs/architecture/README.md § design of record vs shipped engine,
   row 3; docs/architecture/20-medium.md § validity is a ledger
   coordinate, § squash without isolation; docs/architecture/50-api.md
   § the flat-org roster):

   - FL3 — live frontier at quiescence. After runs with injected squashes
     and reissues: every committed address's content equals a
     witnessed-live store's blob; the hygiene sweep finds only bytes
     attributable to dead events. Liveness is derived from settlements —
     a store event is live iff its node is unsettled or retired; no
     per-event kill marks, no tombstones.
   - FL4 — global generation monotonicity. A fold over the whole ledger,
     per address: committed generations strictly increase, across squash
     and crash injection; a mid-run kill and re-boot (Frontier.of_ledger
     + materialize + forward reissue) asserts the same. Monotonicity is
     judged over the ledger because the tree carries no authority to
     retreat.

   Rigged fixtures only; no engine, no model, no network. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Harness plumbing (the same shapes test_landing uses).                *)

let rec mkdirs dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdirs parent;
    try Sys.mkdir dir 0o755 with Sys_error _ -> ()
  end

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  mkdirs path;
  path

let write_file path contents =
  mkdirs (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc contents)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let sh cmd = ignore (Sys.command (cmd ^ " >/dev/null 2>&1"))
let ( // ) = Filename.concat

(* Byte-exact command output, [None] on nonzero exit. *)
let sh_out cmd =
  let tmp = Filename.temp_file "goat_out" ".txt" in
  let status =
    Sys.command (Printf.sprintf "%s >%s 2>/dev/null" cmd (Filename.quote tmp))
  in
  let out = if status = 0 then Some (read_file tmp) else None in
  (try Sys.remove tmp with Sys_error _ -> ());
  out

let seed_repo repo ~files =
  sh (Printf.sprintf "git -C %s init -q" (Filename.quote repo));
  List.iter (fun (file, contents) -> write_file (repo // file) contents) files;
  sh (Printf.sprintf "git -C %s add -A" (Filename.quote repo));
  sh
    (Printf.sprintf
       "git -C %s -c user.name=test -c user.email=test@localhost commit -q -m \
        seed"
       (Filename.quote repo))

(* A file store, the way the engine's tool path lands one: the content
   into the committed repository's object database as a loose blob, the
   Store event carrying the oid.  Returns the oid so committed tree
   entries can be asserted live. *)
let store ~ledger ~repo ~node rel contents =
  let tmp = Filename.temp_file "goat_store" ".tmp" in
  write_file tmp contents;
  let oid =
    match
      sh_out
        (Printf.sprintf "git -C %s hash-object -w -- %s" (Filename.quote repo)
           (Filename.quote tmp))
    with
    | Some printed -> String.trim printed
    | None -> failwith ("hash-object refused " ^ rel)
  in
  (try Sys.remove tmp with Sys_error _ -> ());
  (match Ledger.Delta_ref.blob oid with
  | None -> failwith ("hash-object printed no oid for " ^ rel)
  | Some delta ->
      ignore
        (Ledger.append ledger ~node
           (Ledger.Event.Store
              { tool = "write_file"; address = Ledger.Address.File rel; delta })));
  oid

(* The writer's read point, observed the way the engine records one: a
   Load event carrying the current committed triple. *)
let load ~ledger ~committed ~node rel content =
  let address = Ledger.Address.File rel in
  let generation =
    match Retire.Committed.generation committed address with
    | Some g -> g
    | None -> Ledger.Generation.zero
  in
  ignore
    (Ledger.append ledger ~node
       (Ledger.Event.Load
          {
            tool = "read_file";
            observed =
              [ (address, generation, Ledger.Content_hash.of_string content) ];
          }))

let fixture prefix ~files =
  let repo = temp_dir (prefix ^ "_repo") in
  let scratch = temp_dir (prefix ^ "_scratch") in
  seed_repo repo ~files;
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  (repo, scratch, ledger, registry)

let retire ~committed ~ledger ~registry ~node =
  match
    Retire.step ~committed ~ledger ~registry
      ~merges:Retire.Merge_registry.empty ~node
      ~witness:(Witness.observed ledger ~node)
      ~heads:[]
  with
  | Ok () -> "ok"
  | Error (Retire.Witness_moved _) -> "rejected (Witness_moved)"
  | Error (Retire.Undischarged _) -> "rejected (Undischarged)"
  | Error (Retire.Conflict _) -> "rejected (Conflict)"

let branch_content repo rel =
  sh_out
    (Printf.sprintf "git -C %s show goat:%s" (Filename.quote repo)
       (Filename.quote rel))

let branch_entry_oid repo rel =
  match
    sh_out
      (Printf.sprintf "git -C %s rev-parse goat:%s" (Filename.quote repo)
         (Filename.quote rel))
  with
  | Some printed -> String.trim printed
  | None -> "<absent>"

let tree_str repo rel =
  if Sys.file_exists (repo // rel) then
    Printf.sprintf "%S" (read_file (repo // rel))
  else "<absent>"

let top_str frontier rel =
  match Retire.Frontier.top frontier (Ledger.Address.File rel) with
  | Retire.Frontier.Committed Witness.Committed_state.Absent ->
      "committed absent"
  | Retire.Frontier.Committed (Witness.Committed_state.Landed { generation; _ })
    ->
      Format.asprintf "committed landed@%a" Ledger.Generation.pp generation
  | Retire.Frontier.Committed (Witness.Committed_state.Deleted { generation })
    ->
      Format.asprintf "committed deleted@%a" Ledger.Generation.pp generation
  | Retire.Frontier.In_flight { writer; _ } ->
      Printf.sprintf "in-flight writer=%s" (Id.to_string writer)

(* The store events whose nodes are witnessed live (unsettled or retired)
   vs provenance-dead — derived from settlements alone, exactly the
   frontier's liveness judgment. *)
let store_oids ledger ~live =
  let events = Ledger.Replay.events ledger in
  let settled =
    List.filter_map
      (fun (e : Ledger.Event.t) ->
        match e.kind with
        | Ledger.Event.Settled s -> Option.map (fun n -> (n, s)) e.node
        | _ -> None)
      events
  in
  let is_live n =
    match List.find_opt (fun (m, _) -> Id.equal m n) settled with
    | None | Some (_, Ledger.Settlement.Retired) -> true
    | Some (_, _) -> false
  in
  List.filter_map
    (fun (e : Ledger.Event.t) ->
      match (e.kind, e.node) with
      | Ledger.Event.Store { delta; _ }, Some n when Bool.equal (is_live n) live
        ->
          Ledger.Delta_ref.oid delta
      | _ -> None)
    events

(* FL4's fold: per address, over the whole ledger, the committed
   generations the retirements published (Invalidation_sent) must
   strictly increase. Violation-only report. *)
let mono_report ledger =
  let rows =
    List.filter_map
      (fun (e : Ledger.Event.t) ->
        match e.kind with
        | Ledger.Event.Invalidation_sent { address; new_generation } ->
            Some (address, new_generation)
        | _ -> None)
      (Ledger.Replay.events ledger)
  in
  let addresses =
    List.fold_left
      (fun acc (a, _) ->
        if List.exists (Ledger.Address.equal a) acc then acc else acc @ [ a ])
      [] rows
  in
  let violations =
    List.concat_map
      (fun a ->
        let gens =
          List.filter_map
            (fun (a', g) -> if Ledger.Address.equal a a' then Some g else None)
            rows
        in
        let rec adjacent = function
          | g :: (g' :: _ as rest) ->
              (if Ledger.Generation.compare g' g <= 0 then
                 [
                   Format.asprintf "%s: %a then %a" (Ledger.Address.to_string a)
                     Ledger.Generation.pp g Ledger.Generation.pp g';
                 ]
               else [])
              @ adjacent rest
          | [] | [ _ ] -> []
        in
        adjacent gens)
      addresses
  in
  match violations with
  | [] -> "monotone: ok"
  | vs -> "VIOLATION: " ^ String.concat "; " vs

let gens_str ledger rel =
  let address = Ledger.Address.File rel in
  let gens =
    List.filter_map
      (fun (e : Ledger.Event.t) ->
        match e.kind with
        | Ledger.Event.Invalidation_sent { address = a; new_generation }
          when Ledger.Address.equal a address ->
            Some (Format.asprintf "%a" Ledger.Generation.pp new_generation)
        | _ -> None)
      (Ledger.Replay.events ledger)
  in
  String.concat " " gens

let event_count ledger = List.length (Ledger.Replay.events ledger)

(* ================================================================== *)
(* FL3 — live frontier at quiescence.  A doomed writer drafts over two   *)
(* committed paths and one fresh path straight into the shared tree,     *)
(* squashes, and the reissue overwrites only one of them.  The frontier  *)
(* derives every top from settlements alone; committed content is a      *)
(* witnessed-live store's blob; the sweep (materialize) converges the    *)
(* dead residue and touches nothing live — checkout, never revert.       *)
(* ================================================================== *)

let%expect_test "FL3: after squash and reissue the frontier is live at every \
                 address, and the hygiene sweep finds only dead-event bytes" =
  let repo, scratch, ledger, registry =
    fixture "goat_fl3" ~files:[ ("f.txt", "seed f\n"); ("g.txt", "seed g\n") ]
  in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let nodes : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let hyps : Ledger.hypothesis Id.Minter.t =
    Id.Minter.create ~registry ~realm:"hypothesis"
  in
  let n1 = Id.mint nodes in
  let n2 = Id.mint nodes in
  let n3 = Id.mint nodes in
  (* n1 lands both committed paths. *)
  ignore (store ~ledger ~repo ~node:n1 "f.txt" "landed f\n");
  let g_oid = store ~ledger ~repo ~node:n1 "g.txt" "landed g\n" in
  Printf.printf "retire n1: %s\n" (retire ~committed ~ledger ~registry ~node:n1);
  (* n2, the doomed writer: a hypothesis carrier whose drafts land in the
     shared tree (two committed paths and one fresh file). *)
  let h = Id.mint hyps in
  ignore
    (Ledger.append ledger ~node:n2
       (Ledger.Event.Hypothesis_taken
          {
            hypothesis = h;
            address = Ledger.Address.File "f.txt";
            source = "store-buffer:" ^ Id.to_string n1;
            content = Ledger.Content_hash.of_string "landed f\n";
            confidence = 0.9;
          }));
  ignore (store ~ledger ~repo ~node:n2 "f.txt" "dead draft f\n");
  ignore (store ~ledger ~repo ~node:n2 "g.txt" "dead draft g\n");
  ignore (store ~ledger ~repo ~node:n2 "junk.txt" "dead fresh\n");
  write_file (repo // "f.txt") "dead draft f\n";
  write_file (repo // "g.txt") "dead draft g\n";
  write_file (repo // "junk.txt") "dead fresh\n";
  (* Before the settlement the drafts ARE the live tops. *)
  let frontier = Retire.Frontier.of_ledger ledger ~committed in
  Printf.printf "pre-squash top f.txt: %s\n" (top_str frontier "f.txt");
  Printf.printf "pre-squash top junk.txt: %s\n" (top_str frontier "junk.txt");
  (* The one appended fact: the squash settlement — exactly the event
     [Retire.squash] seals each doomed node with (the provenance walk that
     picks the set is F3's business; FL3 consumes the appended fact).
     Every coordinate under n2 is provenance-dead by derivation — no kill
     marks, no tombstones. *)
  ignore
    (Ledger.append ledger ~node:n2
       (Ledger.Event.Settled
          (Ledger.Settlement.Squashed (Ledger.Squash_cause.Dead_hypothesis h))));
  (* The forward repair: the reissue overwrites f.txt (overwrite-on-reissue
     primary) and leaves g.txt and junk.txt to the lazy-convergence
     backstop.  It serializes behind n1's landing by an observed read. *)
  load ~ledger ~committed ~node:n3 "f.txt" "landed f\n";
  let f_oid = store ~ledger ~repo ~node:n3 "f.txt" "reissued f\n" in
  Printf.printf "retire n3 (reissue): %s\n"
    (retire ~committed ~ledger ~registry ~node:n3);
  let frontier = Retire.Frontier.of_ledger ledger ~committed in
  Printf.printf "top f.txt: %s\n" (top_str frontier "f.txt");
  Printf.printf "top g.txt: %s\n" (top_str frontier "g.txt");
  Printf.printf "top junk.txt: %s\n" (top_str frontier "junk.txt");
  (* Every committed address's content equals a witnessed-live store's
     blob — and no dead store's blob is any committed entry. *)
  let live = store_oids ledger ~live:true in
  let dead = store_oids ledger ~live:false in
  Printf.printf "committed f.txt is a live store's blob: %b\n"
    (List.exists (String.equal (branch_entry_oid repo "f.txt")) live
    && String.equal (branch_entry_oid repo "f.txt") f_oid);
  Printf.printf "committed g.txt is a live store's blob: %b\n"
    (List.exists (String.equal (branch_entry_oid repo "g.txt")) live
    && String.equal (branch_entry_oid repo "g.txt") g_oid);
  Printf.printf "no committed entry is a dead store's blob: %b\n"
    (not
       (List.exists
          (fun oid ->
            String.equal oid (branch_entry_oid repo "f.txt")
            || String.equal oid (branch_entry_oid repo "g.txt"))
          dead));
  (* Sensitivity control: the instrument sees the garbage before the
     sweep — dead bytes on a committed path, a dead fresh file. *)
  Printf.printf "pre-sweep tree g.txt (dead bytes visible): %s\n"
    (tree_str repo "g.txt");
  Printf.printf "pre-sweep tree junk.txt (dead bytes visible): %s\n"
    (tree_str repo "junk.txt");
  Printf.printf "pre-sweep tree f.txt (overwrite-on-reissue cleaned it): %s\n"
    (tree_str repo "f.txt");
  (* The sweep: converge every address to its live top.  Appends nothing,
     moves no coordinate, idempotent. *)
  let before = event_count ledger in
  Retire.Frontier.materialize frontier ~repo;
  Retire.Frontier.materialize frontier ~repo;
  Printf.printf "sweep appended nothing: %b\n" (event_count ledger = before);
  Printf.printf "post-sweep tree f.txt: %s\n" (tree_str repo "f.txt");
  Printf.printf "post-sweep tree g.txt: %s\n" (tree_str repo "g.txt");
  Printf.printf "post-sweep tree junk.txt: %s\n" (tree_str repo "junk.txt");
  Printf.printf "post-sweep committed state g.txt: %s\n"
    (match Retire.Committed.state committed (Ledger.Address.File "g.txt") with
    | Witness.Committed_state.Landed { generation; _ } ->
        Format.asprintf "landed@%a (coordinate unmoved)" Ledger.Generation.pp
          generation
    | _ -> "MOVED");
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    retire n1: ok
    pre-squash top f.txt: in-flight writer=node#1
    pre-squash top junk.txt: in-flight writer=node#1
    retire n3 (reissue): ok
    top f.txt: committed landed@g2
    top g.txt: committed landed@g1
    top junk.txt: committed absent
    committed f.txt is a live store's blob: true
    committed g.txt is a live store's blob: true
    no committed entry is a dead store's blob: true
    pre-sweep tree g.txt (dead bytes visible): "dead draft g\n"
    pre-sweep tree junk.txt (dead bytes visible): "dead fresh\n"
    pre-sweep tree f.txt (overwrite-on-reissue cleaned it): "reissued f\n"
    sweep appended nothing: true
    post-sweep tree f.txt: "reissued f\n"
    post-sweep tree g.txt: "landed g\n"
    post-sweep tree junk.txt: <absent>
    post-sweep committed state g.txt: landed@g1 (coordinate unmoved)
    |}]

(* ================================================================== *)
(* FL3 — the in-flight top.  An unsettled writer's draft is the live top: *)
(* it carries the writer (the read resolver's Store_buffer hypothesis     *)
(* target), the draft's content, and the writer's read point — the same   *)
(* base coordinate the disjoint law judges.  The hygiene sweep never      *)
(* clobbers a live draft with committed content, and a byte-less draft    *)
(* deletion is not a witnessable top.                                     *)
(* ================================================================== *)

let%expect_test "FL3: an in-flight top carries writer, content, and base — \
                 and the sweep never clobbers live drafts" =
  let repo, scratch, ledger, registry =
    fixture "goat_fl3_flight" ~files:[ ("f.txt", "seed f\n") ]
  in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let nodes : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let n1 = Id.mint nodes in
  let n2 = Id.mint nodes in
  let n3 = Id.mint nodes in
  ignore (store ~ledger ~repo ~node:n1 "f.txt" "committed f\n");
  Printf.printf "retire n1: %s\n" (retire ~committed ~ledger ~registry ~node:n1);
  (* n2 reads the committed content, then drafts over it in the shared
     tree; n3 blind-writes a fresh path. *)
  load ~ledger ~committed ~node:n2 "f.txt" "committed f\n";
  ignore (store ~ledger ~repo ~node:n2 "f.txt" "n2 draft\n");
  write_file (repo // "f.txt") "n2 draft\n";
  ignore (store ~ledger ~repo ~node:n3 "h.txt" "n3 fresh draft\n");
  write_file (repo // "h.txt") "n3 fresh draft\n";
  let frontier = Retire.Frontier.of_ledger ledger ~committed in
  (match Retire.Frontier.top frontier (Ledger.Address.File "f.txt") with
  | Retire.Frontier.In_flight { writer; content; base } ->
      Printf.printf "f.txt in-flight writer is n2: %b\n" (Id.equal writer n2);
      Printf.printf "f.txt in-flight content is the draft: %b\n"
        (Ledger.Content_hash.equal content
           (Ledger.Content_hash.of_string "n2 draft\n"));
      Printf.printf
        "f.txt in-flight base is the committed content (the disjoint \
         coordinate): %b\n"
        (match base with
        | Some b ->
            Ledger.Content_hash.equal b
              (Ledger.Content_hash.of_string "committed f\n")
        | None -> false)
  | _ -> print_endline "BUG: draft is not the live top");
  (match Retire.Frontier.top frontier (Ledger.Address.File "h.txt") with
  | Retire.Frontier.In_flight { writer; base; _ } ->
      Printf.printf "h.txt in-flight writer is n3, base none (blind write): %b\n"
        (Id.equal writer n3 && Option.is_none base)
  | _ -> print_endline "BUG: fresh draft is not the live top");
  (* The sweep converges to live tops: drafts stay, and a missing draft is
     re-filled from the ledger's blob — cache fill, not revert. *)
  Sys.remove (repo // "h.txt");
  Retire.Frontier.materialize frontier ~repo;
  Printf.printf "post-sweep tree f.txt (live draft untouched): %s\n"
    (tree_str repo "f.txt");
  Printf.printf "post-sweep tree h.txt (live draft re-filled): %s\n"
    (tree_str repo "h.txt");
  (* A draft deletion is byte-less: existence of uncommitted state is not
     a witnessable claim, so the top falls back to the committed prior. *)
  ignore
    (Ledger.append ledger ~node:n2
       (Ledger.Event.Store
          {
            tool = "delete_file";
            address = Ledger.Address.File "f.txt";
            delta = Ledger.Delta_ref.locator "f.txt";
          }));
  let frontier = Retire.Frontier.of_ledger ledger ~committed in
  Printf.printf "top f.txt after draft deletion: %s\n" (top_str frontier "f.txt");
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    retire n1: ok
    f.txt in-flight writer is n2: true
    f.txt in-flight content is the draft: true
    f.txt in-flight base is the committed content (the disjoint coordinate): true
    h.txt in-flight writer is n3, base none (blind write): true
    post-sweep tree f.txt (live draft untouched): "n2 draft\n"
    post-sweep tree h.txt (live draft re-filled): "n3 fresh draft\n"
    top f.txt after draft deletion: committed landed@g1
    |}]

(* ================================================================== *)
(* FL4 — global generation monotonicity.  The fold is per address over    *)
(* the whole ledger (interleaved addresses keep the global sequence       *)
(* non-monotone while every per-address sequence strictly increases —     *)
(* the grouping is load-bearing), across a squash injection and a         *)
(* mid-run kill.  Re-boot is Frontier.of_ledger + materialize + forward   *)
(* reissue: the re-opened committed map is amnesiac, and the ledger's     *)
(* published coordinate is the floor no landing may retreat below.        *)
(* ================================================================== *)

let%expect_test "FL4: committed generations strictly increase per address, \
                 across squash and a mid-run kill with re-boot" =
  let repo, scratch, ledger, registry =
    fixture "goat_fl4" ~files:[ ("f.txt", "seed f\n"); ("g.txt", "seed g\n") ]
  in
  let ledger_path = scratch // "ledger" in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let nodes : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let hyps : Ledger.hypothesis Id.Minter.t =
    Id.Minter.create ~registry ~realm:"hypothesis"
  in
  let n1 = Id.mint nodes in
  let n2 = Id.mint nodes in
  let n3 = Id.mint nodes in
  let n4 = Id.mint nodes in
  (* n1 moves f.txt to g1; n2 serializes behind it by an observed read and
     moves f.txt to g2 and g.txt to g1 — the interleave that makes the
     per-address grouping load-bearing. *)
  ignore (store ~ledger ~repo ~node:n1 "f.txt" "a\n");
  Printf.printf "retire n1: %s\n" (retire ~committed ~ledger ~registry ~node:n1);
  load ~ledger ~committed ~node:n2 "f.txt" "a\n";
  ignore (store ~ledger ~repo ~node:n2 "f.txt" "b\n");
  ignore (store ~ledger ~repo ~node:n2 "g.txt" "gb\n");
  Printf.printf "retire n2: %s\n" (retire ~committed ~ledger ~registry ~node:n2);
  (* Squash injection: n3's draft dies; no coordinate moves. *)
  let h = Id.mint hyps in
  ignore
    (Ledger.append ledger ~node:n3
       (Ledger.Event.Hypothesis_taken
          {
            hypothesis = h;
            address = Ledger.Address.File "f.txt";
            source = "store-buffer:" ^ Id.to_string n2;
            content = Ledger.Content_hash.of_string "b\n";
            confidence = 0.9;
          }));
  ignore (store ~ledger ~repo ~node:n3 "f.txt" "c\n");
  ignore
    (Ledger.append ledger ~node:n3
       (Ledger.Event.Settled
          (Ledger.Settlement.Squashed (Ledger.Squash_cause.Dead_hypothesis h))));
  (* n4 is in flight — its draft is in the tree — when the run is killed. *)
  load ~ledger ~committed ~node:n4 "f.txt" "b\n";
  ignore (store ~ledger ~repo ~node:n4 "f.txt" "d\n");
  write_file (repo // "f.txt") "d\n";
  Printf.printf "pre-kill %s\n" (mono_report ledger);
  Printf.printf "pre-kill f.txt generations: %s\n" (gens_str ledger "f.txt");
  Printf.printf "pre-kill g.txt generations: %s\n" (gens_str ledger "g.txt");
  (* Sensitivity control: the fold can see a retreat.  A scratch ledger
     with a hand-laid lowered coordinate must be convicted. *)
  let control = Ledger.create ~path:(scratch // "control_ledger") in
  ignore
    (Ledger.append control
       (Ledger.Event.Invalidation_sent
          {
            address = Ledger.Address.File "f.txt";
            new_generation = Ledger.Generation.next Ledger.Generation.zero;
          }));
  ignore
    (Ledger.append control
       (Ledger.Event.Invalidation_sent
          {
            address = Ledger.Address.File "f.txt";
            new_generation = Ledger.Generation.zero;
          }));
  Printf.printf "control (hand-laid retreat) %s\n" (mono_report control);
  (* THE KILL.  Process memory is gone: the re-boot re-opens the ledger
     from disk and an EMPTY committed map.  Boot is crash recovery —
     re-derive the frontier, converge the tree, reissue forward. *)
  let ledger = Ledger.create ~path:ledger_path in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let frontier = Retire.Frontier.of_ledger ledger ~committed in
  Printf.printf "boot top f.txt (n4's store is live: unsettled): %s\n"
    (top_str frontier "f.txt");
  Retire.Frontier.materialize frontier ~repo;
  Printf.printf "boot tree f.txt (the live draft): %s\n" (tree_str repo "f.txt");
  (* Forward reissue: the in-flight attempt abandons (the settlement the
     engine records for an abandoned attempt) so its body match can
     reissue; its residue converges to the committed top. *)
  ignore
    (Ledger.append ledger ~node:n4
       (Ledger.Event.Settled
          (Ledger.Settlement.Squashed Ledger.Squash_cause.Reissue_loser)));
  let frontier = Retire.Frontier.of_ledger ledger ~committed in
  Printf.printf
    "post-abandon top f.txt (recovered from ref + invalidation trail, map \
     amnesiac): %s\n"
    (top_str frontier "f.txt");
  Retire.Frontier.materialize frontier ~repo;
  Printf.printf "post-abandon tree f.txt: %s\n" (tree_str repo "f.txt");
  (* The reissued producer lands the deliverable.  (A blind write: the
     boot-time read resolver over the frontier is migration step 4 —
     what FL4 pins here is the coordinate, not the witness.  The node id
     comes off the pre-kill minter: identity-supply recovery is the
     scheduler's, step 7 — not what FL4 pins.)  The amnesiac map would
     land this at g1; the ledger's floor forbids the retreat. *)
  let n5 = Id.mint nodes in
  ignore (store ~ledger ~repo ~node:n5 "f.txt" "d\n");
  Printf.printf "retire n5 (reissued, after re-boot): %s\n"
    (retire ~committed ~ledger ~registry ~node:n5);
  Printf.printf "post-reissue %s\n" (mono_report ledger);
  Printf.printf "post-reissue f.txt generations: %s\n" (gens_str ledger "f.txt");
  Printf.printf "post-reissue g.txt generations: %s\n" (gens_str ledger "g.txt");
  Printf.printf "committed f.txt content: %s\n"
    (match branch_content repo "f.txt" with
    | Some c -> Printf.sprintf "%S" c
    | None -> "<absent>");
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    retire n1: ok
    retire n2: ok
    pre-kill monotone: ok
    pre-kill f.txt generations: g1 g2
    pre-kill g.txt generations: g1
    control (hand-laid retreat) VIOLATION: file:f.txt: g1 then g0
    boot top f.txt (n4's store is live: unsettled): in-flight writer=node#3
    boot tree f.txt (the live draft): "d\n"
    post-abandon top f.txt (recovered from ref + invalidation trail, map amnesiac): committed landed@g2
    post-abandon tree f.txt: "b\n"
    retire n5 (reissued, after re-boot): ok
    post-reissue monotone: ok
    post-reissue f.txt generations: g1 g2 g3
    post-reissue g.txt generations: g1
    committed f.txt content: "d\n"
    |}]
