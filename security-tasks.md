# Security Review: Cam Control for DJI Osmo

**Date:** 2026-03-03
**Scope:** Full codebase — DJIOsmoKit framework, OsmoMulti iOS app, OsmoWatch watchOS companion
**Context:** Pre-production release assessment

---

## Executive Summary

The app has a strong security posture in several areas — no third-party dependencies, no network calls, no hardcoded secrets, debug code properly gated behind `#if DEBUG`, and WatchConnectivity data is appropriately scoped. However, there are **actionable issues** across BLE input validation, data persistence, logging hygiene, and a missing App Store requirement.

---

## CRITICAL — Must Fix Before Release

### 1. Missing Privacy Manifest (`PrivacyInfo.xcprivacy`)

Apple requires a privacy manifest for App Store submission. The app accesses Bluetooth, Location, and UserDefaults APIs — all of which need declarations. Without this file, **App Store Connect will reject the binary**.

**Action:** Created `OsmoMulti/PrivacyInfo.xcprivacy` with NSPrivacyTracking=false, UserDefaults API declaration (CA92.1), and precise location collection (AppFunctionality, not linked, not tracking). Auto-included via xcodegen sources path.

**Status: done**


---

### 2. GPS Coordinates Logged Without Privacy Redaction

`DJIOsmoKit/Location/OsmoLocationManager.swift:93` and `:107` log latitude/longitude at 6 decimal places (~0.1m precision) without `privacy: .private`. These entries are visible in system logs via `log stream` and could appear in sysdiagnose bundles shared with Apple or third parties.

```swift
OsmoLog.location.debug("GPS push -> \(targets) camera(s) @ \(String(format: "%.6f", lat)),\(String(format: "%.6f", lon))")
```

**Action:** Changed coordinate interpolations to `privacy: .private` in OsmoLocationManager.swift (lines 93 and 107). OSLog automatically shows `.private` values when debugging via Xcode but redacts them in production system logs.

**Status: done**

---

### 3. BLE Peripheral UUIDs Stored in Plaintext UserDefaults

`DJIOsmoKit/Camera/OsmoCameraManager.swift:461-478` persists `peripheralID` (stable iOS-assigned CBPeripheral UUID) in unencrypted UserDefaults. On a jailbroken device or via unencrypted backups, an attacker can extract which specific camera hardware the user owns.

```swift
private struct PersistedCamera: Codable {
    let id: UUID
    let name: String
    let peripheralID: UUID?  // stable hardware identifier
    ...
}
```

**Action:** Consider migrating to Keychain for peripheral ID storage, or accept the risk given the data is device-specific BLE UUIDs (not globally unique tracking IDs). Document the decision either way.

**Status: skipped — will not cause App Store rejection**

**Comments:**
Apple does not audit where you persist local device metadata. Keychain is a security best practice but not a submission requirement. UserDefaults for BLE peripheral UUIDs is acceptable.

---

## HIGH — Strong Recommendations

### 4. Integer Overflow Risk in GPS Coordinate Encoding

`DJIOsmoKit/Protocol/Commands/GPSPushCommand.swift:45-46` casts `Double * 1e7` directly to `Int32`. While valid GPS coordinates stay within Int32 range, a buggy CLLocationManager update with out-of-range values would trigger a runtime trap.

```swift
payload.writeLE(Int32(location.coordinate.longitude * 1e7), at: 8)
```

**Action:** Changed to `Int32(clamping: Int64(...))` for longitude, latitude, and altitude in GPSPushCommand.swift.

**Status: done**


---

### 5. Silent Command Failures in UI (`try?` Everywhere)

`OsmoMulti/Views/CameraDetailView.swift:110, 120, 135, 144` — all camera commands use `try?` with no user feedback on failure. Users tap "Record" and get no indication if the command was lost. The watch app has the same issue — shutter taps silently fail when unreachable.

```swift
Task { try? await camera.sendShutter() }
```

**Action:** Replaced `try?` with `do/catch` in CameraDetailView (mode, shutter, stop, sleep) and GlobalControlsView bulk actions. Added `showToast()` to CameraListViewModel with auto-dismiss after 3s. Toast overlay in CameraListView (capsule with `.ultraThinMaterial`). Bulk commands (`shutterAll`, `startAll`, etc.) now return failure count. Only the final retry failure triggers a toast — `sendWithRetry` handles retries internally.

**Status: done**

---

### 6. No Backpressure on BLE Notification Processing

`DJIOsmoKit/Camera/OsmoCamera.swift` — the notification async iterator processes frames as fast as BLE delivers them with no rate limiting. A misbehaving peripheral could flood the main thread with frame processing.

**Action:** Add a minimum frame interval (e.g., 50ms) or frame counter to throttle processing.

**Status: waiting for next steps**

**Comments:**


---

### 7. Unbounded `pendingResponses` Dictionary

`DJIOsmoKit/Camera/OsmoCamera.swift` — `pendingResponses: [UInt16: CheckedContinuation]` has no size cap. A device that never responds could cause unbounded growth (limited to 65536 by UInt16 key space, but still significant).

**Action:** Added `PendingEntry` struct with `ContinuousClock.Instant` timestamp. Reaping runs piggybacked on `sendAndWait()`/`waitForCommand()` — sweeps both `pendingResponses` and `pendingCommandWaiters` for entries older than 30s, resuming them with timeout error. Capacity check at 32 entries logs a warning and triggers a reap. Existing per-call timeouts (1.5-5s) remain the primary mechanism; the 30s reaper is a safety net for edge cases.

**Status: done**

---

## MEDIUM — Should Address

### 8. BLE Advertisement Data Logged at `.public` Privacy

