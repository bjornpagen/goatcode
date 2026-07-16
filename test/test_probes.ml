(* F15 — compile-time probes (docs/architecture/50-api.md).

   Every state the docs declare *unrepresentable* has a negative
   compilation test: a probe file that must NOT typecheck, compiled by a
   dune rule (see test/dune) that accepts only the compiler's failure exit
   and greps the diagnostic for the expected error class. A probe that
   compiles turns the suite red — an "unrepresentable" that compiles is a
   doc bug or a type bug, and either way the suite goes red.

   The probe roster (each file names its law, its owning doc, and its
   legal twin in probe_control.ml):

   - probe_f15_wrong_relation_ref.ml       wrong-relation phantom ref
                                           (10-theory.md § failure surface)
   - probe_f15_unadmitted_theory.ml        Run.exec on an unadmitted theory
                                           (10-theory.md § termination,
                                            50-api.md § running)
   - probe_f15_bare_switch.ml              bare Switch.throw, no evidence
                                           (30-scheduling.md § default-on)
   - probe_f15_forged_churn.ml             fabricated churn evidence
                                           (30-scheduling.md § default-on)
   - probe_f15_nonidem_speculative.ml      non-idempotent effect tool at the
                                           speculative index
                                           (40-agents.md § tool grants)
   - probe_f15_nonidem_in_grant.ml         same law, attacked via the grant
                                           record's effects list
   - probe_f15_speculative_into_committed.ml
                                           speculative value into committed
                                           structures (30-scheduling.md § abort
                                           by construction) — carries the
                                           RECORDED GAP: 30-scheduling.md words
                                           this law in terms of unique-moded
                                           values; lib/ on this switch uses
                                           no modes, so the probe asserts
                                           the abstraction form (no writer
                                           into Retire.Committed.t exists)
                                           and the mode-level probe is
                                           inexpressible against this
                                           implementation.
   - probe_f15_rx_publish.ml               publish on a reader end
                                           (20-medium.md § the derivation law)
   - probe_control.ml                      the harness control: MUST compile
                                           with the same command, so the
                                           negatives fail on the library's
                                           refusal, never on a broken
                                           harness.

   This module holds the RUNTIME companions: the same boundaries have wire
   edges (an agent is untyped with respect to our phantoms), and each
   compile-time refusal pairs with a runtime rejection at the codec/ledger
   boundary. Deterministic, no executors, no model calls. *)

open Goatcode

(* Phantom realms standing in for relation payload types. *)
type finding_realm
type change_realm

(* A minimal payload + contract, for driving Theory.declare. *)
type task = { title : string }

