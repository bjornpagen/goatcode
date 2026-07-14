(** Read-sets and per-address generations. *)

type t
(** A witness: the read-set of a computation with per-address generations. *)

val create : unit -> t
(** Create an empty witness. *)
