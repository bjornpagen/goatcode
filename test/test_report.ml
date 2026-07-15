(* Falsifiers for the ledger's reader half and the report surface
   (docs/architecture/30-channels.md § the ledger — one log, four named
   readers; docs/architecture/40-scheduling.md § the predictor, § ports).

   The scheduler's lifecycle and drift events are typed data
   ([Ledger.Decision], [Ledger.Drift]); these tests hand-build event
   streams and check that the readers decompose them correctly:

   - Telemetry: blocked/queued/run is a total partition of the node's span,
     recovered from the typed lifecycle markers.
   - Predictor history: samples are keyed by the typed (statement,
     executor, pin) identities [Pin_bump] records — a pin bump resets the
     shape's history; a wrong executor id has no samples. The regression
     pinned here is B11's reader half: a shape key rebuilt by re-wrapping
     the wire name ("fn:agent:refuter") matches nothing; the recorded
     typed id matches its history.
   - Report: per-shape breakdown rows carry the recorded shape key
     verbatim; port queues are recovered from [Queued]/[Admitted]; a
     story's drift notes are rendered at the reader from the typed forms.
   - Replay: drift notes round-trip the durability boundary typed, and the
     recorded route is re-judged against the policy table structurally.

   No engine run, no executor, no sleep longer than milliseconds. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* A minimal admitted theory: one statement, one agent executor — just
   enough to mint a typed statement id and executor id for shape keys.   *)

