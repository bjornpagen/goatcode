# 60 — Agents

The execution units. An executor is what a spawn statement's `by` clause
names: an **agent template** (the common case), a **pure function** (host
OCaml, for mechanical transforms), or a **shell gate** (a build/test command
whose exit status and output become tuples). This doc owns the agent case;
the other two exist so the theory never invokes an LLM to do a compiler's
job. Readers: the `Agent` module; prompt-assembly; `20-contracts.md` (whose
derived artifacts are consumed here).

## Prompt assembly: derived, never authored

**A node's prompt is assembled from derived parts; a hand-authored per-node
prompt is a bug.** The parts, in order:

1. **The template preamble** — the agent template's role text (refuter,
   implementer, summarizer), the one hand-written artifact, owned by the
   theory author, versioned with the theory. It states stance and method,
   never shape.
2. **The contract section** — rendered from the catalog entry: the derived
   prose (doc comments), the wire schema as reference text, and the
   output-shape instruction. The decoder's schema and the prompt's reference
   text derive from the same declaration — one supply (`20-contracts.md`).
3. **The operand section** — the body tuples the node fired on, rendered by
   the codec's printer; for speculative nodes, the hypothesis tuples,
   *explicitly marked as speculative* with the confidence and the
   what-happens-on-drift contract (the agent is told it may receive drift
   notes at yield points and what to do with them).
4. **The footprint grant** — which paths are readable, which are writable
   (its worktree), which tools are granted (effect-capable tools appear only
   with declared-idempotent stamps for speculative nodes —
   `30-channels.md`).
5. **The settlement instruction** — the node's final message is its head
   tuples (structured output against the wire schema), not prose for a
   human. Reports for humans are tuples too (a `summary` relation), so the
   settlement instruction never wavers.

## The primary lane: freeform, then validate, then repair

**Agents generate freeform against a strong model; the contract constrains
at the boundary, never at the decoder.** The reply parses through the
derived codec; parse or schema failure enters the **repair loop**: the same
agent is re-invoked stateless-with-diagnostics — its own invalid output plus
the validator's specific complaints — with a bounded repair budget
(configured per template, small). Repair exhaustion faults the node; faults
route to the scheduler like any settlement (`40-scheduling.md`).

**Decision.** **Alternative:** grammar-constrained decoding on the primary
lane (force the output shape at the token sampler) — lost on the ruling
this design inherits and re-affirms: hard decode-time constraint runs on
constrained paths (provider-specific, weaker sampling, no reasoning
interleave) and buys shape at the cost of quality exactly where quality is
the product; freeform + mechanical validation + diagnostic repair gets the
same guarantee (nothing invalid passes the boundary) while letting the model
work at full strength. The repair loop is the same machinery reconcile uses
(`50-commit.md` § the repair lane), so the lane is paid for once.
**Reverses if:** measured repair-loop exhaustion rates on some (template,
model-pin) pair exceed the constrained lane's measured quality tax on the
same pair — per pair, never globally.

**The fallback lane.** Constrained decoding survives as the *refusal lane*:
when a model refuses or meta-comments instead of producing tuples
(recognized by the codec as a non-parse with refusal markers), the retry
routes to a constrained-decode call whose grammar is derived from the same
schema. Rare, mechanical, and it keeps the primary lane honest about what it
is: a quality choice, not a capability boundary.

## Tool grants and the effect gate

A node's tools are its footprint grant made operational: reads within
granted globs, writes within its worktree, the shell gates the template
declares. **The grant is a type indexed by speculation status, and the
forbidden combination has no constructor**: effect-capable tools enter a
grant only through a declared-idempotence witness on the template, and the
speculative grant type simply lacks the case for non-idempotent effects —
so "a speculative node ran a non-idempotent effect" is not a policy
violation the dispatcher catches, it is a grant nobody can build
(`30-channels.md` § event taxonomy owns the taxonomy; F12/F15 in
`80-validation.md` assert the unconstructibility). An agent requesting an
action outside its grant gets a typed refusal in-band (a tool error it can
read), never a silent no-op — agents route around obstacles they can see;
the refusal is the runtime *edge* of a boundary whose interior is
compile-time.

## Drift notes at yield

Between tool calls, a speculative node may receive **drift notes** —
compact renderings of invalidations that passed its footprint filter
(`30-channels.md` § check-on-yield): the address, the diff class, the schema
diff or delta summary. The note ends with the routing the scheduler already
decided (continue / patch-then-continue / stop-cleanly), so the agent never
guesses its own fate. A stop-cleanly note is the humane form of squash for
an agent mid-turn: finish no further work, emit nothing; the worktree drop
does the rest.

## Model pins

**Every template pins its model; pins move deliberately, never implicitly.**
A pin is (provider, model id, sampling config, prompt-affecting options),
recorded in the theory. The planner template pins the strongest available
model; worker templates pin per task shape. A pin bump is a first-class
ledger event and resets the shape's predictor counters (survival history is
per pin — a new model is a new speculation regime; regime honesty,
`README.md` rule 6). **Decision.** **Alternative:** auto-upgrade to the
provider's latest — lost because the predictor's history silently stops
describing the executor generating the outcomes, corrupting port priority
and the churn detector's evidence — the harness would be measuring one
machine and scheduling another. **Reverses if:** never for silent upgrades; a
*supervised* upgrade lane (shadow-run the new pin on completed shapes,
compare, then bump) is the recorded growth path.

## The planner

The planner is an agent template like any other, distinguished only by its
contract: its head tuples are a **theory** (relations, statements,
templates, pins — the meta-catalog is just more catalog). The operator can
also write theories by hand (`70-api.md`); the planner exists so "here's a
spec, build it" is one invocation. Planner outputs pass the same admission
judgment as hand-written theories (weak acyclicity, acceptance gate, schema
lint) — **the planner earns no trust the operator doesn't have.** A rejected
theory returns to the planner with admission diagnostics through the
standard repair lane. Reader: admission (`10-theory.md`), which sees no
difference; the falsifier suite, which fuzzes admission with
planner-shaped garbage (`80-validation.md`).

## OPEN items

- **Template library.** Refuter, implementer, summarizer, finder templates
  will repeat across theories verbatim. Same trigger as theory composition
  (`10-theory.md`): the second real pipeline that hand-copies them.
- **Context budget management for long nodes.** A node whose agent
  approaches its context ceiling mid-work has no story yet beyond faulting.
  Candidate: a declared checkpoint contract (the node emits partial head
  tuples and a continuation tuple; the chase fires a successor). *Trigger:
  the first fault attributed to context exhaustion in a real pipeline.*
- **Provider abstraction.** Deleted vocabulary until a second provider is
  wired (`00-product.md`); the pin record's provider field is the only
  provision. *Trigger: the second provider.*
