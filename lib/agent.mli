(** Execution units: agent invocation, tool grants, prompt assembly, and
    the validate-and-repair loop.

    An executor is what a spawn statement's [by] clause names: an agent
    template (the common case), a pure function, or a shell gate — the
    latter two exist so the theory never invokes an LLM to do a compiler's
    job. The declarations live in {!Theory.Executor}; this module owns the
    runtimes behind them (docs/architecture/60-agents.md).

    No live LLM call happens in tests: falsifiers run entirely on
    {!Rigged} executors; {!claude_cli} is the real lane and is never
    constructed by the test suite
    (docs/architecture/80-validation.md § the falsifier discipline). *)

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
        (** Handed to the model API as the structured-output reference; the
            decode itself stays freeform on the primary lane. *)
    grant : 'status Grant.t;
    pin : Theory.Pin.t;
  }
end

(** The executor interface: how one invocation runs to a raw reply. The
    engine owns everything around it (parsing, repair, settlement); an
    executor only produces text and yields. *)
module Executor : sig
  type reply = { text : string; usage : Ledger.Usage.t }

  type t = {
    run :
      'status.
      'status Invocation.t ->
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

(** Deterministic fakes: scripted outputs, delays, faults, and
    invalid-output injections — what makes the whole falsifier roster
    runnable in CI without a model call. Live-model runs validate
    templates, never engine laws
    (docs/architecture/80-validation.md § the falsifier discipline). *)
module Rigged : sig
  type step =
    | Reply of string  (** Returned as the turn's final text. *)
    | Invalid of string  (** Injected parse failure: exercises the repair lane. *)
    | Refuse of string  (** Refusal markers: exercises the fallback lane. *)
    | Fault of string  (** Executor error: exercises fault settlement. *)
    | Delay_s of float  (** Scheduling pressure without wall-clock cost in tests. *)
    | Yield  (** Force an [on_yield] — the drift-note delivery point. *)

  val executor : script:step list -> Executor.t
  (** Steps are consumed in order across invocations of the same executor
      value (a repair re-invocation consumes the next step), so F10 can
      script "invalid, invalid, valid" and count attempts. *)
end

val claude_cli : ?binary:string -> unit -> Executor.t
(** The real lane: shells out to the [claude] CLI ([binary] defaults to
    ["claude"]), one process per invocation, prompt on stdin, reply on
    stdout, usage parsed from the CLI's reporting. {b Never constructed by
    tests}; [dune test] must not spawn it, and no falsifier references it. *)

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
    [Repair_attempt] event. A recognized refusal routes one retry to
    [fallback] (the constrained-decode lane, grammar derived from the same
    schema) instead of burning budget. Exhaustion returns
    [Fault.Repair_exhausted]; nothing invalid ever crosses the boundary
    (falsifier F10; docs/architecture/60-agents.md § the primary lane;
    docs/architecture/50-commit.md § the repair lane — one lane, two entry
    points). *)
