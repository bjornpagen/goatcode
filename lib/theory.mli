(** Relations and dependency statements (TGDs, EGDs, cardinality windows):
    the work-structure DSL. *)

type t
(** A theory: a set of relations plus the dependency statements over them. *)

val empty : t
(** The empty theory. *)
