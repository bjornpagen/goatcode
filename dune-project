(lang dune 3.19)

(name goatcode)

(package
 (name goatcode)
 (synopsis "GOAT CODE: a speculative-execution agent-swarm harness")
 (depends
  ocaml
  dune
  ppxlib
  yojson
  ppx_yojson_conv
  ppx_deriving_jsonschema
  (ppx_expect :with-test)))
