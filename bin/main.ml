(* goat — the CLI wrapper around the Goatcode library.

   Thin by ruling: theories compile to executables that link the library and
   call [Run.exec]; [goat run] is a convenience runner around exactly that,
   holding no semantics of its own. [report]/[explain]/[replay] are ledger
   readers ([Report.summarize], [Report.explain], [Run.replay]); [plan] seeds
   the one-statement bootstrap theory whose single node is the planner
   template emitting a theory through the meta-catalog
   (docs/architecture/70-api.md § the CLI). *)

let version = "0.1.0-dev"

type command =
  | Run of { theory_exe : string; seed : string; config : string }
      (** goat run <theory.exe> --seed seed.json --config run.toml *)
  | Plan of { spec : string; config : string }
      (** goat plan "<spec>" --config run.toml *)
  | Report of { ledger : string }  (** goat report <ledger> *)
  | Explain of { ledger : string; node : string }
      (** goat explain <ledger> <node> *)
  | Replay of { ledger : string }  (** goat replay <ledger> *)
  | Version
  | Usage

let usage_text =
  String.concat "\n"
    [
      "goat " ^ version;
      "";
      "usage:";
      "  goat run <theory.exe> --seed <seed.json> --config <run.toml>";
      "  goat plan <spec> --config <run.toml>";
      "  goat report <ledger>            # Report.summarize";
      "  goat explain <ledger> <node>    # one node's story";
      "  goat replay <ledger>            # replay-determinism check";
      "  goat version";
    ]

(* Flag extraction: [--key value] pairs after the positional arguments. *)
let flag key args =
  let rec go = function
    | k :: v :: _ when String.equal k key -> Some v
    | _ :: rest -> go rest
    | [] -> None
  in
  go args

let parse = function
  | "run" :: theory_exe :: rest -> (
      match (flag "--seed" rest, flag "--config" rest) with
      | Some seed, Some config -> Run { theory_exe; seed; config }
      | _ -> Usage)
  | "plan" :: spec :: rest -> (
      match flag "--config" rest with
      | Some config -> Plan { spec; config }
      | None -> Usage)
  | [ "report"; ledger ] -> Report { ledger }
  | [ "explain"; ledger; node ] -> Explain { ledger; node }
  | [ "replay"; ledger ] -> Replay { ledger }
  | [ "version" ] | [ "--version" ] -> Version
  | _ -> Usage

let run_command = function
  | Version -> print_endline ("goatcode " ^ version)
  | Usage -> print_endline usage_text
  | Run _ -> failwith "TODO: goat run"
  | Plan _ -> failwith "TODO: goat plan"
  | Report _ -> failwith "TODO: goat report"
  | Explain _ -> failwith "TODO: goat explain"
  | Replay _ -> failwith "TODO: goat replay"

let () =
  Sys.argv |> Array.to_list |> List.tl |> parse |> run_command
