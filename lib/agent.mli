(** Execution units: agent invocation, tool grants, prompt assembly, and
    the validate-and-repair loop.

    An executor is what a spawn statement's [by] clause names: an agent
    template (the common case), a pure function, or a shell gate — the
    latter two exist so the theory never invokes an LLM to do a compiler's
    job. The declarations live in {!Theory.Executor}; this module owns the
    runtimes behind them (docs/architecture/40-agents.md).

    The agent runtimes are {b direct provider API calls — never a CLI
    shell-out}. The harness owns the tool loop: every load, store, and
    effect an agent performs is executed here and appended to the ledger as
    an evented footprint, which is the only design under which the
    mechanized-witness law can hold (docs/architecture/20-medium.md
    § mechanized witnesses). Two layers:

    - {!Provider} — ONE stateless model turn: request out, assistant reply
      back as a typed {!Provider.outcome}. Three lanes behind one
      signature: Anthropic Messages, OpenAI Responses, and {!Rigged}
      (scripted turns).
    - the agent layer ({!agent}) — shared across lanes: the tool-execution
      loop, ledger eventing, grant enforcement, loop bounds ({!Stop}), and
      (via {!invoke}) the repair lane and refusal recognition.

    Design discipline throughout (docs/architecture/README.md rule 8): the
    representation carries the logic. Tools are values in a table derived
    from the grant — capability is the table, so an ungranted action has no
    entry to dispatch to; tool paths are parsed once into a bounds-carrying
    type at the argument boundary; provider outcomes are a sum whose cases
    carry exactly their own data, so "tool turn with no calls" is not a
    state anyone guards against.

    No live LLM call happens in tests: falsifiers run entirely on
    {!Rigged} lanes; the provider lanes are never constructed by the test
    suite (docs/architecture/50-api.md § the falsifier
    discipline). *)

(** Tool grants: the node's footprint made operational — reads and writes
    within granted globs over the ONE shared tree, the shell gates its
    template declares. There is no private root: [write_globs] is the
    load-bearing boundary that replaced per-node isolation
    (docs/architecture/40-agents.md § tool grants; README.md § design of
    record vs shipped engine, row 4).

    The grant is a type indexed by speculation status, and the forbidden
    combination has no constructor: effect-capable tools enter a grant only
    through a declared-idempotence witness, and a non-idempotent effect
    tool simply cannot be given the [speculative] index — "a speculative
    node ran a non-idempotent effect" is not a policy violation the
    dispatcher catches, it is a grant nobody can build (falsifiers F12 and
    F15; docs/architecture/40-agents.md § tool grants;
    docs/architecture/20-medium.md § event taxonomy). *)
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
    read_globs : string list;
        (** Ambient visibility: readable, snoopable. Everything in-grant
            is snoopable, automatically — a read whose address tops
            [In_flight] at the frontier is a tracked store-buffer
            hypothesis on exactly that writer, never a mount arrangement
            (docs/architecture/20-medium.md § store-to-load
            forwarding). *)
    write_globs : string list;
        (** Where this node's stores may land in the shared tree. A store
            path outside it fails the argument boundary with a typed
            {!Refusal}. Hygiene, not a wall: overlapping grants are legal
            and the base-coordinate disjoint law convicts an actual
            clobber (docs/architecture/40-agents.md § tool grants). *)
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
      (docs/architecture/40-agents.md § prompt assembly, part 4). *)
end

