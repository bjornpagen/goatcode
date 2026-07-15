(* dump_ledger — the raw event stream, one line per append: the ground
   truth the summarizing readers (report/explain) are derived from.
   Offline reader like them; takes a ledger path. *)

open Goatcode

let hex h = String.sub (Ledger.Content_hash.to_hex h) 0 8

let render (e : Ledger.Event.t) =
  let node =
    match e.Ledger.Event.node with
    | Some n -> Id.to_string n
    | None -> "run"
  in
  let body =
    match e.Ledger.Event.kind with
    | Ledger.Event.Load { tool; observed } ->
        Printf.sprintf "Load tool=%s %s" tool
          (String.concat "; "
             (List.map
                (fun (a, g, c) ->
                  Printf.sprintf "%s@%s=%s"
                    (Ledger.Address.to_string a)
                    (Format.asprintf "%a" Ledger.Generation.pp g)
                    (hex c))
                observed))
    | Ledger.Event.Store { tool; address; delta } ->
        Printf.sprintf "Store tool=%s %s delta=%s" tool
          (Ledger.Address.to_string address)
          (Ledger.Delta_ref.to_string delta)
    | Ledger.Event.Effect { tool; resource; idempotent } ->
        Printf.sprintf "Effect tool=%s resource=%S idempotent=%b" tool
          resource idempotent
    | Ledger.Event.Agent_turn { usage } ->
        Printf.sprintf "Agent_turn in=%d out=%d" usage.Ledger.Usage.tokens_in
          usage.Ledger.Usage.tokens_out
    | Ledger.Event.Fired { provenance; minted } ->
        Printf.sprintf "Fired stmt=%s consumed=[%s] minted=[%s]"
          (Theory.Statement.to_string
             provenance.Ledger.Provenance.statement)
          (String.concat ", "
             (List.map
                (fun (r, i) -> r ^ ":" ^ i)
                provenance.Ledger.Provenance.consumed))
          (String.concat ", "
             (List.map (fun (r, i) -> r ^ ":" ^ i) minted))
    | Ledger.Event.Hypothesis_taken { hypothesis; address; source; confidence; _ }
      ->
        Printf.sprintf "Hypothesis_taken %s at %s source=%s conf=%g"
          (Id.to_string hypothesis)
          (Ledger.Address.to_string address)
          source confidence
    | Ledger.Event.Hypothesis_discharged { hypothesis } ->
        Printf.sprintf "Hypothesis_discharged %s" (Id.to_string hypothesis)
    | Ledger.Event.Invalidation_sent { address; new_generation } ->
        Printf.sprintf "Invalidation_sent %s -> %s"
          (Ledger.Address.to_string address)
          (Format.asprintf "%a" Ledger.Generation.pp new_generation)
    | Ledger.Event.Drift_note { address; _ } ->
        Printf.sprintf "Drift_note %s" (Ledger.Address.to_string address)
    | Ledger.Event.Footprint_escape { tool; address } ->
        Printf.sprintf "Footprint_escape tool=%s %s" tool
          (Ledger.Address.to_string address)
    | Ledger.Event.Repair_attempt { attempt; refusal } ->
        Printf.sprintf "Repair_attempt %d refusal=%b" attempt refusal
    | Ledger.Event.Settled s ->
        Printf.sprintf "Settled %s"
          (match s with
          | Ledger.Settlement.Retired -> "retired"
          | Ledger.Settlement.Faulted f -> "faulted: " ^ f.Ledger.Fault.message
          | Ledger.Settlement.Squashed _ -> "squashed")
    | Ledger.Event.Decision { reason; counters; _ } ->
        Printf.sprintf "Decision %s%s" reason
          (match counters with
          | [] -> ""
          | cs ->
              " ["
              ^ String.concat ", "
                  (List.map (fun (k, v) -> Printf.sprintf "%s=%g" k v) cs)
              ^ "]")
    | Ledger.Event.Pin_bump _ -> "Pin_bump"
    | Ledger.Event.Switch_thrown _ -> "Switch_thrown"
    | Ledger.Event.Law_verdict { law; satisfied } ->
        Printf.sprintf "Law_verdict %s %b" law satisfied
    | Ledger.Event.Correction _ -> "Correction"
  in
  Printf.printf "%s %-7s %s\n"
    (Format.asprintf "%a" Ledger.Timestamp.pp e.Ledger.Event.at)
    node body

let () =
  match Sys.argv with
  | [| _; path |] ->
      List.iter render (Ledger.Replay.events (Ledger.load ~path))
  | _ ->
      prerr_endline "usage: dump_ledger <ledger>";
      exit 2
