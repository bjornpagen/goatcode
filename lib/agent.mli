(** Execution units: agent invocation, tool grants, prompt assembly, and
    the validate-and-repair loop.

    An executor is what a spawn statement's [by] clause names: an agent
    template (the common case), a pure function, or a shell gate — the
    latter two exist so the theory never invokes an LLM to do a compiler's
    job. The declarations live in {!Theory.Executor}; this module owns the
    runtimes behind them (docs/architecture/60-agents.md).

    The agent runtimes are {b direct provider API calls — never a CLI
    shell-out}. The harness owns the tool loop: every load, store, and
    effect an agent performs is executed here and appended to the ledger as
    an evented footprint, which is the only design under which the
    mechanized-witness law can hold (docs/architecture/30-channels.md
    § mechanized witnesses). Two layers:

    - {!Provider} — ONE stateless model turn: request out, assistant reply
      (text, tool calls, stop reason, usage) back. Three lanes behind one
      signature: Anthropic Messages, OpenAI Responses, and {!Rigged}
      (scripted turns).
    - the agent layer ({!agent}) — shared across lanes: the tool-execution
      loop, ledger eventing, grant enforcement, and (via {!invoke}) the
      repair lane and refusal recognition.

    No live LLM call happens in tests: falsifiers run entirely on
    {!Rigged} lanes; the provider lanes are never constructed by the test
    suite (docs/architecture/80-validation.md § the falsifier
    discipline). *)

(** Tool grants: the node's footprint made operational — reads within
    granted globs, writes within its own worktree, the shell gates its
    template declares.

    The grant is a type indexed by speculation status, and the forbidden
    combination has no constructor: effect-capable tools enter a grant only
    through a declared-idempotence witness, and a non-idempotent effect
    tool simply cannot be given the [speculative] index — "a speculative
    node ran a non-idempotent effect" is not a policy violation the
    dispatcher catches, it is a grant nobody can build (falsifiers F12 and
    F15; docs/architecture/60-agents.md § tool grants;
    docs/architecture/30-channels.md § event taxonomy). *)
module Grant : sig
  type speculative
  (** Phantom index: the node carries undischarged hypotheses. *)

  type committed
  (** Phantom index: the node runs on witnessed operands only. *)

  (** Declared idempotence: the stamp a template carries for an effect
      tool. This is the honest price of speculation, paid at declaration
      time. *)
  module Idempotence : sig
    type witness

    val declare : tool:string -> why:string -> witness
    (** [why] is the recorded argument (re-runnable install, content-keyed
        cache write); it lands in the ledger with any effect event. *)
  end

  (** An effect-capable tool, indexed by the speculation status it may be
      granted under. *)
  module Effect_tool : sig
    type 'status t

    val idempotent : name:string -> Idempotence.witness -> 'status t
    (** Grantable under either status: idempotent effects are squash-safe
        by declaration. *)

    val non_idempotent : name:string -> committed t
    (** Only the [committed] index exists — there is no function of this
        name (or any name) returning [speculative t] for a non-idempotent
        tool. *)
  end

  type 'status t = {
    read_globs : string list;  (** Readable paths, from the template. *)
    worktree_root : string;  (** The one writable root: the store buffer. *)
    snoop_mounts : string list;
        (** Read-only mounts of upstream store buffers this node may snoop
            (docs/architecture/30-channels.md § store-to-load
            forwarding). *)
    shell_gates : string list list;  (** Declared gate command lines. *)
    effects : 'status Effect_tool.t list;
  }

  (** A typed, in-band refusal for an action outside the grant — a tool
      error the agent can read, never a silent no-op: agents route around
      obstacles they can see. The refusal is the runtime edge of a boundary
      whose interior is compile-time. *)
  module Refusal : sig
    type t = { requested : string; boundary : string }

    val render : t -> string
  end

  val describe : _ t -> string
  (** The footprint-grant prompt section, rendered
      (docs/architecture/60-agents.md § prompt assembly, part 4). *)
end

(** Prompt assembly: derived, never authored. A hand-authored per-node
    prompt is a bug. The parts, in order: template preamble (the one
    hand-written artifact — stance and method, never shape), contract
    section (derived prose + wire schema as reference text), operand
    section (codec-rendered body tuples; hypotheses explicitly marked
    speculative), footprint grant, settlement instruction
    (docs/architecture/60-agents.md § prompt assembly). *)