`DJIOsmoKit/BLE/OsmoBLEScanner.swift:99, 115-118` logs peripheral identifiers and manufacturer data with `privacy: .public`. Useful for development but unnecessary in production.

**Action:** Changed peripheral identifiers, manufacturer data hex, service UUIDs, and overflow UUIDs from `privacy: .public` to `privacy: .private` in OsmoBLEScanner.swift. Non-sensitive values (camera name, RSSI, connectable) left as `.public`.

**Status: done**

---

### 9. Status Payload Hex Dumps in Production Logs

`DJIOsmoKit/Camera/OsmoCamera.swift` logs full hex dumps of status payloads at `.info` level with `privacy: .public`. This reveals camera operational state to anyone with log access.

**Action:** Changed raw payload hex dump interpolation from `privacy: .public` to `privacy: .private` in OsmoCamera.swift. Mode label, camera name, and byte count remain `.public`.

**Status: done**

---

### 10. Hardcoded UTC+8 Timezone in GPS Push

`DJIOsmoKit/Protocol/Commands/GPSPushCommand.swift:25-27` assumes all DJI cameras expect UTC+8. This is correct per DJI's protocol spec but produces incorrect timestamps for users outside China if cameras interpret the timestamp differently.

```swift
cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
```

**Action:** Added 3-line comment above the `TimeZone(secondsFromGMT: 8 * 3600)!` call explaining DJI protocol requires CST, matches reference implementation, and camera interprets all timestamps as CST regardless of locale.

**Status: done**


---

### 11. No Authentication in BLE Handshake

The 3-way handshake (`DJIOsmoKit/Camera/OsmoCameraManager.swift`) accepts any device claiming `verify_mode=2, verify_data=0`. A rogue BLE device could impersonate a camera. This is a **protocol-level limitation** — DJI's protocol has no cryptographic authentication.

**Action:** Added 4-line comment above the `verify_mode == 2 && verify_data == 0` guard in OsmoCameraManager.swift documenting that the protocol has no cryptographic authentication, and trust relies on the user explicitly adding cameras via the Add Camera flow which binds to the peripheral's UUID.

**Status: done**

---

### 12. WatchBridge Timer Race Condition

`OsmoMulti/Watch/WatchBridge.swift:20` — `pushTimer` is marked `nonisolated(unsafe)` to satisfy Swift concurrency rules. The timer callback creates a `Task { @MainActor in }` which is correct but the timer lifecycle itself isn't synchronized.

**Action:** Low practical risk since Timer retains its callback, but consider `DispatchSourceTimer` for cleaner actor isolation.

**Status: deferred — see risk analysis below**

**Comments:**
**Risk analysis:** The `nonisolated(unsafe) var pushTimer: Timer?` has two theoretical races: (1) deinit firing while a timer callback's `Task` is mid-setup — safe because `[weak self]` guard makes `self?` nil; (2) timer firing between last strong ref drop and deinit — also safe because `[weak self]` returns nil. **Practical risk is near-zero** since WatchBridge lives for the entire app lifetime. **Possible fix:** Replace `Timer` with a `Task`-based loop (`while !Task.isCancelled { try await Task.sleep(...) }`) stored in a `Task<Void, Never>?` property, which is fully actor-isolated and needs no `nonisolated(unsafe)`.


---

## LOW — Nice to Have

### 13. Battery Percentage Not Clamped

`DJIOsmoKit/Models/CameraStatus.swift` — `batteryPercentage = Int(bytes[37])` accepts 0-255. A buggy camera reporting >100% would show nonsensical UI values.

**Action:** Changed `let batteryPercentage = Int(bytes[37])` to `min(100, max(0, Int(bytes[37])))` in CameraStatus.swift.

**Status: done**


---

### 14. Silent Swallow of Persistence Errors

`DJIOsmoKit/Camera/OsmoCameraManager.swift:475` — `try?` on JSONEncoder silently drops encoding failures.

**Action:** Replaced `try?` with `do/catch` block that logs via `OsmoLog.manager.error(...)` in OsmoCameraManager.swift.

**Status: done**


---

### 15. Watch Mode Picker Accepts Unvalidated Strings

`OsmoWatch/Views/WatchControlView.swift:31-37` — if the iPhone pushes a mode string that doesn't match any picker value, the picker enters an undefined state. The safe cast on the bridge side makes this unlikely but not impossible.

**Action:** Added validation in `.onChange(of: viewModel.currentMode)` that checks incoming mode string against `modes.map(\.value)` before assigning to `selectedMode`. Invalid modes are silently ignored.

**Status: done**


---

## What's Already Good

| Area | Status |
|---|---|
| **No third-party deps** | Only Apple frameworks — zero supply chain risk |
| **No network calls** | All communication is local BLE + WatchConnectivity |
| **No hardcoded secrets** | No API keys, tokens, or credentials |
| **Debug code gated** | `#if DEBUG` properly guards preview mode |
| **Location permission** | Uses `WhenInUse` (most restrictive) |
| **WCSession data** | Only sends aggregate counts, not camera identifiers |
| **App Transport Security** | Default (enforced HTTPS), though no HTTP calls exist |
| **Code signing** | Automatic with team ID configured |
| **Weak self in closures** | Properly used throughout |

---

## Effort Estimates

| Priority | Items | Est. Effort |
|---|---|---|
| **P0 (blocks release)** | Privacy manifest (#1) | 30 min |
| **P1 (should fix)** | GPS log redaction (#2), silent failures (#5), Int32 overflow (#4) | 2 hrs |
| **P2 (recommended)** | Log privacy (#8, #9), BLE rate limiting (#6), pending cap (#7) | 2 hrs |
| **P3 (when convenient)** | UserDefaults vs Keychain (#3), battery clamp (#13), mode validation (#15) | 2 hrs |
