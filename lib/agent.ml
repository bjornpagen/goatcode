(* Execution units: tool grants, prompt assembly, executors, and the
   validate-and-repair loop (docs/architecture/60-agents.md). *)

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

(* Minimal process plumbing on Stdlib only (the engine library takes no
   [unix] dependency): command via [Sys.command] with [Filename.quote],
   payloads through temp files. *)
let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path contents =
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

let empty_reply text usage = { Executor.text; usage }

module Rigged = struct
  type step =
    | Reply of string
    | Invalid of string
    | Refuse of string
    | Fault of string
    | Delay_s of float
    | Yield

  (* Steps live in a ref shared by every invocation of the same executor
     value: a repair re-invocation consumes the next step, so F10 scripts
     "invalid, invalid, valid" and counts attempts. [Delay_s] is consumed
     without sleeping — scheduling pressure, never wall-clock cost. *)
  let executor ~script =
    let remaining = ref script in
    let run _invocation ~on_yield =
      let rec step () =
        match !remaining with
        | [] ->
            Error
              (fault Ledger.Fault.Executor_error "rigged script exhausted")
        | s :: rest -> (
            remaining := rest;
            match s with
            | Reply text | Invalid text | Refuse text ->
                (* Reply / Invalid / Refuse differ only in the scripted
                   text's fate at the codec boundary; the executor's job is
                   the same for all three: return the turn's final text. *)
                Ok
                  (empty_reply text
                     {
                       Ledger.Usage.tokens_in = 0;
                       tokens_out = approx_tokens text;
                     })
            | Fault message ->
                Error (fault Ledger.Fault.Executor_error message)
            | Delay_s _ -> step ()
            | Yield ->
                if stop_requested (on_yield ()) then
                  Ok (empty_reply "" Ledger.Usage.zero)
                else step ())
      in
      step ()
    in
    { Executor.run }
end

(* The real lane. One process per invocation: prompt on stdin, JSON report
   on stdout ([--output-format json]), usage parsed from that report. Never
   constructed by tests. *)
let claude_cli ?(binary = "claude") () =
  let parse_report out =
    match Yojson.Safe.from_string out with
    | exception _ ->
        Error
          (fault Ledger.Fault.Executor_error
             (Printf.sprintf "%s: unparseable JSON report on stdout" binary))
    | json -> (
        let mem key = function
          | `Assoc fields -> List.assoc_opt key fields
          | _ -> None
        in
        let int_of key j =
          match mem key j with Some (`Int i) -> i | _ -> 0
        in
        match mem "result" json with
        | Some (`String text) ->
            let usage =
              match mem "usage" json with
              | Some u ->
                  {
                    Ledger.Usage.tokens_in = int_of "input_tokens" u;
                    tokens_out = int_of "output_tokens" u;
                  }
              | None -> Ledger.Usage.zero
            in
            Ok (empty_reply text usage)
        | _ ->
            Error
              (fault Ledger.Fault.Executor_error
                 (Printf.sprintf "%s: report carries no string \"result\""
                    binary)))
  in
  let run : type a. a Invocation.t -> on_yield:_ -> _ =
   fun invocation ~on_yield ->
    if stop_requested (on_yield ()) then Ok (empty_reply "" Ledger.Usage.zero)
    else begin
      let prompt_file = Filename.temp_file "goat-prompt-" ".txt" in
      let out_file = Filename.temp_file "goat-reply-" ".json" in
      let err_file = Filename.temp_file "goat-err-" ".txt" in
      Fun.protect
        ~finally:(fun () ->
          remove_quietly prompt_file;
          remove_quietly out_file;
          remove_quietly err_file)
        (fun () ->
          write_file prompt_file (Prompt.render invocation.Invocation.prompt);
          let command =
            Printf.sprintf "%s -p --output-format json < %s > %s 2> %s"
              (Filename.quote binary) (Filename.quote prompt_file)
              (Filename.quote out_file) (Filename.quote err_file)
          in
          let status = Sys.command command in
          if status <> 0 then
            Error
              (fault Ledger.Fault.Executor_error
                 (Printf.sprintf "%s exited %d: %s" binary status
                    (String.trim (read_file err_file))))
          else parse_report (read_file out_file))
    end
  in
  { Executor.run }

(* Host OCaml as an executor: the witnessed operand section (codec-rendered
   JSON) in, head-tuple JSON out. Mechanical transforms never deserve
   tokens, so usage is zero by construction. *)
let pure_fn f =
  let run invocation ~on_yield:_ =
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
            | Ok head -> Ok (empty_reply (Yojson.Safe.to_string head) Ledger.Usage.zero)
            | Error message ->
                Error (fault Ledger.Fault.Executor_error message)))
  in
  { Executor.run }

(* Runs the gate command line the grant declares; exit status and captured
   output become the head tuple. A non-zero exit is data (a failing test
   run is a tuple, not a fault). *)
let shell_gate =
  let run : type a. a Invocation.t -> on_yield:_ -> _ =
   fun invocation ~on_yield ->
    if stop_requested (on_yield ()) then Ok (empty_reply "" Ledger.Usage.zero)
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
              let output = read_file out_file in
              let head =
                `Assoc
                  [ ("exit_status", `Int status); ("output", `String output) ]
              in
              Ok (empty_reply (Yojson.Safe.to_string head) Ledger.Usage.zero))
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
let[@warning "-16"] invoke ~executor ?fallback ~codec ~registry ~invocation
    ~budget ~ledger ~node ~on_yield =
  let max_attempts = Repair_budget.attempts budget in
  let record kind = ignore (Ledger.append ledger ~node kind) in
  let run_once (exec : Executor.t) inv =
    match exec.run inv ~on_yield with
    | Error f -> `Fault f
    | Ok (reply : Executor.reply) -> (
        record (Ledger.Event.Agent_turn { usage = reply.usage });
        match Contract.Codec.parse codec ~registry reply.text with
        | Ok v -> `Parsed v
        | Error d -> `Invalid d)
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
