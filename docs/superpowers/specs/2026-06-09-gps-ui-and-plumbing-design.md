# GPS UI & Plumbing — Design

**Date:** 2026-06-09
**Status:** Approved (brainstorm)
**Context:** Follow-up after PRs #2 (GPS video telemetry) and #3 (mode/UI) merged. Replaces the contributor's per-camera `GPSStatusBadge` with a correct phone-global fix indicator, adds a user-selectable push rate, per-camera GPS *delivery* health, a watch GPS indicator, and a build-path refactor. All converge on one source of truth in `OsmoLocationManager`.

## Background / problem

- GPS *fix quality* is a property of the **phone**, but the merged `GPSStatusBadge` rendered it per-camera in `CameraDetailView`, binding phone-global values (`accuracy`, `lastPushAt`) plus one per-camera flag — conceptually muddled, and it showed green "GPS on" even with no valid fix (`accuracy == nil` fell through to green).
- The validity rule (`horizontalAccuracy >= 0`) was re-derived ad hoc in the view; the satellite-gate and early-return guard each had their own copy.
- Push rate was a hardcoded `Timer` interval (0.1s) — PR #2's contentious 1→10 Hz change. Making it a user setting neutralizes the argument.
- GPS *delivery* (does each BLE link actually receive frames) is genuinely per-camera and uneven (connection-event scheduling drops on some cameras, not all — see pr-review.nogit/pr-2.md §3) but is currently invisible.
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

`pushGPS` currently calls `GPSPushCommand.build(location, seq)` per camera, but the only byte that differs across cameras is `seq`. Refactor so the location-dependent payload (timestamp, coordinates, accuracy, **satellite-validity byte** — all location-derived) is built **once per tick**, then per-camera only the 2-byte `seq` is stamped (and CRC recomputed, since CRC covers seq). Eliminates N redundant full builds/CRCs per tick. Exact shape (e.g. `build` returns a template + a `stamp(seq:)` helper, or `pushGPS` builds base bytes and finalizes per camera) to be decided in the plan; behavior must be byte-identical to today except for the dedup.

## Per-camera delivery instrumentation

- **`OsmoBLEConnection.write`**: gate on `peripheral.canSendWriteWithoutResponse`. If not ready, count a drop instead of calling `writeValue` blindly. (Fire-and-forget GPS: dropping the newest-stale frame and counting it is acceptable; a 1-deep `peripheralIsReady(toSendWriteWithoutResponse:)` drain is optional, deferred unless needed.)
- **`OsmoCamera`** new state: `gpsAttempted: Int`, `gpsDropped: Int`, `gpsDeliveryHistory: [Bool]` (cap ~16, mirroring `rssiHistory`; true = delivered, false = dropped).
- Note: `write` is generic (all frames), but only GPS push should feed these counters — the counting happens at the GPS send path (`sendGPSData`/`pushGPS`), reading the connection's ready state, not inside the generic `write` for every frame type.

## iOS UI

- **SettingsView** (under existing "Push GPS to Cameras" toggle): when enabled, reveal a segmented **Picker "1 Hz" / "10 Hz"** bound to `locationManager.rateHz`. Footer warns 10 Hz is heavier on battery/BLE, especially with many cameras. Add a detail readout: "±N m, last update Xs ago" from `accuracy` / `lastPushAt` (or "No fix" when `fixState == .noFix`).
- **Top bar (CameraListView):** new 3rd `.topBarLeading` toolbar item to the right of the screen-lock toggle. Phone-global GPS indicator: "GPS" text + color dot (gray/red/green from `fixState`) + small state label, using the existing `ControlButton` icon-over-caption idiom. This is the primary at-a-glance indicator while shooting.
- **Remove `GPSStatusBadge`** from `CameraDetailView` (delete the per-camera fix badge entirely).
- **CameraRowView — two distinguishable sparklines:**
  - Existing RSSI `SignalStrengthView`: prefix with a **Bluetooth-style icon** (SF Symbol — no literal "bluetooth" glyph exists; use an antenna/radiowaves symbol, exact choice in plan).
  - New `GPSDeliveryView(history:)` sparkline (green=delivered / red=dropped, Canvas mirroring `SignalStrengthView`): prefix with a **satellite icon**.
  - **Visibility rule (A):** GPS sparkline+icon shown on every row whenever `locationManager.isActive`, hidden entirely when GPS push is off. Principle: "feature on ⇒ its UI present," not gated on ephemeral per-camera connection. A disconnected camera with GPS on shows accumulated history greying/flatlining (truthful "not getting through"). Just-connected/no-history shows icon + empty track until first frame (mirror RSSI `isEmpty` handling so the row doesn't reflow).

## Watch relay (tweak a)

- **`WatchBridge`**: relay `fixState` collapsed to a simple value (e.g. `gpsFix` = "good" / "none" / absent-when-off, or a Bool good/not-good) via `updateApplicationContext`. **Add the new key to BOTH the context dict AND the change-detection comparison** (WatchBridge compares each key explicitly ~L73-78; omitting it from the comparison means the watch never updates on GPS-only changes). Needs `WatchBridge` to observe `locationManager.fixState`.
- **`WatchViewModel`**: read the new key.
- **`WatchControlView`**: small **satellite icon + color** (green / non-green). **No text label.**

## Testing

- Unit: `CLLocation.hasValidGPSFix` (valid/invalid). `GPSFixState` derivation (off/noFix/good across isActive × fix). `GPSPushCommand` byte-44 gate (valid → nominal count, invalid → 0). build-once refactor: same bytes as a per-camera build except `seq`/CRC; two cameras get distinct seq, identical payload otherwise.
- Device (hardware-only): delivery sparkline populates and drops show under load; rate toggle changes live push cadence; top-bar indicator tracks real fix; watch satellite icon reflects fix; GPS off hides per-camera sparkline.

## Out of scope / deferred

- "Stale fix" state (valid-but-old `lastLocation` when CL stalls) — separate axis, not in `GPSFixState`.
- `peripheralIsReady` queue draining — only if simple drop-counting proves insufficient.
- Empirical BLE delivery validation via PacketLogger — the in-app instrumentation is the first-order measurement.

## Suggested implementation phasing

Likely one plan, three phases (each independently buildable/shippable):
1. **Framework keystone:** `CLLocation.hasValidGPSFix`, `GPSFixState`, manager `rateHz`/`fixState`/`accuracy`, #5 log fix, build-once refactor, delivery counters + `canSendWriteWithoutResponse` gating. (Most unit-testable.)
2. **iOS UI:** rate picker, top-bar indicator, remove badge, row sparkline + icons.
3. **Watch:** bridge relay + change-detection key + watch indicator.
