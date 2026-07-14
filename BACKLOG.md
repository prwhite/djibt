# Backlog — Cam Control for DJI Osmo

Deferred ideas / enhancements, parked intentionally. These are not bugs.

## GPS push idle-rate optimization
Push GPS at **1 Hz when a camera is not recording, and ramp to the selected rate
(e.g. 10 Hz) only while *that* camera is recording** (per-camera). The high rate
only matters for fast-motion geotag fidelity *during* recording; idle 10 Hz is
wasted BLE bandwidth — more so multi-cam, where many cameras share one radio.

Notes / constraints:
- The DJI ESP32 reference does **not** gate GPS push on recording (it pushes on
  connected + valid-fix only). Continuous push at an idle baseline is *required*
  so the camera's own GPS-ready indicator stays lit and the fix is fresh at
  record-start — so this is a **rate** optimization, never on/off.
- Only worth it if 10 Hz multi-cam is a real usage pattern. At the 1 Hz default
  the idle cost is negligible (one 48-byte frame/sec/camera).

## GPS send-health: 3-region sparkline (show Void)
Today Void frames (sent when the fix is stale/off) still record as *sent* → the
per-camera GPS send-health sparkline reads **green** during a stale state, which is
mildly misleading (the top-bar dot is honest, so it's low-impact). Make the bar a
3-region stacked column: **green** = real fix delivered, **red** = real fix the BLE
link dropped, **gray** = Void / no real GPS. Two sizings:
- **Cheap:** stop counting Void frames as sends → a fully-Void second falls to the
  existing nil/gray bucket. Gets green/red/gray for the common case (a second is
  ~always all-real or all-void) with no model change. Misses the 3-way split in the
  rare transition second.
- **Full:** track a per-second `{sent, skipped, void}` breakdown (replaces the
  `[Double?]` sent-fraction history) so a 10 Hz column can show all three regions at
  once. Keep one shared implementation for the row + detail views.
A per-sample GitHub-activity grid was considered and dropped (rate-dependent column
height fights the fixed-capacity layout; per-sample detail is illegible in the row).

## CoreBluetooth state restoration
With bluetooth-central, drop detection survives backgrounding — but not app
**termination** (iOS memory pressure). CB state restoration
(`CBCentralManagerOptionRestoreIdentifierKey` + willRestoreState) relaunches
the app for BLE events after termination, closing that last gap. Adds real
complexity (restoration callbacks, re-wiring connections); evaluate after
field experience with plain bluetooth-central.

## Other deferred polish
- **Sparkline accessibility:** the RSSI + GPS send-health Canvas sparklines have
  no VoiceOver labels.
- **Watch recording indicator:** an aggregate breathing record dot driven by the
  already-relayed `isRecording` (optionally relay a representative recording
  duration too). Parked.
- **Detail "Last Seen" for sleeping cameras:** the climbing counter reads like
  staleness when the camera is just napping (connected-sleep, status goes quiet);
  could relabel/suppress for `.sleeping`.
- **Small-device layout stress-test:** verify the camera row (long name +
  telemetry stack) on SE-class screens and large Dynamic Type sizes.

## Osmo Pocket cameras — investigated, NOT viable over BLE (closed 2026-06-14)
Researched + ran a hardware PoC on an Osmo Pocket 3; the conclusion applies to the
Osmo Pocket line (same gimbal + Wi-Fi app architecture). **Dead end for this app's
model.** Pocket cameras speak classic DUML (`0x55`) and over BLE pair + stream
telemetry only — **capture/record/photo/gimbal are WiFi-gated** (canonical capture
opcodes `0x01/0x01`, `0x01/0x02`, `0x01/0x7c` sent over BLE got zero camera
response; two Mimo BLE sniffs showed no Pocket control traffic; reproduces
lib-osmo-ble's gimbal "needs WiFi" finding; confirmed the phone joins the camera's
Wi-Fi AP during Mimo use). WiFi-gated control is incompatible with the core
**simultaneous-multi-camera-over-BLE** model (one AP / one camera at a time), so
Osmo Pocket cameras are **not controllable devices here** — they'd be a separate
single-cam WiFi app. The Action 4/5 + 360 family (R-SDK `0xAA`) is unaffected;
BLE control there works and ships. Don't re-investigate without new evidence that
DJI exposes Pocket capture over BLE. Full writeup + PoC:
`docs.nogit/pocket3-feasibility-and-architecture.md` §12 (gitignored).

## Field report — 13-camera TV commercial shoot (2026-07, NZ operator)
Freelance camera op ran the app across a 2-day shoot: **~10 cameras controlled
simultaneously without issue** (mix of Action 4 / Action 5 Pro / one Osmo 360 / a
newer resolution-missing body). Core loop — cut-and-roll between takes + glanceable
card/battery/rec state — validated in the field; fast relink after out-of-range
praised unprompted. The items below are **candidates from that report — not
committed**; several may not be worth doing.

### Fleet-scale dropout notifications (candidate)
At 10 cameras with cars driving out of range, per-drop alerts were constant noise →
operator turned notifications **off entirely** (losing the drops that actually
matter). Leading idea: a sub-pref to notify **once per camera per session** rather
than on every drop — cheaper and less clutter than expected-vs-unexpected
classification. Alternatives (rate-limit, per-camera mute, global quiet mode) noted
but heavier.

### Live Activity at fleet scale (candidate — likely not worth)
The LA shows only the **top camera** in the list; at N=10 that's near-useless. A
fleet-summary LA ("8 rec / 2 idle / 1 low batt") was floated, but the read is that
**multi-camera status in the LA clutters fast** and may not earn its place. Park
unless the LA is reworked anyway. The single-camera limitation was the operator's
actual reason for disabling it.

### Live Activity teardown while backgrounded (investigated — not a bug)
Operator saw the lock-screen LA "there even when I exited the app." Lifecycle
(`CameraActivityController`) is driven by a **1 Hz foreground timer**: starts on ≥1
`.connected` camera, ends 30 s (`endAfterDisconnectedTicks`) after the connected
count hits 0 (`.immediate` dismissal), `staleDate` 120 s dims stale content. A
`.sleeping` camera does **not** count as connected, so an all-sleep rig correctly
starts the 30 s end countdown. **The gap:** that logic only runs on the foreground
timer — if the rig goes down while the app is backgrounded/killed, the auto-end
can't fire, so the LA freezes, dims at 120 s, and lingers until the app is reopened
(timer resumes → 30 s → end) or iOS reaps the stale activity. This is
**ActivityKit-by-design persistence + foreground-only teardown, not a CoreBluetooth
leak** (sleep drops the count; disconnect drops the count). Optional fix:
event-driven teardown (end on connected→0 from the state change, not just the tick)
so a backgrounded sleep/disconnect dismisses it promptly; relates to the
**CoreBluetooth state restoration** item above. Low priority unless the LA is kept
as-is.

### MIMO coexistence — surface "in use by another controller" (candidate)
Confirmed on set: a camera bound to DJI Mimo (for the live-video rig) is **invisible
to this app until disconnected** — the hard BLE one-controller-per-camera limit, not
a bug. Candidate: an in-app hint ("in use by another controller") instead of the
camera silently not appearing, plus documenting the boundary. Cameras feeding a
live-video path genuinely can't also be ours.

### Help-site FAQ material (for the planned help site)
Real-user FAQ fodder from the same report: (1) **one controller per camera** — Mimo
and this app can't share a camera; (2) **put Mimo on 5.8 GHz, not 2.4 GHz** — 2.4 GHz
Wi-Fi contends with our 2.4 GHz BLE and made *both* laggy (operator confirmed 5.8
fixed it). Feed into the help/support page.
