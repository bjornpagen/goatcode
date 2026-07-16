(* F15 negative probe — smuggling a non-idempotent effect tool into a
   speculative grant's [effects] list MUST NOT typecheck.

   Same law as probe_f15_nonidem_speculative.ml, attacked through the
   record rather than the annotation: take a well-formed speculative grant
   and try to extend its tool surface with the non-idempotent case. The
   phantom index on [Effect_tool.t] flows through the [effects] field, so
   the record update is a type error — there is no coercion point anywhere
   between the constructor and the grant
   (docs/architecture/40-agents.md § tool grants; lib/agent.mli).

   Legal twin: [speculative_grant_with_idempotent_effect] in
   probe_control.ml. *)

open Goatcode

(* ILLEGAL: [committed Effect_tool.t] in a [speculative Grant.t]. *)
let probe (grant : Agent.Grant.speculative Agent.Grant.t) :
    Agent.Grant.speculative Agent.Grant.t =
  {
    grant with
    Agent.Grant.effects =
      [ Agent.Grant.Effect_tool.non_idempotent ~name:"send_email" ];
  }
