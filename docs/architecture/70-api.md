# 70 — API

The host surface: how an operator (or the planner) presents a theory, runs
it, and reads what happened. Readers: theory authors; `bin/goat`; the
falsifier suite (which drives everything through this surface — there is no
privileged internal entry).

## Declaring a theory

A theory is OCaml source: catalog types with derivers, plus a declaration
value assembled from the library's constructors. No macro layer, no external
DSL file, no YAML. The worked review theory (`10-theory.md`), concretely:

```ocaml
open Goatcode

(** A single reviewer finding: one defect claim, anchored to a file. *)
type finding = {
  change : Change.t Id.t;  (** Phantom-typed ref: only the engine mints
                               [Change.t Id.t]s, so a wrong-relation ref is
                               a compile error here and a parse failure at
                               the wire ([20-contracts.md] § phantom). *)
  file : string;   (** Repo-relative path the claim anchors to. *)
  claim : string;  (** One-sentence statement of the defect. *)
}
[@@deriving jsonschema ~variant_as_string, yojson]

(** One refuter's verdict on one finding. *)
type verdict = {
  finding : Finding.t Id.t;
  refuted : bool;  (** True when the refuter killed the claim. *)
  why : string;    (** The refutation or survival argument, one paragraph. *)
}
[@@deriving jsonschema ~variant_as_string, yojson]

(* One catalog entry per relation packages the declaration's derived
   artifacts once: the deriver's schema output and the ppx codec pair. *)
let entry name schema of_json to_json =
  Contract.v ~name ~schema ~codec:(Contract.Codec.v ~of_json ~to_json)

let finder =
  Theory.Executor.Agent_template
    { name = "finder"; pin = Pins.finder; preamble = Prompts.finder;
      read_globs = [ "src/**" ] }

let refuter =
  Theory.Executor.Agent_template
    { name = "refuter"; pin = Pins.refuter; preamble = Prompts.refuter;
      read_globs = [ "src/**" ] }

let theory =
  Theory.declare
    ~relations:
      [
        Theory.Relation.Packed
          (Theory.Relation.v ~name:"change"
             (entry "change" change_jsonschema change_of_yojson
                yojson_of_change));
        Theory.Relation.Packed
          (Theory.Relation.v ~name:"finding"
             (entry "finding" finding_jsonschema finding_of_yojson
                yojson_of_finding));
        Theory.Relation.Packed
          (Theory.Relation.v ~name:"verdict"
             (entry "verdict" verdict_jsonschema verdict_of_yojson
                yojson_of_verdict));
      ]
    ~statements:
      [
        Theory.Spawn.v ~name:"sweep" ~for_:"change"
          ~exists:("finding", Theory.Window.upto 32)
          ~by:finder ();
        Theory.Spawn.v ~name:"review" ~for_:"finding"
          ~exists:("verdict", Theory.Window.nodes 3)
          ~by:refuter ();
      ]
    ~laws:
      [
        Theory.Law.Count
          { name = "quorum"; over = "verdict"; group_by = "finding";
            bound = Theory.Law.Exactly 3 };
      ]
```

`Theory.declare` runs **admission** immediately, and admission is a parse:
it returns `(Theory.admitted, Admission.error list) result`. Weak
acyclicity, the acceptance gate (every law compiled to its judge), the
schema parse into `Wire_schema.t` (`20-contracts.md` § the LLM-safe
subset), and ref-slot resolution all happen here, once —
**`Theory.admitted` has no other constructor, and it is the only theory
type the rest of the API mentions**, so an unadmitted theory cannot reach
the engine by any code path (`10-theory.md` § termination). Admission
errors are values, each carrying the offending statement and, for cycles,
the cycle path — shaped for the planner's repair lane as much as for
humans (`60-agents.md` § the planner).

Surface style is deliberately plain: named constructors, no operator
soup, no builder chaining. **Decision.** **Alternative:** a ppx that reads
a custom `theory%` syntax block — lost for v0 because the constructor
surface is inspectable, greppable, and reachable by the planner (which
emits it as data through the meta-catalog, never as source text anyway); a
surface ppx is sugar with a real maintenance bill under a moving `+ox`
toolchain. **Reverses if:** hand-written theories accumulate enough
boilerplate that authorship error rates show up in admission telemetry.

## Running

