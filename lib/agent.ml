(* Execution units: tool grants, prompt assembly, the provider lanes, the
   harness-owned tool loop, and the validate-and-repair loop
   (docs/architecture/60-agents.md). *)

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
    worktree_root : string;
    snoop_mounts : string list;
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
    line "Writable root (your worktree, the store buffer): %s" g.worktree_root;
    (match g.read_globs with
    | [] -> line "Readable paths: none beyond your worktree."
    | globs ->
        line "Readable paths:";
        List.iter (fun glob -> line "- %s" glob) globs);
    (match g.snoop_mounts with
    | [] -> ()
    | mounts ->
        line "Read-only snoop mounts (upstream store buffers):";
        List.iter (fun m -> line "- %s" m) mounts);
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
  }
end

(* {2 JSON plumbing shared by the provider decoders} *)

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
  }

  type t = { turn : request -> (reply, Ledger.Fault.t) result }

  let usage_of j =
    match jmem "usage" j with
    | Some u ->
        { Ledger.Usage.tokens_in = jint "input_tokens" u;
          tokens_out = jint "output_tokens" u }
    | None -> Ledger.Usage.zero

  (* {3 The Anthropic Messages lane}

     POST https://api.anthropic.com/v1/messages, anthropic-version
     2023-06-01. Fable-5 wire rules (per the claude-api reference):
     - the [thinking] parameter is OMITTED entirely (an explicit disable is
       a 400), and no sampling knobs are ever sent (temperature/top_p/top_k
       are 400s) — the pin's [sampling] list is deliberately ignored here;
     - [output_config] carries [effort] (pin option "effort", default
       "high") and the structured-output [format];
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

  let anthropic_body (req : request) =
    let options = req.pin.Theory.Pin.options in
    `Assoc
      (List.concat
         [
           [
             ("model", `String req.pin.Theory.Pin.model);
             ("max_tokens", `Int (opt_int options "max_tokens" ~default:16000));
             ("messages", anthropic_messages req.messages);
           ];
           (if req.system = "" then []
            else [ ("system", `String req.system) ]);
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
                   ( "format",
                     `Assoc
                       [
                         ("type", `String "json_schema");
                         ("schema", Contract.Wire_schema.to_json req.schema);
                       ] );
                 ] );
           ];
         ])

  let decode_anthropic body =
    match Yojson.Safe.from_string body with
    | exception _ ->
        Error
          (fault Ledger.Fault.Executor_error
             "anthropic: unparseable response body")
    | json -> (
        let text_of_content () =
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
            Ok
              {
                text = text_of_content ();
                calls = [];
                stop = Refused;
                usage = usage_of json;
              }
        | _ ->
            let calls =
              jlist "content" json
              |> List.filter_map (fun block ->
                     match jstr "type" block with
                     | Some "tool_use" ->
                         Some
                           {
                             Call.id =
                               Option.value (jstr "id" block) ~default:"";
                             name =
                               Option.value (jstr "name" block) ~default:"";
                             input =
                               Option.value
                                 (jmem "input" block)
                                 ~default:(`Assoc []);
                           }
                     | _ -> None)
            in
            (* The calls, not the stop_reason, decide: a degenerate
               tool_use stop with zero blocks must end the turn, never
               loop an empty assistant message back at the API. *)
            let stop = if calls <> [] then Tool_calls else End_turn in
            Ok
              { text = text_of_content (); calls; stop; usage = usage_of json })

  let anthropic () =
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
            Http.post_json
              ~headers:
                [
                  ("x-api-key", key);
                  ("anthropic-version", "2023-06-01");
                  ("content-type", "application/json");
                ]
              ~url:"https://api.anthropic.com/v1/messages" ~body ~timeout_s
          with
          | Error (e : Http.error) ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "anthropic: %s (%s)" e.code e.message))
          | Ok (status, body) when status / 100 <> 2 ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "anthropic: HTTP %d: %s" status
                      (excerpt body)))
          | Ok (_, body) -> decode_anthropic body)
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
                         ("schema", Contract.Wire_schema.to_json req.schema);
                         ("strict", `Bool true);
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
            Error
              (fault Ledger.Fault.Executor_error
                 ("openai: response incomplete: " ^ reason))
        | _ ->
            let texts = Buffer.create 256 in
            let refused = ref false in
            let calls = ref [] in
            let bad_arguments = ref None in
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
                | Some "function_call" ->
                    let arguments =
                      Option.value (jstr "arguments" item) ~default:"{}"
                    in
                    (match Yojson.Safe.from_string arguments with
                    | exception _ ->
                        bad_arguments :=
                          Some (excerpt arguments)
                    | input ->
                        calls :=
                          {
                            Call.id =
                              Option.value (jstr "call_id" item) ~default:"";
                            name =
                              Option.value (jstr "name" item) ~default:"";
                            input;
                          }
                          :: !calls)
                | _ -> ())
              (jlist "output" json);
            (match !bad_arguments with
            | Some raw ->
                Error
                  (fault Ledger.Fault.Executor_error
                     ("openai: unparseable function_call arguments: " ^ raw))
            | None ->
                let calls = List.rev !calls in
                let stop =
                  if !refused then Refused
                  else if calls <> [] then Tool_calls
                  else End_turn
                in
                Ok
                  {
                    text = Buffer.contents texts;
                    calls;
                    stop;
                    usage = usage_of json;
                  }))

  let openai () =
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
            Http.post_json
              ~headers:
                [
                  ("authorization", "Bearer " ^ key);
                  ("content-type", "application/json");
                ]
              ~url:"https://api.openai.com/v1/responses" ~body ~timeout_s
          with
          | Error (e : Http.error) ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "openai: %s (%s)" e.code e.message))
          | Ok (status, body) when status / 100 <> 2 ->
              Error
                (fault Ledger.Fault.Executor_error
                   (Printf.sprintf "openai: HTTP %d: %s" status (excerpt body)))
          | Ok (_, body) -> decode_openai body)
    in
    { turn }
