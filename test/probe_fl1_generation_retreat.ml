(* FL1 negative-compile arm (docs/architecture/50-api.md § the flat-org
   roster): no constructor takes a generation backward. The generation
   vocabulary is [zero] and [next] — a retreat is unwritable, not
   guarded, so squash-as-revert cannot even be spelled against the
   committed coordinate. This probe must NOT typecheck; the legal twin
   (the forward move, [Generation.next]) lives in probe_control.ml. *)

let retreat (g : Goatcode.Ledger.Generation.t) :
    Goatcode.Ledger.Generation.t =
  Goatcode.Ledger.Generation.prev g
