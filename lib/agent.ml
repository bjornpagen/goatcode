(* Execution units: tool grants, prompt assembly, the provider lanes, the
   harness-owned tool loop, and the validate-and-repair loop
   (docs/architecture/60-agents.md).

   Design discipline: the representation carries the logic. Tools are
   values in a table derived from the grant (capability IS the table);
   tool paths parse once into a bounds-carrying type; provider outcomes
   are a sum whose cases carry exactly their own data. Where a guard used
   to repeat, a type now stands. *)

let fault origin message = { Ledger.Fault.origin; message }

(* Crude, deterministic token estimate for rigged replies: accounting data
   for [Agent_turn] events without any model in the loop. *)
let approx_tokens s = (String.length s + 3) / 4

(* [`Stop_cleanly] discipline shared by every executor that yields: finish
   no further work, emit nothing (docs/architecture/60-agents.md § drift
   notes at yield). *)
let stop_requested notes =
  List.exists
    (fun (n : Speculate.Drift.note) ->
      match n.disposition with
      | `Stop_cleanly -> true
      | `Continue | `Patch_then_continue -> false)
    notes

let read_file_bytes path =
  In_channel.with_open_bin path In_channel.input_all

let write_file_bytes path contents =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)

let remove_quietly path = try Sys.remove path with Sys_error _ -> ()

module Grant = struct
  type speculative
  type committed

  module Idempotence = struct
    type witness = { tool : string; why : string }

    let declare ~tool ~why = { tool; why }
  end

  module Effect_tool = struct
    (* The phantom ['status] is constrained only by the signature:
       [non_idempotent] is typed [committed t] there, so the speculative
       index for the non-idempotent case is unobtainable outside this file
       (F12/F15). *)
    type 'status t =
      | Idempotent of { name : string; witness : Idempotence.witness }
      | Non_idempotent of { name : string }

    let idempotent ~name witness = Idempotent { name; witness }
    let non_idempotent ~name = Non_idempotent { name }

    (* Internal: the grant-section rendering of one effect tool. *)
    let describe = function
      | Idempotent { name; witness = { Idempotence.why; tool = _ } } ->
          Printf.sprintf "%s — effect, idempotent by declaration (%s)" name why
      | Non_idempotent { name } ->
          Printf.sprintf
            "%s — effect, non-idempotent (grantable on witnessed operands only)"
            name
  end

  type 'status t = {
    read_globs : string list;
    write_globs : string list;
        (* The load-bearing boundary that replaced per-node isolation:
           stores land in the ONE shared tree, within these globs
           (agent.mli owns the ruling; 40-agents.md § tool grants). *)
    shell_gates : string list list;
    effects : 'status Effect_tool.t list;
  }

  module Refusal = struct
    type t = { requested : string; boundary : string }

    let render { requested; boundary } =
      Printf.sprintf
        "refused: %s is outside this node's grant (boundary: %s). No action \
         was taken; route around the obstacle you can now see."
        requested boundary
  end

  let describe (g : _ t) =
    let b = Buffer.create 256 in
    let line fmt =
      Printf.ksprintf
        (fun s ->
          Buffer.add_string b s;
          Buffer.add_char b '\n')
        fmt
    in
    (match g.read_globs with
    | [] -> line "Readable paths (read_globs): none declared."
    | globs ->
        line "Readable paths (read_globs):";
        List.iter (fun glob -> line "- %s" glob) globs);
    (match g.write_globs with
    | [] -> line "Writable paths (write_globs): none — this node stores nothing."
    | globs ->
        line "Writable paths (write_globs):";
        List.iter (fun glob -> line "- %s" glob) globs);
    (match g.shell_gates with
    | [] -> ()
    | gates ->
        line "Shell gates (the declared command lines):";
        List.iter (fun gate -> line "- %s" (String.concat " " gate)) gates);
    (match g.effects with
    | [] -> line "Effect tools: none granted."
    | effects ->
        line "Effect tools:";
        List.iter (fun e -> line "- %s" (Effect_tool.describe e)) effects);
    line
      "Any action outside this grant returns a typed refusal — a tool error \
       you can read — never a silent no-op.";
    Buffer.contents b
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

  (* [diagnostics] is the repair lane's stateless-with-diagnostics rider:
     appended to the rendering only, so [parts] stays the five
     constitutional parts (docs/architecture/60-agents.md § the primary
     lane). *)
  type t = { parts : part list; diagnostics : string option }

  (* The derived prose of the contract section: harvested doc comments,
     walked out of the wire schema — one supply, no hand-carried copy
     (docs/architecture/20-contracts.md § the one-supply law). *)
  let harvest_prose (schema : Contract.Wire_schema.t) =
    let b = Buffer.create 256 in
    let add path doc =
      if String.trim doc <> "" then
        Buffer.add_string b
          (Printf.sprintf "- %s: %s\n"
             (match path with
             | [] -> "(root)"
             | _ -> Contract.Path.to_string path)
             doc)
    in
    let rec walk path (node : Contract.Wire_schema.node) =
      match node with
      | Prim { doc; prim = _ } -> add path doc
      | Str_enum { cases; doc } ->
          add path
            (Printf.sprintf "%s (one of: %s)"
               (String.trim doc)
               (String.concat ", " cases))
      | Record { fields; doc } ->
          add path doc;
          List.iter
            (fun (f : Contract.Wire_schema.field) ->
              walk (path @ [ f.name ]) f.schema)
            fields
      | Array { items; doc; min_items = _; max_items = _ } ->
          add path doc;
          walk (path @ [ "[]" ]) items
      | Nullable node -> walk path node
      | Ref_id { relation; doc } ->
          add path
            (Printf.sprintf "%s (a typed id referencing relation %s)"
               (String.trim doc) relation)
      | Def_ref _ -> ()
    in
    walk [] schema.root;
    List.iter (fun (name, node) -> walk [ name ] node) schema.defs;
    Buffer.contents b

  let settlement_text =
    "Your final message is your head tuples as structured output against the \
     wire schema in the contract section — never prose for a human. Reports \
     for humans are tuples too."

  let drift_contract_text =
    "The operands marked SPECULATIVE are hypotheses, not witnessed facts. If \
     upstream reality lands differently you will receive a drift note at a \
     yield point; the note ends with the routing the scheduler already \
     decided: continue, patch-then-continue (apply the described delta to \
     your work), or stop-cleanly (finish no further work, emit nothing)."

  let assemble ~preamble ~schema ~operands ~hypotheses ~grant =
    {
      parts =
        [
          Preamble preamble;
          Contract_section { prose = harvest_prose schema; schema };
          Operands { witnessed = operands; speculative = hypotheses };
          Footprint_grant (Grant.describe grant);
          Settlement_instruction settlement_text;
        ];
      diagnostics = None;
    }

  let parts t = t.parts

  (* Internal: the repair lane attaches diagnostics without disturbing the
     constitutional parts. *)
  let with_diagnostics t diagnostics = { t with diagnostics = Some diagnostics }

  let render_part = function
    | Preamble s -> "# Role\n\n" ^ s
    | Contract_section { prose; schema } ->
        let b = Buffer.create 256 in
        Buffer.add_string b "# Contract\n\n";
        if String.trim prose <> "" then (
          Buffer.add_string b prose;
          Buffer.add_char b '\n');
        Buffer.add_string b "Wire schema (reference):\n\n";
        Buffer.add_string b
          (Yojson.Safe.pretty_to_string (Contract.Wire_schema.to_json schema));
        Buffer.add_string b
          "\n\nYour head tuples must conform to this schema.";
        Buffer.contents b
    | Operands { witnessed; speculative } ->
        let b = Buffer.create 256 in
        Buffer.add_string b "# Operands\n\n## Witnessed\n\n";
        Buffer.add_string b witnessed;
        (match speculative with
        | [] -> ()
        | hs ->
            Buffer.add_string b
              "\n\n## Speculative (hypotheses, not yet witnessed)\n\n";
            List.iter
              (fun ((h : Speculate.Hypothesis.t), rendered) ->
                Buffer.add_string b
                  (Printf.sprintf
                     "- SPECULATIVE hypothesis %s at %s (confidence %.2f):\n%s\n"
                     (Id.to_string h.id)
                     (Ledger.Address.to_string h.address)
                     h.confidence rendered))
              hs;
            Buffer.add_char b '\n';
            Buffer.add_string b drift_contract_text);
        Buffer.contents b
    | Footprint_grant s -> "# Footprint grant\n\n" ^ s
    | Settlement_instruction s -> "# Settlement\n\n" ^ s

  let render t =
    let body = String.concat "\n\n" (List.map render_part t.parts) in
    match t.diagnostics with
    | None -> body
    | Some d -> body ^ "\n\n# Repair\n\n" ^ d
end

module Invocation = struct
  type 'status t = {
    prompt : Prompt.t;
    schema : Contract.Wire_schema.t;
    grant : 'status Grant.t;
    pin : Theory.Pin.t;
    repo : string;
        (* The ONE shared tree the grant's globs range over — an explicit
           invocation coordinate, never the harness process cwd
           (agent.mli). *)
    frontier : Ledger.Address.t -> Retire.Frontier.top;
        (* The live-frontier lookup the read resolver consults: the place
           a read is served under decides what its load may claim
           (agent.mli; 20-medium.md § store-to-load forwarding). *)
    snoop :
      address:Ledger.Address.t ->
      producer:Ledger.node Id.t ->
      content:Ledger.Content_hash.t ->
      Ledger.Event.kind list;
        (* The tracked-hypothesis mint for reads served from another
           node's in-flight store (agent.mli; falsifier FL2). *)
  }
end

(* {2 JSON plumbing shared by the provider codecs and tool arguments} *)