(** Prompt assembly: derived, never authored. A hand-authored per-node
    prompt is a bug. The parts, in order: template preamble (the one
    hand-written artifact — stance and method, never shape), contract
    section (derived prose + wire schema as reference text), operand
    section (codec-rendered body tuples; hypotheses explicitly marked
    speculative), footprint grant, settlement instruction
    (docs/architecture/40-agents.md § prompt assembly). *)
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
        (** The head contract, one supply: rendered into the prompt as
            reference text, and on the OpenAI lane also handed to the API
            as the (non-strict) structured-output format. The decode
            itself stays freeform on the primary lane — the codec
            boundary parse owns conformance. *)
    grant : 'status Grant.t;
    pin : Theory.Pin.t;
    repo : string;
        (** The ONE shared tree the grant's globs range over — the run's
            repo directory, where reads resolve and stores land. An
            explicit invocation coordinate, never the harness process
            cwd: the cwd is operator state no footprint declares, and
            resolving repo-relative paths against it both missed files
            that were committed all along and could serve the operator's
            own files to an agent (live trace 2026-07-15: an integrator
            polled three times for a module committed 40s earlier).
            Direct callers outside any engine pass ["."]. *)
    frontier : Ledger.Address.t -> Retire.Frontier.top;
        (** The live-frontier lookup the read resolver consults — files
            join the vocabulary the chase already speaks for tuples
            (docs/architecture/20-medium.md § store-to-load forwarding).
            What a load may claim is decided by the top its read was
            served under (the self-witness ruling): a [Committed] top
            enters the observed witness at its real committed
            generation (an [Absent] one at [Ledger.Generation.zero],
            the content hash carrying the commit-point judgment); an
            [In_flight] top by ANOTHER writer is a snooped in-flight
            observation — generation zero, content judged when that
            producer lands, and a tracked hypothesis via [snoop]; an
            [In_flight] top by the node ITSELF is its own draft and
            claims nothing. The chase supplies [Retire.Frontier.top]
            over a fresh derivation; direct callers outside any engine
            supply
            [fun _ -> Retire.Frontier.Committed Witness.Committed_state.Absent]. *)
    snoop :
      address:Ledger.Address.t ->
      producer:Ledger.node Id.t ->
      content:Ledger.Content_hash.t ->
      Ledger.Event.kind list;
        (** The tracked-hypothesis mint for a read served from another
            node's in-flight store: the hypothesis tracker, not any
            mount, is what makes snooping honest — the returned events
            (a [Hypothesis_taken], when the engine tracks one) ride the
            tool outcome and the consumer's retirement blocks until the
            producer's landing discharges or drifts it
            (docs/architecture/20-medium.md § store-to-load forwarding;
            falsifier FL2). The chase supplies the registering closure;
            direct callers outside any engine supply
            [fun ~address:_ ~producer:_ ~content:_ -> []]. *)
    in_flight :
      unit ->
      (Ledger.Address.t * Ledger.node Id.t * Ledger.Content_hash.t) list;
        (** Every address whose frontier top is in flight, with its
            writer and uncommitted content — the effect snapshot's
            universe. A [run_command] subprocess observes the whole
            shared tree exactly like a gate, so its execution takes the
            same honesty snapshot gate dispatch takes: each in-flight
            top (another writer's) becomes a tracked [Store_buffer]
            hypothesis via [snoop] plus a witness triple at the
            uncommitted coordinate, and the node's verdict is
            speculative evidence until every observed writer lands as
            observed (docs/architecture/30-scheduling.md § gates on the
            shared tree; falsifier FL6). The chase supplies
            [Retire.Frontier.in_flight_tops]; direct callers outside any
            engine supply [fun () -> []]. *)
    undischarged : unit -> bool;
        (** The node currently carries undischarged hypotheses. The
            grant's speculation index is fixed at dispatch, but ambient
            snooping can make a committed-granted node speculative
            mid-turn — this closure is the runtime edge of that boundary:
            a non-idempotent effect tool refuses (typed, in-band) while
            it answers [true], because effects are the one event class
            squash cannot undo (docs/architecture/20-medium.md § event
            taxonomy; docs/architecture/40-agents.md § tool grants). The
            chase supplies the live tracker lookup; direct callers
            outside any engine supply [fun () -> false]. *)
    gate_resource : string option;
        (** The declared build-artifact resource a shell-gate run's
            effect lock scopes to — [Some] exactly for gate dispatches,
            threaded from the {!Theory.Executor.Shell_gate} declaration
            (docs/architecture/30-scheduling.md § gates on the shared
            tree: the lock serializes gates per build-artifact resource;
            source-tree reads take no lock). Non-gate executors carry
            [None] and never consult it. *)
  }
end

