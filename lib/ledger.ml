(* Stubs only: signatures are normative (see ledger.mli). *)

type node = unit
type hypothesis = unit

module Timestamp = struct
  type t = unit

  let compare _ _ = failwith "TODO: ledger"
  let to_seconds _ = failwith "TODO: ledger"
  let pp _ _ = failwith "TODO: ledger"
end

module Usage = struct
  type t = { tokens_in : int; tokens_out : int }

  let zero = { tokens_in = 0; tokens_out = 0 }
  let add _ _ = failwith "TODO: ledger"
  let total _ = failwith "TODO: ledger"
end

module Address = struct
  type t =
    | File of string
    | Tuple of { relation : string; id : string }
    | Contract of string
    | Resource of string

  let equal _ _ = failwith "TODO: ledger"
  let compare _ _ = failwith "TODO: ledger"
  let to_string _ = failwith "TODO: ledger"
  let pp _ _ = failwith "TODO: ledger"
end

module Generation = struct
  type t = unit

  let zero = ()
  let next _ = failwith "TODO: ledger"
  let equal _ _ = failwith "TODO: ledger"
  let compare _ _ = failwith "TODO: ledger"
  let pp _ _ = failwith "TODO: ledger"
end

module Content_hash = struct
  type t = unit

  let of_string _ = failwith "TODO: ledger"
  let equal _ _ = failwith "TODO: ledger"
  let compare _ _ = failwith "TODO: ledger"
  let to_hex _ = failwith "TODO: ledger"
  let pp _ _ = failwith "TODO: ledger"
end

module Delta_ref = struct
  type t = unit

  let to_string _ = failwith "TODO: ledger"
  let pp _ _ = failwith "TODO: ledger"
end

module Footprint = struct
  type t = unit

  let empty = ()
  let of_list _ = failwith "TODO: ledger"
  let to_list _ = failwith "TODO: ledger"
  let mem _ _ = failwith "TODO: ledger"
  let union _ _ = failwith "TODO: ledger"
  let inter _ _ = failwith "TODO: ledger"
  let is_empty _ = failwith "TODO: ledger"
end

module Provenance = struct
  type t = {
    statement : Theory.Statement.id;
    consumed : (string * string) list;
    hypotheses : hypothesis Id.t list;
  }
end

module Fault = struct
  type origin = Executor_error | Repair_exhausted | Context_exhausted
  type t = { origin : origin; message : string }
end

module Squash_cause = struct
  type t =
    | Dead_hypothesis of hypothesis Id.t
    | Upstream_fault of node Id.t
    | Upstream_squash of node Id.t
    | Operator_abort
end

module Settlement = struct
  type t = Retired | Faulted of Fault.t | Squashed of Squash_cause.t
end

module Event = struct
  type kind =
    | Load of {
        tool : string;
        observed : (Address.t * Generation.t * Content_hash.t) list;
      }
    | Store of { tool : string; address : Address.t; delta : Delta_ref.t }
    | Effect of { tool : string; resource : string; idempotent : bool }
    | Agent_turn of { usage : Usage.t }
    | Fired of { provenance : Provenance.t; minted : (string * string) list }
    | Hypothesis_taken of {
        hypothesis : hypothesis Id.t;
        address : Address.t;
        source : string;
        content : Content_hash.t;
        confidence : float;
      }
    | Hypothesis_discharged of { hypothesis : hypothesis Id.t }
    | Invalidation_sent of {
        address : Address.t;
        new_generation : Generation.t;
      }
    | Drift_note of { address : Address.t; cls : string; route : string }
    | Repair_attempt of { attempt : int; refusal : bool }
    | Settled of Settlement.t
    | Decision of {
        action : string;
        reason : string;
        counters : (string * float) list;
      }
    | Pin_bump of { statement : string; executor : string; pin : string }
    | Switch_thrown of {
        statement : string;
        executor : string;
        churn : float;
      }
    | Law_verdict of { law : string; satisfied : bool }
    | Correction of { subject : string; cause : string }

  type t = { node : node Id.t option; at : Timestamp.t; kind : kind }
end

type t = unit

let create ~path:_ = failwith "TODO: ledger"
let load ~path:_ = failwith "TODO: ledger"
let append _ ?node:_ _ = failwith "TODO: ledger"

module Replay = struct
  let events _ = failwith "TODO: ledger"
end

module Telemetry = struct
  type timing = { blocked_s : float; queued_s : float; run_s : float }

  let timing _ _ = failwith "TODO: ledger"
  let usage _ _ = failwith "TODO: ledger"
  let run_usage _ = failwith "TODO: ledger"
end

module Predictor_history = struct
  type sample = {
    survived : bool;
    reconcile_tokens : int;
    flush_tokens : int;
    overlap_s : float;
  }

  let samples _ ~statement:_ ~executor:_ ~pin:_ = failwith "TODO: ledger"
end

module Witness_index = struct
  let reads _ _ = failwith "TODO: ledger"
  let writes _ _ = failwith "TODO: ledger"
end
