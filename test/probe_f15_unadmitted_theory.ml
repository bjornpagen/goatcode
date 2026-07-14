(* F15 negative probe — [Run.exec] on an unadmitted theory MUST NOT
   typecheck.

   Law: [Theory.admitted] has no public constructor; the only way to obtain
   one is [Theory.declare], whose result type carries the admission errors.
   Handing the un-matched [declare] result straight to the engine is the
   only spelling of "run an unadmitted theory" the language even lets us
   write down, and it is a type error — an unadmitted theory cannot reach
   the engine by any code path (docs/architecture/10-theory.md
   § termination; docs/architecture/70-api.md § running; lib/theory.mli).

   The other spelling — forging a [Theory.admitted] value directly — is not
   a probe file because there is literally no expression to write: the type
   is abstract with no constructor, no [of_*], no [Meta] bypass ([Meta.admit]
   returns the same result type). Absence of syntax is the strongest form of
   the law; this probe pins the nearest expressible approach.

   Legal twin: [exec_admitted] in probe_control.ml. *)

open Goatcode

(* ILLEGAL: the declare result is [(admitted, Admission.error list) result],
   not [admitted]; the engine's signature refuses it. *)
let probe (config : Run.config) =
  Run.exec
    ~theory:(Theory.declare ~relations:[] ~statements:[] ~laws:[])
    ~seed:[] ~config