end

module Executor = struct
  type reply = { text : string; usage : Ledger.Usage.t; refusal : bool }

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
   agent performs is executed HERE and appended to the ledger with its
   footprint — the mechanized-witness law's substrate
   (docs/architecture/30-channels.md § mechanized witnesses). Reads resolve
   within the grant (worktree first — the node snoops its own store buffer
   — then read_globs against the committed checkout at the process CWD,
   then snoop mounts); writes land only in the worktree; effects run only
   through a granted effect tool, behind the machine lock. Out-of-grant
   actions return a typed in-band tool error, never a silent no-op. *)

module Tools = struct
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

  (* Paths are repo-relative by law: absolute paths and '..' hops are
     outside every grant by construction. *)
  let path_in_bounds p =
    Filename.is_relative p
    && not (List.mem ".." (String.split_on_char '/' p))

  (* Regular files under [root], as root-relative paths. Dot-entries and
     _build are pruned: worktrees and checkouts, not build state. *)
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

  (* The wildcard-free leading segments of a pattern: where a
     committed-tree walk may start without touching the whole checkout. *)
  let static_prefix pattern =
    let rec take acc = function
      | s :: rest when not (String.exists (fun c -> c = '*' || c = '?') s) ->
          take (s :: acc) rest
      | _ -> List.rev acc
    in
    String.concat "/" (take [] (String.split_on_char '/' pattern))

  (* Every (relative path, on-disk path) the grant lets this node read for
     [pattern], deduped with worktree drafts shadowing committed state
     shadowing snoop mounts (store-to-load forwarding order,
     docs/architecture/30-channels.md). *)
  let readable_matches (type s) (grant : s Grant.t) pattern =
    let seen = Hashtbl.create 16 in
    let add acc rel abs =
      if Hashtbl.mem seen rel then acc
      else begin
        Hashtbl.add seen rel ();
        (rel, abs) :: acc
      end
    in
    let acc =
      List.fold_left
        (fun acc rel ->
          if glob_matches pattern rel then
            add acc rel (Filename.concat grant.Grant.worktree_root rel)
          else acc)
        []
        (walk grant.Grant.worktree_root)
    in
    let committed =
      let prefix = static_prefix pattern in
      let base = if prefix = "" then "." else prefix in
      match Sys.is_directory base with
      | exception Sys_error _ -> []
      | true ->
          walk base
          |> List.map (fun rel ->
                 if prefix = "" then rel else prefix ^ "/" ^ rel)
      | false -> if Sys.file_exists base then [ base ] else []
    in
    let acc =
      List.fold_left
        (fun acc rel ->
          if
            glob_matches pattern rel
            && List.exists (fun g -> glob_matches g rel) grant.Grant.read_globs
          then add acc rel rel
          else acc)
        acc committed
    in
    let acc =
      List.fold_left
        (fun acc mount ->
          List.fold_left
            (fun acc rel ->
              if glob_matches pattern rel then
                add acc rel (Filename.concat mount rel)
              else acc)
            acc (walk mount))
        acc grant.Grant.snoop_mounts
    in
    List.rev acc

  (* Where one relative path may be read from, if anywhere. *)
  let readable_source (type s) (grant : s Grant.t) rel =
    let in_worktree = Filename.concat grant.Grant.worktree_root rel in
    if Sys.file_exists in_worktree then Some in_worktree
    else if
      List.exists (fun g -> glob_matches g rel) grant.Grant.read_globs
      && Sys.file_exists rel
    then Some rel
    else
      List.find_map
        (fun mount ->
          let p = Filename.concat mount rel in
          if Sys.file_exists p then Some p else None)
        grant.Grant.snoop_mounts

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
        String.sub hay 0 i ^ replacement
        ^ String.sub hay (i + n) (h - i - n))
      (find 0)

  let contains ~needle hay = count_occurrences ~needle hay > 0

  (* The mkdir-atomic, holder-named machine lock every effect runs behind:
     shared machine state is outside every worktree, so effects serialize
     machine-wide (docs/architecture/30-channels.md § event taxonomy). *)
  let effect_lock_dir =
    Filename.concat (Filename.get_temp_dir_name ()) "goatcode-effect.lock"

  let with_effect_lock ~holder f =
    let holder_file = Filename.concat effect_lock_dir "holder" in
    let rec acquire budget =
      match Unix.mkdir effect_lock_dir 0o755 with
      | () ->
          write_file_bytes holder_file holder;
          Ok ()
      | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
          if budget <= 0 then
            Error
              (Printf.sprintf
                 "effect lock busy (held by %s); no action was taken"
                 (try String.trim (read_file_bytes holder_file)
                  with Sys_error _ -> "unknown"))
          else begin
            Unix.sleepf 0.05;
            acquire (budget - 1)
          end
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

  (* {3 Declarations: what the model is told it may call} *)

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

  let run_command_granted (type s) (grant : s Grant.t) =
    List.find_map
      (fun (e : s Grant.Effect_tool.t) ->
        match e with
        | Grant.Effect_tool.Idempotent { name = "run_command"; _ } ->
            Some true
        | Grant.Effect_tool.Non_idempotent { name = "run_command" } ->
            Some false
        | _ -> None)
      grant.Grant.effects

  let declarations (type s) (grant : s Grant.t) =
    [
      decl "read_file" "Read one file within your grant."
        [ ("path", "Repo-relative path.") ]
        ~required:[ "path" ];
      decl "write_file"
        "Write one file in your worktree (the only writable root), creating \
         parent directories as needed."
        [
          ("path", "Repo-relative path; lands in your worktree.");
          ("content", "The full file contents to write.");
        ]
        ~required:[ "path"; "content" ];
      decl "str_replace_edit"
        "Replace one exact occurrence of old_str with new_str; the edited \
         file lands in your worktree."
        [
          ("path", "Repo-relative path.");
          ("old_str", "Exact text to replace; must occur exactly once.");
          ("new_str", "Replacement text.");
        ]
        ~required:[ "path"; "old_str"; "new_str" ];
      decl "glob_list" "List readable files matching a glob pattern."
        [ ("pattern", "Glob; ** spans directories, * and ? stay in one.") ]
        ~required:[ "pattern" ];
      decl "grep"
        "Search readable files for a substring; returns path:line: text \
         matches."
        [
          ("pattern", "Substring to search for (not a regex).");
          ("glob", "Optional file glob to search within; defaults to **.");
        ]
        ~required:[ "pattern" ];
    ]
    @
    match run_command_granted grant with
    | None -> []
    | Some _ ->
        [
          decl "run_command"
            "Run one shell command in your worktree, behind the machine \
             effect lock; exit status and output come back."
            [ ("command", "The shell command line.") ]
            ~required:[ "command" ];
        ]

  (* {3 Execution: grant enforcement + ledger eventing, one tool call in,
     one typed result out} *)

  let arg name input =
    match jmem name input with Some (`String s) -> Some s | _ -> None

  let ok output = (output, false)
  let error output = (output, true)

  let refuse ~requested ~boundary =
    error (Grant.Refusal.render { Grant.Refusal.requested; boundary })

  let read_boundary = "reads: read_globs + your worktree + snoop mounts"
  let write_boundary = "writes: your worktree only"

  (* Observed witness triples for tool loads carry the content hash by
     observation; the generation is [zero] until the engine threads
     committed-state lookups through the executor (the recorded B2/B7
     rewiring — the event and its footprint are what Phase A owes). *)
  let load_triple rel bytes =
    ( Ledger.Address.File rel,
      Ledger.Generation.zero,
      Ledger.Content_hash.of_string bytes )

  let execute (type s) ~(grant : s Grant.t) ~ledger ~node
      (call : Provider.Call.t) : Provider.Tool_result.t =
    let record kind =
      ignore (Ledger.append ledger ~node kind : Ledger.Event.t)
    in
    let output, is_error =
      match call.Provider.Call.name with
      | "read_file" -> (
          match arg "path" call.input with
          | None -> error "read_file: missing required argument: path"
          | Some path when not (path_in_bounds path) ->
              refuse ~requested:("read_file " ^ path) ~boundary:read_boundary
          | Some path -> (
              match readable_source grant path with
              | Some source -> (
                  match read_file_bytes source with
                  | exception Sys_error m -> error ("read_file: " ^ m)
                  | bytes ->
                      record
                        (Ledger.Event.Load
                           {
                             tool = "read_file";
                             observed = [ load_triple path bytes ];
                           });
                      ok bytes)
              | None ->
                  if
                    List.exists
                      (fun g -> glob_matches g path)
                      grant.Grant.read_globs
                  then error ("read_file: no such file: " ^ path)
                  else
                    refuse
                      ~requested:("read_file " ^ path)
                      ~boundary:read_boundary))
      | "write_file" -> (
          match (arg "path" call.input, arg "content" call.input) with
          | None, _ | _, None ->
              error "write_file: missing required arguments: path, content"
          | Some path, _ when not (path_in_bounds path) ->
              refuse ~requested:("write_file " ^ path) ~boundary:write_boundary
          | Some path, Some content -> (
              let target = Filename.concat grant.Grant.worktree_root path in
              match
                mkdirs (Filename.dirname target);
                write_file_bytes target content
              with
              | exception Sys_error m -> error ("write_file: " ^ m)
              | () ->
                  record
                    (Ledger.Event.Store
                       {
                         tool = "write_file";
                         address = Ledger.Address.File path;
                         delta = Ledger.Delta_ref.v path;
                       });
                  ok
                    (Printf.sprintf "wrote %d bytes to %s"
                       (String.length content) path)))
      | "str_replace_edit" -> (
          match
            ( arg "path" call.input,
              arg "old_str" call.input,
              arg "new_str" call.input )
          with
          | None, _, _ | _, None, _ | _, _, None ->
              error
                "str_replace_edit: missing required arguments: path, \
                 old_str, new_str"
          | Some path, _, _ when not (path_in_bounds path) ->
              refuse
                ~requested:("str_replace_edit " ^ path)
                ~boundary:write_boundary
          | Some path, Some old_str, Some new_str -> (
              match readable_source grant path with
              | None ->
                  if
                    List.exists
                      (fun g -> glob_matches g path)
                      grant.Grant.read_globs
                  then error ("str_replace_edit: no such file: " ^ path)
                  else
                    refuse
                      ~requested:("str_replace_edit " ^ path)
                      ~boundary:read_boundary
              | Some source -> (
                  match read_file_bytes source with
                  | exception Sys_error m -> error ("str_replace_edit: " ^ m)
                  | bytes -> (
                      (* An edit is a read of the source (committed or
                         draft) plus a store into the draft — both
                         evented. *)
                      record
                        (Ledger.Event.Load
                           {
                             tool = "str_replace_edit";
                             observed = [ load_triple path bytes ];
                           });
                      match count_occurrences ~needle:old_str bytes with
                      | 0 ->
                          error
                            ("str_replace_edit: old_str not found in " ^ path)
                      | n when n > 1 ->
                          error
                            (Printf.sprintf
                               "str_replace_edit: old_str occurs %d times in \
                                %s; it must occur exactly once"
                               n path)
                      | _ -> (
                          let edited =
                            Option.get
                              (replace_first ~needle:old_str
                                 ~replacement:new_str bytes)
                          in
                          let target =
                            Filename.concat grant.Grant.worktree_root path
                          in
                          match
                            mkdirs (Filename.dirname target);
                            write_file_bytes target edited
                          with
                          | exception Sys_error m ->
                              error ("str_replace_edit: " ^ m)
                          | () ->
                              record
                                (Ledger.Event.Store
                                   {
                                     tool = "str_replace_edit";
                                     address = Ledger.Address.File path;
                                     delta = Ledger.Delta_ref.v path;
                                   });
                              ok ("edited " ^ path))))))
      | "glob_list" -> (
          match arg "pattern" call.input with
          | None -> error "glob_list: missing required argument: pattern"
          | Some pattern when not (path_in_bounds pattern) ->
              refuse
                ~requested:("glob_list " ^ pattern)
                ~boundary:read_boundary
          | Some pattern ->
              let matches = readable_matches grant pattern in
              (* The observation a glob contributes is the listing itself:
                 which paths exist. *)
              record
                (Ledger.Event.Load
                   {
                     tool = "glob_list";
                     observed =
                       List.map (fun (rel, _) -> load_triple rel rel) matches;
                   });
              ok
                (Yojson.Safe.to_string
                   (`List
                     (List.map (fun (rel, _) -> `String rel) matches))))
      | "grep" -> (
          match arg "pattern" call.input with
          | None -> error "grep: missing required argument: pattern"
          | Some pattern ->
              let glob =
                Option.value (arg "glob" call.input) ~default:"**"
              in
              if not (path_in_bounds glob) then
                refuse ~requested:("grep in " ^ glob) ~boundary:read_boundary
              else begin
                let files = readable_matches grant glob in
                let out = Buffer.create 256 in
                let observed = ref [] in
                let hits = ref 0 in
                List.iter
                  (fun (rel, abs) ->
                    if !hits < 200 then
                      match read_file_bytes abs with
                      | exception Sys_error _ -> ()
                      | bytes ->
                          observed := load_triple rel bytes :: !observed;
                          List.iteri
                            (fun i line ->
                              if !hits < 200 && contains ~needle:pattern line
                              then begin
                                incr hits;
                                Buffer.add_string out
                                  (Printf.sprintf "%s:%d: %s\n" rel (i + 1)
                                     line)
                              end)
                            (String.split_on_char '\n' bytes))
                  files;
                record
                  (Ledger.Event.Load
                     { tool = "grep"; observed = List.rev !observed });
                ok
                  (if Buffer.length out = 0 then "no matches"
                   else Buffer.contents out)
              end)
      | "run_command" -> (
          match run_command_granted grant with
          | None ->
              refuse ~requested:"run_command"
                ~boundary:
                  "effects: only tools granted with an idempotence stamp"
          | Some idempotent -> (
              match arg "command" call.input with
              | None -> error "run_command: missing required argument: command"
              | Some command -> (
                  let out_file = Filename.temp_file "goat-cmd-" ".txt" in
                  let run () =
                    Fun.protect
                      ~finally:(fun () -> remove_quietly out_file)
                      (fun () ->
                        let status =
                          Sys.command
                            (Printf.sprintf "cd %s && ( %s ) > %s 2>&1"
                               (Filename.quote grant.Grant.worktree_root)
                               command (Filename.quote out_file))
                        in
                        (status, read_file_bytes out_file))
                  in
                  match with_effect_lock ~holder:(Id.to_string node) run with
                  | Error m -> error ("run_command: " ^ m)
                  | Ok (status, output) ->
                      record
                        (Ledger.Event.Effect
                           {
                             tool = "run_command";
                             resource = "machine";
                             idempotent;
                           });
                      ok
                        (Yojson.Safe.to_string
                           (`Assoc
                             [
                               ("exit_status", `Int status);
                               ("output", `String output);
                             ])))))
      | other -> error ("unknown tool: " ^ other)
    in
    { Provider.Tool_result.call_id = call.id; output; is_error }
