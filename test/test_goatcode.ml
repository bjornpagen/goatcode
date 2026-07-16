(* Placeholder until the falsifier roster lands (docs/architecture/
   50-api.md): asserts the v0 interfaces exist and link without
   executing any stub body. Every future test drives the library through
   the public surface with rigged executors ([Agent.Rigged]); no test ever
   constructs [Agent.claude_cli]. *)

let%expect_test "v0 interfaces link" =
  let (_ : Goatcode.Theory.admitted option) = None in
  let (_ : Goatcode.Run.settled option) = None in
  let (_ : Goatcode.Ledger.Settlement.t option) = None in
  let (_ : Goatcode.Ledger.Drift.route option) = None in
  print_string "ok";
  [%expect {| ok |}]
