(* F15 negative probe — publishing a wrongly-typed payload through a
   correctly-named relation MUST NOT typecheck.

   Law: a channel end carries the payload type of the admitted relation it
   was opened for, recovered from the name-keyed registry by the relation's
   own payload witness — never by a cast
   (docs/architecture/30-channels.md § pre-opened channels; lib/channel.mli
   [tx]). A re-declaration that shares the NAME of an admitted relation is
   the B12 attack: before the witness, the registry handed it a channel end
   at the admitted type through an unchecked cast (heap corruption from
   safe code). Now the end it yields is typed by the relation VALUE
   presented, so the admitted payload cannot flow through it.

   The probe holds a same-named re-declaration at another payload type and
   tries to push the admitted relation's payload through the tx it obtains.
   The two payload realms are distinct abstract types, so this is a type
   error — not a refused call. (The value-level half — a re-declaration at
   even the SAME payload type is refused at the registry by the witness
   judgment — is the runtime falsifier in test_boundary.ml.)

   Legal twin: [publish_via_registry] in probe_control.ml. *)

open Goatcode

type finding
(* The admitted relation's payload realm. *)

type not_finding
(* A re-declaration's payload realm; the relation NAME may collide, the
   type does not. *)

(* ILLEGAL: [Channel.tx registry forged] is a [not_finding Channel.tx];
   the admitted payload cannot be published through it. *)
let probe (registry : Channel.registry)
    (forged : not_finding Theory.Relation.t) ~(id : finding Id.t)
    (v : finding) =
  Channel.publish (Channel.tx registry forged) ~id v
