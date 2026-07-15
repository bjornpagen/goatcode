(* Falsifiers, group "fiber" (the effects substrate, fiber.mli):

   FB1 — park then wake resumes with the woken value: a read the policy
   declines parks the fiber (printable state, held continuation); an
   external wake ~key delivers the operand the invalidation carried, and
   the fiber resumes with exactly that value.

   FB2 — squash discontinues: Fun.protect finalizers run before squash
   returns, the settlement carries the cause chain, and a fiber that
   CATCHES the squash exception still performs no further operation —
   squash is scheduler state, not a convention (every later instruction
   discontinues again; a swallowed return settles Stopped, never
   Returned).

   FB3 — drift notes are delivered at Yield; a `Stop_cleanly disposition
   never reaches the fiber: the handler discontinues, the settlement
   carries the note, finalizers run.

   FB4 — two slow operations OVERLAP under the scheduler: both transfers
   are submitted before either completes (interleaving order, not wall
   clock), and completion order — not submit order — decides resume
   order.

   FB5 — resume-exactly-once is impossible through the API: continuations
   are never exposed; a second wake of the same key is a counted no-op,
   never Continuation_already_resumed; waking a squashed fiber's key
   wakes nothing.

   FB6 — a rogue (unvocabulary) effect is contained as the fiber's own
   typed fault; siblings settle undisturbed and the scheduler quiesces.

   Rigged transports only; no network, no sleeps. *)

open Goatcode

(* ------------------------------------------------------------------ *)
(* Shared rig *)

let addr name = Ledger.Address.Tuple { relation = "r"; id = name }

let witnessed content =
  Fiber.Operand.Witnessed
    {
      generation = Ledger.Generation.zero;
      content = Ledger.Content_hash.of_string content;
    }

let show_operand = function
  | Fiber.Operand.Witnessed { content; _ } ->
      "witnessed " ^ String.sub (Ledger.Content_hash.to_hex content) 0 8
  | Fiber.Operand.Hypothesis _ -> "hypothesis"

let show_cause = function
  | Ledger.Squash_cause.Operator_abort -> "operator-abort"
  | Ledger.Squash_cause.Dead_hypothesis h -> "dead-hypothesis " ^ Id.to_string h
  | Ledger.Squash_cause.Upstream_fault n -> "upstream-fault " ^ Id.to_string n
  | Ledger.Squash_cause.Upstream_squash n -> "upstream-squash " ^ Id.to_string n
  | Ledger.Squash_cause.Reissue_loser -> "reissue-loser"
  | Ledger.Squash_cause.No_producer -> "no-producer"

let show_settlement show = function
  | None -> "unsettled"
  | Some (Fiber.Returned v) -> "returned " ^ show v
  | Some (Fiber.Stopped (Fiber.Squashed cause)) ->
      "stopped (squashed: " ^ show_cause cause ^ ")"
  | Some (Fiber.Stopped (Fiber.Stopped_cleanly note)) ->
      "stopped (cleanly, note on "
      ^ Ledger.Address.to_string note.Speculate.Drift.address
      ^ ")"
  | Some (Fiber.Faulted f) ->
      if
        String.starts_with ~prefix:"unhandled effect:"
          f.Ledger.Fault.message
      then "faulted (unhandled effect)"
      else "faulted: " ^ f.Ledger.Fault.message

(* A transport no test below actually reaches. *)
let no_transport : Fiber.Transport.t =
  {
    submit = (fun _ -> failwith "no transport in this test");
    poll = (fun ~block:_ -> []);
  }

(* Answer nothing: every read parks. *)
let park_all _ _ = None

let note ?(disposition = `Continue) name =
  {
    Speculate.Drift.address = addr name;
    cls = Speculate.Drift.Schema_identical;
    delta = None;
    disposition;
  }

