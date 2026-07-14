(** Hypotheses, survival-counter predictor, and token budget governor. *)

type t
(** Speculation state: live hypotheses plus predictor and governor state. *)

val create : unit -> t
(** Create fresh speculation state. *)
