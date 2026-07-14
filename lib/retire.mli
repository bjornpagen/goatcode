(** Worktree merge in dependency order and retire-time judgment. *)

type t
(** Retirement state for merging worktrees in dependency order. *)

val create : unit -> t
(** Create retirement state. *)