let show_note (n : Speculate.Drift.note) =
  let d =
    match n.disposition with
    | `Continue -> "continue"
    | `Patch_then_continue -> "patch"
    | `Stop_cleanly -> "stop-cleanly"
  in
  Printf.sprintf "%s/%s" (Ledger.Address.to_string n.address) d

(* ------------------------------------------------------------------ *)

let%expect_test "FB1: park-then-wake resumes with the woken value" =
  let t = Fiber.create ~read:park_all ~transport:no_transport () in
  let h =
    Fiber.spawn t ~name:"consumer" (fun () ->
        let operand = Fiber.read (addr "review") in
        show_operand operand)
  in
  Fiber.run_until_quiescent t;
  print_endline (Fiber.dump t);
  Printf.printf "quiescent, parked on: %s\n"
    (String.concat ", "
       (List.map (fun (_, a) -> Ledger.Address.to_string a) (Fiber.parked t)));
  [%expect
    {|
    f0 consumer: parked-on tuple:r/review
    quiescent, parked on: tuple:r/review
    |}];
  let woken = Fiber.wake t ~key:(addr "review") (witnessed "landed-tuple") in
  Printf.printf "woken: %d\n" woken;
  Fiber.run_until_quiescent t;
  Printf.printf "settlement: %s\n" (show_settlement Fun.id (Fiber.result h));
  Printf.printf "expected hash: %s\n"
    (String.sub
       (Ledger.Content_hash.to_hex (Ledger.Content_hash.of_string "landed-tuple"))
       0 8);
  [%expect
    {|
    woken: 1
    settlement: returned witnessed ede64393
    expected hash: ede64393
    |}]

let%expect_test "FB2: squash discontinues — finalizers run, and a fiber that \
                 catches Squash performs no further operation" =
  let trace = ref [] in
  let say s = trace := !trace @ [ s ] in
  let t = Fiber.create ~read:park_all ~transport:no_transport () in
  (* The obedient fiber: parks, is squashed, its worktree-cleanup stands in
     as the Fun.protect finalizer. *)
  let obedient =
    Fiber.spawn t ~name:"obedient" (fun () ->
        Fun.protect
          ~finally:(fun () -> say "obedient: finalizer ran")
          (fun () ->
            ignore (Fiber.read (addr "a") : Fiber.Operand.t);
            say "obedient: SURVIVED PAST SQUASH"))
  in
  (* The escape artist: catches Squash, then tries to read and yield again,
     then returns a value as if nothing happened. *)
  let escape =
    Fiber.spawn t ~name:"escape-artist" (fun () ->
        (try ignore (Fiber.read (addr "b") : Fiber.Operand.t)
         with Fiber.Squash -> say "escape: caught Squash");
        (try ignore (Fiber.read (addr "b") : Fiber.Operand.t)
         with Fiber.Squash -> say "escape: second read discontinued too");
        (try ignore (Fiber.yield () : Speculate.Drift.note list)
         with Fiber.Squash -> say "escape: yield discontinued too");
        "escaped")
  in
  Fiber.run_until_quiescent t;
  Fiber.squash t (Fiber.id obedient) ~cause:Ledger.Squash_cause.Operator_abort;
  Fiber.squash t (Fiber.id escape) ~cause:Ledger.Squash_cause.Operator_abort;
  Fiber.run_until_quiescent t;
  List.iter print_endline !trace;
  Printf.printf "obedient: %s\n"
    (show_settlement (fun () -> "()") (Fiber.result obedient));
  Printf.printf "escape:   %s\n" (show_settlement Fun.id (Fiber.result escape));
  print_endline (Fiber.dump t);
  [%expect
    {|
    obedient: finalizer ran
    escape: caught Squash
    escape: second read discontinued too
    escape: yield discontinued too
    obedient: stopped (squashed: operator-abort)
    escape:   stopped (squashed: operator-abort)
    f0 obedient: settled stopped
    f1 escape-artist: settled stopped
    |}]

let%expect_test "FB2b: squash before first instruction — the fiber never runs" =
  let t = Fiber.create ~read:park_all ~transport:no_transport () in
  let h =
    Fiber.spawn t ~name:"never-ran" (fun () ->
        print_endline "BODY RAN";
        0)
  in
  Fiber.squash t (Fiber.id h) ~cause:Ledger.Squash_cause.Operator_abort;
  Fiber.run_until_quiescent t;
  Printf.printf "settlement: %s\n"
    (show_settlement string_of_int (Fiber.result h));
  [%expect {| settlement: stopped (squashed: operator-abort) |}]

let%expect_test "FB3: drift notes delivered at Yield; Stop_cleanly \
                 discontinues instead of resuming" =
  let deliveries =
    ref
      [
        [ note "upstream" ];
        [ note ~disposition:`Stop_cleanly "upstream" ];
      ]
  in
  let on_yield () =
    match !deliveries with
    | [] -> []
    | d :: rest ->
        deliveries := rest;
        d
  in
  let trace = ref [] in
  let say s = trace := !trace @ [ s ] in
  let t = Fiber.create ~read:park_all ~transport:no_transport () in
  let h =
    Fiber.spawn t ~name:"worker" ~on_yield (fun () ->
        Fun.protect
          ~finally:(fun () -> say "finalizer ran")
          (fun () ->
            let rec loop n =
              let notes = Fiber.yield () in
              say
                (Printf.sprintf "yield %d: %s" n
                   (String.concat ", " (List.map show_note notes)));
              loop (n + 1)
            in
            loop 1))
  in
  Fiber.run_until_quiescent t;
  List.iter print_endline !trace;
  Printf.printf "settlement: %s\n"
    (show_settlement (fun _ -> "?") (Fiber.result h));
  [%expect
    {|
    yield 1: tuple:r/upstream/continue
    finalizer ran
    settlement: stopped (cleanly, note on tuple:r/upstream)
    |}]