end

(* {2 The agent layer}

   One tool loop shared by every provider lane — which is exactly what
   makes the loop's ledger eventing and grant enforcement a single
   boundary rather than per-lane copies. *)

let agent ~provider =
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
    let tools = Tools.declarations inv.Invocation.grant in
    let rec turn ~usage messages =
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
      | Ok (r : Provider.reply) ->
          (* A bare yield point (rigged [Yield]: zero calls, zero usage) is
             a suspension, not a model turn — it bills no [Agent_turn]. *)
          if not (r.stop = Provider.Tool_calls && r.calls = []) then
            record (Ledger.Event.Agent_turn { usage = r.usage });
          let usage = Ledger.Usage.add usage r.usage in
          (match r.stop with
          | Provider.End_turn ->
              Ok { Executor.text = r.text; usage; refusal = false }
          | Provider.Refused ->
              Ok { Executor.text = r.text; usage; refusal = true }
          | Provider.Tool_calls ->
              let results =
                List.map
                  (Tools.execute ~grant:inv.Invocation.grant ~ledger ~node)
                  r.calls
              in
              (* Between tool calls: the fiber's suspension point, where
                 drift notes land (docs/architecture/60-agents.md § drift
                 notes at yield). *)
              if stop_requested (on_yield ()) then
                Ok { Executor.text = ""; usage; refusal = false }
              else begin
                let followup =
                  match results with
                  | [] -> []
                  | _ -> [ Provider.Message.Tool_results results ]
                in
                turn ~usage
                  (messages
                  @ Provider.Message.Assistant
                      { text = r.text; calls = r.calls }
                    :: followup)
              end)
    in
    turn ~usage:Ledger.Usage.zero
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
     sleeping — scheduling pressure, never wall-clock cost. [Yield] is a
     turn that requests no tool and bills nothing: the agent loop's
     between-tools suspension fires and the script continues. *)
  let provider ~script =
    let remaining = ref script in
    let turn _request =
      let rec step () =
        match !remaining with
        | [] ->
            Error (fault Ledger.Fault.Executor_error "rigged script exhausted")
        | s :: rest -> (
            remaining := rest;
            match s with
            | Reply text | Invalid text ->
                (* Reply and Invalid differ only in the scripted text's fate
                   at the codec boundary; the provider's job is the same:
                   return the turn's final text. *)
                Ok
                  {
                    Provider.text;
                    calls = [];
                    stop = Provider.End_turn;
                    usage =
                      {
                        Ledger.Usage.tokens_in = 0;
                        tokens_out = approx_tokens text;
                      };
                  }
            | Refuse text ->
                Ok
                  {
                    Provider.text;
                    calls = [];
                    stop = Provider.Refused;
                    usage =
                      {
                        Ledger.Usage.tokens_in = 0;
                        tokens_out = approx_tokens text;
                      };
                  }
            | Fault message ->
                Error (fault Ledger.Fault.Executor_error message)
            | Delay_s _ -> step ()
            | Yield ->
                Ok
                  {
                    Provider.text = "";
                    calls = [];
                    stop = Provider.Tool_calls;
                    usage = Ledger.Usage.zero;
                  }
            | Call_tool { name; input } ->
                Ok
                  {
                    Provider.text = "";
                    calls = [ { Provider.Call.id = "rigged"; name; input } ];
                    stop = Provider.Tool_calls;
                    usage = Ledger.Usage.zero;
                  })
      in
      step ()
    in
    { Provider.turn }

  let executor ~script = agent ~provider:(provider ~script)
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
                    Executor.text = Yojson.Safe.to_string head;
                    usage = Ledger.Usage.zero;
                    refusal = false;
                  }
            | Error message ->
                Error (fault Ledger.Fault.Executor_error message)))
  in
  { Executor.run }

