(* F15 negative probe — a non-idempotent effect tool under the
   [speculative] grant index MUST NOT typecheck.

   Law: effect-capable tools enter a grant only through a
   declared-idempotence witness; [Effect_tool.non_idempotent] exists only
   at the [committed] index — "a speculative node ran a non-idempotent
   effect" is not a policy violation the dispatcher catches, it is a grant
   nobody can build (docs/architecture/40-agents.md § tool grants;
   docs/architecture/20-medium.md § event taxonomy; falsifiers F12/F15;
   lib/agent.mli).

   Legal twins: [speculative_idempotent] and [committed_non_idempotent] in
   probe_control.ml — both sides the design permits compile with the same
   command that rejects this file. *)

open Goatcode

(* ILLEGAL: the non-idempotent constructor returns [committed t] only. *)
let probe () : Agent.Grant.speculative Agent.Grant.Effect_tool.t =
  Agent.Grant.Effect_tool.non_idempotent ~name:"deploy_to_prod"
