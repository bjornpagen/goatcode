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
  ; ppx_deriving_jsonschema dropped for v0: 0.0.4 does not compile against
  ; the OxCaml-patched ppxlib (labeled-tuple core_type change). The Contract
  ; module hand-derives schemas from yojson instead.
  (ppx_expect :with-test)))