(* Runs the gate command line the grant declares; exit status and captured
   output become the head tuple. A non-zero exit is data (a failing test
   run is a tuple, not a fault). *)
let shell_gate =
  let run :
      type s.
      s Invocation.t ->
      ledger:Ledger.t ->
      node:Ledger.node Id.t ->
      on_yield:_ ->
      _ =
   fun invocation ~ledger:_ ~node:_ ~on_yield ->
    if stop_requested (on_yield ()) then
      Ok { Executor.text = ""; usage = Ledger.Usage.zero; refusal = false }
    else
      match invocation.Invocation.grant.Grant.shell_gates with
      | [] | [] :: _ ->
          Error
            (fault Ledger.Fault.Executor_error
               "shell_gate: grant declares no gate command line")
      | gate :: _ ->
          let out_file = Filename.temp_file "goat-gate-" ".txt" in
          Fun.protect
            ~finally:(fun () -> remove_quietly out_file)
            (fun () ->
              let command =
                Printf.sprintf "%s > %s 2>&1"
                  (String.concat " " (List.map Filename.quote gate))
                  (Filename.quote out_file)
              in
              let status = Sys.command command in
              let output = read_file_bytes out_file in
              let head =
                `Assoc
                  [ ("exit_status", `Int status); ("output", `String output) ]
              in
              Ok
                {
                  Executor.text = Yojson.Safe.to_string head;
                  usage = Ledger.Usage.zero;
                  refusal = false;
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
    | Ok (reply : Executor.reply) ->
        (* Provider-typed refusals never reach the parser; marker-recognized
           ones surface from the parse as diagnostics with [refusal] set —
           both route the same way below. *)
        if reply.refusal then
          `Invalid
            {
              Contract.Repair.raw_reply = reply.text;
              complaints = [];
              refusal = true;
            }
        else
          match parse reply.text with
          | Ok v -> `Parsed v
          | Error d -> `Invalid d
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
