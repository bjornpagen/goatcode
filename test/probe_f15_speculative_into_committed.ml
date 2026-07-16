(* F15 negative probe — a speculative value flowing into committed
   structures MUST NOT typecheck.

   Law: committed state is reachable only through the retire path;
   [Retire.step] is the only writer, and it refuses (as a VALUE, not a
   type error: [Undischarged]) any node with undischarged hypotheses
   (docs/architecture/30-scheduling.md § abort by construction, § retirement
   order; lib/retire.mli).

   RECORDED GAP (the mode half of this falsifier, as the task and
   50-api.md F15 anticipate): 30-scheduling.md states the OxCaml
   enforcement as speculative results being [unique]-moded values,
   consumed exactly once by retire or by squash. The v0 implementation on
   this switch (5.2.0+ox) carries NO mode annotations anywhere in lib/ —
   speculative outputs are not [unique]-moded, so a probe of the form
   "alias a unique speculative value into a committed structure" cannot be
   written to fail against this implementation: there is no moded API for
   it to collide with. The library discharges the law by ABSTRACTION
   instead: [Retire.Committed.t] is abstract, and no function anywhere on
   the public surface inserts into it, mutates it, or converts to it —
   the only writers are [Retire.step] (which gates on hypothesis
   discharge) and [Retire.squash] (which writes nothing committed). This
   probe therefore asserts the abstraction form: the write operation a
   leak would need does not exist, so the compiler reports an unbound
   value. If the mode-based enforcement lands, this file should gain a
   second probe aliasing a [unique] speculative result.

   Legal twin: [read_committed] in probe_control.ml — reading committed
   state is open to all; only the write path is engine-only. *)

open Goatcode

(* ILLEGAL: no such operation exists on the public surface — committed
   state has no writer outside the retire path. *)
let probe (committed : Retire.Committed.t) (tuple : Retire.Committed.tuple) =
  Retire.Committed.insert committed tuple