```ocaml
val Run.exec :
  theory:Theory.admitted ->
  seed:Tuple.t list ->            (* the initial facts, e.g. one change tuple *)
  config:Run.config ->            (* worktree root, ledger path, port table,
                                     backstops: token ceiling + confidence
                                     floor, per-shape speculation off switches *)
  Run.settled Lwt.t               (* or effect-based equivalent; the fiber
                                     substrate is an implementation fact *)
```

One entry point. Seed tuples are facts, not work product: each one enters
committed state at run open, at the primordial generation, with its payload
carried into the body-match feed — so where-filters match seed fields,
agents read seed data in their operand sections, and law judgment counts
seeded referents in its universe (a quorum law over a seeded relation is
never vacuously satisfied). `config` carries every number the docs say the
operator owns: the port table (provider ceilings), the two backstops
(`40-scheduling.md` § backstops), any per-shape off switches, paths. The
off switch is representation-enforced: `Switch.throw` takes the churn
evidence as an argument (`Churn.measurement`, a ledger-derived value) — a
bare switch is not rejected by the config loader, it is unconstructible
(doc rule 8; the counter is named in `80-validation.md`). Nothing in
config changes semantics — a run with speculation disabled retires the
same tuples with the same law verdicts, only slower; the falsifier suite
asserts exactly this equivalence (`80-validation.md` F9).

## The settled map

The answer is a value, never an exception:

```ocaml
type Run.settled = {
  nodes : Node.settlement Node.Map.t;   (* retired / faulted / squashed, cause chains, timings *)
  tuples : Tuple.committed Relation.Map.t;
  laws : Law.verdict list;              (* judged at quiescence, final state *)
  ledger : Ledger.handle;               (* the run's ledger, for the four readers *)
}
```

Each settlement carries the timing decomposition — `blocked` (operand
wait), `queued` (port wait), `run` — plus the speculation stamps
(hypotheses fired on, discharge times, drift notes received). A run-level
rejection exists only for host misuse (unadmitted theory, config paths that
don't exist), never for node failure or law violation: **the map is the
answer** (`40-scheduling.md` § settlement).

## Reading a run

Pull surfaces, all ledger queries, none of them on any hot path:

- **`Report.summarize settled`** — wall clock, total work, realized
  parallelism, the critical path (the chain that *was* the wall clock,
  walked backward through latest-settling operands), per-port queue
  rankings, and the speculation account: tokens spent under undischarged
  hypotheses, tokens squashed, latency bought (measured overlap, not
  theoretical). This report is where the success criteria
  (`00-product.md`) are read, so its fields are the criteria's fields.
- **`Report.scoreboard run`** — live occupancy while running: per-port
  active/pending, in-flight hypotheses with confidence products, ledger
  append rate. Pull-only; polling it does not touch the dispatch path.
- **`Report.explain settled node_id`** — one node's story assembled from
  the ledger: why it fired when it did (the counters consulted, the
  hypothesis constructed), every drift note it received and the route
  taken, its witness at retire, its settlement. The answer to "why did
  this run twice" is this function's output, and the scheduler's ruling
  that every decision lands in the ledger with reasons
  (`40-scheduling.md`) exists so this function can exist.

## The CLI

`bin/goat` wraps the library for the terminal:

```
goat run <theory.exe> --seed seed.json --config run.toml
goat report <ledger>            # summarize
goat explain <ledger> <node>    # one node's story
goat replay <ledger>            # replay-determinism check (80-validation.md)
```

Theories compile to executables that link the library and call `Run.exec` —
the CLI's `run` is a convenience runner around exactly that, holding no
semantics of its own. The planner path (`goat plan "<spec>"`) seeds a
one-statement bootstrap theory whose single node is the planner template
emitting a theory through the meta-catalog, then runs admission and, on
success, the emitted theory — the full loop in one command, with the
admission-repair cycle visible in the ledger like any other repair.

## OPEN items

- **Config defaulting.** Which config fields get defaults vs stay required
  (the exchange-rate question is recorded at `40-scheduling.md`; the rest
  follow the same trigger).
- **Streaming report surface.** `scoreboard` polls; a push surface (SSE or
  a TUI) is presentation-layer and waits for a consumer. *Trigger: the
  first operator who runs a >30-minute pipeline and asks for a progress
  bar.*
- **Seed tooling.** Seeds are JSON tuples validated through the same codec
  boundary; sugar for common seeds (a git diff as a `change` tuple) belongs
  in `bin/goat` once patterns repeat. *Trigger: the third hand-written
  seed file with the same shape.*
