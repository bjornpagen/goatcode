(* Falsifiers F6 (witness honesty) and F7 (free-commit)
   (docs/architecture/50-api.md § the falsifier discipline).

   F6 — witness honesty: a node whose executor is rigged to CLAIM a
   dependency it never read, or to HIDE one it did read, gets the witness
   the ledger observed, both times (docs/architecture/20-medium.md
   § mechanized witnesses; docs/architecture/30-scheduling.md § law 1).

   F7 — free-commit: an upstream that lands byte-identically to the
   hypothesis advances no generation, fires no invalidation, and its
   speculators retire with zero reconcile events
   (docs/architecture/30-scheduling.md § law 2 — the economic keystone).

   Law 3, fresh addresses — the commit-point check judges the artifact:
   a consumer that witnessed a pre-commit draft a producer's first landing
   replaced is rejected even though both states share the first generation
   (docs/architecture/30-scheduling.md § law 3 — absence is a real case).

   Every executor here is [Agent.Rigged]; no test constructs
   [Agent.claude_cli]; nothing sleeps; nothing touches the network. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Harness plumbing: temp dirs, a scratch git repo, event counters.     *)

let rec mkdirs dir =
  if not (Sys.file_exists dir) then begin
    let parent = Filename.dirname dir in
    if not (String.equal parent dir) then mkdirs parent;
    try Sys.mkdir dir 0o755 with Sys_error _ -> ()
  end

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  mkdirs path;
  path

let write_file path contents =
  mkdirs (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc contents)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let sh cmd = ignore (Sys.command (cmd ^ " >/dev/null 2>&1"))
