(** The scheduler: fires dependency statements when their bodies are
    witnessed. *)

type t
(** A chase scheduler instance. *)

val create : unit -> t
(** Create a scheduler. *)