module Prompt : sig
  type part =
    | Preamble of string
    | Contract_section of {
        prose : string;  (** Harvested doc comments, the derived prose. *)
        schema : Contract.Wire_schema.t;  (** Reference text, one supply. *)
      }
    | Operands of {
        witnessed : string;  (** Codec-rendered body tuples. *)
        speculative : (Speculate.Hypothesis.t * string) list;
            (** Hypothesis tuples, each rendered and explicitly marked with
                its confidence and the what-happens-on-drift contract. *)
      }
    | Footprint_grant of string
    | Settlement_instruction of string
        (** The node's final message is its head tuples against the wire
            schema, never prose for a human; reports for humans are tuples
            too. *)

  type t
  (** An assembled prompt: the parts, in the constitutional order. *)

  val assemble :
    preamble:string ->
    schema:Contract.Wire_schema.t ->
    operands:string ->
    hypotheses:(Speculate.Hypothesis.t * string) list ->
    grant:'status Grant.t ->
    t

  val parts : t -> part list
  (** Inspectable for tests; assembly order is fixed by construction. *)

  val render : t -> string
end

(** One dispatch: everything an executor needs, indexed by the node's
    speculation status so the grant index is carried, not re-checked. *)
module Invocation : sig
  type 'status t = {
    prompt : Prompt.t;
    schema : Contract.Wire_schema.t;
        (** Handed to the model API as the structured-output format; the
            decode itself stays freeform on the primary lane. *)
    grant : 'status Grant.t;
    pin : Theory.Pin.t;
  }
end

(** The provider layer: ONE stateless model turn — request (system,
    messages including tool results, tool declarations, wire schema) in,
    assistant reply (text, tool calls, stop reason, usage) out. The tool
    loop lives {e above} this signature, in the agent layer, so a provider
    never executes anything: it moves bytes to a model API and types the
    reply (docs/architecture/60-agents.md § model pins and provider
    routing, § the executor transport). *)
module Provider : sig
  (** A tool the model may call: harness-owned declarations, one per tool
      the grant admits. *)
  module Tool_decl : sig
    type t = {
      name : string;
      description : string;
      input_schema : Yojson.Safe.t;  (** Plain JSON Schema, harness-authored. *)
    }
  end

  (** One requested tool call in an assistant reply. *)
  module Call : sig
    type t = { id : string; name : string; input : Yojson.Safe.t }
  end

  (** The harness's answer to one call. [is_error] carries typed in-band
      failures (grant refusals, missing files) the agent can read. *)
  module Tool_result : sig
    type t = { call_id : string; output : string; is_error : bool }
  end

  (** Provider-neutral conversation history; each lane encodes it into its
      wire format. *)
  module Message : sig
    type t =
      | User of string
      | Assistant of { text : string; calls : Call.t list }
      | Tool_results of Tool_result.t list
  end

  (** Why the turn ended. [Refused] is a typed outcome (Anthropic
      [stop_reason: "refusal"], an OpenAI [refusal] content item): it
      routes to the repair/fallback lane and is never parsed as payload. *)
  type stop = End_turn | Tool_calls | Refused

  type reply = {
    text : string;
    calls : Call.t list;
    stop : stop;
    usage : Ledger.Usage.t;
  }

  type request = {
    pin : Theory.Pin.t;
    system : string;
    messages : Message.t list;
    tools : Tool_decl.t list;
    schema : Contract.Wire_schema.t;
        (** The head contract, sent as the structured-output format. *)
  }

  type t = { turn : request -> (reply, Ledger.Fault.t) result }

  val anthropic : unit -> t
  (** Anthropic Messages API, direct ([POST /v1/messages]). Reads
      [ANTHROPIC_API_KEY] from the environment at turn time; an unset key
      is an executor fault, never a crash. Fable-5 rules are encoded here:
      no [thinking] parameter, no sampling knobs, [output_config] carries
      effort and the json_schema format. *)

  val openai : unit -> t
  (** OpenAI Responses API, direct ([POST /v1/responses], stateless:
      [store: false], full history each turn). Reads [OPENAI_API_KEY] at
      turn time. *)
end

(** The executor interface: how one invocation runs to a raw reply. The
    engine owns everything around it (parsing, repair, settlement); an
    executor produces the turn's final text — and, because the harness owns
    the tool loop, it also owes the ledger every tool event, which is why
    [run] takes the ledger and the node identity. *)
