# RS AI Doc v0.1.12 - Compatibility and Live Acceptance

## Package and current flow

This ZIP is the complete rs-aidoc resource derived from the supplied Codex-modified ZIP, with the proven animation choreography restored from the separately supplied older working ZIP. Conscious treatment, mouth movement, AIDOC plate, road navigation, payment journal and medical verification remain included. Back up the resource and the server KVP journal before replacing it.

`/medic` -> server validates injured/down state, EMS availability and funds -> server-created doctor and AIDOC ambulance -> client drives/approaches -> server checks exact responder IDs, model, bucket and nearby doctor position, with a bounded ambulance/patient corroboration path for stale server doctor coordinates (not transient owner) -> fee billed once -> diagnosis -> kneeling examination and timed CPR animation for both patient modes -> server rechecks current medical state -> Qbox Heal or provider Revive/native heal -> server checks medical result -> departure/cleanup.

Patient eligibility includes non-dead players with missing HP (5 or more by default) or Qbox bleeding/limb injuries. Full-health healthy players are rejected. `Config.RequireDead = true` optionally restores down-only calls. The server enforces treatment timing and may escalate an injured patient's treatment to revive if the patient dies during the procedure.

For living patients, Qbox uses the documented `exports.qbx_medical:Heal(src)`. QBCore/ESX/standalone use a server-initiated client native heal which restores ped HP but does not promise to clear custom framework bleeding/limb-injury states. Medical provider effects and recorded changes require live confirmation. Dead/laststand patients still use the matching framework's existing revive adapter and confirmation handshake.

Dr. Graves' mouth is animated with a GTA facial animation while audio plays; NUI audioStarted and audioEnded events prevent untimed looping. Facial movement is not perfect word-by-word lip-sync. The infected model may not support all facial blend animations.

## Providers and ownership

| Stack | Medical action for dead/down | Medical action while conscious |
|---|---|---|
| Qbox | `qbx_medical:Revive` | `qbx_medical:Heal` |
| QBCore | `hospital:client:Revive` | Native HP restore (custom injuries require adaptation) |
| ESX | `esx_ambulancejob:revive` | Native HP restore (custom injuries require adaptation) |
| Standalone | Native revive | Native HP restore |

Enable OneSync. Treatments still validate server-created responder entities, net IDs, ped/vehicle models and routing bucket. Server doctor position remains the primary distance check; if client/server ped positions disagree, the narrow fallback also requires the original ambulance near the patient according to the server, client/patient coordinate agreement, and the expected doctor net ID. Treatment completion rechecks the original entity plus the patient's approved location. `NetworkGetEntityOwner` is diagnostic only because ownership may migrate during the mission.

## Payment Journal

Resource KVP key: `rs_aidoc_settlements_v1`. Each paid intent contains a stable
character identity, account, amount, session ID, timestamps, state and reason.
Never remove this data just to permit another call. Back up the server KVP store.

- Write/readback of intent must succeed before a money mutation is requested.
- Refunds require the original online character. A source reused by another
  character cannot receive that credit. Qbox mutators use the original citizen ID.
- A confirmed paid session interrupted before medical dispatch becomes
  `refund_due`; reconciliation runs on resource startup, Qbox player load and
  subsequent dispatch requests. It does not automatically mutate offline players.
- `charging`, `refunding` and `reviving` interrupted by restart become `review`.
  An uncertain provider return or dispatched-but-unobserved revive also requires
  review. Do not blindly repeat debit/credit or refund a possibly delayed revive.
- Pending entries block a new paid session for that character. Definitive debit
  rejection may use a different funded account; ambiguous results never do.
- This is a recovery journal, not an atomic transaction shared with the framework.
  A crash between provider mutation and receipt needs provider-history review.
  ESX concurrent balance changes can also make delta confirmation ambiguous.

Server console only:

```text
aidocsettlements
aidocsettle <review-id> refund
aidocsettle <review-id> complete
```

First verify the named original character's bank/cash history and medical outcome.
`refund` explicitly confirms a debit happened and reimbursement is still owed;
it queues credit for that character, including when they are currently offline.
`complete` closes an already-settled outcome or a proven non-charge without moving
money. Do not use `refund` when a prior credit already succeeded. These commands
only act on `review` entries; resolved entries cannot be replayed through them.

## Medical Confirmation and Progress

Positive health alone is not revival: downed Qbox peds may already have positive
health, and the server Revive export clears medical metadata before the client
completes recovery. Success now requires a nonce/token-bound observation from the
current patient's client, the expected provider event and independent server
alive-state checks. Qbox observation also waits for full health, IsDead/IsLaststand
false and invBusy=false. This is a functional handshake, not proof that an
untrusted client ran a particular animation.

