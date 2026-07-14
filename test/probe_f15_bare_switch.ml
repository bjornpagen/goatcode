(* F15 negative probe — a bare [Switch.throw] MUST NOT typecheck.

   Law: the per-shape speculation off switch is representation-enforced —
   [Speculate.Switch.throw] requires a [Churn.measurement], so a switch
   thrown without churn evidence is not rejected by the config loader, it
   is unconstructible (docs/architecture/70-api.md § running;
   docs/architecture/40-scheduling.md § speculation is default-on;
   lib/speculate.mli).

   The probe: throw with everything EXCEPT the evidence and claim the
   result is a switch. What comes back is a function still demanding
   [~evidence:Churn.measurement] — the annotation is a type error, and the
   error text names the missing evidence type.

   Legal twin: [switch_with_evidence] in probe_control.ml. See also
   probe_f15_forged_churn.ml for the "fabricate the evidence" approach. *)

open Goatcode

(* ILLEGAL: no evidence, no switch. *)
let probe () : Speculate.Switch.t =
  Speculate.Switch.throw ~thrown_by:`Operator
