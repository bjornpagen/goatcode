let%expect_test "contract payload round-trips through yojson" =
  let payload = { Goatcode.Contract.relation = "task"; arity = 2 } in
  let json = Goatcode.Contract.yojson_of_payload payload in
  print_string (Yojson.Safe.to_string json);
  [%expect {| {"relation":"task","arity":2} |}]

let%expect_test "contract payload schema is derivable" =
  print_string (Yojson.Safe.to_string Goatcode.Contract.payload_schema);
  [%expect
    {| {"type":"object","properties":{"relation":{"type":"string"},"arity":{"type":"integer"}},"required":["relation","arity"]} |}]
