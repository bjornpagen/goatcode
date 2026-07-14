(** Append-only event log. *)

type t
(** An append-only ledger of events. *)

val create : unit -> t
(** Create an empty ledger. *)