let jmem key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let jstr key j = match jmem key j with Some (`String s) -> Some s | _ -> None
let jint key j = match jmem key j with Some (`Int i) -> i | _ -> 0
let jlist key j = match jmem key j with Some (`List l) -> l | _ -> []

let opt_int options key ~default =
  match List.assoc_opt key options with
  | Some s -> ( match int_of_string_opt s with Some i -> i | None -> default)
  | None -> default

let opt_str options key ~default =
  Option.value (List.assoc_opt key options) ~default

let excerpt s =
  if String.length s <= 400 then s else String.sub s 0 400 ^ "…"

module Provider = struct
  module Tool_decl = struct
    type t = {
      name : string;
      description : string;
      input_schema : Yojson.Safe.t;
    }
  end

  module Call = struct
    type t = { id : string; name : string; input : Yojson.Safe.t }
  end

  module Tool_result = struct
    type t = { call_id : string; output : string; is_error : bool }
  end

  module Message = struct
    type t =
      | User of string
      | Assistant of { text : string; calls : Call.t list }
      | Tool_results of Tool_result.t list
  end

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
  }

  type t = { turn : request -> (reply, Ledger.Fault.t) result }

  (* The transport seam: each constructed lane carries its POST as data —
     blocking for callers outside any fiber scheduler, [Fiber.http_post]
     when the executor runs inside the chase's fibers (the perform is the
     suspension the scheduler overlaps). Never a global flag. *)
  type post = Http.Request.t -> (int * string, Http.error) result

  let blocking_post : post =
   fun (r : Http.Request.t) ->
    Http.post_json ~headers:r.headers ~url:r.url ~body:r.body
      ~timeout_s:r.timeout_s

  (* {3 Transport retry}

     Transient transport failures — HTTP 429/5xx and curl timeouts —
     retry bounded INSIDE the lane, before any [Executor_error] escapes:
     transport noise is not the node's work, so no Ledger event is owed
     and the repair budget is never touched; a permanent fault message
     carries the attempt count so the exhausted retries stay visible.
     Bounded and typed: [transport_attempts] tries, exponential backoff
     ([Unix.sleepf]). *)
  let transport_attempts = 3

  let transient_status status = status = 429 || status / 100 = 5

  (* libcurl spells the constant CURLE_OPERATION_TIMEDOUT (older
     bindings: CURLE_OPERATION_TIMEOUTED) — match the shared stem. *)
  let transient_error (e : Http.error) =
    let hay = e.Http.code and needle = "TIME" in
    let n = String.length hay and m = String.length needle in
    let rec go i =
      i + m <= n && (String.equal (String.sub hay i m) needle || go (i + 1))
    in
    go 0

  (* One POST under the transient-retry envelope; failures carry the
     attempt count for the lane's fault message. *)
  let post_with_retry (post : post) req =
    let rec go attempt =
      let retry () =
        Unix.sleepf (0.25 *. (2. ** float_of_int (attempt - 1)));
        go (attempt + 1)
      in
      match post req with
      | Error e when transient_error e && attempt < transport_attempts ->
          retry ()
      | Error e -> Error (`Transport (e, attempt))
      | Ok (status, body) when transient_status status ->
          if attempt < transport_attempts then retry ()
          else Error (`Http (status, body, attempt))
      | Ok (status, body) when status / 100 <> 2 ->
          Error (`Http (status, body, attempt))
      | Ok (_, body) -> Ok body
    in
    go 1

  let attempts_suffix = function
    | 1 -> ""
    | n -> Printf.sprintf " (attempt %d of %d)" n transport_attempts

  (* {3 Schema lowering for the API-rendered format}

     One supply, two renderings: the SAME admitted [Wire_schema] is shown
     in the prompt (full: ref formats, array windows) and — on the OpenAI
     lane only — sent as the provider's structured-output format. But a
     ref slot renders as [{"type":"string","format":"ref:<relation>"}],
     and "ref:*" is not a format the json_schema subset documents — so
     the OpenAI encoder lowers the API rendering ONLY: a "ref:<relation>"
     format is stripped and folded into the description, so the model
     still sees the target relation in prose. [minItems]/[maxItems] stay:
     the OpenAI format rides [strict: false] where the schema is
     guidance, not a validated grammar. The Anthropic lane sends no
     format at all — the schema is a serialization codec, never a decode
     constraint: Anthropic compiles a json_schema format into a grammar
     with a hard size ceiling, and the meta-catalog schema (any real
     contract, eventually) blows it (live trace, 2026-07-15: HTTP 400
     "compiled grammar is too large"). Rather than branch on schema size,
     the case is made unexpressible: the prompt carries the full schema
     as reference text and the codec boundary parse plus the repair lane
     are the correctness backstop — the same freeform-with-reference
     posture the primary lane already commits to (60-agents.md § the
     primary lane). The decoder judges refs and windows fully at the
     codec ([Contract.Codec.by_schema]), so nothing semantic moves. *)
  let rec lower_api_schema (j : Yojson.Safe.t) : Yojson.Safe.t =
    match j with
    | `List items -> `List (List.map lower_api_schema items)
    | `Assoc fields ->
        let ref_target =
          List.find_map
            (function
              | "format", `String f when String.starts_with ~prefix:"ref:" f
                ->
                  Some (String.sub f 4 (String.length f - 4))
              | _ -> None)
            fields
        in
        let note target =
          Printf.sprintf
            "The wire id of a %s tuple (resolved against mint provenance \
             at the decode boundary)."
            target
        in
        let fields =
          List.filter_map
            (fun (k, v) ->
              match (k, v, ref_target) with
              | "format", `String f, Some _
                when String.starts_with ~prefix:"ref:" f ->
                  None
              | "description", `String d, Some target ->
                  Some
                    ( "description",
                      `String
                        (if String.equal d "" then note target
                         else d ^ " " ^ note target) )
              | _ -> Some (k, lower_api_schema v))
            fields
        in
        let fields =
          match ref_target with
          | Some target when not (List.mem_assoc "description" fields) ->
              fields @ [ ("description", `String (note target)) ]
          | _ -> fields
        in
        `Assoc fields
    | other -> other

  let usage_of j =
    match jmem "usage" j with
    | Some u ->
        {
          (* Fuel is context processed: uncached input plus cache writes
             plus cache reads sum to the turn's full prompt (the three
             price differently — cache reads ~0.1x — but the ledger's
             usage type carries volume, not price; a priced account is
             recorded future work). *)
          Ledger.Usage.tokens_in =
            jint "input_tokens" u
            + jint "cache_creation_input_tokens" u
            + jint "cache_read_input_tokens" u;
          tokens_out = jint "output_tokens" u;
        }
    | None -> Ledger.Usage.zero

  (* Classify decoded text + calls into the outcome sum: the one place the
     "did it call tools" judgment lives. *)
  let classify ~text ~calls ~refused =
    if refused then Refused { text }
    else
      match calls with
      | [] -> Settled { text }
      | first :: rest -> Calls { text; first; rest }

  (* {3 The Anthropic Messages lane}

     POST https://api.anthropic.com/v1/messages, anthropic-version
     2023-06-01. Fable-5 wire rules (per the claude-api reference):
     - the [thinking] parameter is OMITTED entirely (an explicit disable is
       a 400), and no sampling knobs are ever sent (temperature/top_p/top_k
       are 400s) — the pin's [sampling] list is deliberately ignored here;
     - [output_config] carries [effort] (pin option "effort", default
       "high") and NO [format]: the format compiles into a grammar with a
       hard size ceiling on the provider side, so the schema rides the
       prompt as reference text and the codec owns conformance (see the
       schema-lowering note above);
     - [stop_reason: "refusal"] is a typed outcome checked BEFORE content
       (an HTTP 200 whose content may be empty or partial);
     - parallel [tool_use] blocks are all answered in ONE user message of
       [tool_result] blocks (the agent layer already batches this way). *)

  let anthropic_messages msgs =
    `List
      (List.map
         (function
           | Message.User s ->
               `Assoc
                 [
                   ("role", `String "user");
                   ( "content",
                     `List
                       [ `Assoc [ ("type", `String "text"); ("text", `String s) ] ]
                   );
                 ]
           | Message.Assistant { text; calls } ->
               let text_blocks =
                 if String.trim text = "" then []
                 else
                   [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ]
               in
               let call_blocks =
                 List.map
                   (fun (c : Call.t) ->
                     `Assoc
                       [
                         ("type", `String "tool_use");
                         ("id", `String c.id);
                         ("name", `String c.name);
                         ("input", c.input);
                       ])
                   calls
               in
               `Assoc
                 [
                   ("role", `String "assistant");
                   ("content", `List (text_blocks @ call_blocks));
                 ]
           | Message.Tool_results rs ->
               `Assoc
                 [
                   ("role", `String "user");
                   ( "content",
                     `List
                       (List.map
                          (fun (r : Tool_result.t) ->
                            `Assoc
                              [
                                ("type", `String "tool_result");
                                ("tool_use_id", `String r.call_id);
                                ("content", `String r.output);
                                ("is_error", `Bool r.is_error);
                              ])
                          rs) );
                 ])
         msgs)

  (* Prompt caching, the standard two-breakpoint multi-turn shape (of the
     four the API allows): one on the system block — the render order is
     tools -> system -> messages, so it caches the tool table and system
     prompt together — and one MOVING breakpoint on the last content
     block of the last message, so each tool-loop turn reads the previous
     turn's cache and pays full price only for the turn's new suffix.
     Pre-fix the stateless resend billed the whole history at full price
     every turn: a nine-turn integrator paid 43.8k input tokens of which
     ~85% was the same bytes re-read (live trace 2026-07-15). Prompts
     below the model's minimum cacheable prefix silently don't cache —
     harmless. *)
  let cache_breakpoint = ("cache_control", `Assoc [ ("type", `String "ephemeral") ])

  let rec map_last f = function
    | [] -> []
    | [ x ] -> [ f x ]
    | x :: rest -> x :: map_last f rest

  let with_moving_breakpoint (msgs : Yojson.Safe.t) =
    let mark_block = function
      | `Assoc fields -> `Assoc (fields @ [ cache_breakpoint ])
      | other -> other
    in
    let mark_msg = function
      | `Assoc fields ->
          `Assoc
            (List.map
               (fun (k, v) ->
                 match (k, v) with
                 | "content", `List blocks ->
                     (k, `List (map_last mark_block blocks))
                 | _ -> (k, v))
               fields)
      | other -> other
    in
    match msgs with
    | `List (_ :: _ as items) -> `List (map_last mark_msg items)
    | other -> other

  let anthropic_body (req : request) =
    let options = req.pin.Theory.Pin.options in
    `Assoc
      (List.concat
         [
           [
             ("model", `String req.pin.Theory.Pin.model);
             ("max_tokens", `Int (opt_int options "max_tokens" ~default:16000));
             ( "messages",
               with_moving_breakpoint (anthropic_messages req.messages) );
           ];
           (if req.system = "" then []
            else
              [
                ( "system",
                  `List
                    [
                      `Assoc
                        [
                          ("type", `String "text");
                          ("text", `String req.system);
                          cache_breakpoint;
                        ];
                    ] );
              ]);
           (match req.tools with
           | [] -> []
           | ts ->
               [
                 ( "tools",
                   `List
                     (List.map
                        (fun (d : Tool_decl.t) ->
                          `Assoc
                            [
                              ("name", `String d.name);
                              ("description", `String d.description);
                              ("input_schema", d.input_schema);
                            ])
                        ts) );
               ]);
           [
             ( "output_config",
               `Assoc
                 [
                   ("effort", `String (opt_str options "effort" ~default:"high"));
                 ] );
           ];
         ])

  (* Parse, don't validate: a tool_use block without id or name is a wire
     fault surfaced loudly, never a "" that breaks result matching three
     turns later. *)
  let decode_anthropic body =
    match Yojson.Safe.from_string body with
    | exception _ ->
        Error
          (fault Ledger.Fault.Executor_error
             "anthropic: unparseable response body")
    | json -> (
        let text =
          jlist "content" json
          |> List.filter_map (fun block ->
                 match jstr "type" block with
                 | Some "text" -> jstr "text" block
                 | _ -> None)
          |> String.concat ""
        in
        (* stop_reason before content: a refusal is HTTP 200 with empty or
           partial content, never parsed as payload. *)
        match jstr "stop_reason" json with
        | Some "refusal" ->
            Ok { outcome = Refused { text }; usage = usage_of json }
        | Some "max_tokens" ->
            (* Truncation is a typed outcome, and it faults IMMEDIATELY:
               the reply is not repairable by re-asking — the repair loop
               would resend an identical request and truncate identically,
               burning the whole budget. The operator raises the pin
               option instead. *)
            Error
              (fault Ledger.Fault.Executor_error
                 "anthropic: response truncated at max_tokens — an \
                  identical retry would truncate identically, so this \
                  faults without touching the repair budget; raise the \
                  pin option \"max_tokens\" (or shrink the contract)")
        | _ -> (
            let calls =
              jlist "content" json
              |> List.filter_map (fun block ->
                     match jstr "type" block with
                     | Some "tool_use" ->
                         Some
                           (match (jstr "id" block, jstr "name" block) with
                           | Some id, Some name ->
                               Ok
                                 {
                                   Call.id;
                                   name;
                                   input =
                                     Option.value
                                       (jmem "input" block)
                                       ~default:(`Assoc []);
                                 }
                           | _ ->
                               Error
                                 "anthropic: tool_use block missing id or name")
                     | _ -> None)
            in
            match
              List.partition_map
                (function Ok c -> Left c | Error e -> Right e)
                calls
            with
            | _, e :: _ -> Error (fault Ledger.Fault.Executor_error e)
            | calls, [] ->
                Ok
                  {
                    outcome = classify ~text ~calls ~refused:false;
                    usage = usage_of json;
                  }))

  let anthropic ?(post = blocking_post) () =
    let turn (req : request) =
      match Sys.getenv_opt "ANTHROPIC_API_KEY" with
      | None | Some "" ->
          Error
            (fault Ledger.Fault.Executor_error
               "anthropic: ANTHROPIC_API_KEY is not set")
      | Some key -> (
          let body = Yojson.Safe.to_string (anthropic_body req) in
          let timeout_s =
            float_of_int
              (opt_int req.pin.Theory.Pin.options "timeout_s" ~default:600)
          in
          match
            post_with_retry post
              {
                Http.Request.headers =
                  [
                    ("x-api-key", key);
                    ("anthropic-version", "2023-06-01");
                    ("content-type", "application/json");
                  ];
                url = "https://api.anthropic.com/v1/messages";
                body;
                timeout_s;
              }
          with
          | Error (`Transport ((e : Http.error), attempts)) ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "anthropic: %s (%s)%s" e.code e.message
                      (attempts_suffix attempts)))
          | Error (`Http (status, body, attempts)) ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "anthropic: HTTP %d%s: %s" status
                      (attempts_suffix attempts) (excerpt body)))
          | Ok body -> decode_anthropic body)
    in
    { turn }

  (* {3 The OpenAI Responses lane}

     POST https://api.openai.com/v1/responses, stateless ([store: false],
     the full history resent each turn). Wire shapes verified against the
     openai-openapi spec (FunctionTool, FunctionToolCall,
     FunctionToolCallOutput, OutputMessage, TextResponseFormatJsonSchema,
     ResponseUsage):
     - function tools are FLAT: {type:"function", name, description,
       parameters, strict} — no nested "function" object;
     - the model's calls arrive as output items {type:"function_call",
       call_id, name, arguments} with [arguments] a JSON-encoded string;
       answers go back as input items {type:"function_call_output",
       call_id, output};
     - structured output rides text.format = {type:"json_schema", name,
       schema, strict};
     - a refusal is a content item {type:"refusal", refusal} inside an
       output message;
     - usage is {input_tokens, output_tokens}. *)

  let openai_input msgs =
    `List
      (List.concat_map
         (function
           | Message.User s ->
               [
                 `Assoc
                   [ ("role", `String "user"); ("content", `String s) ];
               ]
           | Message.Assistant { text; calls } ->
               let msg =
                 if String.trim text = "" then []
                 else
                   [
                     `Assoc
                       [
                         ("role", `String "assistant");
                         ("content", `String text);
                       ];
                   ]
               in
               msg
               @ List.map
                   (fun (c : Call.t) ->
                     `Assoc
                       [
                         ("type", `String "function_call");
                         ("call_id", `String c.id);
                         ("name", `String c.name);
                         ("arguments", `String (Yojson.Safe.to_string c.input));
                       ])
                   calls
           | Message.Tool_results rs ->
               List.map
                 (fun (r : Tool_result.t) ->
                   `Assoc
                     [
                       ("type", `String "function_call_output");
                       ("call_id", `String r.call_id);
                       ( "output",
                         (* The Responses output item has no is_error flag;
                            the error marker travels in-band. *)
                         `String
                           (if r.is_error then "ERROR: " ^ r.output
                            else r.output) );
                     ])
                 rs)
         msgs)

  let openai_body (req : request) =
    let options = req.pin.Theory.Pin.options in
    `Assoc
      (List.concat
         [
           [
             ("model", `String req.pin.Theory.Pin.model);
             ("input", openai_input req.messages);
             ("store", `Bool false);
             ( "max_output_tokens",
               `Int (opt_int options "max_tokens" ~default:16000) );
           ];
           (if req.system = "" then []
            else [ ("instructions", `String req.system) ]);
           (match req.tools with
           | [] -> []
           | ts ->
               [
                 ( "tools",
                   `List
                     (List.map
                        (fun (d : Tool_decl.t) ->
                          `Assoc
                            [
                              ("type", `String "function");
                              ("name", `String d.name);
                              ("description", `String d.description);
                              ("parameters", d.input_schema);
                              (* strict:false — the harness tool schemas
                                 carry optional parameters, which strict
                                 mode forbids; inputs are validated in-band
                                 by the tool loop anyway. *)
                              ("strict", `Bool false);
                            ])
                        ts) );
               ]);
           [
             ( "text",
               `Assoc
                 [
                   ( "format",
                     `Assoc
                       [
                         ("type", `String "json_schema");
                         ("name", `String "head_tuples");
                         ( "schema",
                           lower_api_schema
                             (Contract.Wire_schema.to_json req.schema) );
                         (* strict:false, like the tool declarations: our
                            admitted schemas carry optional fields, and
                            strict mode demands every property in
                            [required]. The strict-mode growth path is a
                            second lowering — optional becomes
                            required-plus-nullable — worth building once
                            live smoke shows non-strict schema drift the
                            codec has to repair; until then the codec
                            boundary is the enforcement
                            (docs/architecture/70-api.md § OPEN items). *)
                         ("strict", `Bool false);
                       ] );
                 ] );
           ];
           (* Unlike the Anthropic lane, the pin's sampling knobs are legal
              here and sent verbatim. *)
           List.map
             (fun (k, v) -> (k, `Float v))
             req.pin.Theory.Pin.sampling;
         ])

  let decode_openai body =
    match Yojson.Safe.from_string body with
    | exception _ ->
        Error
          (fault Ledger.Fault.Executor_error
             "openai: unparseable response body")
    | json -> (
        match jstr "status" json with
        | Some "failed" ->
            let message =
              match jmem "error" json with
              | Some e -> Option.value (jstr "message" e) ~default:"failed"
              | None -> "failed"
            in
            Error
              (fault Ledger.Fault.Executor_error ("openai: " ^ message))
        | Some "incomplete" ->
            let reason =
              match jmem "incomplete_details" json with
              | Some d -> Option.value (jstr "reason" d) ~default:"unknown"
              | None -> "unknown"
            in
            (* Truncation faults immediately, mirroring the Anthropic
               max_tokens outcome: an identical retry truncates
               identically, so the repair budget is never spent here. *)
            let guidance =
              if String.equal reason "max_output_tokens" then
                " — an identical retry would truncate identically; raise \
                 the pin option \"max_tokens\" (or shrink the contract)"
              else ""
            in
            Error
              (fault Ledger.Fault.Executor_error
                 ("openai: response incomplete: " ^ reason ^ guidance))
        | _ ->
            let texts = Buffer.create 256 in
            let refused = ref false in
            let calls = ref [] in
            let wire_error = ref None in
            List.iter
              (fun item ->
                match jstr "type" item with
                | Some "message" ->
                    List.iter
                      (fun content ->
                        match jstr "type" content with
                        | Some "output_text" ->
                            Buffer.add_string texts
                              (Option.value (jstr "text" content) ~default:"")
                        | Some "refusal" ->
                            refused := true;
                            Buffer.add_string texts
                              (Option.value
                                 (jstr "refusal" content)
                                 ~default:"")
                        | _ -> ())
                      (jlist "content" item)
                | Some "function_call" -> (
                    match (jstr "call_id" item, jstr "name" item) with
                    | Some id, Some name -> (
                        let arguments =
                          Option.value (jstr "arguments" item) ~default:"{}"
                        in
                        match Yojson.Safe.from_string arguments with
                        | exception _ ->
                            wire_error :=
                              Some
                                ("openai: unparseable function_call \
                                  arguments: " ^ excerpt arguments)
                        | input ->
                            calls := { Call.id; name; input } :: !calls)
                    | _ ->
                        wire_error :=
                          Some "openai: function_call missing call_id or name")
                | _ -> ())
              (jlist "output" json);
            (match !wire_error with
            | Some e -> Error (fault Ledger.Fault.Executor_error e)
            | None ->
                Ok
                  {
                    outcome =
                      classify ~text:(Buffer.contents texts)
                        ~calls:(List.rev !calls) ~refused:!refused;
                    usage = usage_of json;
                  }))

  let openai ?(post = blocking_post) () =
    let turn (req : request) =
      match Sys.getenv_opt "OPENAI_API_KEY" with
      | None | Some "" ->
          Error
            (fault Ledger.Fault.Executor_error
               "openai: OPENAI_API_KEY is not set")
      | Some key -> (
          let body = Yojson.Safe.to_string (openai_body req) in
          let timeout_s =
            float_of_int
              (opt_int req.pin.Theory.Pin.options "timeout_s" ~default:600)
          in
          match
            post_with_retry post
              {
                Http.Request.headers =
                  [
                    ("authorization", "Bearer " ^ key);
                    ("content-type", "application/json");
                  ];
                url = "https://api.openai.com/v1/responses";
                body;
                timeout_s;
              }
          with
          | Error (`Transport ((e : Http.error), attempts)) ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "openai: %s (%s)%s" e.code e.message
                      (attempts_suffix attempts)))
          | Error (`Http (status, body, attempts)) ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "openai: HTTP %d%s: %s" status
                      (attempts_suffix attempts) (excerpt body)))
          | Ok body -> decode_openai body)
    in
    { turn }
end

module Stop = struct
  type t = Step_ceiling of int | Token_ceiling of int

  let step_ceiling n = Step_ceiling n
  let token_ceiling n = Token_ceiling n

  let why ~steps ~usage = function
    | Step_ceiling n when steps >= n ->
        Some (Printf.sprintf "step ceiling reached (%d tool rounds)" n)
    | Token_ceiling n when Ledger.Usage.total usage >= n ->
        Some
          (Printf.sprintf "token ceiling reached (%d of %d)"
             (Ledger.Usage.total usage) n)
    | Step_ceiling _ | Token_ceiling _ -> None

  let check conditions ~steps ~usage =
    List.find_map (why ~steps ~usage) conditions
end

module Executor = struct
  type outcome = Text of string | Refusal of string

  type reply = { outcome : outcome; usage : Ledger.Usage.t }

  type t = {
    run :
      'status.
      'status Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:(unit -> Speculate.Drift.note list) ->
      (reply, Ledger.Fault.t) result;
  }
end

(* {2 The harness-owned tool surface}

   The point of the direct-API rebuild: every load, store, and effect an
   agent performs is executed HERE, and its ledger event travels as DATA in
   the tool's outcome — the loop appends it, so an unevented execution is
   not writable inside a tool (docs/architecture/30-channels.md
   § mechanized witnesses).

   Capability is a table: {!Toolset.of_grant} derives the tool values a
   grant admits, and dispatch is lookup — an ungranted tool has no entry,
   so there is no run-time grant check to forget. Reads resolve against
   the ONE shared tree, place judged by the invocation's frontier lookup
   (own in-flight top = draft, another's = snooped, else committed);
   writes land in the same tree, within the grant's write_globs
   (20-medium.md § store-to-load forwarding; README.md § design of
   record vs shipped engine, row 4). *)

(* A repo-relative, escape-free path or glob pattern: the bounds proof,
   carried by the type. Parsed once at the tool-argument boundary;
   everything downstream takes [Relpath.t] and cannot receive an unchecked
   string (parse, don't validate). *)
module Relpath : sig
  type t

  val parse : string -> t option
  (** [None] for absolute paths and any ['..'] hop — outside every grant
      by construction. *)

  val to_string : t -> string
end = struct
  type t = string

  let parse p =
    if
      Filename.is_relative p
      && not (List.mem ".." (String.split_on_char '/' p))
    then Some p
    else None

  let to_string t = t
end

(* Segment-wise glob matching: '**' spans directory segments; '*' and '?'
   stay within one segment. *)
let glob_matches pattern path =
  let seg p s =
    let np = String.length p and ns = String.length s in
    let rec go pi si =
      if pi = np then si = ns
      else
        match p.[pi] with
        | '*' -> go (pi + 1) si || (si < ns && go pi (si + 1))
        | '?' -> si < ns && go (pi + 1) (si + 1)
        | c -> si < ns && s.[si] = c && go (pi + 1) (si + 1)
    in
    go 0 0
  in
  let rec go ps ss =
    match (ps, ss) with
    | [], [] -> true
    | [ "**" ], _ -> true
    | "**" :: prest, [] -> go prest []
    | "**" :: prest, _ :: srest -> go prest ss || go ps srest
    | p :: prest, s :: srest -> seg p s && go prest srest
    | _ :: _, [] | [], _ :: _ -> false
  in
  go (String.split_on_char '/' pattern) (String.split_on_char '/' path)

(* Regular files under [root], as root-relative paths. Dot-entries and
   _build are pruned: the shared tree's sources, not build state. *)
let walk root =
  let acc = ref [] in
  let rec go rel_dir =
    let abs = if rel_dir = "" then root else Filename.concat root rel_dir in
    match Sys.readdir abs with
    | exception Sys_error _ -> ()
    | entries ->
        Array.iter
          (fun entry ->
            if entry <> "" && entry.[0] <> '.' && entry <> "_build" then begin
              let rel =
                if rel_dir = "" then entry else rel_dir ^ "/" ^ entry
              in
              match Sys.is_directory (Filename.concat root rel) with
              | exception Sys_error _ -> ()
              | true -> go rel
              | false -> acc := rel :: !acc
            end)
          entries
  in
  go "";
  List.rev !acc

(* Where one path reads from, decided once against the ONE shared tree.
   Reads are unwalled — the read declaration is a filter, never a wall
   (20-medium.md § footprint filtering): an out-of-declaration load
   surfaces at retire as a [Footprint_escape], it is not refused here.
   Only [`Missing] remains as a read failure.

   [place] records WHERE the read is served from — the fact the observed
   witness needs (see [load_observation]) — and it is a frontier
   judgment, never a filesystem one (20-medium.md § validity is a ledger
   coordinate): an address topping [In_flight] by the reading node
   itself is its own draft; by another writer, a snooped in-flight
   observation carrying that producer; a [Committed] top carries the
   committed state the witness stamps generations from. *)
module Source = struct
  (* The resolver's coordinates, bound once per invocation: the reading
     node, the shared tree, and the chase-supplied frontier/snoop
     closures (agent.mli § Invocation). *)
  type view = {
    me : Ledger.node Id.t;
    repo : string;
    frontier : Ledger.Address.t -> Retire.Frontier.top;
    snoop :
      address:Ledger.Address.t ->
      producer:Ledger.node Id.t ->
      content:Ledger.Content_hash.t ->
      Ledger.Event.kind list;
  }

  type place =
    | Draft
    | Committed of Witness.Committed_state.t
    | Snooped of Ledger.node Id.t

  type t = { rel : string; disk : string; place : place }

  let place_of view rel =
    match view.frontier (Ledger.Address.File rel) with
    | Retire.Frontier.In_flight { writer; _ } ->
        if Id.equal writer view.me then Draft else Snooped writer
    | Retire.Frontier.Committed state -> Committed state

  let resolve view (path : Relpath.t) =
    let rel = Relpath.to_string path in
    let disk = Filename.concat view.repo rel in
    if Sys.file_exists disk then Ok { rel; disk; place = place_of view rel }
    else Error `Missing
end

(* The wildcard-free leading segments of a pattern: where a committed-tree
   walk may start without touching the whole checkout. *)
let static_prefix pattern =
  let rec take acc = function
    | s :: rest when not (String.exists (fun c -> c = '*' || c = '?') s) ->
        take (s :: acc) rest
    | _ -> List.rev acc
  in
  String.concat "/" (take [] (String.split_on_char '/' pattern))

(* Every (relative path, on-disk path, place) [pattern] matches in the
   shared tree — ONE walk, each path's place a frontier judgment, exactly
   as [Source.resolve] judges a single path. The walk starts at the
   pattern's wildcard-free prefix — never the harness process cwd
   ([view.repo] owns the coordinate); rels stay repo-relative, disks
   absolute under the root. *)
let readable_matches (view : Source.view) pattern =
  let prefix = static_prefix pattern in
  let base =
    if prefix = "" then view.Source.repo
    else Filename.concat view.Source.repo prefix
  in
  let rels =
    match Sys.is_directory base with
    | exception Sys_error _ -> []
    | true ->
        walk base
        |> List.map (fun rel -> if prefix = "" then rel else prefix ^ "/" ^ rel)
    | false -> if Sys.file_exists base then [ prefix ] else []
  in
  List.filter_map
    (fun rel ->
      if glob_matches pattern rel then
        Some
          ( rel,
            Filename.concat view.Source.repo rel,
            Source.place_of view rel )
      else None)
    rels

let rec mkdirs dir =
  if dir = "." || dir = "/" || Sys.file_exists dir then ()
  else begin
    mkdirs (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let count_occurrences ~needle hay =
  let n = String.length needle and h = String.length hay in
  if n = 0 then 0
  else begin
    let rec go i acc =
      if i + n > h then acc
      else if String.sub hay i n = needle then go (i + n) (acc + 1)
      else go (i + 1) acc
    in
    go 0 0
  end

let replace_first ~needle ~replacement hay =
  let n = String.length needle and h = String.length hay in
  let rec find i =
    if n = 0 || i + n > h then None
    else if String.sub hay i n = needle then Some i
    else find (i + 1)
  in
  Option.map
    (fun i ->
      String.sub hay 0 i ^ replacement ^ String.sub hay (i + n) (h - i - n))
    (find 0)

let contains ~needle hay = count_occurrences ~needle hay > 0

(* The mkdir-atomic, holder-named machine lock every effect runs behind:
   shared machine state is outside every granted write surface, so
   effects serialize machine-wide (docs/architecture/20-medium.md § event
   taxonomy; migration row 6 re-scopes this to per-resource locks).

   The holder file carries the holder's NAME and PID: a crashed run
   cannot release its lock, so a lock whose recorded pid no longer runs
   is STALE — removed and retaken with one warning line instead of a 30s
   spin into a spurious busy error. An unreadable or pid-less holder
   file stays conservative (treated as live: only positive evidence of
   death breaks a lock). *)
let effect_lock_dir =
  Filename.concat (Filename.get_temp_dir_name ()) "goatcode-effect.lock"

let holder_pid contents =
  let marker = " pid=" in
  let n = String.length contents and m = String.length marker in
  let rec find i =
    if i + m > n then None
    else if String.equal (String.sub contents i m) marker then Some (i + m)
    else find (i + 1)
  in
  Option.bind (find 0) (fun i ->
      int_of_string_opt (String.trim (String.sub contents i (n - i))))

let pid_alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
  | exception Unix.Unix_error (_, _, _) -> false

let with_effect_lock ~holder f =
  let holder_file = Filename.concat effect_lock_dir "holder" in
  let rec acquire budget =
    match Unix.mkdir effect_lock_dir 0o755 with
    | () ->
        write_file_bytes holder_file
          (Printf.sprintf "%s pid=%d" holder (Unix.getpid ()));
        Ok ()
    | exception Unix.Unix_error (Unix.EEXIST, _, _) -> (
        let contents =
          try Some (String.trim (read_file_bytes holder_file))
          with Sys_error _ -> None
        in
        match Option.bind contents holder_pid with
        | Some pid when not (pid_alive pid) ->
            Printf.eprintf
              "goatcode: effect lock holder is not running (%s); removing \
               the stale lock\n\
               %!"
              (Option.value contents ~default:"unknown");
            remove_quietly holder_file;
            (try Unix.rmdir effect_lock_dir
             with Unix.Unix_error (_, _, _) -> ());
            acquire budget
        | _ ->
            if budget <= 0 then
              Error
                (Printf.sprintf
                   "effect lock busy (held by %s); no action was taken"
                   (Option.value contents ~default:"unknown"))
            else begin
              Unix.sleepf 0.05;
              acquire (budget - 1)
            end)
    | exception Unix.Unix_error (_, _, _) ->
        Error "effect lock: cannot create lock directory"
  in
  match acquire 600 with
  | Error m -> Error m
  | Ok () ->
      Fun.protect
        ~finally:(fun () ->
          remove_quietly holder_file;
          try Unix.rmdir effect_lock_dir
          with Unix.Unix_error (_, _, _) -> ())
        (fun () -> Ok (f ()))

(* One harness tool: a declaration plus a run function with the grant
   already bound. Events travel in the outcome as data; the loop appends
   them (the fetchmail move: variation lives in the table, not a match). *)
module Tool = struct
  type outcome = { payload : string; events : Ledger.Event.kind list }
  type failure = Refused of Grant.Refusal.t | Errored of string

  type t = {
    decl : Provider.Tool_decl.t;
    run : Yojson.Safe.t -> (outcome, failure) result;
  }
end

let ( let* ) = Result.bind

(* {3 Tool arguments: parsed once at the boundary, refined values flow} *)

let str_arg name input : (string, Tool.failure) result =
  match jmem name input with
  | Some (`String s) -> Ok s
  | Some _ ->
      Error (Tool.Errored (Printf.sprintf "argument %S must be a string" name))
  | None -> Error (Tool.Errored ("missing required argument: " ^ name))

let path_arg ~tool ~boundary name input : (Relpath.t, Tool.failure) result =
  let* raw = str_arg name input in
  match Relpath.parse raw with
  | Some p -> Ok p
  | None ->
      Error
        (Tool.Refused
           { Grant.Refusal.requested = tool ^ " " ^ raw; boundary })

let read_boundary = "reads: repo-relative paths within the shared tree"

let write_boundary (grant : _ Grant.t) =
  match grant.Grant.write_globs with
  | [] -> "writes: no write_globs granted"
  | globs -> "writes: write_globs [" ^ String.concat ", " globs ^ "]"

(* What one served read may CLAIM in the observed witness, decided by the
   place it was served from (the self-witness ruling, wave 3):

   - [Committed]: the read observed committed bytes — stamp the REAL
     committed generation the place already carries; the content hash is
     the bytes actually read, so a stale tree still fails [Witness.holds]
     (falsifier F6). An address with no committed entry stays at [zero]
     with the content carrying the commit-point judgment (B7).
   - [Snooped]: an in-flight observation of another node's store —
     generation zero, content judged when that producer lands (F7's
     free-commit discrimination). The tracked-hypothesis half rides
     [snoop_events] below.
   - [Draft]: store-to-load forwarding of the node's OWN in-flight work —
     not an observation of shared state, so it claims NOTHING. A draft
     triple could never hold at the node's own retire (its landing has
     not happened when the witness is judged: pre-fix, an edited file
     read back poisoned the witness into spurious Witness_moved
     reissues), and a vacuously-held one would shield the conflict
     judgment's witnessed-membership proof. The claims that gate
     retirement are the committed reads that seeded the draft and the
     write's base coordinate. *)
let load_observation ~place rel bytes =
  let address = Ledger.Address.File rel in
  match (place : Source.place) with
  | Source.Draft -> []
  | Source.Snooped _ ->
      [ (address, Ledger.Generation.zero, Ledger.Content_hash.of_string bytes) ]
  | Source.Committed state ->
      let generation =
        match state with
        | Witness.Committed_state.Landed { generation; _ }
        | Witness.Committed_state.Deleted { generation } ->
            generation
        | Witness.Committed_state.Absent -> Ledger.Generation.zero
      in
      [ (address, generation, Ledger.Content_hash.of_string bytes) ]

(* The tracked half of a snooped read: everything in-grant is snoopable,
   automatically, and the hypothesis tracker — not any mount — is what
   makes it honest (20-medium.md § store-to-load forwarding). The
   chase-supplied closure mints and registers the [Hypothesis_taken];
   the events ride the tool outcome like any other (falsifier FL2). *)
let snoop_events (view : Source.view) ~place rel bytes =
  match (place : Source.place) with
  | Source.Snooped producer ->
      view.Source.snoop
        ~address:(Ledger.Address.File rel)
        ~producer
        ~content:(Ledger.Content_hash.of_string bytes)
  | Source.Draft | Source.Committed _ -> []

let decl name description props ~required : Provider.Tool_decl.t =
  {
    name;
    description;
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc
              (List.map
                 (fun (pname, doc) ->
                   ( pname,
                     `Assoc
                       [
                         ("type", `String "string");
                         ("description", `String doc);
                       ] ))
                 props) );
          ("required", `List (List.map (fun r -> `String r) required));
          ("additionalProperties", `Bool false);
        ];
  }

let read_file_tool (view : Source.view) : Tool.t =
  {
    decl =
      decl "read_file" "Read one file from the shared tree."
        [ ("path", "Repo-relative path.") ]
        ~required:[ "path" ];
    run =
      (fun input ->
        let* path =
          path_arg ~tool:"read_file" ~boundary:read_boundary "path" input
        in
        match Source.resolve view path with
        | Error `Missing ->
            Error
              (Tool.Errored
                 ("read_file: no such file: " ^ Relpath.to_string path))
        | Ok { Source.rel; disk; place } -> (
            match read_file_bytes disk with
            | exception Sys_error m -> Error (Tool.Errored ("read_file: " ^ m))
            | bytes ->
                Ok
                  {
                    Tool.payload = bytes;
                    events =
                      snoop_events view ~place rel bytes
                      @ [
                          Ledger.Event.Load
                            {
                              tool = "read_file";
                              observed = load_observation ~place rel bytes;
                            };
                        ];
                  }));
  }

(* The store path's git boundary: hash [file]'s bytes into the object
   database at [repo] as a loose blob ([git hash-object -w]) and parse the
   printed oid. Shelling out to git is the engine's commit-substrate idiom
   (retire.ml owns the same boundary), and the git ban binds workers,
   never the harness (docs/architecture/60-agents.md § the git ban): this
   subprocess is the harness writing its own blob store. *)
let blob_into_object_store ~repo file =
  let ic =
    Unix.open_process_in
      (Printf.sprintf "git -C %s hash-object -w -- %s 2>/dev/null"
         (Filename.quote repo) (Filename.quote file))
  in
  let line = In_channel.input_line ic in
  match (Unix.close_process_in ic, line) with
  | Unix.WEXITED 0, Some printed -> Ledger.Delta_ref.blob printed
  | _, _ -> None

(* The write half of the argument boundary: the [Relpath] parse plus the
   write_globs judgment, one site — a store path outside the grant is the
   typed in-band refusal, and nothing downstream re-checks
   (40-agents.md § tool grants; README.md § design of record vs shipped
   engine, row 4). *)
let store_path_arg ~tool (grant : _ Grant.t) name input :
    (Relpath.t, Tool.failure) result =
  let boundary = write_boundary grant in
  let* path = path_arg ~tool ~boundary name input in
  let rel = Relpath.to_string path in
  if List.exists (fun g -> glob_matches g rel) grant.Grant.write_globs then
    Ok path
  else
    Error (Tool.Refused { Grant.Refusal.requested = tool ^ " " ^ rel; boundary })

(* Every file store lands through this one site, three obligations,
   ordered (docs/architecture/20-medium.md § event taxonomy): blob first —
   the full content into the object database at the shared tree's repo,
   so the oid exists before any event names it; rename second — the bytes
   move from a same-directory temporary into place by rename(2), atomic
   on POSIX, so the readers the domain does not schedule (gate
   subprocesses, external tools, the operator's own editor) can never
   observe an interleaving (falsifier FL7); Store event third — returned
   as data for the tool loop to append. A store whose blob cannot land is
   a typed tool error, not a write: no event may name an oid the object
   store does not hold. *)
let store_file ~tool (view : Source.view) rel content :
    (Ledger.Event.kind, Tool.failure) result =
  let errored m = Error (Tool.Errored (tool ^ ": " ^ m)) in
  let target = Filename.concat view.Source.repo rel in
  match
    mkdirs (Filename.dirname target);
    Filename.temp_file ~temp_dir:(Filename.dirname target) ".goat-store" ".tmp"
  with
  | exception Sys_error m -> errored m
  | tmp -> (
      match
        write_file_bytes tmp content;
        (* the temporary is born 0600; the landed file keeps the store's
           usual read bits (best effort — permissions are not the law
           here, atomicity is) *)
        try Unix.chmod tmp 0o644 with Unix.Unix_error _ -> ()
      with
      | exception Sys_error m ->
          remove_quietly tmp;
          errored m
      | () -> (
          match blob_into_object_store ~repo:view.Source.repo tmp with
          | None ->
              remove_quietly tmp;
              errored
                ("the object store refused the content (no repository at "
                ^ view.Source.repo ^ ")")
          | Some delta -> (
              match Sys.rename tmp target with
              | exception Sys_error m ->
                  remove_quietly tmp;
                  errored m
              | () ->
                  Ok
                    (Ledger.Event.Store
                       { tool; address = Ledger.Address.File rel; delta }))))

let write_file_tool (view : Source.view) (grant : _ Grant.t) : Tool.t =
  {
    decl =
      decl "write_file"
        "Write one file in the shared tree, within your write_globs, \
         creating parent directories as needed."
        [
          ("path", "Repo-relative path; must match your write_globs.");
          ("content", "The full file contents to write.");
        ]
        ~required:[ "path"; "content" ];
    run =
      (fun input ->
        let* path = store_path_arg ~tool:"write_file" grant "path" input in
        let* content = str_arg "content" input in
        let rel = Relpath.to_string path in
        let* store_event = store_file ~tool:"write_file" view rel content in
        Ok
          {
            Tool.payload =
              Printf.sprintf "wrote %d bytes to %s" (String.length content)
                rel;
            events = [ store_event ];
          });
  }

let str_replace_edit_tool (view : Source.view) (grant : _ Grant.t) : Tool.t =
  {
    decl =
      decl "str_replace_edit"
        "Replace one exact occurrence of old_str with new_str; the edited \
         file lands in the shared tree, within your write_globs."
        [
          ("path", "Repo-relative path; must match your write_globs.");
          ("old_str", "Exact text to replace; must occur exactly once.");
          ("new_str", "Replacement text.");
        ]
        ~required:[ "path"; "old_str"; "new_str" ];
    run =
      (fun input ->
        let* path = store_path_arg ~tool:"str_replace_edit" grant "path" input in
        let* old_str = str_arg "old_str" input in
        let* new_str = str_arg "new_str" input in
        match Source.resolve view path with
        | Error `Missing ->
            Error
              (Tool.Errored
                 ("str_replace_edit: no such file: " ^ Relpath.to_string path))
        | Ok { Source.rel; disk; place } -> (
            match read_file_bytes disk with
            | exception Sys_error m ->
                Error (Tool.Errored ("str_replace_edit: " ^ m))
            | bytes -> (
                (* An edit is a read of the source (committed, snooped, or
                   the node's own draft) plus a store — both evented; the
                   place decides what the read claims, and a snooped
                   source is a tracked hypothesis like any other snooped
                   read. *)
                let read_events =
                  snoop_events view ~place rel bytes
                  @ [
                      Ledger.Event.Load
                        {
                          tool = "str_replace_edit";
                          observed = load_observation ~place rel bytes;
                        };
                    ]
                in
                match count_occurrences ~needle:old_str bytes with
                | 0 ->
                    Error
                      (Tool.Errored
                         ("str_replace_edit: old_str not found in " ^ rel))
                | n when n > 1 ->
                    Error
                      (Tool.Errored
                         (Printf.sprintf
                            "str_replace_edit: old_str occurs %d times in %s; \
                             it must occur exactly once"
                            n rel))
                | _ ->
                    let edited =
                      Option.get
                        (replace_first ~needle:old_str ~replacement:new_str
                           bytes)
                    in
                    let* store_event =
                      store_file ~tool:"str_replace_edit" view rel edited
                    in
                    Ok
                      {
                        Tool.payload = "edited " ^ rel;
                        events = read_events @ [ store_event ];
                      })));
  }

let glob_list_tool (view : Source.view) : Tool.t =
  {
    decl =
      decl "glob_list" "List files in the shared tree matching a glob pattern."
        [ ("pattern", "Glob; ** spans directories, * and ? stay in one.") ]
        ~required:[ "pattern" ];
    run =
      (fun input ->
        let* pattern =
          path_arg ~tool:"glob_list" ~boundary:read_boundary "pattern" input
        in
        let matches = readable_matches view (Relpath.to_string pattern) in
        Ok
          {
            Tool.payload =
              Yojson.Safe.to_string
                (`List (List.map (fun (rel, _, _) -> `String rel) matches));
            (* The observation a glob contributes is the listing itself:
               which paths exist. For a path whose top is Committed
               Landed, the listing witnesses the committed (generation,
               content) pair straight from the place — the node read no
               bytes, so the recorded content is the committed record,
               never a hash of the path string. A path that exists only
               in flight (a draft, a snoop, absent from committed state)
               contributes no triple: existence-of-uncommitted is not a
               claim [Witness.holds] can judge in v0 — the recorded
               choice (docs/architecture/20-medium.md § event
               taxonomy). *)
            events =
              [
                Ledger.Event.Load
                  {
                    tool = "glob_list";
                    observed =
                      List.filter_map
                        (fun (rel, _, place) ->
                          match (place : Source.place) with
                          | Source.Committed
                              (Witness.Committed_state.Landed
                                { generation; content }) ->
                              Some
                                (Ledger.Address.File rel, generation, content)
                          | Source.Committed _ | Source.Draft
                          | Source.Snooped _ ->
                              None)
                        matches;
                  };
              ];
          });
  }

let grep_tool (view : Source.view) : Tool.t =
  {
    decl =
      decl "grep"
        "Search readable files for a substring; returns path:line: text \
         matches."
        [
          ("pattern", "Substring to search for (not a regex).");
          ("glob", "Optional file glob to search within; defaults to **.");
        ]
        ~required:[ "pattern" ];
    run =
      (fun input ->
        let* pattern = str_arg "pattern" input in
        let* glob =
          match jmem "glob" input with
          | None -> Ok "**"
          | Some _ ->
              let* g =
                path_arg ~tool:"grep" ~boundary:read_boundary "glob" input
              in
              Ok (Relpath.to_string g)
        in
        let files = readable_matches view glob in
        let out = Buffer.create 256 in
        let observed = ref [] in
        let snooped = ref [] in
        let hits = ref 0 in
        List.iter
          (fun (rel, disk, place) ->
            if !hits < 200 then
              match read_file_bytes disk with
              | exception Sys_error _ -> ()
              | bytes ->
                  observed := load_observation ~place rel bytes @ !observed;
                  snooped := snoop_events view ~place rel bytes @ !snooped;
                  List.iteri
                    (fun i line ->
                      if !hits < 200 && contains ~needle:pattern line then begin
                        incr hits;
                        Buffer.add_string out
                          (Printf.sprintf "%s:%d: %s\n" rel (i + 1) line)
                      end)
                    (String.split_on_char '\n' bytes))
          files;
        Ok
          {
            Tool.payload =
              (if Buffer.length out = 0 then "no matches"
               else Buffer.contents out);
            events =
              List.rev !snooped
              @ [
                  Ledger.Event.Load
                    { tool = "grep"; observed = List.rev !observed };
                ];
          });
  }

(* The git ban (operator ruling: "ban all git commands from any of the
   workers"; docs/architecture/60-agents.md § the git ban). Git is the
   harness's commit substrate — [Retire.Committed] holds the only writer
   lock on the committed branch — so a worker running git is an
   unwitnessed effect plus revert machinery plus branch machinery, three
   laws in one act. The screen walks the token stream for
   command-position tokens: argv0; tokens after [&&]/[||]/[;]/[|]/[&],
   subshell and substitution opens, and backticks; leading VAR=value
   assignments, wrapper commands ([env], [exec], ...), their flags, and
   bare numbers are transparent; one layer of matched quotes is stripped
   and the basename compared. HONESTY: this is a tripwire, not a security
   boundary — [sh -c], [$PATH] games, and a script that calls git all
   pass it; PATH/sandbox control over worker subprocesses is the recorded
   growth path. *)
let git_ban_boundary =
  "git is the harness's commit substrate; workers never touch it"

let names_git command =
  let unquote token =
    let n = String.length token in
    if
      n >= 2
      && ((token.[0] = '"' && token.[n - 1] = '"')
         || (token.[0] = '\'' && token.[n - 1] = '\''))
    then String.sub token 1 (n - 2)
    else token
  in
  let is_assignment token =
    match String.index_opt token '=' with
    | Some i when i > 0 ->
        String.for_all
          (fun c ->
            (c >= 'a' && c <= 'z')
            || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')
            || c = '_')
          (String.sub token 0 i)
    | Some _ | None -> false
  in
  let is_wrapper = function
    | "env" | "exec" | "command" | "nohup" | "time" | "timeout" | "nice"
    | "stdbuf" | "xargs" | "sudo" ->
        true
    | _ -> false
  in
  let is_number token = String.for_all (fun c -> c >= '0' && c <= '9') token in
  (* Space out the separator characters so command position survives
     unspaced spellings like [x&&git status] and [$(git rev-parse)]. *)
  let spaced = Buffer.create (String.length command * 2) in
  String.iter
    (fun c ->
      match c with
      | ';' | '|' | '&' | '(' | ')' | '`' | '\n' ->
          Buffer.add_char spaced ' ';
          Buffer.add_char spaced c;
          Buffer.add_char spaced ' '
      | c -> Buffer.add_char spaced c)
    command;
  let tokens =
    String.split_on_char ' ' (Buffer.contents spaced)
    |> List.concat_map (String.split_on_char '\t')
    |> List.filter (fun t -> t <> "")
  in
  let separator = function
    | ";" | "|" | "&" | "(" | ")" | "`" -> true
    | _ -> false
  in
  let rec scan command_position = function
    | [] -> false
    | token :: rest ->
        if separator token then scan true rest
        else if
          command_position
          && (is_assignment token
             || is_number token
             || String.length token > 0
                && token.[0] = '-')
        then scan true rest
        else
          (* Case-insensitive: a case-insensitive filesystem (macOS)
             happily executes [GIT]. *)
          let word =
            String.lowercase_ascii (Filename.basename (unquote token))
          in
          if command_position && String.equal word "git" then true
          else scan (command_position && is_wrapper word) rest
  in
  scan true tokens

let run_command_tool ~idempotent (view : Source.view) : Tool.t =
  {
    decl =
      decl "run_command"
        "Run one shell command in the shared tree, behind the machine \
         effect lock; exit status and output come back. Git is banned: \
         the harness owns the commit substrate."
        [ ("command", "The shell command line.") ]
        ~required:[ "command" ];
    run =
      (fun input ->
        let* command = str_arg "command" input in
        let* () =
          if names_git command then
            Error
              (Tool.Refused
                 {
                   Grant.Refusal.requested = "run_command " ^ command;
                   boundary = git_ban_boundary;
                 })
          else Ok ()
        in
        let out_file = Filename.temp_file "goat-cmd-" ".txt" in
        let run () =
          Fun.protect
            ~finally:(fun () -> remove_quietly out_file)
            (fun () ->
              let status =
                Sys.command
                  (Printf.sprintf "cd %s && ( %s ) > %s 2>&1"
                     (Filename.quote view.Source.repo)
                     command (Filename.quote out_file))
              in
              (status, read_file_bytes out_file))
        in
        match with_effect_lock ~holder:(Id.to_string view.Source.me) run with
        | Error m -> Error (Tool.Errored ("run_command: " ^ m))
        | Ok (status, output) ->
            Ok
              {
                Tool.payload =
                  Yojson.Safe.to_string
                    (`Assoc
                      [
                        ("exit_status", `Int status);
                        ("output", `String output);
                      ]);
                events =
                  [
                    Ledger.Event.Effect
                      {
                        tool = "run_command";
                        resource = "machine";
                        idempotent;
                      };
                  ];
              });
  }

(* The capability table. Derivation is the ONLY place grant becomes
   ability: run_command appears exactly when the grant's effects carry it
   (with the idempotence its constructor declared — the F12/F15 index
   already screened what could be constructed), and an absent entry is an
   undeclared tool the model was never shown. *)
module Toolset = struct
  type t = (string * Tool.t) list

  (* [view] carries the node identity (the effect lock's holder name and
     the draft judgment), the shared tree, and the frontier/snoop
     closures the invocation supplied. *)
  let of_grant ~(view : Source.view) (grant : _ Grant.t) : t =
    let base =
      [
        read_file_tool view;
        write_file_tool view grant;
        str_replace_edit_tool view grant;
        glob_list_tool view;
        grep_tool view;
      ]
    in
    let effects =
      List.filter_map
        (fun (e : _ Grant.Effect_tool.t) ->
          match e with
          | Grant.Effect_tool.Idempotent { name = "run_command"; _ } ->
              Some (run_command_tool ~idempotent:true view)
          | Grant.Effect_tool.Non_idempotent { name = "run_command" } ->
              Some (run_command_tool ~idempotent:false view)
          | _ -> None)
        grant.Grant.effects
    in
    List.map (fun (t : Tool.t) -> (t.decl.Provider.Tool_decl.name, t)) (base @ effects)

  let decls (t : t) = List.map (fun (_, tool) -> tool.Tool.decl) t

  (* One call in, one typed result plus its events out. Dispatch is
     lookup; the grant was consulted at derivation, not here. *)
  let execute (t : t) (call : Provider.Call.t) :
      Provider.Tool_result.t * Ledger.Event.kind list =
    match List.assoc_opt call.Provider.Call.name t with
    | None ->
        ( {
            Provider.Tool_result.call_id = call.id;
            output =
              Printf.sprintf
                "unknown tool: %s (not declared in this node's grant)"
                call.name;
            is_error = true;
          },
          [] )
    | Some tool -> (
        match tool.Tool.run call.input with
        | Ok { Tool.payload; events } ->
            ( {
                Provider.Tool_result.call_id = call.id;
                output = payload;
                is_error = false;
              },
              events )
        | Error (Tool.Refused r) ->
            ( {
                Provider.Tool_result.call_id = call.id;
                output = Grant.Refusal.render r;
                is_error = true;
              },
              [] )
        | Error (Tool.Errored m) ->
            ( {
                Provider.Tool_result.call_id = call.id;
                output = m;
                is_error = true;
              },
              [] ))
end

(* {2 The agent layer}

   One tool loop shared by every provider lane — which is exactly what
   makes the loop's ledger eventing, grant boundary, and stop policy a
   single implementation rather than per-lane copies. *)

let agent ~stop ~provider =
  let run :
      type s.
      s Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:(unit -> Speculate.Drift.note list) ->
      (Executor.reply, Ledger.Fault.t) result =
   fun inv ~ledger ~node ~on_yield ->
    let record kind =
      ignore (Ledger.append ledger ~node kind : Ledger.Event.t)
    in
    let toolset =
      Toolset.of_grant
        ~view:
          {
            Source.me = node;
            repo = inv.Invocation.repo;
            frontier = inv.Invocation.frontier;
            snoop = inv.Invocation.snoop;
          }
        inv.Invocation.grant
    in
    let tools = Toolset.decls toolset in
    let conditions =
      Stop.step_ceiling
        (opt_int inv.Invocation.pin.Theory.Pin.options "max_steps" ~default:32)
      :: stop
    in
    let rec turn ~steps ~usage messages =
      match Stop.check conditions ~steps ~usage with
      | Some why -> Error (fault Ledger.Fault.Context_exhausted why)
      | None -> (
          match
            provider.Provider.turn
              {
                Provider.pin = inv.Invocation.pin;
                system = "";
                messages;
                tools;
                schema = inv.Invocation.schema;
              }
          with
          | Error f -> Error f
          | Ok (r : Provider.reply) -> (
              let usage = Ledger.Usage.add usage r.usage in
              match r.outcome with
              | Provider.Suspend ->
                  (* A work-free suspension bills no model turn; the
                     script continues unless a note says stop. *)
                  if stop_requested (on_yield ()) then
                    Ok { Executor.outcome = Executor.Text ""; usage }
                  else turn ~steps ~usage messages
              | Provider.Settled { text } ->
                  record (Ledger.Event.Agent_turn { usage = r.usage });
                  Ok { Executor.outcome = Executor.Text text; usage }
              | Provider.Refused { text } ->
                  record (Ledger.Event.Agent_turn { usage = r.usage });
                  Ok { Executor.outcome = Executor.Refusal text; usage }
              | Provider.Calls { text; first; rest } ->
                  record (Ledger.Event.Agent_turn { usage = r.usage });
                  let calls = first :: rest in
                  let results =
                    List.map
                      (fun call ->
                        let result, events = Toolset.execute toolset call in
                        List.iter record events;
                        result)
                      calls
                  in
                  (* Between tool calls: the fiber's suspension point,
                     where drift notes land (docs/architecture/60-agents.md
                     § drift notes at yield). *)
                  if stop_requested (on_yield ()) then
                    Ok { Executor.outcome = Executor.Text ""; usage }
                  else
                    turn ~steps:(steps + 1) ~usage
                      (messages
                      @ [
                          Provider.Message.Assistant { text; calls };
                          Provider.Message.Tool_results results;
                        ])))
    in
    turn ~steps:0 ~usage:Ledger.Usage.zero
      [ Provider.Message.User (Prompt.render inv.Invocation.prompt) ]
  in
  { Executor.run }

module Rigged = struct
  type step =
    | Reply of string
    | Invalid of string
    | Refuse of string
    | Fault of string
    | Delay_s of float
    | Yield
    | Call_tool of { name : string; input : Yojson.Safe.t }

  (* Steps live in a ref shared by every turn of the same provider value: a
     repair re-invocation consumes the next step, so F10 scripts "invalid,
     invalid, valid" and counts attempts. [Delay_s] is consumed without
     sleeping — scheduling pressure, never wall-clock cost. [Yield] is
     {!Provider.Suspend}: the agent loop's suspension fires and the script
     continues. *)
  let provider ~script =
    let remaining = ref script in
    let turn _request =
      let rec step () =
        match !remaining with
        | [] ->
            Error (fault Ledger.Fault.Executor_error "rigged script exhausted")
        | s :: rest -> (
            remaining := rest;
            let scripted_usage text =
              { Ledger.Usage.tokens_in = 0; tokens_out = approx_tokens text }
            in
            match s with
            | Reply text | Invalid text ->
                (* Reply and Invalid differ only in the scripted text's fate
                   at the codec boundary; the provider's job is the same:
                   return the turn's final text. *)
                Ok
                  {
                    Provider.outcome = Provider.Settled { text };
                    usage = scripted_usage text;
                  }
            | Refuse text ->
                Ok
                  {
                    Provider.outcome = Provider.Refused { text };
                    usage = scripted_usage text;
                  }
            | Fault message ->
                Error (fault Ledger.Fault.Executor_error message)
            | Delay_s _ -> step ()
            | Yield ->
                Ok
                  {
                    Provider.outcome = Provider.Suspend;
                    usage = Ledger.Usage.zero;
                  }
            | Call_tool { name; input } ->
                Ok
                  {
                    Provider.outcome =
                      Provider.Calls
                        {
                          text = "";
                          first = { Provider.Call.id = "rigged"; name; input };
                          rest = [];
                        };
                    usage = Ledger.Usage.zero;
                  })
      in
      step ()
    in
    { Provider.turn }

  let executor ~script = agent ~stop:[] ~provider:(provider ~script)
end

(* Host OCaml as an executor: the witnessed operand section (codec-rendered
   JSON) in, head-tuple JSON out. Mechanical transforms never deserve
   tokens, so usage is zero by construction. *)
let pure_fn f =
  let run :
      type s.
      s Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:_ ->
      _ =
   fun invocation ~ledger:_ ~node:_ ~on_yield:_ ->
    let witnessed =
      List.find_map
        (function
          | Prompt.Operands { witnessed; speculative = _ } -> Some witnessed
          | _ -> None)
        (Prompt.parts invocation.Invocation.prompt)
    in
    match witnessed with
    | None ->
        Error
          (fault Ledger.Fault.Executor_error
             "pure_fn: invocation prompt carries no operand section")
    | Some w -> (
        let operands =
          let w = String.trim w in
          if w = "" then Ok `Null
          else
            match Yojson.Safe.from_string w with
            | json -> Ok json
            | exception _ ->
                Error "pure_fn: operand section is not valid JSON"
        in
        match operands with
        | Error message -> Error (fault Ledger.Fault.Executor_error message)
        | Ok operands -> (
            match f operands with
            | Ok head ->
                Ok
                  {
                    Executor.outcome =
                      Executor.Text (Yojson.Safe.to_string head);
                    usage = Ledger.Usage.zero;
                  }
            | Error message ->
                Error (fault Ledger.Fault.Executor_error message)))
  in
  { Executor.run }

(* Runs the gate command line the grant declares; exit status and captured
   output become the head tuple. A non-zero exit is data (a failing test
   run is a tuple, not a fault). The gate is an effect against shared
   machine state, under the same discipline as [run_command]: it executes
   behind the mkdir-atomic, holder-named machine lock and appends the
   [Effect] event with the declared command line as the resource — an
   unobserved, un-locked effect lane is not writable here. Idempotence is
   the declaration's: a gate is a build/test command the engine may
   freely reissue, which is why gates are grantable under either
   speculation index (docs/architecture/30-channels.md § event
   taxonomy). *)
let shell_gate =
  let run :
      type s.
      s Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:_ ->
      _ =
   fun invocation ~ledger ~node ~on_yield ->
    if stop_requested (on_yield ()) then
      Ok { Executor.outcome = Executor.Text ""; usage = Ledger.Usage.zero }
    else
      match invocation.Invocation.grant.Grant.shell_gates with
      | [] | [] :: _ ->
          Error
            (fault Ledger.Fault.Executor_error
               "shell_gate: grant declares no gate command line")
      | gate :: _ -> (
          let out_file = Filename.temp_file "goat-gate-" ".txt" in
          let run_gate () =
            Fun.protect
              ~finally:(fun () -> remove_quietly out_file)
              (fun () ->
                (* The gate runs IN the shared tree: the one tree its
                   body operands landed on, so the command sees exactly
                   the state it was spawned to judge. The gate's judgment
                   is its head tuple; a file it writes into the tree is
                   not an evented store, and the landing is built from
                   Store events alone (README.md § design of record vs
                   shipped engine, row 2) — so gate tree-writes never
                   land at retire (migration row 6 re-scopes gates to a
                   frontier snapshot). The harness process cwd is
                   ambient machine state no footprint declares (live
                   trace 2026-07-15: a test gate resolved its test file
                   against the operator's shell cwd and reported a
                   spurious red). *)
                let command =
                  Printf.sprintf "cd %s && %s > %s 2>&1"
                    (Filename.quote invocation.Invocation.repo)
                    (String.concat " " (List.map Filename.quote gate))
                    (Filename.quote out_file)
                in
                let status = Sys.command command in
                (status, read_file_bytes out_file))
          in
          match with_effect_lock ~holder:(Id.to_string node) run_gate with
          | Error m ->
              Error (fault Ledger.Fault.Executor_error ("shell_gate: " ^ m))
          | Ok (status, output) ->
              ignore
                (Ledger.append ledger ~node
                   (Ledger.Event.Effect
                      {
                        tool = "shell_gate";
                        resource = String.concat " " gate;
                        idempotent = true;
                      })
                  : Ledger.Event.t);
              let head =
                `Assoc
                  [ ("exit_status", `Int status); ("output", `String output) ]
              in
              Ok
                {
                  Executor.outcome =
                    Executor.Text (Yojson.Safe.to_string head);
                  usage = Ledger.Usage.zero;
                })
  in
  { Executor.run }

module Repair_budget = struct
  type t = int

  let v n = if n < 0 then 0 else n
  let attempts t = t
end

(* Diagnostics shaped for the repair re-invocation: the agent's own invalid
   output plus the parser's specific complaints
   (docs/architecture/20-contracts.md § failure surface). *)
let render_diagnostics (d : Contract.Repair.diagnostics) =
  let b = Buffer.create 256 in
  Buffer.add_string b
    "Your previous reply failed the contract boundary parse.\n\n\
     Your reply was:\n\n";
  Buffer.add_string b d.raw_reply;
  Buffer.add_string b "\n\nComplaints:\n";
  if d.complaints = [] then Buffer.add_string b "- the reply did not parse\n"
  else
    List.iter
      (fun (c : Contract.Repair.complaint) ->
        Buffer.add_string b
          (Printf.sprintf "- at %s: expected %s, got %s\n"
             (Contract.Path.to_string c.path)
             c.expected c.got))
      d.complaints;
  Buffer.add_string b
    "\nRe-emit your head tuples as valid structured output against the wire \
     schema in the contract section. Output only the tuples.";
  Buffer.contents b

let complaint_summary (d : Contract.Repair.diagnostics) =
  if d.Contract.Repair.refusal then "refusal"
  else if d.complaints = [] then "unparseable reply"
  else
    String.concat "; "
      (List.map
         (fun (c : Contract.Repair.complaint) ->
           Printf.sprintf "%s: expected %s, got %s"
             (Contract.Path.to_string c.path)
             c.expected c.got)
         d.complaints)

(* Warning 16 (unerasable optional argument) is inherent to the signature
   agent.mli mandates: [?fallback] is followed only by labelled arguments. *)
let[@warning "-16"] invoke_parsed ~executor ?fallback ~parse ~invocation
    ~budget ~ledger ~node ~on_yield =
  let max_attempts = Repair_budget.attempts budget in
  let record kind = ignore (Ledger.append ledger ~node kind) in
  let run_once (exec : Executor.t) inv =
    match exec.run inv ~ledger ~node ~on_yield with
    | Error f -> `Fault f
    | Ok (reply : Executor.reply) -> (
        (* Provider-typed refusals never reach the parser; marker-recognized
           ones surface from the parse as diagnostics with [refusal] set —
           both route the same way below. *)
        match reply.outcome with
        | Executor.Refusal text ->
            `Invalid
              {
                Contract.Repair.raw_reply = text;
                complaints = [];
                refusal = true;
              }
        | Executor.Text text -> (
            match parse text with
            | Ok v -> `Parsed v
            | Error d -> `Invalid d))
  in
  let repair_invocation (d : Contract.Repair.diagnostics) =
    {
      invocation with
      Invocation.prompt =
        Prompt.with_diagnostics invocation.Invocation.prompt
          (render_diagnostics d);
    }
  in
  (* [attempts_used] counts budgeted repair re-invocations; the one refusal
     reroute to the fallback lane never burns budget
     (docs/architecture/60-agents.md § the fallback lane). Repair attempts
     always re-invoke the primary executor — the same agent, stateless,
     with diagnostics. *)
  let rec loop ~attempts_used ~fallback_spent current inv =
    match run_once current inv with
    | `Parsed v -> Ok v
    | `Fault f -> Error f
    | `Invalid (d : Contract.Repair.diagnostics) ->
        if d.refusal && (not fallback_spent) && Option.is_some fallback then begin
          record
            (Ledger.Event.Repair_attempt
               { attempt = attempts_used; refusal = true });
          loop ~attempts_used ~fallback_spent:true (Option.get fallback) inv
        end
        else if attempts_used >= max_attempts then
          Error
            (fault Ledger.Fault.Repair_exhausted
               (Printf.sprintf
                  "repair budget (%d) exhausted; last complaints: %s"
                  max_attempts (complaint_summary d)))
        else begin
          let attempt = attempts_used + 1 in
          record
            (Ledger.Event.Repair_attempt { attempt; refusal = d.refusal });
          loop ~attempts_used:attempt ~fallback_spent executor
            (repair_invocation d)
        end
  in
  loop ~attempts_used:0 ~fallback_spent:false executor invocation

let[@warning "-16"] invoke ~executor ?fallback ~codec ~registry ~invocation
    ~budget ~ledger ~node ~on_yield =
  invoke_parsed ~executor ?fallback
    ~parse:(fun text -> Contract.Codec.parse codec ~registry text)
    ~invocation ~budget ~ledger ~node ~on_yield
