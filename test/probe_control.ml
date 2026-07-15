(* F15 harness control — this file MUST compile.

   Every negative probe in this directory is compiled with exactly the same
   command as this file (ocamlfind ocamlc against the library's cmis). If
   this control ever stops compiling, every negative probe would "fail to
   typecheck" for a spurious reason (broken include path, missing package)
   and the suite would be green on garbage. The control pins the harness:
   negative probes fail because the LIBRARY refuses them, not because the
   compiler never saw the library (docs/architecture/80-validation.md F15).

   Each value below is the LEGAL twin of one negative probe: the same
   boundary, approached from the permitted side. *)

open Goatcode

type finding
(* A phantom payload realm, standing in for a relation payload type. *)

(* Legal twin of probe_f15_wrong_relation_ref.ml: a ref slot filled with an
   id of the SAME realm typechecks. *)
type verdict = { subject : finding Id.t }

let well_typed_ref (id : finding Id.t) : verdict = { subject = id }

(* Legal twin of probe_f15_unadmitted_theory.ml: [Run.exec] applied to a
   [Theory.admitted] — the only theory type the engine surface mentions —
   typechecks. *)
let exec_admitted ~(theory : Theory.admitted) ~(config : Run.config) =
  Run.exec ~theory ~seed:[] ~config

(* Legal twin of probe_f15_bare_switch.ml / probe_f15_forged_churn.ml: a
   switch thrown WITH ledger-derived churn evidence typechecks. *)
let switch_with_evidence (m : Speculate.Churn.measurement) : Speculate.Switch.t
    =
  Speculate.Switch.throw ~evidence:m ~thrown_by:`Operator

(* Legal twins of probe_f15_nonidem_speculative.ml and
   probe_f15_nonidem_in_grant.ml: an IDEMPOTENT effect tool is grantable
   under either index (squash-safe by declaration), and the non-idempotent
   case exists under the [committed] index. *)
let speculative_idempotent () :
    Agent.Grant.speculative Agent.Grant.Effect_tool.t =
  let w =
    Agent.Grant.Idempotence.declare ~tool:"opam_install"
      ~why:"re-runnable install: same inputs, same store"
  in
  Agent.Grant.Effect_tool.idempotent ~name:"opam_install" w

let committed_non_idempotent () :
    Agent.Grant.committed Agent.Grant.Effect_tool.t =
  Agent.Grant.Effect_tool.non_idempotent ~name:"deploy_to_prod"

let speculative_grant_with_idempotent_effect
    (grant : Agent.Grant.speculative Agent.Grant.t) :
    Agent.Grant.speculative Agent.Grant.t =
  { grant with Agent.Grant.effects = [ speculative_idempotent () ] }

(* Legal twin of probe_f15_speculative_into_committed.ml: committed state is
   READABLE by anyone; only the write path is engine-only. *)
let read_committed (c : Retire.Committed.t) = Retire.Committed.tuples c

(* Legal twin of probe_f15_rx_publish.ml: pulling on an rx and publishing on
   a tx — each end used for the one thing it can do. *)
let drain (r : finding Channel.rx) = Channel.pull_tuples r

let publish_on_tx (t : finding Channel.tx) ~(id : finding Id.t) (v : finding) =
  Channel.publish t ~id v

(* Legal twin of probe_f15_wrong_payload_publish.ml: a tx obtained by
   presenting the relation's own declaration carries that relation's
   payload type, and its own payload publishes through it. *)
let publish_via_registry (registry : Channel.registry)
    (r : finding Theory.Relation.t) ~(id : finding Id.t) (v : finding) =
  Channel.publish (Channel.tx registry r) ~id v

(* Legal twin of probe_fl1_generation_retreat.ml: the generation
   vocabulary moves forward — [next] typechecks; no retreat exists. *)
let forward (g : Ledger.Generation.t) : Ledger.Generation.t =
  Ledger.Generation.next g
