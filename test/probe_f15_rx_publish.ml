(* F15 negative probe — publishing on a reader end MUST NOT typecheck.

   Law: channels are unidirectional by construction, not by check — the
   reader end ([rx]) has no publish operation, the writer end ([tx]) has no
   pull operation, and no function converts between them
   (docs/architecture/30-channels.md § the unidirectional law;
   lib/channel.mli). F11 sweeps the runtime surface for any backchannel;
   this is the compile-time edge of the same law, which 80-validation.md
   F15 covers under "every state these docs declare unrepresentable has a
   negative compilation test".

   The probe hands the only publish operation in the module an [rx]. The
   two ends are distinct abstract types, so this is a type error — not a
   refused call.

   Legal twin: [drain] and [publish_on_tx] in probe_control.ml. *)

open Goatcode

type finding

(* ILLEGAL: [publish] takes the writer end; an [rx] is not one. *)
let probe (r : finding Channel.rx) ~(id : finding Id.t) (v : finding) =
  Channel.publish r ~id v
