(* Stubs only: signatures are normative (see agent.mli). *)

module Grant = struct
  type speculative = unit
  type committed = unit

  module Idempotence = struct
    type witness = unit

    let declare ~tool:_ ~why:_ = failwith "TODO: agent"
  end

  module Effect_tool = struct
    type 'status t = unit

    let idempotent ~name:_ _ = failwith "TODO: agent"
    let non_idempotent ~name:_ = failwith "TODO: agent"
  end

  type 'status t = {
    read_globs : string list;
    worktree_root : string;
    snoop_mounts : string list;
    shell_gates : string list list;
    effects : 'status Effect_tool.t list;
  }

  module Refusal = struct
    type t = { requested : string; boundary : string }

    let render _ = failwith "TODO: agent"
  end

  let describe _ = failwith "TODO: agent"
end

module Prompt = struct
  type part =
    | Preamble of string
    | Contract_section of {
        prose : string;
        schema : Contract.Wire_schema.t;
      }
    | Operands of {
        witnessed : string;
        speculative : (Speculate.Hypothesis.t * string) list;
      }
    | Footprint_grant of string
    | Settlement_instruction of string

  type t = unit

  let assemble ~preamble:_ ~schema:_ ~operands:_ ~hypotheses:_ ~grant:_ =
    failwith "TODO: agent"

  let parts _ = failwith "TODO: agent"
  let render _ = failwith "TODO: agent"
end

module Invocation = struct
  type 'status t = {
    prompt : Prompt.t;
    schema : Contract.Wire_schema.t;
    grant : 'status Grant.t;
    pin : Theory.Pin.t;
  }
end

module Executor = struct
  type reply = { text : string; usage : Ledger.Usage.t }

  type t = {
    run :
      'status.
      'status Invocation.t ->
      on_yield:(unit -> Speculate.Drift.note list) ->
      (reply, Ledger.Fault.t) result;
  }
end

module Rigged = struct
  type step =
    | Reply of string
    | Invalid of string
    | Refuse of string
    | Fault of string
    | Delay_s of float
    | Yield

  let executor ~script:_ = failwith "TODO: agent"
end

let claude_cli ?binary:_ () = failwith "TODO: agent"
let pure_fn _ = failwith "TODO: agent"

let shell_gate =
  { Executor.run = (fun _ ~on_yield:_ -> failwith "TODO: agent") }

module Repair_budget = struct
  type t = unit

  let v _ = failwith "TODO: agent"
  let attempts _ = failwith "TODO: agent"
end

let invoke ~executor:_ ?fallback:_ ~codec:_ ~registry:_ ~invocation:_
    ~budget:_ ~ledger:_ ~node:_ ~on_yield:_ =
  failwith "TODO: agent"