let record ?(required = []) fields : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc fields);
      ("required", `List (List.map (fun f -> `String f) required));
      ("additionalProperties", `Bool false);
    ]

let str_field : Yojson.Safe.t = `Assoc [ ("type", `String "string") ]

let pin =
  {
    Theory.Pin.provider = "anthropic";
    model = "claude-fable-5";
    sampling = [];
    options = [];
  }

let review_by =
  Theory.Executor.Agent_template
    {
      name = "refuter";
      pin;
      preamble = "Refute the finding.";
      read_globs = [];
      write_globs = [ "**" ];
      effects = [];
    }

let review_sid () =
  let finding =
    Theory.Relation.dynamic ~name:"finding"
      ~schema:(record ~required:[ "desc" ] [ ("desc", str_field) ])
  in
  let verdict =
    Theory.Relation.dynamic ~name:"verdict"
      ~schema:(record ~required:[ "ok" ] [ ("ok", str_field) ])
  in
  let statement =
    Theory.Spawn.v ~name:"review" ~for_:"finding"
      ~exists:("verdict", Theory.Window.nodes 1)
      ~by:review_by ()
  in
  match
    Theory.declare
      ~relations:
        [ Theory.Relation.Packed finding; Theory.Relation.Packed verdict ]
      ~statements:[ statement ] ~laws:[]
  with
  | Error errors ->
      failwith
        ("admission rejected the reader-test theory: "
        ^ String.concat "; " (List.map Theory.Admission.to_string errors))
  | Ok admitted -> (
      match Theory.statements admitted with
      | [ (sid, _) ] -> sid
      | _ -> failwith "expected exactly one admitted statement")

(* ------------------------------------------------------------------ *)
(* Stream-building plumbing.                                            *)

type stream = {
  ledger : Ledger.t;
  node_minter : Ledger.node Id.Minter.t;
  hyp_minter : Ledger.hypothesis Id.Minter.t;
}

let open_stream tag =
  let dir = Filename.temp_dir "goatcode_readers" ("." ^ tag) in
  let ledger = Ledger.create ~path:(Filename.concat dir "ledger.bin") in
  let registry = Id.Registry.create () in
  {
    ledger;
    node_minter = Id.Minter.create ~registry ~realm:"node";
    hyp_minter = Id.Minter.create ~registry ~realm:"hypothesis";
  }

let ev s ?node kind = ignore (Ledger.append s.ledger ?node kind : Ledger.Event.t)

(* Strictly-increasing ledger timestamps between phases (the ledger clamps
   appends monotone; the decomposition needs real gaps to partition). *)
let tick () = Unix.sleepf 0.002

let fired s ~sid node =
  ev s ~node
    (Ledger.Event.Fired
       {
         provenance =
           { Ledger.Provenance.statement = sid; consumed = []; hypotheses = [] };
         minted = [];
       })

let decide s node action =
  ev s ~node (Ledger.Event.Decision { action; reason = "test"; counters = [] })

let turn s node ~tokens_in ~tokens_out =
  ev s ~node
    (Ledger.Event.Agent_turn { usage = { Ledger.Usage.tokens_in; tokens_out } })

let span_of s node =
  let mine =
    List.filter
      (fun (e : Ledger.Event.t) ->
        match e.node with Some n -> Id.equal n node | None -> false)
      (Ledger.Replay.events s.ledger)
  in
  match mine with
  | [] -> 0.
  | first :: _ ->
      let last = List.nth mine (List.length mine - 1) in
      Ledger.Timestamp.to_seconds last.at
      -. Ledger.Timestamp.to_seconds first.at

(* ------------------------------------------------------------------ *)
(* Telemetry: the lifecycle markers partition the span.                 *)

let%expect_test "telemetry: typed lifecycle markers partition blocked/queued/\
                 run" =
  let sid = review_sid () in
  let s = open_stream "telemetry" in
  (* Full lifecycle: queued -> admitted -> dispatched, one suspension. *)
  let n = Id.mint s.node_minter in
  fired s ~sid n;
  decide s n (Ledger.Decision.Queued { port = "model" });
  tick ();
  decide s n (Ledger.Decision.Admitted { port = "model" });
  decide s n Ledger.Decision.Dispatched;
  tick ();
  decide s n Ledger.Decision.Suspended;
  tick ();
  decide s n Ledger.Decision.Resumed;
  tick ();
  ev s ~node:n (Ledger.Event.Settled Ledger.Settlement.Retired);
  (* Late telemetry-irrelevant traffic must not stretch the span: the
     node's clock stops at its settlement. *)
  tick ();
  turn s n ~tokens_in:1 ~tokens_out:1;
  (match Ledger.Telemetry.timing s.ledger n with
  | None -> print_endline "!! no timing for a node the ledger saw"
  | Some t ->
      let settle_span =
        span_of s n (* first event to the LAST event, incl. the late turn *)
      in
      Printf.printf "queued>0 %b  blocked>0 %b  run>0 %b\n"
        (t.queued_s > 0.) (t.blocked_s > 0.) (t.run_s > 0.);
      (* The three phases partition first-event..settlement exactly, so
         their sum is strictly under the late-traffic span. *)
      Printf.printf "partition stops at settlement: %b\n"
        (t.queued_s +. t.blocked_s +. t.run_s < settle_span));
  (* No lifecycle markers at all: the whole span reads as run time. *)
  let bare = Id.mint s.node_minter in
  fired s ~sid bare;
  tick ();
  ev s ~node:bare (Ledger.Event.Settled Ledger.Settlement.Retired);
  (match Ledger.Telemetry.timing s.ledger bare with
  | None -> print_endline "!! no timing for the bare node"
  | Some t ->
      Printf.printf "bare node: queued=%g blocked=%g run>0 %b\n" t.queued_s
        t.blocked_s (t.run_s > 0.));
  (* Suspended and never resumed: blocked runs to the settlement. *)
  let parked = Id.mint s.node_minter in
  fired s ~sid parked;
  decide s parked Ledger.Decision.Suspended;
  tick ();
  ev s ~node:parked
    (Ledger.Event.Settled
       (Ledger.Settlement.Squashed Ledger.Squash_cause.Operator_abort));
  (match Ledger.Telemetry.timing s.ledger parked with
  | None -> print_endline "!! no timing for the parked node"
  | Some t ->
      Printf.printf "parked node: blocked>0 %b  queued=%g\n" (t.blocked_s > 0.)
        t.queued_s);
  [%expect
    {|
    queued>0 true  blocked>0 true  run>0 true
    partition stops at settlement: true
    bare node: queued=0 blocked=0 run>0 true
    parked node: blocked>0 true  queued=0
    |}]

(* ------------------------------------------------------------------ *)
(* Predictor history: typed shape keys, per pin.                        *)

let%expect_test "predictor history: samples key on the recorded typed \
                 identities, per pin" =
  let sid = review_sid () in
  let executor = Theory.Executor.id review_by in
  let s = open_stream "predictor" in
  let address =
    Ledger.Address.Tuple { relation = "finding"; id = "finding#0" }
  in
  (* Regime A: one hypothesis, discharged — a surviving sample. *)
  let pin_a = Theory.Pin.key pin in
  ev s (Ledger.Event.Pin_bump { statement = sid; executor; pin = pin_a });
  let n1 = Id.mint s.node_minter in
  let h1 = Id.mint s.hyp_minter in
  fired s ~sid n1;
  ev s ~node:n1
    (Ledger.Event.Hypothesis_taken
       {
         hypothesis = h1;
         address;
         source = "issued-contract:finding";
         content = Ledger.Content_hash.of_string "guess";
         confidence = 1.0;
       });
  tick ();
  ev s ~node:n1 (Ledger.Event.Hypothesis_discharged { hypothesis = h1 });
  turn s n1 ~tokens_in:100 ~tokens_out:50;
  ev s ~node:n1 (Ledger.Event.Settled Ledger.Settlement.Retired);
  (* Pin bump: a new speculation regime. One drifted, squashed sample. *)
  let pin_b = pin_a ^ ";bumped" in
  ev s (Ledger.Event.Pin_bump { statement = sid; executor; pin = pin_b });
  let n2 = Id.mint s.node_minter in
  let h2 = Id.mint s.hyp_minter in
  fired s ~sid n2;
  ev s ~node:n2
    (Ledger.Event.Hypothesis_taken
       {
         hypothesis = h2;
         address;
         source = "issued-contract:finding";
         content = Ledger.Content_hash.of_string "stale guess";
         confidence = 1.0;
       });
  ev s ~node:n2
    (Ledger.Event.Drift_note
       {
         address;
         cls = Ledger.Drift.Breaking_narrow;
         route = Ledger.Drift.Reconcile_delta;
       });
  turn s n2 ~tokens_in:800 ~tokens_out:400;
  tick ();
  ev s ~node:n2
    (Ledger.Event.Settled
       (Ledger.Settlement.Squashed
          (Ledger.Squash_cause.Dead_hypothesis h2)));
  let describe pin =
    match
      Ledger.Predictor_history.samples s.ledger ~statement:sid ~executor ~pin
    with
    | [] -> "no samples"
    | samples ->
        String.concat "; "
          (List.map
             (fun (sm : Ledger.Predictor_history.sample) ->
               Printf.sprintf
                 "survived=%b reconcile=%d flush=%d overlap>0=%b" sm.survived
                 sm.reconcile_tokens sm.flush_tokens (sm.overlap_s > 0.))
             samples)
  in
  Printf.printf "pin A: %s\n" (describe pin_a);
  Printf.printf "pin B: %s\n" (describe pin_b);
  (* B11's reader half, pinned: an executor id REBUILT by wrapping the wire
     name in a fresh declaration ("fn:agent:refuter") is a different
     identity and matches no history; only the recorded typed id does. *)
  let rewrapped =
    Theory.Executor.id
      (Theory.Executor.Pure_fn
         { name = Theory.Executor.id_to_string executor })
  in
  Printf.printf "rewrapped id %S has samples: %b\n"
    (Theory.Executor.id_to_string rewrapped)
    (Ledger.Predictor_history.samples s.ledger ~statement:sid
       ~executor:rewrapped ~pin:pin_a
    <> []);
  [%expect
    {|
    pin A: survived=true reconcile=0 flush=0 overlap>0=true
    pin B: survived=false reconcile=1200 flush=1200 overlap>0=false
    rewrapped id "fn:agent:refuter" has samples: false
    |}]

(* ------------------------------------------------------------------ *)
(* The report surface: shape keys verbatim, port queues, the story.     *)

let%expect_test "report: shape rows carry the recorded key; ports and drift \
                 notes are read back typed" =
  let sid = review_sid () in
  let executor = Theory.Executor.id review_by in
  let s = open_stream "report" in
  let address =
    Ledger.Address.Tuple { relation = "finding"; id = "finding#0" }
  in
  ev s
    (Ledger.Event.Pin_bump
       { statement = sid; executor; pin = Theory.Pin.key pin });
  let n = Id.mint s.node_minter in
  let h = Id.mint s.hyp_minter in
  fired s ~sid n;
  decide s n (Ledger.Decision.Queued { port = "model" });
  tick ();
  decide s n (Ledger.Decision.Admitted { port = "model" });
  ev s ~node:n
    (Ledger.Event.Hypothesis_taken
       {
         hypothesis = h;
         address;
         source = "issued-contract:finding";
         content = Ledger.Content_hash.of_string "guess";
         confidence = 0.9;
       });
  ev s ~node:n
    (Ledger.Event.Drift_note
       {
         address;
         cls = Ledger.Drift.Additive;
         route = Ledger.Drift.Reconcile_note;
       });
  tick ();
  ev s ~node:n (Ledger.Event.Hypothesis_discharged { hypothesis = h });
  turn s n ~tokens_in:100 ~tokens_out:40;
  ev s ~node:n (Ledger.Event.Settled Ledger.Settlement.Retired);
  let settled =
    {
      Run.nodes =
        [
          ( n,
            {
              Run.settlement = Ledger.Settlement.Retired;
              timing =
                (match Ledger.Telemetry.timing s.ledger n with
                | Some t -> t
                | None -> failwith "no timing");
              usage = Ledger.Telemetry.usage s.ledger n;
              hypotheses = [ h ];
            } );
        ];
      tuples = [];
      laws = [];
      ledger = s.ledger;
    }
  in
  let summary = Report.summarize settled in
  (* The shape-key format, pinned: statement/executor@pin, the executor id
     exactly as the theory declared it — never re-prefixed. *)
  List.iter
    (fun ((shape, counters) : Speculate.Shape.t * Speculate.Counters.t) ->
      Printf.printf "shape %s: samples=%d survival=%g\n"
        (Speculate.Shape.to_string shape)
        counters.samples counters.survival)
    summary.speculation.per_shape;
  List.iter
    (fun (port, queued) -> Printf.printf "port %s queued>0 %b\n" port (queued > 0.))
    summary.port_queues;
  Printf.printf "ceiling bound: %b\n" summary.token_ceiling_bound;
  (match Report.explain settled ~node:n with
  | None -> print_endline "!! no story for a fired node"
  | Some story ->
      List.iter
        (fun (_, action, reason) ->
          Printf.printf "decision: %s (%s)\n" action reason)
        story.decisions;
      List.iter
        (fun (_, cls, route) -> Printf.printf "drift note: %s -> %s\n" cls route)
        story.drift_notes);
  [%expect
    {|
    shape review/agent:refuter@anthropic/claude-fable-5;sampling=;options=: samples=1 survival=1
    port model queued>0 true
    ceiling bound: false
    decision: queued:model (test)
    decision: admitted:model (test)
    drift note: additive -> reconcile_note
    |}]

(* ------------------------------------------------------------------ *)
(* Replay: typed drift notes cross the durability boundary and the
   recorded route is re-judged against the policy table.                *)

let%expect_test "replay: drift routes re-derive structurally from the table" =
  let dir = Filename.temp_dir "goatcode_readers" ".replay" in
  let path = Filename.concat dir "ledger.bin" in
  let ledger = Ledger.create ~path in
  let address =
    Ledger.Address.Tuple { relation = "finding"; id = "finding#0" }
  in
  ignore
    (Ledger.append ledger
       (Ledger.Event.Drift_note
          {
            address;
            cls = Ledger.Drift.Breaking_broad;
            route = Ledger.Drift.Flush_subtree;
          })
      : Ledger.Event.t);
  (* Re-open read-only: the reader half sees exactly what was written. *)
  let reread = Ledger.load ~path in
  List.iter
    (fun (e : Ledger.Event.t) ->
      match e.kind with
      | Ledger.Event.Drift_note { cls; route; _ } ->
          Printf.printf "reread note: %s -> %s\n"
            (Ledger.Drift.cls_to_string cls)
            (Ledger.Drift.route_to_string route)
      | _ -> ())
    (Ledger.Replay.events reread);
  (match Run.replay reread with
  | Ok () -> print_endline "replay: coherent"
  | Error ds -> Printf.printf "!! %d divergences\n" (List.length ds));
  (* A recorded route the table disagrees with is a divergence — the
     completeness audit reads the typed forms, not a rendering. *)
  ignore
    (Ledger.append ledger
       (Ledger.Event.Drift_note
          {
            address;
            cls = Ledger.Drift.Additive;
            route = Ledger.Drift.Flush_subtree;
          })
      : Ledger.Event.t);
  (match Run.replay (Ledger.load ~path) with
  | Ok () -> print_endline "!! an off-table route replayed clean"
  | Error ds ->
      List.iter
        (fun (d : Run.divergence) ->
          Printf.printf "divergence: %s | %s\n" d.recorded d.replayed)
        ds);
  [%expect
    {|
    reread note: breaking_broad -> flush_subtree
    replay: coherent
    divergence: drift at tuple:finding/finding#0 (class "additive") routed "flush_subtree" | the routing table routes this class to "reconcile_note"
    |}]
