# GPS UI & Plumbing — Design

**Date:** 2026-06-09
**Status:** Approved (brainstorm)
**Context:** Follow-up after PRs #2 (GPS video telemetry) and #3 (mode/UI) merged. Replaces the contributor's per-camera `GPSStatusBadge` with a correct phone-global fix indicator, adds a user-selectable push rate, per-camera GPS *send health* (honest proxy — see terminology note below), a watch GPS indicator, and a build-path refactor. All converge on one source of truth in `OsmoLocationManager`.

## Background / problem

- GPS *fix quality* is a property of the **phone**, but the merged `GPSStatusBadge` rendered it per-camera in `CameraDetailView`, binding phone-global values (`accuracy`, `lastPushAt`) plus one per-camera flag — conceptually muddled, and it showed green "GPS on" even with no valid fix (`accuracy == nil` fell through to green).
- The validity rule (`horizontalAccuracy >= 0`) was re-derived ad hoc in the view; the satellite-gate and early-return guard each had their own copy.
- Push rate was a hardcoded `Timer` interval (0.1s) — PR #2's contentious 1→10 Hz change. Making it a user setting neutralizes the argument.
- GPS *send health* (does each BLE link keep up with our writes) is genuinely per-camera and uneven (connection-event scheduling throttles some links, not all — see pr-review.nogit/pr-2.md §3) but is currently invisible. (Can't measure true *delivery* — `.withoutResponse` has no ACK; see terminology note.)
- `GPSPushCommand.build` runs per-camera though only `seq` differs across cameras — redundant builds/CRCs.

## Keystone: `OsmoLocationManager` as single source of truth

The manager owns all GPS *behavior* and *state*; every consumer reads from it.

```swift
enum GPSFixState { case off, noFix, good }   // gray / red / green

// OsmoLocationManager (additions / changes)
var rateHz: Int { didSet { persist(rateHz); if isActive { restartTimer() } } }
var fixState: GPSFixState {
    guard isActive else { return .off }
    return (lastLocation?.hasValidGPSFix == true) ? .good : .noFix
}
var accuracy: Double? {            // for the Settings "±N m" readout
    guard let l = lastLocation, l.hasValidGPSFix else { return nil }
    return l.horizontalAccuracy
}
// existing: isActive, lastLocation, lastPushAt
```

- **`rateHz: Int`** (values 1 or 10; UI constrains to those two). Owns persistence: read from `UserDefaults` key `gps_push_hz` at **init** (next to the existing `gps_push_enabled` read), written in `didSet`. `didSet` invalidates + reschedules the push `Timer` at `1.0 / Double(rateHz)` when `isActive`. Default 1 if unset. This matches how `gps_push_enabled` is already owned (read in `App.init`, written by `SettingsView`).
- **`fixState`** computed — the one place "off/noFix/good" is derived. Top bar, watch relay, Settings readout all bind this.
- Auto-start path (`OsmoMultiApp.init` calls `start()` when `gps_push_enabled`) works with zero view involvement because the manager reads its own rate at init.

## Shared predicate (DRY, no layer inversion)

The duplicated thing is the *predicate*, not the state. One definition, in the framework, depending on nothing:

```swift
// DJIOsmoKit — CLLocation+Fix.swift
extension CLLocation {
    /// Single definition of "usable GPS fix": Core Location marks lat/lon
    /// invalid with a negative horizontalAccuracy.
    var hasValidGPSFix: Bool { horizontalAccuracy >= 0 }
}
```

Consumed by (each on the `CLLocation` it already holds — no manager state plumbed into the protocol layer):
- `OsmoLocationManager.fixState` / `accuracy`
- early-return guard in `pushGPSToAllCameras` (`guard let location = lastLocation, location.hasValidGPSFix`)
- satellite gate in `GPSPushCommand.build` (`location.hasValidGPSFix ? nominalSatelliteCount : 0`)

Also fix the #5 guard's debug message, which currently says "no location yet" even when the real cause is an invalid fix — split into two distinct guards/messages (no-location vs invalid-fix).

## `build()`-once-per-tick refactor (tweak c)

`pushGPS` currently calls `GPSPushCommand.build(location, seq)` per camera. Across cameras the **48-byte data payload is identical** (timestamp, coordinates, accuracy, satellite-validity byte — all location-derived); only `seq` differs.

**CRITICAL — the CRCs cannot be shared.** `seq` sits in the header (bytes 8–9), which CRC16 covers (SOF→SEQ, bytes 0–9) and CRC32 covers (whole frame). So a per-camera `seq` invalidates **both** CRCs — they MUST recompute per camera. Naively reusing a cached full frame and patching seq bytes would ship corrupt frames.

So the dedup is **two-phase**, and the only genuinely shared work is **payload encoding** (notably the `Calendar.dateComponents` timestamp decomposition):
1. **Once per tick:** encode the 48-byte data payload from `location` (the expensive/identical part).
2. **Per camera:** assemble header + this camera's `seq` + CRC16 + payload + CRC32 (cheap, but per-camera and correct).

Net saving is modest (≈one `Calendar` decomposition per camera avoided — ~9 calls/tick at 10 cams @ 10 Hz). Worth doing for tidiness; the value is correctness-of-framing, not perf. Likely shape: `GPSPushCommand.encodePayload(location) -> Data` + `GPSPushCommand.frame(payload:seq:) -> Data`, with `build(location:seq:)` kept as a convenience wrapper (`frame(encodePayload(location), seq)`) so existing callers/tests still work. Per-camera output must be byte-identical to today.

## Per-camera GPS *send health* instrumentation

**Terminology — we measure SEND health, not delivery.** GPS push is fire-and-forget (`.withoutResponse`): the camera never ACKs, so we **cannot** know what it received. What we *can* observe is whether our local CoreBluetooth stack accepted the write — `peripheral.canSendWriteWithoutResponse`. When the connection-event scheduler starves a link, `canSend` goes false and we skip. So green = **sent**, red = **skipped/throttled** (the link couldn't keep up); the readout is "GPS skipped: N/M," never "delivered." This is a genuine proxy for link health, honestly labeled. (Switching to `.withResponse` for real ACKs would ~double airtime + add latency, defeating 10 Hz — so we accept the proxy.)

- **`OsmoBLEConnection`**: expose readiness (`peripheral.canSendWriteWithoutResponse`) to the GPS send path. The GPS send checks it: ready → `write` (sent), not ready → skip + count (don't call `writeValue` blindly). A 1-deep `peripheralIsReady(toSendWriteWithoutResponse:)` drain is optional/deferred. The generic `write` stays unchanged — only the GPS send path (`sendGPSData`/`pushGPS`) consults readiness and feeds counters, not every frame type.
- **`OsmoCamera`** new state (buckets live here — data with the thing it describes; `CameraRowView` reads `camera.…`):
  - Session totals: `gpsAttempted: Int`, `gpsSkipped: Int` (drive the "skipped 30 / 1932 (1.5%)" readout). **"Session" = reset on each GPS `start()`** so the percentage reflects the current run, not lifetime.
  - Current open second (transient): `gpsSecondAttempts: Int`, `gpsSecondSent: Int` — accumulated as sends happen; snapshotted + reset by the 1 Hz tick.
  - `gpsSendHistory: [Double?]` (cap ~16, mirroring `rssiHistory`) — per-second **sent fraction**, with a crucial distinction:
    - `nil` = **no attempts that second** (GPS stalled / camera disconnected) → renders **gray/empty** bar.
    - `0.0` = attempted but **all skipped** → red. `1.0` = all sent → green. `0.7` = 7/10 sent (partial split bar at 10 Hz).
    - `nil` vs `0.0` matters: leaving GPS on indoors (no fix → no attempts) must show gray, NOT solid red — we didn't fail, we didn't try.

### Sparkline cadence — fixed 1 Hz, decoupled from push rate (time-based, option B)

One bar always = one second, whether `rateHz` is 1 or 10.

- **Ownership (resolved):** the **1 Hz aggregation tick is owned by `OsmoLocationManager`** (it already owns GPS-active state + the push timer, and iterates `enabledConnectedCameras` in `pushGPS`); the **per-second counters + history live on `OsmoCamera`**. One owner for the *when*, locality for the *what*.
- Each tick, while GPS is active, for every enabled camera: append `gpsSecondAttempts > 0 ? Double(gpsSecondSent)/Double(gpsSecondAttempts) : nil` to `gpsSendHistory` (cap ~16), then reset the per-second counters.
- **Time-based:** the tick fires on wall-clock and always appends, so a stall appends `nil` (gray) and the sparkline advances rather than freezing — visibly showing the gap.
- Buckets accrue only while GPS is active; GPS off ⇒ sparkline hidden entirely (rule A).

## iOS UI

- **SettingsView** (under existing "Push GPS to Cameras" toggle): when enabled, reveal a segmented **Picker "1 Hz" / "10 Hz"** bound to `locationManager.rateHz`. Footer warns 10 Hz is heavier on battery/BLE, especially with many cameras. Add a detail readout: "±N m, last update Xs ago" from `accuracy` / `lastPushAt` (or "No fix" when `fixState == .noFix`). The "Xs ago" counter needs a `TimelineView(.periodic(by: 1))` to tick while the view is open (same pattern as `CameraRowView`'s "Xs ago").
- **Top bar (CameraListView):** new 3rd `.topBarLeading` toolbar item to the right of the screen-lock toggle. Phone-global GPS indicator: "GPS" text + color dot (gray/red/green from `fixState`) + small state label, using the existing `ControlButton` icon-over-caption idiom. This is the primary at-a-glance indicator while shooting.
- **Remove `GPSStatusBadge`** from `CameraDetailView` (delete the per-camera fix badge entirely).
- **CameraRowView — two distinguishable sparklines:**
  - Existing RSSI `SignalStrengthView`: prefix with a **Bluetooth-style icon** (SF Symbol — no literal "bluetooth" glyph exists; use an antenna/radiowaves symbol, exact choice in plan).
  - New `GPSSendHealthView(history: [Double?])` sparkline, prefixed with a **satellite icon**. Canvas mirroring `SignalStrengthView`'s geometry, but bars are **full-height and split** by the per-second sent fraction: green segment = sent fraction, red = skipped remainder; `nil` bucket = gray/empty bar (no attempts). The split-bar + icon make it visually distinct from RSSI's variable-height single-colour bars.
  - **Visibility rule (A):** GPS sparkline+icon shown on every row whenever `locationManager.isActive`, hidden entirely when GPS push is off. Principle: "feature on ⇒ its UI present," not gated on ephemeral per-camera connection. A disconnected camera (or no fix) with GPS on shows `nil`/gray bars advancing — truthful "nothing sent." Just-connected/no-history shows icon + empty track until first tick (mirror RSSI `isEmpty` handling so the row doesn't reflow).

## Watch relay (tweak a)

- **`WatchBridge` constructor change:** today it's `WatchBridge(cameraManager:)` with no location access; `OsmoMultiApp.init` constructs it that way. Add an `OsmoLocationManager` dependency (`WatchBridge(cameraManager:locationManager:)`) and update `App.init`.
- **Relay `fixState`** as a string key `gpsFix` ("off" / "noFix" / "good") in the existing 1 s `pushStateIfChanged`. **Add `gpsFix` to BOTH the context dict AND the change-detection comparison** (WatchBridge compares each key explicitly ~L73-78; omit it from the comparison and the watch never updates on GPS-only changes).
- **`WatchViewModel`**: read `gpsFix` (default "off" when absent).
- **`WatchControlView`**: small **satellite icon + color, NO text label**. Tri-state: **hidden entirely when off** (don't clutter the small screen with an unused feature), **red** for noFix, **green** for good.
- Note: `updateApplicationContext` is coalesced by the system — the watch indicator may lag by seconds. Acceptable for a status dot.

## Testing

- Unit: `CLLocation.hasValidGPSFix` (valid/invalid). `GPSFixState` derivation (off/noFix/good across isActive × fix). `GPSPushCommand` byte-44 gate (valid → nominal count, invalid → 0). **build-once refactor: `frame(encodePayload(loc), seq)` for two distinct seqs produces frames identical except seq+both CRCs, and each equals the legacy `build(loc, seq)` byte-for-byte** (guards against the CRC-sharing trap). Per-second bucket math: attempts>0 → sent/attempts; attempts==0 → `nil` (not 0.0).
- Device (hardware-only): send-health sparkline populates, shows red on throttle under multi-camera load and gray when no fix; rate toggle changes live push cadence; top-bar indicator tracks real fix; watch satellite icon reflects fix (hidden when off); GPS off hides per-camera sparkline.

## Minor notes (accepted, low-priority)

- `fixState` recomputes on every CL update (~1 Hz+); harmless, no memoization (YAGNI).
- Define "session" for `gpsAttempted/gpsSkipped`: reset on each GPS `start()`.

## Out of scope / deferred

- "Stale fix" state (valid-but-old `lastLocation` when CL stalls) — separate axis, not in `GPSFixState`.
- `peripheralIsReady` queue draining — only if simple skip-counting proves insufficient.
- Real delivery confirmation — impossible without `.withResponse` (rejected: airtime/latency cost). Send-health is the honest proxy.
- Empirical BLE validation via PacketLogger — the in-app send-health instrumentation is the first-order measurement.

## Suggested implementation phasing

Likely one plan, three phases (each independently buildable/shippable):
1. **Framework keystone:** `CLLocation.hasValidGPSFix`, `GPSFixState`, manager `rateHz`/`fixState`/`accuracy` + 1 Hz aggregation tick, #5 log fix, build-once refactor, send-health counters + `canSendWriteWithoutResponse` gating. (Most unit-testable.)
2. **iOS UI:** rate picker, top-bar indicator, remove badge, row sparkline + icons.
3. **Watch:** bridge relay + change-detection key + watch indicator.
