(* F15 negative probe — fabricated churn evidence MUST NOT typecheck.

   Law: a [Speculate.Churn.measurement] is obtainable only from a ledger
   ([Churn.measure]) — there is no public constructor, so the off switch
   cannot be thrown on folklore (docs/architecture/30-scheduling.md
   § speculation is default-on; lib/speculate.mli).

   The probe writes the measurement down as if it were a record. The type
   is abstract: no record fields, no constructors, nothing to forge —
   the compiler reports an unbound field, which is exactly the shape of
   "no constructor exists".

   Legal twin: [switch_with_evidence] in probe_control.ml (evidence
   obtained as a value of the abstract type). Runtime companion:
   test_probes.ml shows [Churn.measure] returning [None] on a ledger with
   no churn regime — no evidence, no switch, by construction. *)

open Goatcode

(* ILLEGAL: the measurement type has no fields to write. *)
let probe () : Speculate.Churn.measurement = { lengthening_s = 12.0 }
