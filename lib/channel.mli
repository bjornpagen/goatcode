(** Unidirectional invalidation delivery and footprints. *)

type t
(** A unidirectional invalidation channel. *)

val create : unit -> t
(** Create a channel. *)