let task_schema : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc [ ("title", `Assoc [ ("type", `String "string") ]) ]);
      ("required", `List [ `String "title" ]);
      ("additionalProperties", `Bool false);
    ]

let task_codec =
  Contract.Codec.v
    ~of_json:(function
      | `Assoc kv -> (
          match List.assoc_opt "title" kv with
          | Some (`String s) -> { title = s }
          | _ -> failwith "task: title must be a string")
      | _ -> failwith "task: object expected")
    ~to_json:(fun t -> `Assoc [ ("title", `String t.title) ])

let relation name = Theory.Relation.v ~name (Contract.v ~name ~schema:task_schema ~codec:task_codec)

(* Companion to probe_f15_unadmitted_theory.ml: the only path to
   [Theory.admitted] is [declare], and declare is a real gate — a
   self-spawning statement (a cycle through the head's mint position) comes
   back as [Error], so the value the compile probe shows cannot be forged
   also cannot be earned for a non-terminating theory. *)
let%expect_test "F15 companion: admission is the only gate and it rejects" =
  let task = relation "task" in
  let statements =
    [
      Theory.Spawn.v ~name:"expand" ~for_:"task"
        ~exists:("task", Theory.Window.exactly 1)
        ~by:(Theory.Executor.Pure_fn { name = "copy" })
        ();
    ]
  in
  (match
     Theory.declare
       ~relations:[ Theory.Relation.Packed task ]
       ~statements ~laws:[]
   with
  | Ok _ -> print_endline "BUG: self-spawning theory admitted"
  | Error errs ->
      List.iter (fun e -> print_endline (Theory.Admission.to_string e)) errs);
  [%expect
    {| weak-acyclicity violation: this statement chain can spawn itself forever; cycle through mint positions [task.id] |}]

(* The acyclic twin admits, and its admitted value feeds the churn
   companion below — no re-checking anywhere downstream. *)
let admit_linear () : Theory.admitted =
  let statements =
    [
      Theory.Spawn.v ~name:"review" ~for_:"task"
        ~exists:("verdict", Theory.Window.exactly 1)
        ~by:(Theory.Executor.Pure_fn { name = "judge" })
        ();
    ]
  in
  match
    Theory.declare
      ~relations:
        [
          Theory.Relation.Packed (relation "task");
          Theory.Relation.Packed (relation "verdict");
        ]
      ~statements ~laws:[]
  with
  | Ok admitted -> admitted
  | Error errs ->
      List.iter (fun e -> prerr_endline (Theory.Admission.to_string e)) errs;
      failwith "linear theory failed admission"

(* Companion to probe_f15_wrong_relation_ref.ml: the wire edge of the
   phantom-ref law. An agent's reply is untyped, so the phantom cannot
   protect it — [Id.Registry.resolve] does, and it accepts exactly the ids
   this run's own minters produced, in the realm they were minted in. *)
let%expect_test "F15 companion: wire ids resolve only against mint provenance"
    =
  let reg = Id.Registry.create () in
  let minter : finding_realm Id.Minter.t =
    Id.Minter.create ~registry:reg ~realm:"finding"
  in
  let fid = Id.mint minter in
  let s = Id.to_string fid in
  (match Id.Registry.resolve reg ~realm:"finding" s with
  | Ok (_ : finding_realm Id.t) ->
      print_endline "minted id resolves in its own realm"
  | Error (`Unknown_id u) -> Printf.printf "BUG: own id rejected: %s\n" u);
  (match Id.Registry.resolve reg ~realm:"change" s with
  | Ok (_ : change_realm Id.t) ->
      print_endline "BUG: finding id resolved in the change realm"
  | Error (`Unknown_id u) ->
      Printf.printf "cross-realm resolve rejected: %s\n" u);
  (match Id.Registry.resolve reg ~realm:"finding" "finding-999" with
  | Ok (_ : finding_realm Id.t) -> print_endline "BUG: invented id resolved"
  | Error (`Unknown_id u) -> Printf.printf "invented id rejected: %s\n" u);
  [%expect
    {|
    minted id resolves in its own realm
    cross-realm resolve rejected: finding#0
    invented id rejected: finding-999
    |}]

(* Companion to probe_f15_speculative_into_committed.ml: provisional ids
   bind exactly once (at their minting node's retirement) and a squashed
   node's provisional ids die — they never resolve again, nothing
   renumbers (30-scheduling.md § provisional identity). *)
let%expect_test "F15 companion: provisional ids bind once, dropped ids die" =
  let reg = Id.Registry.create () in
  let minter : finding_realm Id.Minter.t =
    Id.Minter.create ~registry:reg ~realm:"finding"
  in
  let a = Id.mint minter in
  (match Id.Registry.status reg a with
  | Some `Provisional -> print_endline "minted: provisional"
  | Some `Committed -> print_endline "BUG: committed at mint"
  | None -> print_endline "BUG: unknown to its own registry");
  (match Id.Registry.bind reg a with
  | Ok () -> print_endline "bound at retirement"
  | Error `Already_bound -> print_endline "BUG: fresh id already bound");
  (match Id.Registry.status reg a with
  | Some `Committed -> print_endline "bound: committed"
  | _ -> print_endline "BUG: bind did not commit");
  (match Id.Registry.bind reg a with
  | Ok () -> print_endline "BUG: double bind accepted"
  | Error `Already_bound -> print_endline "second bind refused");
  let b = Id.mint minter in
  Id.Registry.drop_provisional reg [ b ];
  (match Id.Registry.resolve reg ~realm:"finding" (Id.to_string b) with
  | Ok (_ : finding_realm Id.t) -> print_endline "BUG: squashed id resolved"
  | Error (`Unknown_id u) -> Printf.printf "squashed id never resolves: %s\n" u);
  [%expect
    {|
    minted: provisional
    bound at retirement
    bound: committed
    second bind refused
    squashed id never resolves: finding#1
    |}]

(* Companion to probe_f15_bare_switch.ml / probe_f15_forged_churn.ml: the
   only constructor of churn evidence is [Churn.measure], and on a ledger
   with no churn regime it returns [None] — no evidence exists, so no
   switch can be built, by construction (30-scheduling.md § default-on). *)
let%expect_test "F15 companion: no churn regime in the ledger, no evidence" =
  let admitted = admit_linear () in
  let statement, spawn =
    match Theory.statements admitted with
    | (s, sp) :: _ -> (s, sp)
    | [] -> failwith "admitted theory lost its statement"
  in
  let shape =
    {
      Speculate.Shape.statement;
      executor = Theory.Executor.id spawn.Theory.Spawn.by;
      pin = "(none)";
    }
  in
  let path = Filename.temp_file "goatcode_f15_probe" ".ledger" in
  Sys.remove path;
  let ledger = Ledger.create ~path in
  (match Speculate.Churn.measure ledger ~shape with
  | None -> print_endline "no churn regime: no measurement, no switch"
  | Some m ->
      Printf.printf "BUG: evidence from an empty ledger (%.3fs)\n"
        (Speculate.Churn.lengthening_s m));
  Sys.remove path;
  [%expect {| no churn regime: no measurement, no switch |}]
