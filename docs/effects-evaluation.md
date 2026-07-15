# OCaml 5 effects — the language-test report (NON-NORMATIVE)

Written for the substrate decision (`00-product.md` § substrate decision;
the operator effects ruling, `executor-campaign.md`). This is an evidence
file, not an architecture doc: it records what the effects port of the
fiber substrate (`lib/fiber.mli`/`fiber.ml`, `Http.Multi`,
`test/test_fiber.ml`) actually bought, every sharp edge the code hit, and
what that implies for the recorded Rust-port trigger. The ruling has
landed: the adoption is a Decision block in `40-scheduling.md`
§ read-time binding, and `00-product.md` § substrate decision names this
file as the evidence the port decision consults — this file stays as
that linked evidence record (folding it inline would bloat a normative
doc with narrative history, which doc rule 5 bans). Honest verdict at
the end.

## What was built

A single-domain cooperative fiber scheduler as a Deep-handler evaluator
over a three-instruction typed vocabulary:

```ocaml
type _ Effect.t +=
  | Read : Ledger.Address.t -> Operand.t Effect.t
  | Yield : Speculate.Drift.note list Effect.t
  | Http_post : Http.Request.t -> (int * string, Http.error) result Effect.t
```

Ready queue (FIFO), parked table keyed by the awaited address, in-flight
table keyed by transfer token; when nothing is ready and transfers are in
flight the loop drives curl-multi (`Http.Multi`, the async lane beside the
untouched blocking `post_json`). External `wake ~key` resumes exactly the
fibers parked on the address an invalidation names; `squash` discontinues
with a dedicated exception so `Fun.protect` finalizers (worktree cleanup)
run. Falsifiers FB1–FB7 hold all of it: park/wake value delivery, squash
inescapability, Stop_cleanly-by-discontinue, overlap asserted on
interleaving order, wake-twice as a counted no-op, rogue-effect
containment, and one hermetic loopback test through real curl-multi.

## What effects bought

**Versus the blocking v0** (`run.mli` "Blocking in v0"): overlap. The
blocking engine can hold N provider calls open only by burning N threads
or serializing; here N calls overlap on one domain with zero preemption
(FB4/FB7 assert both transfers in flight before either completes). Equally
material: chase.ml's parking story stops being simulation. Today
`dispatch_node` re-reads *all* operands per attempt, parks whole
instances, and retirement requeues the entire parked list; on the
substrate the read itself parks mid-flight and `wake` resumes exactly the
address that changed. The scheduler's mid-run state became *printable*
(`dump`: ready / parked-on / in-flight / settled) where the blocking
engine has only a call stack.

**Versus Lwt**: no monadic coloring. The fiber body is direct-style OCaml
— `let operand = Fiber.read addr in ...` — so the agent tool loop and the
chase dispatch keep their straight-line shape; under Lwt every function
between the loop and the suspension point would return `'a Lwt.t` and the
whole engine recolors. Cancellation is also strictly better here:
squash-by-discontinue unwinds the fiber's real stack, so ordinary
`Fun.protect` is the cleanup mechanism (FB2), where Lwt cancellation is a
separate, half-deprecated protocol.

**Versus Eio**: Eio is these same effects plus somebody else's scheduler.
This project's scheduler *is* the product (deterministic, inspectable,
ledger-ordered, the chase's port/priority policy); a 350-line evaluator we
own outright beats importing a general-purpose runtime we would spend the
integration fighting. Also: no new dependencies was a ground rule, and
stdlib `Effect` + installed ocurl met it.

## Sharp edges actually hit

Every one of these bit during this port; code references are to the
commits landing with this file.

1. **Untyped effects — nothing in a signature says what a function
   performs.** `val read : Ledger.Address.t -> Operand.t` is
   indistinguishable from a pure function; the only place the vocabulary
   exists is the `type _ Effect.t +=` declaration itself. The mitigation
   is discipline-as-documentation (fiber.mli centralizes the vocabulary
   and says so); the type checker contributes nothing. A computation
   performing an effect outside the vocabulary is a *runtime* fault: FB6
   exists because the compiler cannot.

