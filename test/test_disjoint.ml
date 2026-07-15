(* Falsifier for the disjoint-writes retire law
   (docs/architecture/50-commit.md § retirement order and the merge,
   § final-state judgment).

   The law is the final-state backstop BEHIND the per-retire conflict
   judgment: the conflict judge sees only observed store footprints, so a
   writer whose stores were never evented (the blind writer) sails past it
   — and the law must still convict the clobber from committed state alone.
   The coordinates make it detectable by construction: every committed
   write is recorded with the base it advanced from (the content its
   writer's witness proves it derived from; blind writes carry the absence
   case), so two writes to one address from one base ARE the clobber, and
   serialized writers cannot collide because the later one witnessed the
   earlier landing.

   Rigged fixtures only; no engine, no model, no network. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Fixture helpers (the same shapes test_witness uses).                 *)

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

let sh cmd = ignore (Sys.command (cmd ^ " >/dev/null 2>&1"))
let ( // ) = Filename.concat

let seed_repo repo ~file ~contents =
  sh (Printf.sprintf "git -C %s init -q" (Filename.quote repo));
  write_file (repo // file) contents;
  sh (Printf.sprintf "git -C %s add -A" (Filename.quote repo));
  sh
    (Printf.sprintf
       "git -C %s -c user.name=test -c user.email=test@localhost commit -q -m \
        seed"
       (Filename.quote repo))

(* The smallest admissible theory carrying the law under test. *)
let schema_json : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ( "properties",
        `Assoc [ ("note", `Assoc [ ("type", `String "string") ]) ] );
      ("required", `List [ `String "note" ]);
      ("additionalProperties", `Bool false);
    ]

let disjoint_theory () =
  let codec : Yojson.Safe.t Contract.Codec.t =
    Contract.Codec.v ~of_json:Fun.id ~to_json:Fun.id
  in
  let relation name : Yojson.Safe.t Theory.Relation.t =
    Theory.Relation.v ~name (Contract.v ~name ~schema:schema_json ~codec)
  in
  let pin =
    { Theory.Pin.provider = "rigged"; model = "fake"; sampling = []; options = [] }
  in
  let worker =
    Theory.Executor.Agent_template
      { name = "worker"; pin; preamble = "produce the result"; read_globs = []; effects = [] }
  in
  match
    Theory.declare
      ~relations:
        [
          Theory.Relation.Packed (relation "task");
          Theory.Relation.Packed (relation "result");
        ]
      ~statements:
        [
          Theory.Spawn.v ~name:"work" ~for_:"task"
            ~exists:("result", Theory.Window.nodes 1)
            ~by:worker ();
        ]
      ~laws:[ Theory.Law.Disjoint_writes { name = "disjoint-writes" } ]
  with
  | Ok t -> t
  | Error errs ->
      failwith
        ("disjoint theory rejected: "
        ^ String.concat "; " (List.map Theory.Admission.to_string errs))

let verdict_line (v : Theory.Law.verdict) =
  Printf.printf "law %s satisfied=%b offenders=[%s]\n" v.Theory.Law.law
    v.satisfied
    (String.concat "; " v.offenders)

(* ==================================================================== *)
(* Two writers of one path, each derived from the same base (neither saw *)
(* the other's landing), both slipping past the conflict judge because    *)
(* their stores were never evented.  The second landing clobbers the      *)
(* first; the law must say so.  The serialized pair is the control: the   *)
(* second writer witnessed the first's landing, so its write advances     *)
(* from a different base and the law stays satisfied.                     *)
(* ==================================================================== *)

let%expect_test "disjoint law: a blind clobber is a violation; a serialized \
                 rewrite is not" =
  let repo = temp_dir "goat_disjoint_repo" in
  let scratch = temp_dir "goat_disjoint_scratch" in
  seed_repo repo ~file:"seed.txt" ~contents:"seed\n";
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let theory = disjoint_theory () in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let merges = Retire.Merge_registry.empty in
  let n1 = Id.mint node_minter in
  let n2 = Id.mint node_minter in
  let n3 = Id.mint node_minter in
  let n4 = Id.mint node_minter in
  (* Buffers snapshot BEFORE anything retires: n2 genuinely never saw n1's
     landing (and its ledger holds no load of shared.txt — a blind write). *)
  let wt n = Retire.Worktree.create ~root:(repo // "buffers") ~node:n in
  let wt1 = wt n1 and wt2 = wt n2 and wt3 = wt n3 and wt4 = wt n4 in
  let retire node worktree =
    match
      Retire.step ~committed ~ledger ~registry ~merges ~node ~worktree
        ~witness:(Witness.observed ledger ~node)
        ~heads:[]
    with
    | Ok () -> "ok"
    | Error (Retire.Conflict _) -> "rejected (Conflict)"
    | Error (Retire.Witness_moved _) -> "rejected (Witness_moved)"
    | Error (Retire.Undischarged _) -> "rejected (Undischarged)"
  in
  write_file (Retire.Worktree.path wt1 // "shared.txt") "first landing\n";
  write_file (Retire.Worktree.path wt2 // "shared.txt") "second landing\n";
  Printf.printf "n1 (blind writer) retire: %s\n" (retire n1 wt1);
  Printf.printf "n2 (blind writer) retire: %s\n" (retire n2 wt2);
  List.iter verdict_line (Retire.judge ~theory ~committed ~ledger);
  [%expect
    {|
    n1 (blind writer) retire: ok
    n2 (blind writer) retire: ok
    law disjoint-writes satisfied=false offenders=[file:shared.txt]
    |}];
  (* Control: n4 reads n3's landing before rewriting — the observed load is
     the base its write advances from, so the pair is serialized, not a
     clobber.  shared.txt's violation persists (final-state judgment is
     over all committed writes); serial.txt adds no offender. *)
  write_file (Retire.Worktree.path wt3 // "serial.txt") "one\n";
  Printf.printf "n3 (creator) retire: %s\n" (retire n3 wt3);
  ignore
    (Ledger.append ledger ~node:n4
       (Ledger.Event.Load
          {
            tool = "read";
            observed =
              [
                ( Ledger.Address.File "serial.txt",
                  Ledger.Generation.zero,
                  Ledger.Content_hash.of_string "one\n" );
              ];
          }));
  write_file (Retire.Worktree.path wt4 // "serial.txt") "two\n";
  Printf.printf "n4 (serialized rewriter) retire: %s\n" (retire n4 wt4);
  List.iter verdict_line (Retire.judge ~theory ~committed ~ledger);
  sh
    (Printf.sprintf "rm -rf %s %s" (Filename.quote repo)
       (Filename.quote scratch));
  [%expect
    {|
    n3 (creator) retire: ok
    n4 (serialized rewriter) retire: ok
    law disjoint-writes satisfied=false offenders=[file:shared.txt]
    |}]