let ( // ) = Filename.concat

(* A one-commit git repository: the committed branch's storage engine
   (docs/architecture/30-scheduling.md § durability boundary). *)
let seed_repo repo ~file ~contents =
  sh (Printf.sprintf "git -C %s init -q" (Filename.quote repo));
  write_file (repo // file) contents;
  sh (Printf.sprintf "git -C %s add -A" (Filename.quote repo));
  sh
    (Printf.sprintf
       "git -C %s -c user.name=test -c user.email=test@localhost commit -q -m \
        seed"
       (Filename.quote repo))

(* A file store, the way the engine's tool path lands one (migration row 2,
   README.md § design of record vs shipped engine): the content into the
   committed repository's object database as a loose blob, the Store event
   carrying the oid — the retire step's landing reads exactly this, never
   any tree. *)
let store ~ledger ~repo ~node rel contents =
  let tmp = Filename.temp_file "goat_store" ".tmp" in
  write_file tmp contents;
  let out = Filename.temp_file "goat_oid" ".txt" in
  ignore
    (Sys.command
       (Printf.sprintf "git -C %s hash-object -w -- %s >%s 2>/dev/null"
          (Filename.quote repo) (Filename.quote tmp) (Filename.quote out)));
  let oid = String.trim (read_file out) in
  (try Sys.remove tmp with Sys_error _ -> ());
  (try Sys.remove out with Sys_error _ -> ());
  match Ledger.Delta_ref.blob oid with
  | None -> failwith ("hash-object printed no oid for " ^ rel)
  | Some delta ->
      ignore
        (Ledger.append ledger ~node
           (Ledger.Event.Store
              { tool = "write_file"; address = Ledger.Address.File rel; delta }))

(* Guard against a vacuously-absent store: the free commit must be a REAL
   store event in the node's ledger, not a missing one. *)
let stored_addresses ledger node =
  List.filter_map
    (fun (e : Ledger.Event.t) ->
      match (e.kind, e.node) with
      | Ledger.Event.Store { address; _ }, Some n when Id.equal n node ->
          Some address
      | _ -> None)
    (Ledger.Replay.events ledger)

let count ledger pred =
  List.length
    (List.filter
       (fun (e : Ledger.Event.t) -> pred e.kind)
       (Ledger.Replay.events ledger))

let invalidations ledger =
  count ledger (function
    | Ledger.Event.Invalidation_sent _ -> true
    | _ -> false)

let drift_notes ledger =
  count ledger (function Ledger.Event.Drift_note _ -> true | _ -> false)

let repair_attempts ledger =
  count ledger (function Ledger.Event.Repair_attempt _ -> true | _ -> false)

let settled ledger node =
  List.find_map
    (fun (e : Ledger.Event.t) ->
      match (e.kind, e.node) with
      | Ledger.Event.Settled s, Some n when Id.equal n node -> Some s
      | _ -> None)
    (Ledger.Replay.events ledger)

let settlement_name = function
  | None -> "unsettled"
  | Some Ledger.Settlement.Retired -> "retired"
  | Some (Ledger.Settlement.Faulted _) -> "faulted"
  | Some (Ledger.Settlement.Squashed _) -> "squashed"

let gen_str = function
  | None -> "none"
  | Some g -> Format.asprintf "%a" Ledger.Generation.pp g

let state_str = function
  | Witness.Committed_state.Absent -> "absent"
  | Witness.Committed_state.Landed { generation; _ } ->
      Format.asprintf "landed@%a" Ledger.Generation.pp generation
  | Witness.Committed_state.Deleted { generation } ->
      Format.asprintf "deleted@%a" Ledger.Generation.pp generation

let route_name = function
  | Ledger.Drift.Discharge_silently -> "discharge_silently"
  | Ledger.Drift.Reconcile_note -> "reconcile_note"
  | Ledger.Drift.Reconcile_delta -> "reconcile_delta"
  | Ledger.Drift.Flush_subtree -> "flush_subtree"

(* ------------------------------------------------------------------ *)
(* The rigged executor lane: the lie crosses the REAL invoke path — the
   executor produces text, the codec parses it — and the witness must
   never consult any of it.                                             *)

(* Identity codec: F6 is not about payload shape, it is about whether a
   well-formed, successfully parsed reply can influence the witness. *)
let identity_codec : Yojson.Safe.t Contract.Codec.t =
  Contract.Codec.v ~of_json:Fun.id ~to_json:Fun.id

let test_schema () =
  match
    Contract.Wire_schema.parse
      (`Assoc
        [
          ("type", `String "object");
          ( "properties",
            `Assoc [ ("note", `Assoc [ ("type", `String "string") ]) ] );
          ("required", `List [ `String "note" ]);
          ("additionalProperties", `Bool false);
        ])
  with
  | Ok s -> s
  | Error _ -> failwith "test schema escaped the safe subset"

let invocation () =
  let schema = test_schema () in
  let grant =
    {
      Agent.Grant.read_globs = [ "**" ];
      write_globs = [ "**" ];
      shell_gates = [];
      effects = [];
    }
  in
  let prompt =
    Agent.Prompt.assemble ~preamble:"Rigged falsifier executor." ~schema
      ~operands:"{}" ~hypotheses:[] ~grant
  in
  {
    Agent.Invocation.prompt;
    schema;
    grant;
    pin =
      { Theory.Pin.provider = "rigged"; model = "none"; sampling = []; options = [] };
    (* Direct-drive tests run outside any engine: nothing is committed
       and nothing is in flight, so every top is Absent and tool loads
       witness at generation zero (agent.mli § Invocation). *)
    repo = ".";
    frontier = (fun _ -> Retire.Frontier.Committed Witness.Committed_state.Absent);
    snoop = (fun ~address:_ ~producer:_ ~content:_ -> []);
    in_flight = (fun () -> []);
    undischarged = (fun () -> false);
    gate_resource = None;
  }

(* Run one lying reply through the primary lane and return the parsed
   value: proof the lie was accepted as data before the witness ignores
   it. *)
let invoke_lying ~ledger ~registry ~node ~reply_text =
  Agent.invoke
    ~executor:(Agent.Rigged.executor ~script:[ Agent.Rigged.Reply reply_text ])
    ?fallback:None ~codec:identity_codec ~registry
    ~invocation:(invocation ())
    ~budget:(Agent.Repair_budget.v 1) ~ledger ~node
    ~on_yield:(fun () -> [])

(* ================================================================== *)
(* F6 — claim direction: an executor rigged to claim a dependency it    *)
(* never read.  The claim parses cleanly at the boundary; the witness    *)
(* is still exactly the ledger's observed load set, so when the CLAIMED  *)
(* address later moves, the witness holds and the node retires — the     *)
(* fabricated read bought neither staleness nor immunity.                *)
(* ================================================================== *)

let%expect_test "F6: a claimed-but-never-read dependency never enters the \
                 witness" =
  let dir = temp_dir "goat_f6_claim" in
  let ledger = Ledger.create ~path:(dir // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let n = Id.mint node_minter in
  let real = Ledger.Address.File "src/real_input.txt" in
  let claimed = Ledger.Address.File "docs/never_read.md" in
  let g0 = Ledger.Generation.zero in
  (* The observation lane: the harness logged the ONE load the node's tool
     calls actually made.  Nothing else was read. *)
  ignore
    (Ledger.append ledger ~node:n
       (Ledger.Event.Load
          {
            tool = "read";
            observed = [ (real, g0, Ledger.Content_hash.of_string "real bytes") ];
          }));
  (* The executor lies upward: its reply claims a second dependency, with a
     version number attached — exactly the asserted-version residue the
     protocol refuses to trust. *)
  let lie =
    {|{"note":"done","i_also_read":"docs/never_read.md","at_generation":9}|}
  in
  (match
     invoke_lying ~ledger ~registry ~node:n ~reply_text:lie
   with
  | Ok (`Assoc fields) ->
      Printf.printf "boundary parse: ok (claims %s)\n"
        (match List.assoc_opt "i_also_read" fields with
        | Some (`String s) -> s
        | _ -> "?")
  | Ok _ -> print_endline "boundary parse: ok (unexpected shape)"
  | Error _ -> print_endline "boundary parse: fault");
  let w = Witness.observed ledger ~node:n in
  List.iter
    (fun (t : Witness.triple) ->
      Printf.printf "observed triple: %s @ %s\n"
        (Ledger.Address.to_string t.address)
        (Format.asprintf "%a" Ledger.Generation.pp t.generation))
    (Witness.triples w);
  let in_witness a = Ledger.Footprint.mem (Witness.addresses w) a in
  Printf.printf "claimed address in witness: %b\n" (in_witness claimed);
  Printf.printf "real address in witness: %b\n" (in_witness real);
  (* Kill shot: the CLAIMED address moves.  If the reply had any path into
     the witness, this commit-point check would go stale; it must hold. *)
  let committed a =
    if Ledger.Address.equal a claimed then
      Witness.Committed_state.Landed
        {
          generation = Ledger.Generation.next Ledger.Generation.zero;
          content = Ledger.Content_hash.of_string "moved bytes";
        }
    else if Ledger.Address.equal a real then
      Witness.Committed_state.Landed
        { generation = g0; content = Ledger.Content_hash.of_string "real bytes" }
    else Witness.Committed_state.Absent
  in
  (match Witness.holds w ~committed ~dead:(fun _ _ -> false) with
  | Ok () -> print_endline "claimed address moved: witness holds (claim bought nothing)"
  | Error _ -> print_endline "claimed address moved: witness went stale (LIE ENTERED WITNESS)");
  (* Control for instrument sensitivity: when the address the node REALLY
     read moves, the same witness must fail. *)
  let committed_real_moved a =
    if Ledger.Address.equal a real then
      Witness.Committed_state.Landed
        {
          generation = Ledger.Generation.next Ledger.Generation.zero;
          content = Ledger.Content_hash.of_string "moved bytes";
        }
    else Witness.Committed_state.Absent
  in
  (match
     Witness.holds w ~committed:committed_real_moved ~dead:(fun _ _ -> false)
   with
  | Ok () -> print_endline "real address moved: witness holds (INSTRUMENT BLIND)"
  | Error [ stale ] ->
      Printf.printf "real address moved: stale %s witnessed %s current %s\n"
        (Ledger.Address.to_string stale.address)
        (Format.asprintf "%a" Ledger.Generation.pp stale.witnessed)
        (state_str stale.current)
  | Error _ -> print_endline "real address moved: multiple stales");
  sh (Printf.sprintf "rm -rf %s" (Filename.quote dir));
  [%expect
    {|
    boundary parse: ok (claims docs/never_read.md)
    observed triple: file:src/real_input.txt @ g0
    claimed address in witness: false
    real address in witness: true
    claimed address moved: witness holds (claim bought nothing)
    real address moved: stale file:src/real_input.txt witnessed g0 current landed@g1
    |}]

(* ================================================================== *)
(* F6 — hide direction: an executor rigged to deny a dependency it DID  *)
(* read.  The denial parses cleanly; the ledger-observed load convicts   *)
(* the node anyway when the hidden dependency moves under it — through   *)
(* the full retire step, against a real committed tree.                  *)
(* ================================================================== *)

let%expect_test "F6: a hidden-but-observed dependency convicts the node at \
                 retire" =
  let repo = temp_dir "goat_f6_hide_repo" in
  let scratch = temp_dir "goat_f6_hide_scratch" in
  seed_repo repo ~file:"f.txt" ~contents:"v1\n";
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let upstream = Id.mint node_minter in
  let hider = Id.mint node_minter in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let merges = Retire.Merge_registry.empty in
  (* The hider READS f.txt (the harness observes the load at the committed
     generation of the moment, zero)... *)
  ignore
    (Ledger.append ledger ~node:hider
       (Ledger.Event.Load
          {
            tool = "read";
            observed =
              [
                ( Ledger.Address.File "f.txt",
                  Ledger.Generation.zero,
                  Ledger.Content_hash.of_string "v1\n" );
              ];
          }));
  (* ...and its executor then denies everything, asserting immunity. *)
  let denial =
    {|{"note":"I consulted nothing; my output is immune to upstream changes","consulted":[]}|}
  in
  (match
     invoke_lying ~ledger ~registry ~node:hider ~reply_text:denial
   with
  | Ok _ -> print_endline "boundary parse: ok (denial accepted as data)"
  | Error _ -> print_endline "boundary parse: fault");
  (* Upstream lands a REAL change to the hidden dependency and retires. *)
  store ~ledger ~repo ~node:upstream "f.txt" "v2\n";
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:upstream
       ~witness:(Witness.observed ledger ~node:upstream)
       ~heads:[]
   with
  | Ok () -> print_endline "upstream retire: ok"
  | Error _ -> print_endline "upstream retire: rejected");
  Printf.printf "f.txt committed generation: %s\n"
    (gen_str (Retire.Committed.generation committed (Ledger.Address.File "f.txt")));
  (* The hider's witness is what the ledger observed, not what it said. *)
  let w = Witness.observed ledger ~node:hider in
  Printf.printf "hidden read in witness: %b\n"
    (Ledger.Footprint.mem (Witness.addresses w) (Ledger.Address.File "f.txt"));
  (match
     Witness.holds w
       ~committed:(Retire.Committed.state committed)
       ~dead:(fun _ _ -> false)
   with
  | Ok () -> print_endline "holds: ok (DENIAL ERASED THE READ)"
  | Error [ stale ] ->
      Printf.printf "holds: stale %s witnessed %s current %s\n"
        (Ledger.Address.to_string stale.address)
        (Format.asprintf "%a" Ledger.Generation.pp stale.witnessed)
        (state_str stale.current)
  | Error _ -> print_endline "holds: multiple stales");
  (* The retire step routes it as the typed Witness_moved signal — no
     retry, no merge heroics, no silent re-read. *)
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:hider ~witness:w
       ~heads:[]
   with
  | Error (Retire.Witness_moved _) ->
      print_endline "hider retire: rejected (Witness_moved)"
  | Error (Retire.Undischarged _) -> print_endline "hider retire: rejected (Undischarged)"
  | Error (Retire.Conflict _) -> print_endline "hider retire: rejected (Conflict)"
  | Ok () -> print_endline "hider retire: ok (HIDDEN READ ESCAPED)");
  Printf.printf "upstream settlement: %s\n"
    (settlement_name (settled ledger upstream));
  Printf.printf "hider settlement: %s\n" (settlement_name (settled ledger hider));
  sh (Printf.sprintf "rm -rf %s %s" (Filename.quote repo) (Filename.quote scratch));
  [%expect
    {|
    boundary parse: ok (denial accepted as data)
    upstream retire: ok
    f.txt committed generation: g1
    hidden read in witness: true
    holds: stale file:f.txt witnessed g0 current landed@g1
    hider retire: rejected (Witness_moved)
    upstream settlement: retired
    hider settlement: unsettled
    |}]

(* ================================================================== *)
(* F7 — free-commit, file-shaped.  Upstream B lands bytes that are a     *)
(* REAL change against its own snapshot but identical to the committed   *)
(* content its speculator hypothesized: no generation advance, no        *)
(* invalidation, the hypothesis discharges silently, and the speculator  *)
(* retires with zero reconcile events.  Node A is the in-test control:   *)
(* its landing IS a semantic change and must advance and fire, proving   *)
(* the instrument can see the non-free path.                             *)
(* ================================================================== *)

let%expect_test "F7: a byte-identical landing advances nothing, fires \
                 nothing, and retires its speculator for free" =
  let repo = temp_dir "goat_f7_repo" in
  let scratch = temp_dir "goat_f7_scratch" in
  seed_repo repo ~file:"f.txt" ~contents:"v1\n";
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let hyp_minter : Ledger.hypothesis Id.Minter.t =
    Id.Minter.create ~registry ~realm:"hypothesis"
  in
  let a = Id.mint node_minter in
  let b = Id.mint node_minter in
  let c = Id.mint node_minter in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let merges = Retire.Merge_registry.empty in
  let f_addr = Ledger.Address.File "f.txt" in
  (* Control: A lands a semantic change.  Generation must advance and an
     invalidation must fire — the non-free path is detectable. *)
  store ~ledger ~repo ~node:a "f.txt" "v2\n";
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:a
       ~witness:(Witness.observed ledger ~node:a) ~heads:[]
   with
  | Ok () -> print_endline "A (control) retire: ok"
  | Error _ -> print_endline "A (control) retire: rejected");
  Printf.printf "after A: generation %s, invalidations %d\n"
    (gen_str (Retire.Committed.generation committed f_addr))
    (invalidations ledger);
  let g1 =
    match Retire.Committed.generation committed f_addr with
    | Some g -> g
    | None -> failwith "control retire advanced nothing"
  in
  (* C speculates downstream of B: its snooped read of "v2" enters its
     witness (a Load observation) and it takes the hypothesis that B's
     landing is exactly these bytes. *)
  let hyp = Id.mint hyp_minter in
  let v2_hash = Ledger.Content_hash.of_string "v2\n" in
  ignore
    (Ledger.append ledger ~node:c
       (Ledger.Event.Load
          { tool = "snoop"; observed = [ (f_addr, g1, v2_hash) ] }));
  ignore
    (Ledger.append ledger ~node:c
       (Ledger.Event.Hypothesis_taken
          {
            hypothesis = hyp;
            address = f_addr;
            source = Id.to_string b;
            content = v2_hash;
            confidence = 0.9;
          }));
  (* B lands byte-identically to the hypothesis: a real Store event in its
     ledger (guard below), identical to the committed bytes. B's read of
     A's landing is observed first — under migration row 2 the landing is
     built from Store events (README.md § design of record vs shipped
     engine), so B's write set is visible to the conflict judge and only
     the witnessed read serializes B behind A; the free-commit law under
     test is unchanged: the byte-identical landing advances nothing. *)
  ignore
    (Ledger.append ledger ~node:b
       (Ledger.Event.Load
          { tool = "read"; observed = [ (f_addr, g1, v2_hash) ] }));
  store ~ledger ~repo ~node:b "f.txt" "v2\n";
  Printf.printf "B stored f.txt in the event stream: %b\n"
    (List.exists (Ledger.Address.equal f_addr) (stored_addresses ledger b));
  let gen_before = Retire.Committed.generation committed f_addr in
  let inv_before = invalidations ledger in
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:b
       ~witness:(Witness.observed ledger ~node:b) ~heads:[]
   with
  | Ok () -> print_endline "B retire: ok"
  | Error _ -> print_endline "B retire: rejected");
  let gen_after = Retire.Committed.generation committed f_addr in
  Printf.printf "generation advanced by B's landing: %b (%s -> %s)\n"
    (not
       (match (gen_before, gen_after) with
       | Some g, Some g' -> Ledger.Generation.equal g g'
       | _ -> false))
    (gen_str gen_before) (gen_str gen_after);
  Printf.printf "invalidations fired by B's landing: %d\n"
    (invalidations ledger - inv_before);
  (* The refresher's parse of the landing: reality matched the hypothesis
     byte for byte, the diff is empty, and the routing table says the
     discharge is silent — no consumer event of any kind. *)
  let landed_hash =
    Ledger.Content_hash.of_string (read_file (repo // "f.txt"))
  in
  Printf.printf "landing matches hypothesis content: %b\n"
    (Ledger.Content_hash.equal landed_hash v2_hash);
  let cls = Speculate.Drift.classify ~landing:(`Landed []) ~consumed:[] in
  Printf.printf "drift route for the identical landing: %s\n"
    (route_name (Speculate.Drift.route cls));
  ignore
    (Ledger.append ledger ~node:c
       (Ledger.Event.Hypothesis_discharged { hypothesis = hyp }));
  (* The speculator retires: witness still holds, hypothesis discharged,
     zero reconcile machinery ever ran. *)
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:c
       ~witness:(Witness.observed ledger ~node:c) ~heads:[]
   with
  | Ok () -> print_endline "speculator retire: ok"
  | Error (Retire.Witness_moved _) ->
      print_endline "speculator retire: rejected (Witness_moved)"
  | Error (Retire.Undischarged _) ->
      print_endline "speculator retire: rejected (Undischarged)"
  | Error (Retire.Conflict _) ->
      print_endline "speculator retire: rejected (Conflict)");
  Printf.printf "speculator settlement: %s\n" (settlement_name (settled ledger c));
  Printf.printf "reconcile events over the whole run: drift notes %d, repair \
                 attempts %d\n"
    (drift_notes ledger) (repair_attempts ledger);
  Printf.printf "invalidations over the whole run: %d (the control's only)\n"
    (invalidations ledger);
  sh (Printf.sprintf "rm -rf %s %s" (Filename.quote repo) (Filename.quote scratch));
  [%expect
    {|
    A (control) retire: ok
    after A: generation g1, invalidations 1
    B stored f.txt in the event stream: true
    B retire: ok
    generation advanced by B's landing: false (g1 -> g1)
    invalidations fired by B's landing: 0
    landing matches hypothesis content: true
    drift route for the identical landing: discharge_silently
    speculator retire: ok
    speculator settlement: retired
    reconcile events over the whole run: drift notes 0, repair attempts 0
    invalidations over the whole run: 1 (the control's only)
    |}]

(* ================================================================== *)
(* F7 — sensitivity control: the SAME construction with one changed     *)
(* byte is not free.  The generation advances, the invalidation fires,   *)
(* and the speculator's witness fails to hold.  This kills any           *)
(* implementation that would make the free-commit test pass vacuously    *)
(* by never advancing or never firing.                                   *)
(* ================================================================== *)

let%expect_test "F7 control: a landing that differs by one byte advances, \
                 fires, and stales its speculator" =
  let repo = temp_dir "goat_f7c_repo" in
  let scratch = temp_dir "goat_f7c_scratch" in
  seed_repo repo ~file:"f.txt" ~contents:"v1\n";
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let a = Id.mint node_minter in
  let b = Id.mint node_minter in
  let c = Id.mint node_minter in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let merges = Retire.Merge_registry.empty in
  let f_addr = Ledger.Address.File "f.txt" in
  store ~ledger ~repo ~node:a "f.txt" "v2\n";
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:a
       ~witness:(Witness.observed ledger ~node:a) ~heads:[]
   with
  | Ok () -> print_endline "A retire: ok"
  | Error _ -> print_endline "A retire: rejected");
  let g1 =
    match Retire.Committed.generation committed f_addr with
    | Some g -> g
    | None -> failwith "control retire advanced nothing"
  in
  (* Same witnessed read as the free-commit test... *)
  ignore
    (Ledger.append ledger ~node:c
       (Ledger.Event.Load
          {
            tool = "snoop";
            observed = [ (f_addr, g1, Ledger.Content_hash.of_string "v2\n") ];
          }));
  (* ...but B — serialized behind A's landing by the same observed read as
     the free-commit test — lands DIFFERENT bytes. *)
  ignore
    (Ledger.append ledger ~node:b
       (Ledger.Event.Load
          {
            tool = "read";
            observed = [ (f_addr, g1, Ledger.Content_hash.of_string "v2\n") ];
          }));
  store ~ledger ~repo ~node:b "f.txt" "v3\n";
  let inv_before = invalidations ledger in
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:b
       ~witness:(Witness.observed ledger ~node:b) ~heads:[]
   with
  | Ok () -> print_endline "B retire: ok"
  | Error _ -> print_endline "B retire: rejected");
  Printf.printf "generation after B: %s\n"
    (gen_str (Retire.Committed.generation committed f_addr));
  Printf.printf "invalidations fired by B's landing: %d\n"
    (invalidations ledger - inv_before);
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:c
       ~witness:(Witness.observed ledger ~node:c) ~heads:[]
   with
  | Error (Retire.Witness_moved _) ->
      print_endline "speculator retire: rejected (Witness_moved)"
  | Error _ -> print_endline "speculator retire: rejected (other)"
  | Ok () -> print_endline "speculator retire: ok (STALE WITNESS COMMITTED)");
  sh (Printf.sprintf "rm -rf %s %s" (Filename.quote repo) (Filename.quote scratch));
  [%expect
    {|
    A retire: ok
    B retire: ok
    generation after B: g2
    invalidations fired by B's landing: 1
    speculator retire: rejected (Witness_moved)
    |}]

(* ================================================================== *)
(* F7 — tuple-shaped free commit.  A head tuple whose payload is         *)
(* identical to the committed one advances no generation and fires no    *)
(* invalidation; a differing payload advances and fires.  Fresh tuples   *)
(* start at g0 with no invalidation — there is no one to invalidate,     *)
(* and a snooper who witnessed the prediction at g0 retires free.        *)
(* ================================================================== *)

let%expect_test "F7: an identical head-tuple payload is a free commit" =
  let scratch = temp_dir "goat_f7_tuple" in
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let a = Id.mint node_minter in
  let b = Id.mint node_minter in
  let d = Id.mint node_minter in
  (* No git needed: tuple state is the committed tuple set; the nodes'
     ledgers hold no file stores, so nothing lands file-shaped. *)
  let committed = Retire.Committed.open_ ~repo:(scratch // "repo") ~branch:"goat" in
  let merges = Retire.Merge_registry.empty in
  let addr = Ledger.Address.Tuple { relation = "report"; id = "r-1" } in
  let head payload =
    [ { Retire.relation = "report"; id = "r-1"; payload } ]
  in
  let retire node payload =
    match
      Retire.step ~committed ~ledger ~registry ~merges ~node
        ~witness:(Witness.observed ledger ~node)
        ~heads:(head payload)
    with
    | Ok () -> "ok"
    | Error _ -> "rejected"
  in
  let show label =
    Printf.printf "%s: generation %s, invalidations %d, tuples %d\n" label
      (gen_str (Retire.Committed.generation committed addr))
      (invalidations ledger)
      (List.length (Retire.Committed.tuples committed))
  in
  Printf.printf "A inserts report/r-1 verdict=pass: %s\n"
    (retire a (`Assoc [ ("verdict", `String "pass") ]));
  show "after A (fresh: g0, nobody to invalidate)";
  Printf.printf "B re-lands the identical payload: %s\n"
    (retire b (`Assoc [ ("verdict", `String "pass") ]));
  show "after B (free commit)";
  Printf.printf "D lands a different payload: %s\n"
    (retire d (`Assoc [ ("verdict", `String "fail") ]));
  show "after D (semantic change)";
  sh (Printf.sprintf "rm -rf %s" (Filename.quote scratch));
  [%expect
    {|
    A inserts report/r-1 verdict=pass: ok
    after A (fresh: g0, nobody to invalidate): generation g0, invalidations 0, tuples 1
    B re-lands the identical payload: ok
    after B (free commit): generation g0, invalidations 0, tuples 1
    D lands a different payload: ok
    after D (semantic change): generation g1, invalidations 1, tuples 1
    |}]

(* ================================================================== *)
(* Law 3 — the fresh-address hole.  Fresh commits land at the address's  *)
(* first generation, which is also the generation a pre-commit read is   *)
(* witnessed at — so a generation-only check would let a consumer that    *)
(* snooped a DIFFERENT draft retire over the producer's landing.  The     *)
(* commit-point check judges the artifact (the content hash the triple    *)
(* already carries; 30-scheduling.md § law 1/law 3): the drifted snooper is   *)
(* rejected, the exact-prediction snooper still retires free, and the     *)
(* rejection carries the store event's delta ref.                         *)
(* ================================================================== *)

let%expect_test "law 3: a pre-commit witness of a fresh address is judged by \
                 content, never by the primordial generation" =
  let repo = temp_dir "goat_b7_repo" in
  let scratch = temp_dir "goat_b7_scratch" in
  seed_repo repo ~file:"seed.txt" ~contents:"seed\n";
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let producer = Id.mint node_minter in
  let drifted = Id.mint node_minter in
  let exact = Id.mint node_minter in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let merges = Retire.Merge_registry.empty in
  let addr = Ledger.Address.File "gen.ml" in
  let g0 = Ledger.Generation.zero in
  (* Both consumers snooped the producer's store buffer BEFORE it settled:
     one read a draft the producer later rewrote, one read the exact bytes
     that land.  Both witness the fresh address at g0 — only the content
     hash distinguishes them. *)
  ignore
    (Ledger.append ledger ~node:drifted
       (Ledger.Event.Load
          {
            tool = "snoop";
            observed = [ (addr, g0, Ledger.Content_hash.of_string "draft\n") ];
          }));
  ignore
    (Ledger.append ledger ~node:exact
       (Ledger.Event.Load
          {
            tool = "snoop";
            observed = [ (addr, g0, Ledger.Content_hash.of_string "final\n") ];
          }));
  store ~ledger ~repo ~node:producer "gen.ml" "final\n";
  (* The store event's delta is real data: address paired with the ref
     consumers pull through (20-medium.md § invalidate, don't update).
     The ref is the landed content's blob oid — migration row 1
     (README.md § design of record vs shipped engine) moved deltas from
     path locators to content addresses in git's object database, and
     row 2 made the event stream the landing's one source (30-scheduling.md
     § retirement order and the landing) — so the expected ref below is
     [git hash-object] of "final\n". *)
  List.iter
    (fun (e : Ledger.Event.t) ->
      match (e.kind, e.node) with
      | Ledger.Event.Store { address; delta; _ }, Some n
        when Id.equal n producer ->
          Printf.printf "store event: %s -> %s\n"
            (Ledger.Address.to_string address)
            (Ledger.Delta_ref.to_string delta)
      | _ -> ())
    (Ledger.Replay.events ledger);
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:producer
       ~witness:(Witness.observed ledger ~node:producer)
       ~heads:[]
   with
  | Ok () -> print_endline "producer retire: ok"
  | Error _ -> print_endline "producer retire: rejected");
  Printf.printf "gen.ml committed generation: %s\n"
    (gen_str (Retire.Committed.generation committed addr));
  (* The drifted snooper witnessed pre-commit state the landing replaced:
     its retire is the typed Witness_moved rejection, delta ref attached. *)
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:drifted
       ~witness:(Witness.observed ledger ~node:drifted)
       ~heads:[]
   with
  | Error (Retire.Witness_moved moves) ->
      List.iter
        (fun (m : Retire.generation_moved) ->
          Printf.printf
            "drifted retire: rejected (Witness_moved %s witnessed %s current \
             %s delta %s)\n"
            (Ledger.Address.to_string m.address)
            (Format.asprintf "%a" Ledger.Generation.pp m.witnessed)
            (Format.asprintf "%a" Ledger.Generation.pp m.current)
            (Ledger.Delta_ref.to_string m.delta_ref))
        moves
  | Error _ -> print_endline "drifted retire: rejected (other)"
  | Ok () -> print_endline "drifted retire: ok (STALE WITNESS COMMITTED)");
  (* The exact-prediction snooper is the free commit law 2 promises. *)
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:exact
       ~witness:(Witness.observed ledger ~node:exact)
       ~heads:[]
   with
  | Ok () -> print_endline "exact retire: ok (free commit)"
  | Error _ -> print_endline "exact retire: rejected (PREDICTION TAXED)");
  sh (Printf.sprintf "rm -rf %s %s" (Filename.quote repo) (Filename.quote scratch));
  [%expect
    {|
    store event: file:gen.ml -> 8ff82333fa5f2870433063e24f7218e7702a078d
    producer retire: ok
    gen.ml committed generation: g0
    drifted retire: rejected (Witness_moved file:gen.ml witnessed g0 current g0 delta 8ff82333fa5f2870433063e24f7218e7702a078d)
    exact retire: ok (free commit)
    |}]

(* ================================================================== *)
(* Law 3's dead-content backstop (20-medium.md § squash without         *)
(* isolation, step 2; FL2's untracked arm).  A squashed producer's      *)
(* FRESH file tops Absent and its residue reads at generation zero —    *)
(* coordinate-indistinguishable from a legitimate pre-commit read; the  *)
(* content-judged witness is the only thing standing between dead bytes *)
(* and committed state, and pre-fix the Absent arm judged generation    *)
(* alone, so the consumer retired on garbage.  The in-test control is a *)
(* pre-commit read at the SAME coordinates whose content resolves to no *)
(* dead store: absence alone convicts nothing.                          *)
(* ================================================================== *)

let%expect_test "law 3: a squashed producer's fresh-file bytes cannot be \
                 witnessed into committed state; a pre-commit read at the \
                 same coordinates still holds" =
  let repo = temp_dir "goat_dead_fresh_repo" in
  let scratch = temp_dir "goat_dead_fresh_scratch" in
  seed_repo repo ~file:"seed.txt" ~contents:"seed\n";
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let producer = Id.mint node_minter in
  let consumer = Id.mint node_minter in
  let fixture_reader = Id.mint node_minter in
  let committed = Retire.Committed.open_ ~repo ~branch:"goat" in
  let merges = Retire.Merge_registry.empty in
  let addr = Ledger.Address.File "notes.txt" in
  let g0 = Ledger.Generation.zero in
  (* The producer stores a FRESH file (never committed anywhere), then
     squashes: the store event is provenance-dead, the frontier top is
     Absent, and the bytes sit on disk until hygiene. *)
  store ~ledger ~repo ~node:producer "notes.txt" "dead note\n";
  ignore
    (Ledger.append ledger ~node:producer
       (Ledger.Event.Settled
          (Ledger.Settlement.Squashed Ledger.Squash_cause.Reissue_loser)));
  (* The consumer reads the residue AFTER the squash: the read is
     untracked (no snoop hypothesis — the frontier says Committed
     Absent), witnessed at generation zero. *)
  ignore
    (Ledger.append ledger ~node:consumer
       (Ledger.Event.Load
          {
            tool = "read_file";
            observed = [ (addr, g0, Ledger.Content_hash.of_string "dead note\n") ];
          }));
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:consumer
       ~witness:(Witness.observed ledger ~node:consumer)
       ~heads:[]
   with
  | Error (Retire.Witness_moved moves) ->
      Printf.printf
        "consumer retire: rejected (Witness_moved, %d routable move(s) — \
         dead state has no live coordinate)\n"
        (List.length moves)
  | Error _ -> print_endline "consumer retire: rejected (other)"
  | Ok () -> print_endline "consumer retire: ok (RETIRED ON DEAD BYTES)");
  (* Control: a pre-commit read of a never-stored fixture file shares the
     consumer's coordinates exactly (Absent, g0) — only the content
     distinguishes them, and it must hold. *)
  ignore
    (Ledger.append ledger ~node:fixture_reader
       (Ledger.Event.Load
          {
            tool = "read_file";
            observed =
              [
                ( Ledger.Address.File "fixture.txt",
                  g0,
                  Ledger.Content_hash.of_string "fixture bytes\n" );
              ];
          }));
  (match
     Retire.step ~committed ~ledger ~registry ~merges ~node:fixture_reader
       ~witness:(Witness.observed ledger ~node:fixture_reader)
       ~heads:[]
   with
  | Ok () -> print_endline "pre-commit fixture read: ok (absence convicts nothing)"
  | Error _ -> print_endline "pre-commit fixture read: rejected (INSTRUMENT OVERBROAD)");
  sh (Printf.sprintf "rm -rf %s %s" (Filename.quote repo) (Filename.quote scratch));
  [%expect
    {|
    consumer retire: rejected (Witness_moved, 0 routable move(s) — dead state has no live coordinate)
    pre-commit fixture read: ok (absence convicts nothing)
    |}]

(* ================================================================== *)
(* The base coordinate is the LATEST observed read — ledger order,      *)
(* never set order (30-scheduling.md § retirement order, step 2: the    *)
(* base is the content the writer's witness proves it derived from).    *)
(* Two snoops of one evolving draft both enter at generation zero; the  *)
(* set orders them by content hash, which is noise — whichever order    *)
(* the contents hash in, the node derived from the read the ledger      *)
(* appended LAST.                                                       *)
(* ================================================================== *)

let%expect_test "observed_content: the latest observed read wins, in ledger \
                 order, whatever the contents' hash order" =
  let scratch = temp_dir "goat_latest_read" in
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let forward = Id.mint node_minter in
  let backward = Id.mint node_minter in
  let addr = Ledger.Address.File "draft.ml" in
  let g0 = Ledger.Generation.zero in
  let c1 = Ledger.Content_hash.of_string "draft one\n" in
  let c2 = Ledger.Content_hash.of_string "draft two\n" in
  let load node content =
    ignore
      (Ledger.append ledger ~node
         (Ledger.Event.Load { tool = "snoop"; observed = [ (addr, g0, content) ] }))
  in
  (* One node reads c1 then c2; its twin reads c2 then c1. If set order
     leaked into the base, one of the two would report the EARLIER read. *)
  load forward c1;
  load forward c2;
  load backward c2;
  load backward c1;
  let base node =
    Witness.observed_content (Witness.observed ledger ~node) addr
  in
  Printf.printf "forward reader's base is its last read (c2): %b\n"
    (match base forward with
    | Some c -> Ledger.Content_hash.equal c c2
    | None -> false);
  Printf.printf "backward reader's base is its last read (c1): %b\n"
    (match base backward with
    | Some c -> Ledger.Content_hash.equal c c1
    | None -> false);
  sh (Printf.sprintf "rm -rf %s" (Filename.quote scratch));
  [%expect
    {|
    forward reader's base is its last read (c2): true
    backward reader's base is its last read (c1): true
    |}]

let%expect_test "law 3, tuple-shaped: a predicted payload is judged by \
                 content at the tuple's first generation" =
  let scratch = temp_dir "goat_b7_tuple" in
  let ledger = Ledger.create ~path:(scratch // "ledger") in
  let registry = Id.Registry.create () in
  let node_minter : Ledger.node Id.Minter.t =
    Id.Minter.create ~registry ~realm:"node"
  in
  let producer = Id.mint node_minter in
  let drifted = Id.mint node_minter in
  let exact = Id.mint node_minter in
  let committed =
    Retire.Committed.open_ ~repo:(scratch // "repo") ~branch:"goat"
  in
  let merges = Retire.Merge_registry.empty in
  let addr = Ledger.Address.Tuple { relation = "report"; id = "r-9" } in
  let payload_hash p = Ledger.Content_hash.of_string (Yojson.Safe.to_string p) in
  let pass : Yojson.Safe.t = `Assoc [ ("verdict", `String "pass") ] in
  let fail_ : Yojson.Safe.t = `Assoc [ ("verdict", `String "fail") ] in
  (* One consumer hypothesized the wrong verdict, one the landed verdict;
     both witnessed the uncommitted tuple at g0. *)
  ignore
    (Ledger.append ledger ~node:drifted
       (Ledger.Event.Load
          {
            tool = "chase.operand";
            observed = [ (addr, Ledger.Generation.zero, payload_hash pass) ];
          }));
  ignore
    (Ledger.append ledger ~node:exact
       (Ledger.Event.Load
          {
            tool = "chase.operand";
            observed = [ (addr, Ledger.Generation.zero, payload_hash fail_) ];
          }));
  let retire node ~heads =
    match
      Retire.step ~committed ~ledger ~registry ~merges ~node
        ~witness:(Witness.observed ledger ~node)
        ~heads
    with
    | Ok () -> "ok"
    | Error (Retire.Witness_moved _) -> "rejected (Witness_moved)"
    | Error _ -> "rejected (other)"
  in
  Printf.printf "producer inserts report/r-9 verdict=fail: %s\n"
    (retire producer
       ~heads:[ { Retire.relation = "report"; id = "r-9"; payload = fail_ } ]);
  Printf.printf "report/r-9 committed generation: %s\n"
    (gen_str (Retire.Committed.generation committed addr));
  Printf.printf "drifted consumer: %s\n" (retire drifted ~heads:[]);
  Printf.printf "exact consumer: %s\n" (retire exact ~heads:[]);
  sh (Printf.sprintf "rm -rf %s" (Filename.quote scratch));
  [%expect
    {|
    producer inserts report/r-9 verdict=fail: ok
    report/r-9 committed generation: g0
    drifted consumer: rejected (Witness_moved)
    exact consumer: ok
    |}]

(* ================================================================== *)
(* F7 — channel edge: [Channel.invalidate] is fired only on a moved      *)
(* generation, and the durable fact it fans out from is the ledger's     *)
(* [Invalidation_sent] event.  A byte-identical landing appends none,    *)
(* so a consumer edge's pending queue stays empty across it: nothing to  *)
(* deliver at the next yield, no drift note to render, no reconcile.     *)
(* Asserted above via ledger event counts; the wired delivery half       *)
(* (retire publishes, consumers pull at yields) is exercised end to end  *)
(* in test_delivery.ml — including F6's engine half: an observed         *)
(* [read_file] tool load gating retirement through the real machinery.   *)
(* ================================================================== *)
