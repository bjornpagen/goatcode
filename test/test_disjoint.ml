(* Falsifier for the disjoint-writes retire law
   (docs/architecture/30-scheduling.md § retirement order and the landing,
   § final-state judgment).

   The law is the final-state backstop BEHIND the per-retire conflict
   judgment, which sees only observed store footprints and excuses a
   declared merge route — and the law must still convict the clobber from
   committed state alone. The coordinates make it detectable by
   construction: every committed write is recorded with the base it
   advanced from (the content its writer's witness proves it derived from;
   blind writes carry the absence case), so two writes to one address from
   one base ARE the clobber, and serialized writers cannot collide because
   the later one witnessed the earlier landing.

   Re-aimed under migration row 2 (README.md § design of record vs shipped
   engine): the landing is built from Store events, so a write that was
   never evented can no longer land at all — the old blind-writer vehicle
   is closed by construction. The blind pair now rides the declared-merge
   route past the per-retire judgment (a registered last-writer-wins merge
   fn, 30-scheduling.md § retirement order step 2), and the final-state
   law still convicts the same-base pair.

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
let read_file path = In_channel.with_open_bin path In_channel.input_all
let ( // ) = Filename.concat

(* A file store, the way the engine's tool path lands one (migration
   row 2, README.md § design of record vs shipped engine): the content
   into the committed repository's object database as a loose blob, the
   Store event carrying the oid — the retire step's landing reads exactly
   this, never any tree. *)
let store ~ledger ~repo ~node rel contents =
  let tmp = Filename.temp_file "goat_store" ".tmp" in
  write_file tmp contents;
  let out = Filename.temp_file "goat_oid" ".txt" in
  ignore
    (Sys.command
       (Printf.sprintf "git -C %s hash-object -w -- %s >%s 2>/dev/null"
          (Filename.quote repo) (Filename.quote tmp) (Filename.quote out)));
  let oid = String.trim (read_file out) in
  (try Sys.remove tmp with Sys_error _ -> ());
  (try Sys.remove out with Sys_error _ -> ());
  match Ledger.Delta_ref.blob oid with
  | None -> failwith ("hash-object printed no oid for " ^ rel)
  | Some delta ->
      ignore
        (Ledger.append ledger ~node
           (Ledger.Event.Store
              { tool = "write_file"; address = Ledger.Address.File rel; delta }))

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
(* the other's landing), both slipping past the conflict judge on the     *)
(* declared merge route.  The second landing clobbers the first; the law  *)
(* must say so.  The serialized pair is the control: the second writer    *)
(* witnessed the first's landing, so its write advances from a different  *)
(* base and the law stays satisfied.                                      *)
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
  (* The declared merge route for the contested path: the per-retire
     judgment excuses it (merge, never improvised — registered at theory
     accept), so both blind writers land and only the final-state law is
     left to convict the same-base pair. *)
  let merges =
    Retire.Merge_registry.register Retire.Merge_registry.empty
      ~address_class:"shared.txt" ~merge_fn:"last-writer-wins"
  in
  let n1 = Id.mint node_minter in
  let n2 = Id.mint node_minter in
  let n3 = Id.mint node_minter in
  let n4 = Id.mint node_minter in
  let retire node =
    match
      Retire.step ~committed ~ledger ~registry ~merges ~node
        ~witness:(Witness.observed ledger ~node)
        ~heads:[]
    with
    | Ok () -> "ok"
    | Error (Retire.Conflict _) -> "rejected (Conflict)"
    | Error (Retire.Witness_moved _) -> "rejected (Witness_moved)"
    | Error (Retire.Undischarged _) -> "rejected (Undischarged)"
  in
  (* n2 genuinely never saw n1's landing: its ledger holds no load of
     shared.txt — a blind write, base absent. *)
  store ~ledger ~repo ~node:n1 "shared.txt" "first landing\n";
  store ~ledger ~repo ~node:n2 "shared.txt" "second landing\n";
  Printf.printf "n1 (blind writer) retire: %s\n" (retire n1);
  Printf.printf "n2 (blind writer) retire: %s\n" (retire n2);
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
  store ~ledger ~repo ~node:n3 "serial.txt" "one\n";
  Printf.printf "n3 (creator) retire: %s\n" (retire n3);
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
  store ~ledger ~repo ~node:n4 "serial.txt" "two\n";
  Printf.printf "n4 (serialized rewriter) retire: %s\n" (retire n4);
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
