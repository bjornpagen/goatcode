(* Falsifiers for migration row 2 — retire from the ledger, not the tree
   (docs/architecture/README.md § design of record vs shipped engine,
   row 2; docs/architecture/30-scheduling.md § retirement order and the
   landing, step 3: "a pathspec-limited commit built from the ledger's
   blobs, never from the tree").

   The laws under test:
   - the retire step's write set is the node's Store events, its bytes the
     object database's blobs — no tree is a source of landed content, so a
     neighbor's later in-flight bytes cannot tear the commit;
   - the retire commit is pathspec-limited: exactly the node's write set,
     its tree entries the store events' oids;
   - stores coalesce in the event stream (last store per address wins; a
     store that restores the committed bytes cancels to a free commit);
   - a deletion is derived from the event stream (a locator ref at a file
     address), not from any tree diff.

   Rigged fixtures only; no engine, no model, no network. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Harness plumbing (the same shapes test_witness uses).                *)

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

let seed_repo repo ~file ~contents =
  sh (Printf.sprintf "git -C %s init -q" (Filename.quote repo));
  write_file (repo // file) contents;
  sh (Printf.sprintf "git -C %s add -A" (Filename.quote repo));
  sh
    (Printf.sprintf
       "git -C %s -c user.name=test -c user.email=test@localhost commit -q -m \
        seed"
       (Filename.quote repo))

(* A file store, the way the engine's tool path lands one: the content
   into the committed repository's object database as a loose blob, the
   Store event carrying the oid.  Returns the oid so the commit's tree
   entry can be asserted against it. *)
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

(* A byte-less deletion, derived from the event stream: a locator ref at
   the file address — no tree diff anywhere. *)
let store_deletion ~ledger ~node rel =
  ignore
    (Ledger.append ledger ~node
       (Ledger.Event.Store
          {
            tool = "delete_file";
            address = Ledger.Address.File rel;
            delta = Ledger.Delta_ref.locator rel;
          }))

let fixture prefix =
  let repo = temp_dir (prefix ^ "_repo") in
  let scratch = temp_dir (prefix ^ "_scratch") in
  seed_repo repo ~file:"f.txt" ~contents:"v1\n";
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
  match
    sh_out
      (Printf.sprintf "git -C %s show goat:%s" (Filename.quote repo)
         (Filename.quote rel))
  with
  | Some c -> Printf.sprintf "%S" c
  | None -> "<absent>"

let branch_entry_oid repo rel =
  match
    sh_out
      (Printf.sprintf "git -C %s rev-parse goat:%s" (Filename.quote repo)
         (Filename.quote rel))
  with
  | Some printed -> String.trim printed
  | None -> "<absent>"

let last_commit_files repo =
  match
    sh_out
      (Printf.sprintf "git -C %s show --name-only --format= goat"
         (Filename.quote repo))
  with
  | Some out ->
      String.split_on_char '\n' out
      |> List.filter (fun l -> String.trim l <> "")
      |> String.concat ", "
  | None -> "<no commit>"

let gen_str = function
  | None -> "none"
  | Some g -> Format.asprintf "%a" Ledger.Generation.pp g

let state_str = function
  | Witness.Committed_state.Absent -> "absent"
  | Witness.Committed_state.Landed { generation; _ } ->
      Format.asprintf "landed@%a" Ledger.Generation.pp generation
  | Witness.Committed_state.Deleted { generation } ->
      Format.asprintf "deleted@%a" Ledger.Generation.pp generation

let invalidations ledger =
  List.length
    (List.filter
       (fun (e : Ledger.Event.t) ->
         match e.kind with
         | Ledger.Event.Invalidation_sent _ -> true
         | _ -> false)
       (Ledger.Replay.events ledger))

(* ================================================================== *)
(* Row 2 — the landing comes from the ledger's blobs, never from the    *)
(* tree.  A neighbor's later in-flight bytes on the SAME path (written   *)
(* straight into the checkout, the shared tree's stand-in) are visible   *)
(* in the tree at retire time; the commit must carry the store event's   *)
(* blob — tree entry oid included — and the checkout is repaired to the  *)
(* landed bytes as cache fill.                                           *)
(* ================================================================== *)

let%expect_test "row 2: the commit is built from the ledger's blobs, never \
                 from the tree" =
  let repo, scratch, ledger, registry = fixture "goat_r2_blob" in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let n = Id.mint node_minter in
  let m = Id.mint node_minter in
  let oid = store ~ledger ~repo ~node:n "f.txt" "stored bytes\n" in
  (* The neighbor's in-flight bytes land in the tree AFTER the store event:
     the tear the old net-delta read was exposed to. *)
  write_file (repo // "f.txt") "torn in-flight bytes\n";
  Printf.printf "neighbor's bytes visible in the tree at retire: %b\n"
    (String.equal (read_file (repo // "f.txt")) "torn in-flight bytes\n");
  Printf.printf "retire n: %s\n" (retire ~committed ~ledger ~registry ~node:n);
  Printf.printf "committed content: %s\n" (branch_content repo "f.txt");
  Printf.printf "tree entry oid = store event oid: %b\n"
    (String.equal (branch_entry_oid repo "f.txt") oid);
  Printf.printf "checkout repaired to the landed bytes: %b\n"
    (String.equal (read_file (repo // "f.txt")) "stored bytes\n");
  Printf.printf "committed state: %s\n"
    (state_str (Retire.Committed.state committed (Ledger.Address.File "f.txt")));
  (* The dual tamper: the tree already holds EXACTLY the bytes m stores —
     but the committed record does not.  A landing judged against the
     tree would silently free-commit and never move the coordinate; law 2
     compares against committed content, so it must advance.  (m is
     serialized behind n by an observed read: base coordinates, not
     conflict, are under test.) *)
  ignore
    (Ledger.append ledger ~node:m
       (Ledger.Event.Load
          {
            tool = "read";
            observed =
              [
                ( Ledger.Address.File "f.txt",
                  (match
                     Retire.Committed.generation committed
                       (Ledger.Address.File "f.txt")
                   with
                  | Some g -> g
                  | None -> Ledger.Generation.zero),
                  Ledger.Content_hash.of_string "stored bytes\n" );
              ];
          }));
  ignore (store ~ledger ~repo ~node:m "f.txt" "rewritten bytes\n");
  write_file (repo // "f.txt") "rewritten bytes\n";
  Printf.printf "retire m (tree pre-holds m's exact bytes): %s\n"
    (retire ~committed ~ledger ~registry ~node:m);
  Printf.printf "committed state advanced anyway: %s\n"
    (state_str (Retire.Committed.state committed (Ledger.Address.File "f.txt")));
  Printf.printf "committed content: %s\n" (branch_content repo "f.txt");
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    neighbor's bytes visible in the tree at retire: true
    retire n: ok
    committed content: "stored bytes\n"
    tree entry oid = store event oid: true
    checkout repaired to the landed bytes: true
    committed state: landed@g1
    retire m (tree pre-holds m's exact bytes): ok
    committed state advanced anyway: landed@g2
    committed content: "rewritten bytes\n"
    |}]

(* ================================================================== *)
(* Row 2 — the retire commit is pathspec-limited to the node's write     *)
(* set.  A neighbor's in-flight bytes on ANOTHER path (an untracked file  *)
(* in the checkout) must not ride the commit: the commit lists exactly    *)
(* the write set, and the branch never gains the neighbor's path.         *)
(* ================================================================== *)

let%expect_test "row 2: a neighbor's in-flight path never enters the retire \
                 commit" =
  let repo, scratch, ledger, registry = fixture "goat_r2_pathspec" in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let n = Id.mint node_minter in
  ignore (store ~ledger ~repo ~node:n "mine.txt" "my landing\n");
  write_file (repo // "neighbor.txt") "someone else's draft\n";
  Printf.printf "retire: %s\n" (retire ~committed ~ledger ~registry ~node:n);
  Printf.printf "retire commit files: %s\n" (last_commit_files repo);
  Printf.printf "neighbor.txt on the committed branch: %s\n"
    (branch_content repo "neighbor.txt");
  Printf.printf "neighbor's draft still in the tree (not cleaned, not \
                 committed): %b\n"
    (String.equal (read_file (repo // "neighbor.txt")) "someone else's draft\n");
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    retire: ok
    retire commit files: mine.txt
    neighbor.txt on the committed branch: <absent>
    neighbor's draft still in the tree (not cleaned, not committed): true
    |}]

(* ================================================================== *)
(* Row 2 — the write set is the event stream.  Bytes sitting in the      *)
(* shared tree with NO Store event never land — even bytes the retiring   *)
(* node itself put there: the tree is not read at retire.  (Re-aimed at   *)
(* the one shared tree with migration row 5, README.md § design of        *)
(* record vs shipped engine — the per-node buffer this test used to       *)
(* write into no longer exists; the law is unchanged.)  The control arm   *)
(* proves the instrument sees a landing: the same bytes WITH a Store      *)
(* event land.                                                            *)
(* ================================================================== *)

let%expect_test "row 2: un-evented tree bytes never land — the tree is not \
                 read at retire" =
  let repo, scratch, ledger, registry = fixture "goat_r2_unevented" in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let n = Id.mint node_minter in
  let m = Id.mint node_minter in
  (* The shared tree holds real bytes, written by the retiring node
     itself... that no Store event ever named (the old changed-paths read
     would have landed them). *)
  write_file (repo // "junk.txt") "never stored\n";
  Printf.printf "tree holds the bytes: %b\n"
    (String.equal (read_file (repo // "junk.txt")) "never stored\n");
  Printf.printf "retire n: %s\n" (retire ~committed ~ledger ~registry ~node:n);
  Printf.printf "junk.txt committed state: %s\n"
    (state_str
       (Retire.Committed.state committed (Ledger.Address.File "junk.txt")));
  Printf.printf "junk.txt on the committed branch: %s\n"
    (branch_content repo "junk.txt");
  (* Control: the same bytes through the event stream DO land. *)
  ignore (store ~ledger ~repo ~node:m "junk.txt" "never stored\n");
  Printf.printf "retire m (control, evented): %s\n"
    (retire ~committed ~ledger ~registry ~node:m);
  Printf.printf "junk.txt on the committed branch: %s\n"
    (branch_content repo "junk.txt");
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    tree holds the bytes: true
    retire n: ok
    junk.txt committed state: absent
    junk.txt on the committed branch: <absent>
    retire m (control, evented): ok
    junk.txt on the committed branch: "never stored\n"
    |}]

(* ================================================================== *)
(* Row 2 — stores coalesce in the event stream.  Twelve edits forward as  *)
(* one landing: the last store per address wins, one generation advance,  *)
(* one tree entry.  And a final store that restores the committed bytes   *)
(* cancels to nothing — the free commit, judged from the event stream     *)
(* (law 2; falsifier F7's event-sourced shape).                           *)
(* ================================================================== *)

let%expect_test "row 2: stores coalesce — the last store per address wins, \
                 and a restoring store cancels to a free commit" =
  let repo, scratch, ledger, registry = fixture "goat_r2_coalesce" in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let n = Id.mint node_minter in
  let m = Id.mint node_minter in
  ignore (store ~ledger ~repo ~node:n "out.txt" "draft 1\n");
  ignore (store ~ledger ~repo ~node:n "out.txt" "draft 2\n");
  let final_oid = store ~ledger ~repo ~node:n "out.txt" "final\n" in
  Printf.printf "retire n: %s\n" (retire ~committed ~ledger ~registry ~node:n);
  Printf.printf "committed content: %s\n" (branch_content repo "out.txt");
  Printf.printf "tree entry oid = LAST store's oid: %b\n"
    (String.equal (branch_entry_oid repo "out.txt") final_oid);
  Printf.printf "generation after the coalesced landing: %s (one fresh \
                 advance)\n"
    (gen_str (Retire.Committed.generation committed (Ledger.Address.File "out.txt")));
  Printf.printf "invalidations (fresh address, nobody to invalidate): %d\n"
    (invalidations ledger);
  (* The cancellation arm: m edits f.txt away and back; its last store is
     byte-identical to the committed content, so nothing advances, nothing
     fires, and the retire commit stages no entry. *)
  ignore (store ~ledger ~repo ~node:m "f.txt" "edited\n");
  ignore (store ~ledger ~repo ~node:m "f.txt" "v1\n");
  Printf.printf "retire m: %s\n" (retire ~committed ~ledger ~registry ~node:m);
  Printf.printf "f.txt generation after the restoring store: %s\n"
    (gen_str (Retire.Committed.generation committed (Ledger.Address.File "f.txt")));
  Printf.printf "invalidations after the free commit: %d\n"
    (invalidations ledger);
  Printf.printf "m's retire commit files: %s\n" (last_commit_files repo);
  Printf.printf "f.txt committed content: %s\n" (branch_content repo "f.txt");
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    retire n: ok
    committed content: "final\n"
    tree entry oid = LAST store's oid: true
    generation after the coalesced landing: g0 (one fresh advance)
    invalidations (fresh address, nobody to invalidate): 0
    retire m: ok
    f.txt generation after the restoring store: none
    invalidations after the free commit: 0
    m's retire commit files:
    f.txt committed content: "v1\n"
    |}]

(* ================================================================== *)
(* Row 2 — a deletion is derived from the event stream: a locator ref at  *)
(* a file address (no bytes to address), never a tree diff.  The landing  *)
(* removes the path from the committed branch and the checkout, advances  *)
(* the generation, and fires the invalidation.                            *)
(* ================================================================== *)

let%expect_test "row 2: a deletion is a locator-ref store event, derived \
                 from the event stream" =
  let repo, scratch, ledger, registry = fixture "goat_r2_delete" in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let n = Id.mint node_minter in
  store_deletion ~ledger ~node:n "f.txt";
  Printf.printf "retire: %s\n" (retire ~committed ~ledger ~registry ~node:n);
  Printf.printf "f.txt committed state: %s\n"
    (state_str (Retire.Committed.state committed (Ledger.Address.File "f.txt")));
  Printf.printf "f.txt on the committed branch: %s\n"
    (branch_content repo "f.txt");
  Printf.printf "f.txt gone from the checkout: %b\n"
    (not (Sys.file_exists (repo // "f.txt")));
  Printf.printf "retire commit files: %s\n" (last_commit_files repo);
  Printf.printf "invalidations: %d\n" (invalidations ledger);
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    retire: ok
    f.txt committed state: deleted@g1
    f.txt on the committed branch: <absent>
    f.txt gone from the checkout: true
    retire commit files: f.txt
    invalidations: 1
    |}]