The server allows eight seconds after medical dispatch. Missing confirmation
records review because delayed recovery may still occur. Only a definite provider
rejection before dispatch follows automatic refund handling.

The local progress adapter uses the installed `progressbar` export with
useWhileDead=true. It falls back to a native on-screen bar when absent/busy and
preserves minimum treatment time. Cleanup cancels only its active provider bar;
an already-finished bar does not cancel a later unrelated operation.

## Install and Live Gate

1. Back up resource files and KVP storage. Stop `rs-aidoc` when no rescue is active.
2. Replace the resource using the full `rs-aidoc` folder in this ZIP, preserving any custom local settings with a careful merge. Start the core and matching medical resource first.
3. Leave Config.UseExternalBridge=false. Enable OneSync; start progressbar first
   when installed. Run `refresh`, then `restart rs-aidoc` (or `ensure` if stopped).
4. Use `/aidocdiag` in the **client F8 console** during a rescue to check the animation and GPS stages; the **server console** also has a separate `aidocdiag` diagnostic. Check startup errors and pending entries
   with `aidocsettlements`; enable Config.Debug temporarily for acceptance.
5. On two real clients, test a conscious injured player (e.g., HP 150/200), Qbox bleeding at full HP, laststand and full death **separately**: `/medic` -> ambulance drives to a nearby road -> Graves approaches -> `amb@medic@standing@tendtodead@base/base` -> `mini@cpr@char_a@cpr_str/cpr_pumpchest` (with configured alternatives) -> heal or revive -> one $500 charge -> correct medical state -> Graves stands, runs back, boards and drives away -> safe entity cleanup. Confirm the CPR animation runs continuously throughout the progressbar, including after interrupted scripts or an animation reset.
   Verify the ambulance reads AIDOC and the doctor's face moves while each recorded line is actually playing. Test an uninjured patient is denied free of charge.
6. Test blocked roads, blocked ambulance doors, roof/interior/water positions, both relocation attempts, waypoint updates when the player moves, a blocked car for multiple 4-second GPS stalls, and a 20–40m on-foot walk back to the ambulance,
   lost ownership, bucket changes, forged early/duplicate events, insufficient
   funds, protected Qbox cash and real progressbar busy/cancellation behavior.
7. Test logout/switch/reconnect, source reuse, restart before payment/after payment/
   during revival, provider interruption, delayed revival and refund interruption.
   Inspect pre/post balances and the journal. Resolve review only after checking
   provider history; confirm no duplicate charge or refund on another restart.

## Verification Boundary

All 13 Lua chunks passed static syntax compilation using LuaTeX loadfile and NUI JavaScript passed node --check. Two additional isolated mocked animation start/fallback cases passed, with a static check of the non-blocking alignment flow. Older Codex mock counts have not been rerun for this patch. All supplied OGG clips are retained. The changed config is intentional and requires a careful merge for existing installations.

No live restart, FiveM/CEF, OneSync two-client, production database or Legacy/
Enhanced acceptance was performed. Do not treat simulated success as a complete
release certification, particularly for QBCore, ESX or a custom external bridge.

## 10-14-2026 — Regression details

The previous Codex build could refuse to start the kneeling clip because a hand-bone index or an exact nearby ped-safe coordinate was missing. It also rejected CPR if the two hand bones were too far from the projected chest. Those checks are no longer treatment gates. The first usable animation clip now takes priority, rather than a perfect positional calibration; the existing animation-monitor thread retries when a task is interrupted. Use `/aidocdiag` and F8 to confirm the actual playing clip during kneel and CPR. An attempted clip without a confirmed native playback state no longer aborts an authorized rescue; a warning and retry is used. These are static/mock-verified repairs and remain unverified in a FiveM session.

## 10-14-2026 — v0.1.13 facial-only regression check

A mouth-animation update must not alter treatment authorization, position,
patient state, medical provider or departure code. Compare hashes of unchanged
Lua/NUI/OGG assets to v0.1.12; validate all Lua syntax and NUI JavaScript;
exercise audioStarted/audioEnded/Stop/SetSpeaker cancellation with a mocked
facial native and failing network ownership; then visually inspect the zombie
model during dispatch, arrival, examination and CPR in live FiveM.

Use `aidocdiag` without `/` in F8: `faceRequested=true` indicates that a
voice clip is eligible for a facial animation. Enable `Config.Debug = true`
to see whether the mouth animation native was requested successfully. Neither
diagnostic proves that the model shows visible jaw movement.