(* A scripted transport: records submissions, completes them in the order
   the script says — the rigged stand-in for curl-multi that lets the
   falsifier assert interleaving instead of wall clock. *)
let scripted_transport ~say ~complete_in_order:reorder =
  let pending = ref [] in
  let next = ref 0 in
  {
    Fiber.Transport.submit =
      (fun (req : Http.Request.t) ->
        let tok = !next in
        incr next;
        say (Printf.sprintf "transport: submit #%d %s" tok req.url);
        pending := !pending @ [ (tok, req) ];
        tok);
    poll =
      (fun ~block:_ ->
        let order = reorder !pending in
        pending := [];
        List.map
          (fun (tok, (req : Http.Request.t)) ->
            say (Printf.sprintf "transport: complete #%d" tok);
            (tok, Ok (200, "reply-for " ^ req.url)))
          order);
  }

let%expect_test "FB4: two provider calls overlap on one domain — both \
                 submitted before either completes; completion order \
                 decides resume order" =
  let trace = ref [] in
  let say s = trace := !trace @ [ s ] in
  let transport = scripted_transport ~say ~complete_in_order:List.rev in
  let t = Fiber.create ~read:park_all ~transport () in
  let call name url =
    Fiber.spawn t ~name (fun () ->
        say (name ^ ": posting");
        match
          Fiber.http_post { headers = []; url; body = "{}"; timeout_s = 5. }
        with
        | Ok (status, body) ->
            say (Printf.sprintf "%s: got %d %s" name status body);
            body
        | Error e -> failwith e.Http.code)
  in
  let a = call "alpha" "https://one" in
  let b = call "beta" "https://two" in
  (* Drive until both are in flight, then inspect the printable view
     before any completion is delivered. *)
  ignore (Fiber.step t : [ `Progressed | `Quiescent ]);
  ignore (Fiber.step t : [ `Progressed | `Quiescent ]);
  print_endline (Fiber.dump t);
  [%expect
    {|
    f0 alpha: in-flight #0
    f1 beta: in-flight #1
    |}];
  Fiber.run_until_quiescent t;
  List.iter print_endline !trace;
  Printf.printf "alpha: %s\n" (show_settlement Fun.id (Fiber.result a));
  Printf.printf "beta:  %s\n" (show_settlement Fun.id (Fiber.result b));
  [%expect
    {|
    alpha: posting
    transport: submit #0 https://one
    beta: posting
    transport: submit #1 https://two
    transport: complete #1
    transport: complete #0
    beta: got 200 reply-for https://two
    alpha: got 200 reply-for https://one
    alpha: returned reply-for https://one
    beta:  returned reply-for https://two
    |}]