2. **`Effect.Unhandled` at runtime.** A perform with no handler raises at
   the perform site. Hit twice: (a) the rogue-effect case — contained in
   the handler's `exnc` as a typed `Ledger.Fault.t` (fiber.ml, the
   `Effect.Unhandled _, _` branch), which is the best available answer
   and still only a runtime answer; (b) `Fiber.read` called outside any
   scheduler raises the same way — the mli documents it because no type
   can.

3. **The GADT answer type escapes its scope when a continuation is
   stored.** First attempt at holding a continuation was
   `held := Some k` into a `ref None` — rejected with "this instance of
   int is ambiguous: it would escape the scope of its equation". Inside
   `effc (fun (type b) (eff : b Effect.t) -> ...)` the equation
   `b = Operand.t` exists only within the match branch, so every table
   that stores a continuation must be monomorphic in the answer type
   (`parked_tbl : (... * Operand.t Once.t) list`) or carry an existential
   pack (`Resume : id * 'a Once.t * 'a -> ready_entry`). Mechanical once
   learned; invisible until the compiler refuses.

4. **One-shot continuations are a runtime-only guarantee.** A second
   `continue` raises `Continuation_already_resumed` (verified on this
   switch before writing fiber.ml). Nothing in
   `('a, 'b) continuation`'s type says one-shot; linearity is exactly
   what the type system doesn't track. The substrate's answer is
   structural: continuations never cross the API (`wake`/`squash` are the
   only resume paths), and internal custody goes through a take-once cell
   (`Once` in fiber.ml) so a would-be double resume is a `None` branch,
   not a crash. FB5 falsifies the surface. This wrapper is pure
   defense-in-depth against our own scheduler bugs — the language makes
   the mistake representable, so the module has to make it unreachable.