module Executor : sig
  type reply = {
    text : string;
    usage : Ledger.Usage.t;  (** Summed across the invocation's turns. *)
    refusal : bool;
        (** The provider typed this turn as a refusal; routed to the
            repair/fallback lane by {!invoke}, never parsed as payload. *)
  }

  type t = {
    run :
      'status.
      'status Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:(unit -> Speculate.Drift.note list) ->
      (reply, Ledger.Fault.t) result;
        (** Run one invocation. [on_yield] is called between tool calls —
            the fiber's suspension points — and returns any drift notes
            that passed the node's footprint filter; each note carries the
            disposition the scheduler already decided (check-on-yield,
            docs/architecture/30-channels.md § delivery). A
            [`Stop_cleanly] disposition obliges the executor to finish no
            further work and emit nothing. *)
  }
end

val agent : provider:Provider.t -> Executor.t
(** The agent layer over one provider lane — shared across all three, so
    there is exactly one tool loop, one grant boundary, one eventing path.
    Per turn: send the conversation, receive the reply, log an
    [Agent_turn]; on tool calls, execute each within the grant and append
    the matching ledger event with its footprint —

    - {b Load} ([read_file], [glob_list], [grep]): reads within the grant's
      [read_globs], the worktree, or a snoop mount; the observed content
      hash enters the witness triple.
    - {b Store} ([write_file], [str_replace_edit]): writes land {e only} in
      the node's worktree; the event carries the address and a delta ref.
    - {b Effect} ([run_command]): granted only when the grant's [effects]
      carry a tool of that name — which the type index already polices
      (F12/F15) — and runs behind the mkdir-atomic, holder-named machine
      lock.

    An action outside the grant returns a typed in-band tool error
    ({!Grant.Refusal}, [is_error] on the result), never a silent no-op.
    After each tool batch the loop calls [on_yield]; a stop-cleanly note
    ends the invocation with no further work and nothing emitted
    (docs/architecture/60-agents.md § tool grants, § drift notes at
    yield). *)

(** Deterministic fakes: scripted provider turns — outputs, delays, faults,
    invalid-output injections, and scripted tool calls — what makes the
    whole falsifier roster runnable in CI without a model call. Live-model
    runs validate templates, never engine laws
    (docs/architecture/80-validation.md § the falsifier discipline). *)
module Rigged : sig
  type step =
    | Reply of string  (** An end-turn reply with this final text. *)
    | Invalid of string  (** Injected parse failure: exercises the repair lane. *)
    | Refuse of string
        (** A typed provider refusal: exercises the fallback lane. *)
    | Fault of string  (** Provider error: exercises fault settlement. *)
    | Delay_s of float  (** Scheduling pressure without wall-clock cost in tests. *)
    | Yield
        (** A turn boundary with no tool work: forces an [on_yield] — the
            drift-note delivery point. *)
    | Call_tool of { name : string; input : Yojson.Safe.t }
        (** A scripted tool call: drives the harness tool loop (and its
            Load/Store/Effect eventing) offline. *)

  val provider : script:step list -> Provider.t
  (** Steps are consumed in order across turns of the same provider value
      (a repair re-invocation consumes the next step), so F10 can script
      "invalid, invalid, valid" and count attempts. *)

  val executor : script:step list -> Executor.t
  (** [agent ~provider:(provider ~script)] — the offline lane, behind the
      same tool loop as the live ones. *)
end

val pure_fn : (Yojson.Safe.t -> (Yojson.Safe.t, string) result) -> Executor.t
(** Host OCaml as an executor: operand JSON in, head-tuple JSON out.
    Mechanical transforms that never deserve tokens. *)

val shell_gate : Executor.t
(** Runs the command line declared on the {!Theory.Executor.Shell_gate};
    exit status and captured output become the head tuple. *)

(** The bounded repair budget, configured per template, small. *)
module Repair_budget : sig
  type t

  val v : int -> t
  val attempts : t -> int
end

val invoke :
  executor:Executor.t ->
  ?fallback:Executor.t ->
  codec:'a Contract.Codec.t ->
  registry:Id.Registry.t ->
  invocation:'status Invocation.t ->
  budget:Repair_budget.t ->
  ledger:Ledger.t ->
  node:Ledger.node Id.t ->
  on_yield:(unit -> Speculate.Drift.note list) ->
  ('a, Ledger.Fault.t) result
(** The primary lane: freeform generation, then the boundary parse through
    the derived codec, then — on parse or schema failure — the repair loop:
    the same agent re-invoked stateless-with-diagnostics (its own invalid
    output plus the parser's specific complaints), at most
    [Repair_budget.attempts] times, each attempt a ledger
    [Repair_attempt] event. A recognized refusal (typed by the provider or
    marker-recognized by the codec) routes one retry to [fallback] (the
    constrained-decode lane, grammar derived from the same schema) instead
    of burning budget. Exhaustion returns [Fault.Repair_exhausted]; nothing
    invalid ever crosses the boundary (falsifier F10;
    docs/architecture/60-agents.md § the primary lane;
    docs/architecture/50-commit.md § the repair lane — one lane, two entry
    points). *)

val invoke_parsed :
  executor:Executor.t ->
  ?fallback:Executor.t ->
  parse:(string -> ('a, Contract.Repair.diagnostics) result) ->
  invocation:'status Invocation.t ->
  budget:Repair_budget.t ->
  ledger:Ledger.t ->
  node:Ledger.node Id.t ->
  on_yield:(unit -> Speculate.Drift.note list) ->
  ('a, Ledger.Fault.t) result
(** {!invoke} with the boundary parse supplied by the caller — the same
    single repair lane behind a different decoder. The chase engine enters
    here while its head parse is still its own (its migration onto
    [Contract.Codec] is the recorded B1 rewiring); when that lands, this
    entry remains for tests that need a scripted boundary. There is exactly
    one repair-loop implementation; {!invoke} is [invoke_parsed] applied to
    the codec's parse. *)