let%expect_test "FB5: resume-exactly-once is the API — a second wake is a \
                 counted no-op; a squashed fiber's key wakes nothing" =
  let t = Fiber.create ~read:park_all ~transport:no_transport () in
  let h =
    Fiber.spawn t ~name:"once" (fun () ->
        show_operand (Fiber.read (addr "k")))
  in
  Fiber.run_until_quiescent t;
  let w1 = Fiber.wake t ~key:(addr "k") (witnessed "first") in
  let w2 = Fiber.wake t ~key:(addr "k") (witnessed "second") in
  Fiber.run_until_quiescent t;
  let w3 = Fiber.wake t ~key:(addr "k") (witnessed "third") in
  Printf.printf "wakes: %d %d %d\n" w1 w2 w3;
  Printf.printf "settlement: %s (hash of \"first\": %s)\n"
    (show_settlement Fun.id (Fiber.result h))
    (String.sub
       (Ledger.Content_hash.to_hex (Ledger.Content_hash.of_string "first"))
       0 8);
  [%expect
    {|
    wakes: 1 0 0
    settlement: returned witnessed 8b04d5e3 (hash of "first": 8b04d5e3)
    |}];
  (* Squash-then-wake: the parked continuation is discontinued at squash,
     so the later invalidation finds nobody — 0, and no
     Continuation_already_resumed anywhere. *)
  let t2 = Fiber.create ~read:park_all ~transport:no_transport () in
  let h2 =
    Fiber.spawn t2 ~name:"squashed" (fun () ->
        show_operand (Fiber.read (addr "k")))
  in
  Fiber.run_until_quiescent t2;
  Fiber.squash t2 (Fiber.id h2) ~cause:Ledger.Squash_cause.Operator_abort;
  Printf.printf "wake after squash: %d\n"
    (Fiber.wake t2 ~key:(addr "k") (witnessed "late"));
  Printf.printf "settlement: %s\n" (show_settlement Fun.id (Fiber.result h2));
  [%expect
    {|
    wake after squash: 0
    settlement: stopped (squashed: operator-abort)
    |}]

(* FB7's server: the one genuinely-multi test runs against a loopback
   listener on an ephemeral port — hermetic (no name resolution, no
   network beyond 127.0.0.1) and single-threaded: the scheduler under test
   owns the only domain, so the server is pumped from the test transport's
   [poll] instead of a thread. Connection-close framing makes libcurl
   finish each transfer unambiguously. *)
let contains_blank_line s =
  let terminator = "\r\n\r\n" in
  let n = String.length s and m = String.length terminator in
  let rec at i =
    if i + m > n then false
    else if String.equal (String.sub s i m) terminator then true
    else at (i + 1)
  in
  at 0

