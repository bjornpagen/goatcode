# GOAT CODE

A coding harness built as a **speculative chase engine whose rule firings
invoke LLM agents** — Tomasulo's algorithm and the database chase observed to
be the same algorithm at different levels, plus speculation, run at the level
where the execution units cost tokens and take minutes.

**The objective is wall-clock time, at all costs.** The scarce resource is
the operator's calendar; tokens are fuel — accounted, backstopped, reported,
never the objective. Consequences, each a ruling in the architecture docs:

- **Work is a theory, not a script.** The design's deepest commitment is the
  Brooks–Pike–Raymond–Torvalds principle that the representation, not the
  control flow, is where complexity lives: orchestration is reified as data
  (relations as channels; spawn rules with data-generated fanout;
  cardinality windows; retire laws judged once against final state) and the
  scheduler is a small evaluator — a chase — over it. Everywhere else the
  same move repeats: boundaries parse into refined types, forbidden states
  are unconstructible rather than guarded, unavoidable branching is a table.
- **Every channel is pre-opened at admission** (s6/systemd socket-activation
  lineage): every node starts at t=0, and readiness is a property of a
  *read*, never of a node. Waiting happens at reads; suspended fibers are
  free.
- **Speculation is default-on.** A read of a missing operand takes a
  hypothesis wherever a source exists (an issued contract, a producer's
  streaming store buffer). Hypotheses are taken at read time — as late and
  as well-informed as the work allows. The single off switch is per task
  shape and requires measured reconcile churn.
- **Contracts are one supply.** An OCaml type declaration derives the JSON
  Schema handed to the model, the codec that parses the reply, and the
  prompt prose the model reads (`ppx_deriving_jsonschema` +
  `ppx_yojson_conv`). Drift is a schema diff; correct speculation commits
  for free (generations advance only on semantic change).
- **Abort by construction.** Speculative state lives in git worktrees and
  an append-only ledger; squash drops a worktree and marks events — no
  rollback, no compensation. Witnesses are observed from tool events, never
  self-reported. Retirement is dependency-ordered; squash precision is
  absolute.
- **Channels are unidirectional.** Feedback is a forward edge firing a new
  generation; the scheduler is the only bidirectional party.

The normative design lives in [`docs/architecture/`](docs/architecture/) —
start at its [README](docs/architecture/README.md) for the doc rules
(decision records with reversal evidence, OPEN items with closure triggers,
the acceptance gate) and the reading order.

## Status

Design phase. The architecture docs are complete and normative; the OxCaml
implementation is scaffolding. Nothing here has run a pipeline yet; every
measured claim in the docs is marked as unearned until the ledger earns it.

## Toolchain

OCaml on the OxCaml toolchain (modes prove squash safety; effects carry the
fibers). See `dune-project` for the package set; the switch is linked to
this directory.

## License

0BSD © Bjorn Pagen
