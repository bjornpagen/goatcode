(** LLM subagent invocation and the validate-and-repair loop. *)

type t
(** A handle to an LLM subagent. *)

val create : unit -> t
(** Create a subagent handle. *)