module Loopback = struct
  type t = {
    sock : Unix.file_descr;
    mutable conns : (Unix.file_descr * Buffer.t) list;
  }

  let create () =
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt sock Unix.SO_REUSEADDR true;
    Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
    Unix.listen sock 8;
    Unix.set_nonblock sock;
    let port =
      match Unix.getsockname sock with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> assert false
    in
    ({ sock; conns = [] }, port)

  let would_block = function
    | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> true
    | _ -> false

  (* One non-blocking service round: accept whatever is pending, read
     whatever arrived, answer any request whose headers are complete (the
     two-byte test entity rides the same packet with every libcurl this
     substrate meets). *)
  let pump t =
    (try
       while true do
         let conn, _ = Unix.accept t.sock in
         Unix.set_nonblock conn;
         t.conns <- t.conns @ [ (conn, Buffer.create 256) ]
       done
     with e when would_block e -> ());
    let buf = Bytes.create 4096 in
    t.conns <-
      List.filter
        (fun (conn, acc) ->
          match Unix.read conn buf 0 (Bytes.length buf) with
          | exception e when would_block e -> true
          | 0 ->
              Unix.close conn;
              false
          | n ->
              Buffer.add_subbytes acc buf 0 n;
              if contains_blank_line (Buffer.contents acc) then begin
                let reply = "pong" in
                let response =
                  Printf.sprintf
                    "HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\
                     Connection: close\r\n\r\n%s"
                    (String.length reply) reply
                in
                ignore
                  (Unix.write_substring conn response 0
                     (String.length response)
                    : int);
                Unix.close conn;
                false
              end
              else true)
        t.conns

  let close t =
    List.iter (fun (conn, _) -> Unix.close conn) t.conns;
    Unix.close t.sock
end

type _ Effect.t += Rogue : unit Effect.t

let%expect_test "FB6: a rogue effect is a typed fault, not a process crash; \
                 siblings settle undisturbed" =
  let t = Fiber.create ~read:(fun _ _ -> Some (witnessed "x")) ~transport:no_transport () in
  let rogue =
    Fiber.spawn t ~name:"rogue" (fun () ->
        Effect.perform Rogue;
        "unreachable")
  in
  let sibling =
    Fiber.spawn t ~name:"sibling" (fun () ->
        show_operand (Fiber.read (addr "fine")))
  in
  Fiber.run_until_quiescent t;
  Printf.printf "rogue:   %s\n" (show_settlement Fun.id (Fiber.result rogue));
  Printf.printf "sibling: %s\n" (show_settlement Fun.id (Fiber.result sibling));
  Printf.printf "quiescent: %b\n" (Fiber.quiescent t);
  [%expect
    {|
    rogue:   faulted (unhandled effect)
    sibling: returned witnessed 9dd4e461
    quiescent: true
    |}]

let%expect_test "FB7: the live curl-multi lane — two loopback transfers held \
                 in flight together, driven to quiescence by the scheduler" =
  let server, port = Loopback.create () in
  Fun.protect ~finally:(fun () -> Loopback.close server) @@ fun () ->
  let live = Fiber.Transport.live () in
  let transport =
    {
      Fiber.Transport.submit = live.submit;
      poll =
        (fun ~block ->
          Loopback.pump server;
          live.poll ~block);
    }
  in
  let t = Fiber.create ~read:park_all ~transport () in
  let url = Printf.sprintf "http://127.0.0.1:%d/turn" port in
  let call name =
    Fiber.spawn t ~name (fun () ->
        match
          Fiber.http_post
            {
              headers = [ ("content-type", "application/json") ];
              url;
              body = "{}";
              timeout_s = 10.;
            }
        with
        | Ok (status, body) -> Printf.sprintf "%d %s" status body
        | Error e -> "transport error " ^ e.Http.code)
  in
  let a = call "alpha" in
  let b = call "beta" in
  (* Two steps run both fibers to their Http_post suspensions: both
     transfers are in flight before any byte comes back — the overlap,
     in the printable view. *)
  ignore (Fiber.step t : [ `Progressed | `Quiescent ]);
  ignore (Fiber.step t : [ `Progressed | `Quiescent ]);
  print_endline (Fiber.dump t);
  Fiber.run_until_quiescent t;
  Printf.printf "alpha: %s\n" (show_settlement Fun.id (Fiber.result a));
  Printf.printf "beta:  %s\n" (show_settlement Fun.id (Fiber.result b));
  [%expect
    {|
    f0 alpha: in-flight #0
    f1 beta: in-flight #1
    alpha: returned 200 pong
    beta:  returned 200 pong
    |}]