5. **`discontinue` + finalizer interactions — good news, with one trap.**
   `Effect.Deep.discontinue k Squash` runs `Fun.protect` finalizers on
   the fiber's stack (FB2, verified in a probe before the port; the
   operator ruling recorded the same). The trap: a fiber may *catch* the
   squash exception — discontinue is just a raise from the suspension
   point — so "squashed" as a convention is escapable. The substrate
   closes it by making squash scheduler state (`squash_mark`): every
   subsequent perform discontinues again and a swallowed return still
   settles `Stopped` (FB2's escape-artist fiber). Without that mark, an
   agent-loop fiber catching exceptions broadly (repair lanes do) would
   survive its own squash.

6. **`effc`'s typing shape forces duplication.** The squash-mark check
   appears once per vocabulary constructor because the refined answer
   type `b` exists only inside each branch — a helper
   `check_squash : (b, _) continuation -> ...` cannot be written
   polymorphically over the branches without another layer of packing.
   Tolerable at three instructions; it scales linearly with the
   vocabulary.

7. **The event lane's one real bug was FFI identity, not effects.** The
   first FB7 run spun at full CPU forever (82M scheduler iterations in
   15s, `perform`'s running count dropping 1→0, `remove_finished`
   forever `None`-shaped from the caller's view). Root cause, found by
   bisecting down to a raw-ocurl probe: `Curl.Multi.remove_finished`
   returns the finished transfer as the same C handle in a *different
   OCaml block* (curl-helper.c: "NB: same handle, but different block"),
   so resolving completions by physical equality silently drops every
   one — and `curl_multi_wait` on an emptied stack returns instantly,
   which is the spin. Fix: the token rides the handle itself
   (`CURLOPT_PRIVATE`), recorded as a comment at the site (http.ml).
   Worth recording here because the failure *presented* as a scheduler
   bug and cost the port its only real debugging session; the effects
   machinery was innocent. A collateral improvement: FB7's loopback
   server is pumped from the test transport's own `poll` — single
   threaded, one domain, the same discipline the scheduler asserts —
   rather than riding a systhread beside it.

8. **OxCaml specifics: none.** The 5.2.0+ox switch compiled stock
   `Effect`/`Effect.Deep` code unchanged — no mode annotations demanded,
   no stack-allocation interaction surfaced, `match_with` handler records
   and locally abstract types behaved as on vanilla 5.2. (The switch's
   sharp edges so far are all ppx-side — `ppx_deriving_jsonschema`, the
   recorded wound — not effects-side.) One non-effects footnote from this
   work: the worktree must build with `dune --root=.`, since dune
   otherwise ascends to the outer checkout.

## Implication for the Rust-port trigger

**Effects do not port.** Rust has no analogue of resumable,
direct-style, one-shot delimited continuations. The Rust translation of
this scheduler is one of exactly two shapes:

- **async/await**: each fiber body becomes an `async fn`; `Read`/`Yield`/
  `Http_post` become awaits on scheduler-owned futures; the executor is a
  hand-rolled single-threaded runtime polling in ready-queue order.
  Squash maps surprisingly well — cancellation is dropping the future,
  and `Drop` impls are the finalizers — but the coloring is total: every
  function between the agent loop and a suspension point becomes async,
  which is precisely the Lwt shape effects avoided. Determinism needs the
  same care (a custom executor, not tokio).
- **explicit defunctionalization**: each fiber is an enum of its resume
  points and the scheduler matches on it. That is what `chase.ml`'s
  parked-instance list already is — the blocking engine is the
  defunctionalized version of this substrate — and it is exactly the
  representation the mli's park-the-read-itself story exists to delete;
  at agent-loop granularity it stays coarse (park the whole turn, re-read
  operands on resume) because nobody hand-writes resume points inside a
  tool loop.

So the honest reading for the ruling: the *semantics* port cleanly
(park/wake/squash/overlap are all expressible in async Rust, with Drop
even improving the squash story), but the *ergonomics* do not — Rust
buys back monadic coloring, and the direct-style agent loop is the one
thing lost. That cost is bounded: it is confined to this one file's
worth of scheduler plus the executor loop's signatures, not smeared
through the theory/ledger/contract layers, which stay control-flow-free
by design. Nothing learned here blocks either recorded port trigger.

## Verdict

Effects earned their keep here — overlap without threads, squash with
real finalizers, no coloring, a scheduler small enough to own — and the
evaluation also confirms the feature's known character: all of its
guarantees are dynamic. Untyped performs, runtime Unhandled, runtime
one-shot enforcement, escapable discontinue — four places this port had
to build discipline (a documented vocabulary, exnc containment, the
`Once` cell, the squash mark) where the rest of this codebase gets to
use types. The representation doctrine survives, but at this one layer
its enforcement is tests (FB1–FB7), not construction. For the substrate
decision: effects are a real, measurable OCaml advantage at exactly one
seam — direct-style agent fibers — and a bounded loss everywhere the
Rust port would pay it.

## Recorded amendment owed (doc rule 4 handoff) — DISCHARGED

`run.mli`'s `exec` comment read "Blocking in v0; the fiber substrate is
an implementation fact." The integration pass (the wave-2 tail) mounted
the chase on `Fiber` and amended that sentence in the same change, with
the wording recorded here: runs on the cooperative fiber substrate —
reads park mid-flight, provider calls overlap on one domain, squash
discontinues; still one process, one domain. What the mount confirmed
beyond the substrate's own falsifiers: the synchronous engine's whole
trace reproduced exactly under the fibers (zero expect diffs on the
pre-existing suite — the blocking engine really was the defunctionalized
version of this scheduler), and the three new engine-level falsifiers
(FM1 overlap through the real Messages encoder, FM2 mid-flight squash
with `Fun.protect` worktree cleanup, FM3 wake-exactly-the-address) hold.
`40-scheduling.md` § read-time binding now names the mount normatively.