(** The provider layer: ONE stateless model turn — request (system,
    messages including tool results, tool declarations, wire schema) in,
    assistant reply out. The tool loop lives {e above} this signature, in
    the agent layer, so a provider never executes anything: it moves bytes
    to a model API and types the reply
    (docs/architecture/40-agents.md § model pins and provider routing,
    § the executor transport). *)
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

  (** How one turn ended, with exactly the data that ending carries.
      [Calls] is non-empty by construction ([first] plus [rest]) — a
      "tool turn with zero calls" is unrepresentable, so no code guards
      it. [Suspend] is a bare yield point (work-free suspension): the
      rigged lane's drift-note delivery step; live decoders never produce
      it, and it bills no model turn. [Refused] is a typed outcome
      (Anthropic [stop_reason: "refusal"], an OpenAI [refusal] content
      item): routed to the repair/fallback lane, never parsed as
      payload. *)
  type outcome =
    | Settled of { text : string }
    | Refused of { text : string }
    | Calls of { text : string; first : Call.t; rest : Call.t list }
    | Suspend

  type reply = { outcome : outcome; usage : Ledger.Usage.t }

  type request = {
    pin : Theory.Pin.t;
    system : string;
    messages : Message.t list;
    tools : Tool_decl.t list;
    schema : Contract.Wire_schema.t;
        (** The head contract. The OpenAI lane sends it as the non-strict
            [text.format]; the Anthropic lane sends no format (the
            provider compiles a format into a grammar with a hard size
            ceiling — the schema is a serialization codec, not a decode
            constraint, so it rides the prompt and the codec judges the
            reply). *)
  }

  type t = { turn : request -> (reply, Ledger.Fault.t) result }

  type post = Http.Request.t -> (int * string, Http.error) result
  (** The transport seam: how a lane's one POST reaches the wire. A
      parameter, never a global flag — each constructed provider value
      carries its transport. Two instances exist: {!blocking_post}
      (default; [Http.post_json], for non-fiber callers) and
      [Fiber.http_post] (performs the [Http_post] instruction, so N
      provider turns overlap on one domain when the executor runs inside
      the chase's fiber scheduler). The rigged lane performs nothing —
      scripted turns never construct a request. *)

  val blocking_post : post
  (** [Http.post_json] over the reified request: the blocking lane, which
      stands for callers outside any fiber scheduler. *)

  val anthropic : ?post:post -> unit -> t
  (** Anthropic Messages API, direct ([POST /v1/messages]). Reads
      [ANTHROPIC_API_KEY] from the environment at turn time; an unset key
      is an executor fault, never a crash. Fable-5 rules are encoded here:
      no [thinking] parameter, no sampling knobs, [output_config] carries
      effort and deliberately NO json_schema format: the provider
      compiles a format into a grammar with a hard size ceiling that
      real contract schemas exceed (live trace 2026-07-15), so the
      schema reaches the model as prompt reference text only and the
      codec boundary parse plus the repair lane own conformance — the
      freeform-with-reference posture. Transient transport failures (HTTP
      429/5xx, curl timeouts) retry bounded inside the lane with backoff
      — transport, not work: no ledger event, no repair budget; an
      exhausted retry faults with the attempt count named.
      [stop_reason: "max_tokens"] is a typed truncation outcome that
      faults immediately with raise-the-pin-option guidance — an
      identical retry truncates identically, so it never enters the
      repair loop. [post] defaults to {!blocking_post}. *)

  val openai : ?post:post -> unit -> t
  (** OpenAI Responses API, direct ([POST /v1/responses], stateless:
      [store: false], full history each turn). Reads [OPENAI_API_KEY] at
      turn time. The same transport-retry envelope and schema lowering as
      {!anthropic}; [text.format] rides [strict: false] (admitted schemas
      carry optional fields, which strict mode forbids — the strict-mode
      lowering, optional to required-plus-nullable, is the recorded
      growth path); a truncated response ([incomplete] /
      [max_output_tokens]) faults immediately with the same guidance.
      [post] defaults to {!blocking_post}. *)
end

(** Loop bounds as data, checked by the agent loop before each model turn
    (the runaway-loop backstop; cf. the same posture in
    docs/architecture/30-scheduling.md § backstops: a ceiling is declared,
    never implied). Exhaustion is the node's own throw —
    [Fault.Context_exhausted] — and settles like any fault. *)
module Stop : sig
  type t

  val step_ceiling : int -> t
  (** Bound on tool-execution rounds. Every agent invocation carries one:
      the pin option ["max_steps"] (default 32) — a model that never stops
      calling tools is a fault, not a hang. *)

  val token_ceiling : int -> t
  (** Bound on the invocation's summed usage. *)

  val check :
    t list -> steps:int -> usage:Ledger.Usage.t -> string option
  (** [Some why] when any condition trips; the string lands in the fault
      message. *)
end

(** The executor interface: how one invocation runs to a raw reply. The
    engine owns everything around it (parsing, repair, settlement); an
    executor produces the turn's final outcome — and, because the harness
    owns the tool loop, it also owes the ledger every tool event, which is
    why [run] takes the ledger and the node identity. *)
module Executor : sig
  (** The two ways an invocation can speak: payload text for the codec
      boundary, or a typed refusal for the repair/fallback lane. One sum,
      not a text-plus-flag pair. *)
  type outcome = Text of string | Refusal of string

  type reply = {
    outcome : outcome;
    usage : Ledger.Usage.t;  (** Summed across the invocation's turns. *)
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
            docs/architecture/20-medium.md § delivery). A
            [`Stop_cleanly] disposition obliges the executor to finish no
            further work and emit nothing. *)
  }
end

val agent : stop:Stop.t list -> provider:Provider.t -> Executor.t
(** The agent layer over one provider lane — shared across all three, so
    there is exactly one tool loop, one grant boundary, one eventing path.
    [stop] is the caller's extra loop bounds — written, never implied
    ([~stop:[]] is an explicit "pin ceiling only").

    The tool surface is a table of tool values derived from the grant at
    invocation start — the table {e is} the capability set: [read_file],
    [glob_list], [grep] (loads over the shared tree, place judged by the
    invocation's frontier lookup), [write_file], [str_replace_edit]
    (stores, landing in the shared tree at the grant's [write_globs];
    every store is one site, three obligations, ordered — the full
    content into git's object database first, so the Store event's
    {!Ledger.Delta_ref} names an oid the store already holds, tmp+rename
    at the target second, so a reader the domain does not schedule can
    never observe an interleaving, the Store event third —
    docs/architecture/20-medium.md § event taxonomy;
    falsifier FL7), and [run_command] {e only when} the
    grant's effects carry a tool of that name (which the status index
    already polices — F12/F15; it runs behind the mkdir-atomic,
    holder-named machine lock). An ungranted tool has no table entry to
    dispatch to; there is no run-time grant check to forget. Tool paths
    parse once, at the argument boundary, into a bounds-carrying type —
    absolute paths and ['..'] hops are outside every grant by
    construction, and the refusal is a typed in-band tool error
    ({!Grant.Refusal}), never a silent no-op. [run_command] additionally
    refuses any command whose token stream names git in command position —
    git is the harness's commit substrate; workers never touch it
    (operator ruling; the v0 screen is a recorded tripwire, not a security
    boundary — docs/architecture/40-agents.md § the git ban; falsifier
    F17).

    Every execution appends the matching ledger event with its footprint —
    Load / Store / Effect — returned by the tool as data and appended by
    the loop, so an unevented execution is not writable inside a tool.
    Each billed model turn appends an [Agent_turn]. After each tool batch
    the loop calls [on_yield]; a stop-cleanly note ends the invocation
    with no further work and nothing emitted. [stop] conditions (plus the
    pin's step ceiling) bound the loop; exhaustion faults with
    [Context_exhausted]
    (docs/architecture/40-agents.md § tool grants, § notes at
    yield). *)

(** Deterministic fakes: scripted provider turns — outputs, delays, faults,
    invalid-output injections, and scripted tool calls — what makes the
    whole falsifier roster runnable in CI without a model call. Live-model
    runs validate templates, never engine laws
    (docs/architecture/50-api.md § the falsifier discipline). *)
module Rigged : sig
  type step =
    | Reply of string  (** A settled turn with this final text. *)
    | Invalid of string  (** Injected parse failure: exercises the repair lane. *)
    | Refuse of string
        (** A typed provider refusal: exercises the fallback lane. *)
    | Fault of string  (** Provider error: exercises fault settlement. *)
    | Delay_s of float  (** Scheduling pressure without wall-clock cost in tests. *)
    | Yield
        (** A {!Provider.Suspend} turn: forces an [on_yield] — the
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
(** Runs the command line declared on the {!Theory.Executor.Shell_gate},
    with the invocation's shared tree ([repo]) as its working directory —
    the one tree its operands landed on, so the command judges exactly
    that tree, neighbors' in-flight edits included: gate honesty is the
    dispatch-time frontier snapshot the chase takes over the grant (every
    [In_flight] top a store-buffer hypothesis plus a witness triple at
    the uncommitted coordinate), so the verdict is speculative evidence
    until every observed writer lands as observed
    (docs/architecture/30-scheduling.md § gates on the shared tree;
    falsifier FL6). Its judgment is its head tuple; a file the gate
    writes into the tree is not an evented store and never lands at
    retire, because the landing is built from Store events alone
    (docs/architecture/README.md § design of record vs shipped engine,
    row 2). The harness process cwd is ambient state no footprint
    declares. Exit status and captured output become the head tuple. A
    non-zero exit is data (a failing test run is a tuple, not a fault).
    The gate is an effect against shared machine state: it runs behind
    the mkdir-atomic, holder-named effect lock scoped to the invocation's
    declared build-artifact resource ([gate_resource] — gates on distinct
    resources overlap; source-tree reads take no lock) and appends
    [Ledger.Event.Effect] (tool ["shell_gate"], the declared command line
    as the resource) — the same discipline as [run_command], so a gate
    run is never an unobserved effect lane. Idempotence is the
    declaration's: a gate is a build/test command the engine may freely
    reissue, which is why gates are grantable under either speculation
    index (docs/architecture/20-medium.md § event taxonomy). A
    git-naming gate never reaches this runtime — admission rejects it
    ({!Theory.Admission.error}, [Git_gate]). *)

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
    docs/architecture/40-agents.md § the primary lane;
    docs/architecture/30-scheduling.md § the repair lane — one lane, two entry
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
    here with [Contract.Codec.parse] over the window-lowered head schema
    (its parse wraps the codec's to fill tuple-window existentials); tests
    that need a scripted boundary enter here too. There is exactly one
    repair-loop implementation; {!invoke} is [invoke_parsed] applied to
    the codec's parse. *)
