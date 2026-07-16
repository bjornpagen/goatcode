(* F15 negative probe — wrong-relation phantom ref MUST NOT typecheck.

   Law: a ref slot is a ['target Id.t]; a verdict referencing a [change]
   where a [finding] belongs is a compile error in host code, never a
   runtime admission check (docs/architecture/10-theory.md § failure
   surface; lib/id.mli). The dune rule compiling this file accepts only
   exit code 2 and asserts the error class "is not compatible with type".

   Legal twin: [well_typed_ref] in probe_control.ml. *)

open Goatcode

type finding
type change

type verdict = { subject : finding Id.t }

(* ILLEGAL: a change-realm id in a finding-realm ref slot. *)
let probe (id : change Id.t) : verdict = { subject = id }
