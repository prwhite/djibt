# GPS UI & Plumbing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-camera GPS badge with a correct phone-global fix indicator, add a user-selectable 1/10 Hz push rate, per-camera GPS send-health, and a watch GPS indicator — all converging on one source of truth in `OsmoLocationManager`.

**Architecture:** A keystone refactor in the `DJIOsmoKit` framework (`OsmoLocationManager` owns `rateHz`/`fixState`/`accuracy` + a single 1 Hz aggregation tick; a shared `CLLocation.hasValidGPSFix` predicate; a two-phase `GPSPushCommand` encode/frame split; per-camera send-health counters) followed by iOS UI (Settings rate picker, top-bar indicator, badge removal, send-health sparkline) and watchOS relay (WatchBridge `gpsFix` + watch satellite dot). Framework logic is TDD-unit-tested; SwiftUI/WCSession is compile-verified (`make build-ci`) plus on-device checklists.

**Tech Stack:** Swift 5.9, SwiftUI (`@Observable`, `Canvas`, `TimelineView`), CoreLocation, CoreBluetooth (`.withoutResponse`), WatchConnectivity, XCTest, xcodegen, Makefile.

**Spec:** `docs/superpowers/specs/2026-06-09-gps-ui-and-plumbing-design.md`

---

## Execution order & dependencies

Implement phases in order — each is independently shippable and leaves the app compiling:

1. **Phase 1 — Framework keystone** (Tasks 1.1–1.8): pure `DJIOsmoKit` + `DJIOsmoKitTests`, fully TDD-unit-tested. No UI depends on it yet; the manager self-seeds `rateHz` at init so the app still builds.
2. **Phase 2 — iOS UI** (Tasks 2.1–2.4): binds the Phase-1 manager/camera API. Compile-verified + device checklist.
3. **Phase 3 — Watch** (Tasks 3.1–3.4): relays `fixState` to the watch. Compile-verified + device checklist.

**Build/test commands** (from the Makefile):
- `make test` — compiles `DJIOsmoKitTests` (TDD red/green is compile-driven; see Phase 1 intro for why).
- `make build-ci` — compile-only app build, no signing.
- `make gen` — `xcodegen generate`; **run after adding/deleting any source file** (targets glob their directories).
- `make build` / `make install DEVICE=<id>` / `make install-watch DEVICE=<id>` — signed device build + install for the on-device checklists (`make devices` lists IDs).

## Implementer "confirm-or-swap" notes (from plan review)

These are deliberate choices flagged during review — verify on device, swap if you disagree, but they are not blockers:

- **Top-bar indicator** (Task 2.2) renders a color-coded icon + "GPS" caption; the explicit state word ("good"/"no fix"/"off") lives in the `accessibilityLabel`, not as visible text. If you want a visible state word under the caption, add it in `GPSTopBarIndicator`.
- **Icon glyphs** are placeholders verified to exist: `globe.americas.fill` (GPS, used on the top bar **and** the per-camera row for consistency) and `antenna.radiowaves.left.and.right` (RSSI — there is no literal "bluetooth" SF Symbol), `location.fill` on the watch. If a true satellite glyph is preferred, confirm availability on the target OS at device-verify time and swap the `systemName` only.
- **Watch** uses `location.fill` while iOS uses `globe.americas.fill` for the same conceptual GPS signal — unify if you want one glyph everywhere.

---

## Phase 1 — Framework keystone (DJIOsmoKit)

All work in this phase lives in the `DJIOsmoKit` framework + `DJIOsmoKitTests`, which are 100% unit-testable without a device. The `DJIOsmoKit` target sources its entire directory by path (`project.yml` line 37: `- path: DJIOsmoKit`) and `DJIOsmoKitTests` likewise (line 50), so **new files are picked up automatically by xcodegen** — but you MUST run `make gen` after adding any new file before it compiles.

Build/test commands used throughout:
- **Run unit tests:** `make test` → `xcodebuild -project OsmoMulti.xcodeproj -target DJIOsmoKitTests -sdk iphoneos -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build`. **Important:** the Makefile `test` target only **compiles** the test target (no `test-without-building` run on a simulator, since BLE/sim is unavailable). A failing assertion therefore manifests as a *test that compiles but is not yet satisfied by impl*; we drive TDD by first writing the test referencing a not-yet-existing symbol (compile FAILS = red), then adding the symbol (compile PASSES = green). Where a symbol already exists, we make the assertion logically meaningful and rely on `make test` compiling clean.
- **Compile-only app check:** `make build-ci`.
- **Regenerate project after adding files:** `make gen` → `xcodegen generate`.

---

### Task 1.1 — `CLLocation.hasValidGPSFix` predicate + test

**Files:**
- Create: `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/CLLocation+Fix.swift`
- Create (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`
- Modify: run `make gen` to register both new files in the project

- [ ] **Step 1: Write the failing test referencing the not-yet-existing predicate.**
  Create `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`:
  ```swift
  import XCTest
  import CoreLocation
  @testable import DJIOsmoKit

  final class GPSFixTests: XCTestCase {

      // MARK: - CLLocation.hasValidGPSFix

      func testValidFixWhenHorizontalAccuracyNonNegative() {
          let loc = CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
              altitude: 0,
              horizontalAccuracy: 5,   // valid
              verticalAccuracy: 5,
              timestamp: Date()
          )
          XCTAssertTrue(loc.hasValidGPSFix)
      }

      func testValidFixWhenHorizontalAccuracyExactlyZero() {
          let loc = CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
              altitude: 0,
              horizontalAccuracy: 0,   // boundary: 0 is still valid per `>= 0`
              verticalAccuracy: 5,
              timestamp: Date()
          )
          XCTAssertTrue(loc.hasValidGPSFix)
      }

      func testInvalidFixWhenHorizontalAccuracyNegative() {
          let loc = CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
              altitude: 0,
              horizontalAccuracy: -1,  // Core Location marks lat/lon invalid this way
              verticalAccuracy: -1,
              timestamp: Date()
          )
          XCTAssertFalse(loc.hasValidGPSFix)
      }
  }
  ```

- [ ] **Step 2: Register the test file (predicate doesn't exist yet) and confirm RED.**
  Run:
  ```bash
  make gen && make test
  ```
  Expected: compile **FAILS** with `value of type 'CLLocation' has no member 'hasValidGPSFix'` for all three test methods. This is our red state.

- [ ] **Step 3: Add the minimal predicate.**
  Create `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/CLLocation+Fix.swift`:
  ```swift
  import CoreLocation

  extension CLLocation {
      /// Single definition of "usable GPS fix". Core Location marks lat/lon
      /// invalid by setting `horizontalAccuracy` negative; a non-negative value
      /// means the coordinate is usable. This is the one place the rule lives —
      /// consumed by `OsmoLocationManager.fixState`/`accuracy`, the
      /// `pushGPSToAllCameras` early-return guard, and `GPSPushCommand`'s
      /// satellite-validity gate.
      var hasValidGPSFix: Bool { horizontalAccuracy >= 0 }
  }
  ```

- [ ] **Step 4: Register the new source file and confirm GREEN.**
  Run:
  ```bash
  make gen && make test
  ```
  Expected: compile **SUCCEEDS** (`** BUILD SUCCEEDED **`). The three predicate tests now reference a real symbol with correct boundary behavior.

- [ ] **Step 5: Commit.**
  ```bash
  git add DJIOsmoKit/Location/CLLocation+Fix.swift DJIOsmoKitTests/GPSFixTests.swift OsmoMulti.xcodeproj/project.pbxproj
  git commit -m "Add CLLocation.hasValidGPSFix predicate with tests

Single source of truth for the GPS fix-validity rule (horizontalAccuracy >= 0),
replacing the ad-hoc copies in the push guard and satellite gate.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 1.2 — `GPSFixState` enum

**Files:**
- Create: `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/GPSFixState.swift`
- Modify (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift` (append cases)
- Modify: run `make gen` to register the new file

- [ ] **Step 1: Append a failing test for the enum's raw values (needed later for the watch string relay).**
  In `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`, add these methods inside the `GPSFixTests` class, after `testInvalidFixWhenHorizontalAccuracyNegative()`:
  ```swift
      // MARK: - GPSFixState

      func testGPSFixStateRawValuesMatchWatchRelayStrings() {
          // These string raw values are the wire format relayed to the watch
          // ("off" / "noFix" / "good"); changing them breaks the watch indicator.
          XCTAssertEqual(GPSFixState.off.rawValue, "off")
          XCTAssertEqual(GPSFixState.noFix.rawValue, "noFix")
          XCTAssertEqual(GPSFixState.good.rawValue, "good")
      }

      func testGPSFixStateRoundTripsThroughRawValue() {
          XCTAssertEqual(GPSFixState(rawValue: "off"), .off)
          XCTAssertEqual(GPSFixState(rawValue: "noFix"), .noFix)
          XCTAssertEqual(GPSFixState(rawValue: "good"), .good)
          XCTAssertNil(GPSFixState(rawValue: "bogus"))
      }
  ```

- [ ] **Step 2: Confirm RED.**
  ```bash
  make test
  ```
  Expected: compile **FAILS** with `cannot find 'GPSFixState' in scope`.

- [ ] **Step 3: Add the enum.**
  Create `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/GPSFixState.swift`:
  ```swift
  import Foundation

  /// Phone-global GPS fix quality, derived in exactly one place
  /// (`OsmoLocationManager.fixState`). Rendered gray / red / green by the
  /// top-bar indicator, the Settings readout, and the watch relay.
  ///
  /// Raw values are the wire format pushed to the watch via WCSession
  /// (`gpsFix` key); keep them stable.
  public enum GPSFixState: String {
      /// GPS push is not active. (gray)
      case off
      /// Active but no usable fix yet (e.g. indoors). (red)
      case noFix
      /// Active with a valid fix. (green)
      case good
  }
  ```

- [ ] **Step 4: Confirm GREEN.**
  ```bash
  make gen && make test
  ```
  Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Commit.**
  ```bash
  git add DJIOsmoKit/Location/GPSFixState.swift DJIOsmoKitTests/GPSFixTests.swift OsmoMulti.xcodeproj/project.pbxproj
  git commit -m "Add GPSFixState enum (off/noFix/good)

String-backed so raw values double as the WCSession watch-relay wire format.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 1.3 — `OsmoLocationManager`: `rateHz` (owns UserDefaults `gps_push_hz`) + `fixState` + `accuracy`

This is the keystone. The manager becomes the single owner of push rate (read from `UserDefaults` at init next to the existing `gps_push_enabled` read in `App.init`, written in `didSet`) and the single place `fixState`/`accuracy` are derived. The hardcoded `0.1` interval at line 66 becomes `1.0 / Double(rateHz)`, and `didSet` reschedules the timer when active.

**Files:**
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/OsmoLocationManager.swift` (state block ~lines 22-42; init lines 47-54; start lines 59-72)
- Modify (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`

- [ ] **Step 1: Write failing tests for `fixState` and `accuracy` derivation.**
  Because `fixState`/`accuracy` depend on `isActive` (private-set) and `lastLocation` (private-set), the test exercises them through a deterministic helper rather than poking private state. Add a `@testable`-visible test helper on the manager first via the test, then implement it. Append to `GPSFixTests.swift` inside the class:
  ```swift
      // MARK: - OsmoLocationManager fixState / accuracy

      @MainActor
      func testFixStateOffWhenInactive() {
          let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          // Fresh manager: not active → off, regardless of location.
          XCTAssertEqual(mgr.fixState, .off)
          XCTAssertNil(mgr.accuracy)
      }

      @MainActor
      func testFixStateGoodWithValidFixWhileActive() {
          let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          let valid = CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
              altitude: 0, horizontalAccuracy: 4, verticalAccuracy: 4, timestamp: Date()
          )
          mgr._testSetActive(true, location: valid)
          XCTAssertEqual(mgr.fixState, .good)
          XCTAssertEqual(mgr.accuracy, 4)
      }

      @MainActor
      func testFixStateNoFixWithInvalidFixWhileActive() {
          let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          let invalid = CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
              altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date()
          )
          mgr._testSetActive(true, location: invalid)
          XCTAssertEqual(mgr.fixState, .noFix)
          XCTAssertNil(mgr.accuracy)   // accuracy nil when fix invalid
      }

      @MainActor
      func testRateHzDefaultsTo1AndPersists() {
          UserDefaults.standard.removeObject(forKey: "gps_push_hz")
          let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          XCTAssertEqual(mgr.rateHz, 1, "Default rate is 1 Hz when key unset")

          mgr.rateHz = 10
          XCTAssertEqual(UserDefaults.standard.integer(forKey: "gps_push_hz"), 10,
                         "didSet must persist rateHz to gps_push_hz")

          // A freshly-constructed manager reads the persisted value at init.
          let mgr2 = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          XCTAssertEqual(mgr2.rateHz, 10)
          UserDefaults.standard.removeObject(forKey: "gps_push_hz")
      }
  ```
  > Note: `OsmoCameraManager.makePreview()` already exists (used in `OsmoMultiApp.init` under `--preview-mode`). The `_testSetActive(_:location:)` helper is added in Step 3.

- [ ] **Step 2: Confirm RED.**
  ```bash
  make test
  ```
  Expected: compile **FAILS** — `value of type 'OsmoLocationManager' has no member 'fixState'` / `'accuracy'` / `'rateHz'` / `'_testSetActive'`.

- [ ] **Step 3: Add `rateHz` state (read at init, persist + reschedule in didSet), `fixState`, `accuracy`, the timer-reschedule helper, and the test hook.**
  In `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/OsmoLocationManager.swift`:

  First, add observable state after the `lastPushAt` block (after line 31). Insert:
  ```swift
      /// GPS push frequency in Hz. UI constrains to {1, 10}. Owns persistence:
      /// read from `UserDefaults` ("gps_push_hz") at init, written here on change.
      /// While active, changing this reschedules the push timer at 1/rateHz.
      public var rateHz: Int = 1 {
          didSet {
              guard rateHz != oldValue else { return }
              UserDefaults.standard.set(rateHz, forKey: "gps_push_hz")
              if isActive { restartTimer() }
          }
      }

      /// Phone-global fix quality — the one place "off/noFix/good" is derived.
      public var fixState: GPSFixState {
          guard isActive else { return .off }
          return (lastLocation?.hasValidGPSFix == true) ? .good : .noFix
      }

      /// Horizontal accuracy in metres for the Settings "±N m" readout,
      /// or nil when there is no valid fix.
      public var accuracy: Double? {
          guard let l = lastLocation, l.hasValidGPSFix else { return nil }
          return l.horizontalAccuracy
      }
  ```

  Next, seed `rateHz` from `UserDefaults` at the end of `init` (after line 53 `locationManager.activityType = .other`). **Set it *before* `start()` could ever fire and write the default raw — assign the backing value without tripping persistence by guarding on a sentinel.** Insert after line 53:
  ```swift
          // Read persisted rate (next to gps_push_enabled, read in App.init).
          // Default to 1 Hz if unset (UserDefaults.integer returns 0 for missing).
          let storedHz = UserDefaults.standard.integer(forKey: "gps_push_hz")
          rateHz = (storedHz == 1 || storedHz == 10) ? storedHz : 1
  ```
  > **Note:** Swift does NOT run `didSet` for an assignment inside the declaring class's own initializer, so this line only seeds the stored value — it does not persist or reschedule. That's fine: persistence happens on later user-driven changes (the Settings picker), and `isActive` is false during init anyway. (If init-time persistence were ever wanted, call `UserDefaults.standard.set(rateHz, forKey: "gps_push_hz")` explicitly here — not needed now.)

  Now replace the hardcoded interval in `start()`. Change line 66 from:
  ```swift
          pushTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
              Task { @MainActor in
                  self?.pushGPSToAllCameras()
              }
          }
  ```
  to a call into a shared scheduler, so `start()` and the `didSet` reschedule share one code path. Replace those lines with:
  ```swift
          restartTimer()
  ```

  Then add the `restartTimer()` helper and the test hook in the `// MARK: - Start / Stop` section, immediately after `stop()` (after line 82). Insert:
  ```swift
      /// (Re)schedule the push timer at the current rate. Safe to call repeatedly.
      /// Used by `start()` and by `rateHz.didSet` while active.
      private func restartTimer() {
          pushTimer?.invalidate()
          let interval = 1.0 / Double(rateHz)
          pushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
              Task { @MainActor in
                  self?.pushGPSToAllCameras()
                  self?.aggregateGPSSecond()   // added in Task 1.8; harmless no-op until then
              }
          }
      }

      #if DEBUG
      /// Test-only hook to drive `fixState`/`accuracy` derivation without a real
      /// CLLocationManager. Not for production use.
      func _testSetActive(_ active: Bool, location: CLLocation?) {
          isActive = active
          lastLocation = location
      }
      #endif
  ```
  > NOTE: `aggregateGPSSecond()` is introduced in Task 1.8. To keep this task self-contained and GREEN, add a stub now and flesh it out later — see Step 3a.

- [ ] **Step 3a: Add a temporary stub for `aggregateGPSSecond()` so this task compiles.**
  In `OsmoLocationManager.swift`, in the `// MARK: - Push` section after `pushGPSToAllCameras()` (after line 103), insert:
  ```swift
      /// 1 Hz aggregation tick — fleshed out in Task 1.8.
      private func aggregateGPSSecond() { }
  ```

- [ ] **Step 4: Confirm GREEN.**
  ```bash
  make test
  ```
  Expected: **BUILD SUCCEEDED**. The five new tests now reference real members. Also run `make build-ci` to confirm the app target (which constructs the manager) still compiles:
  ```bash
  make build-ci
  ```
  Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Commit.**
  ```bash
  git add DJIOsmoKit/Location/OsmoLocationManager.swift DJIOsmoKitTests/GPSFixTests.swift
  git commit -m "OsmoLocationManager: rateHz + fixState + accuracy keystone

rateHz owns UserDefaults('gps_push_hz') — read at init, persisted + timer
rescheduled (1/rateHz) in didSet. fixState/accuracy are the single derivation
of GPS state. Replaces the hardcoded 0.1s timer interval with 1/rateHz via a
shared restartTimer() path. Adds a DEBUG-only test hook.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 1.4 — Split the #5 "no location yet" guard into no-location vs invalid-fix, using `hasValidGPSFix`

The current single guard (`OsmoLocationManager.swift` lines 91-94) conflates two distinct causes — null location and invalid fix (negative accuracy) — under one misleading message "GPS push skipped: no location yet". Split into two guards with distinct messages, and switch the validity test to the shared `hasValidGPSFix` predicate.

**Files:**
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/OsmoLocationManager.swift` (lines 91-94)
- Modify (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`

- [ ] **Step 1: Write a failing test asserting the guard now distinguishes the two cases.**
  We can't capture `OsmoLog` output in a unit test, but we *can* assert the observable side-effect: `pushGPSToAllCameras` must NOT set `lastPushAt` when there is no location, and must NOT set it when the fix is invalid — and the path uses `hasValidGPSFix`. Expose a thin test seam that returns the guard outcome. Append to `GPSFixTests.swift`:
  ```swift
      // MARK: - pushGPSToAllCameras guard split

      @MainActor
      func testPushSkippedWhenNoLocation() {
          let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          mgr._testSetActive(true, location: nil)
          XCTAssertEqual(mgr._testPushPrecheck(), .noLocation)
      }

      @MainActor
      func testPushSkippedWhenInvalidFix() {
          let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          let invalid = CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
              altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date()
          )
          mgr._testSetActive(true, location: invalid)
          XCTAssertEqual(mgr._testPushPrecheck(), .invalidFix)
      }

      @MainActor
      func testPushReadyWithValidFixAndConnectedCameras() {
          let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
          let valid = CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
              altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
          )
          mgr._testSetActive(true, location: valid)
          // makePreview() seeds 4 enabled+connected cameras, so a valid fix
          // passes all guards → .ready. (This proves the location AND fix guards
          // both pass; the .noLocation / .invalidFix tests above prove they fire.)
          XCTAssertEqual(mgr._testPushPrecheck(), .ready)
      }
  ```

- [ ] **Step 2: Confirm RED.**
  ```bash
  make test
  ```
  Expected: compile **FAILS** — `has no member '_testPushPrecheck'` and `cannot find type` for the precheck result.

- [ ] **Step 3: Refactor the guard into two, expose a precheck enum, and add the test seam.**
  In `OsmoLocationManager.swift`, replace the body of `pushGPSToAllCameras()` (lines 86-103). The current guard #2 (lines 91-94):
  ```swift
          guard let location = lastLocation, location.horizontalAccuracy >= 0 else {
              OsmoLog.location.debug("GPS push skipped: no location yet")
              return
          }
  ```
  becomes two guards. Replace the whole method with:
  ```swift
      /// Outcome of the pre-send guards, surfaced for tests.
      enum PushPrecheck: Equatable {
          case noManager, noLocation, invalidFix, noCameras, ready
      }

      /// Evaluate the pre-send guards without performing the send.
      func _testPushPrecheck() -> PushPrecheck {
          guard cameraManager != nil else { return .noManager }
          guard let location = lastLocation else { return .noLocation }
          guard location.hasValidGPSFix else { return .invalidFix }
          guard let manager = cameraManager, manager.enabledConnectedCameras.count > 0 else {
              return .noCameras
          }
          return .ready
      }

      private func pushGPSToAllCameras() {
          guard let manager = cameraManager else {
              OsmoLog.location.debug("GPS push skipped: no camera manager")
              return
          }
          guard let location = lastLocation else {
              OsmoLog.location.debug("GPS push skipped: no location yet")
              return
          }
          guard location.hasValidGPSFix else {
              OsmoLog.location.debug("GPS push skipped: invalid fix (no satellites / indoors)")
              return
          }
          let targets = manager.enabledConnectedCameras.count
          guard targets > 0 else {
              OsmoLog.location.debug("GPS push skipped: no connected cameras")
              return
          }
          OsmoLog.location.debug("GPS push → \(targets) camera(s) @ \(String(format: "%.6f", location.coordinate.latitude), privacy: .private),\(String(format: "%.6f", location.coordinate.longitude), privacy: .private)")
          manager.pushGPS(location)
          lastPushAt = Date()
      }
  ```
  > The temporary `aggregateGPSSecond()` stub added in Task 1.3 Step 3a stays for now; it's replaced in Task 1.8.

- [ ] **Step 4: Confirm GREEN.**
  ```bash
  make test
  ```
  Expected: **BUILD SUCCEEDED**. The "no location" message now only appears for genuine null-location, and a distinct "invalid fix" message covers negative accuracy.

- [ ] **Step 5: Commit.**
  ```bash
  git add DJIOsmoKit/Location/OsmoLocationManager.swift DJIOsmoKitTests/GPSFixTests.swift
  git commit -m "Split GPS push guard: no-location vs invalid-fix, use hasValidGPSFix

The single 'no location yet' message previously covered both null location and
negative-accuracy invalid fix (the #5 log bug). Now two guards with distinct
messages, both routed through the shared hasValidGPSFix predicate.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 1.5 — `GPSPushCommand` two-phase refactor + the CRITICAL byte-for-byte CRC test

Split `build(location:seq:)` into `encodePayload(location:) -> Data` (the expensive, per-tick-shared Calendar decomposition + 48-byte assembly, with the satellite byte gated on `hasValidGPSFix`) and `frame(payload:seq:) -> Data` (per-camera header + both CRCs). Keep `build(location:seq:)` as a wrapper so existing callers/tests are unaffected and output stays byte-identical.

**Files:**
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/Protocol/Commands/GPSPushCommand.swift` (lines 22-78)
- Modify (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/FrameTests.swift`

- [ ] **Step 1: Write the failing CRITICAL test (the CRC-sharing trap guard) + the byte-44 gate test.**
  The frame layout (from `FrameBuilder.swift` lines 28-31, 63-74): `SOF(1) | Ver/Len(2) | CmdType(1) | ENC(1) | RES(3) | SEQ(2) | CRC16(2) | CmdSet(1) | CmdID(1) | Payload(48) | CRC32(4)`. SEQ is at byte indices **8-9**; CRC16 at **10-11**; CmdSet at **12**; CmdID at **13**; payload at **14..61**; CRC32 (last 4 bytes) at **62..65**. The payload's satellite byte (offset 44 within payload) is therefore at **frame index 14 + 44 = 58**. Append to `FrameTests.swift` (inside `FrameTests`, after `testRawFrameCommandAcceptsFormattedHex()`):
  ```swift
      // MARK: - GPSPushCommand two-phase build

      private func makeValidLocation() -> CLLocation {
          CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
              altitude: 12, horizontalAccuracy: 5, verticalAccuracy: 5,
              course: -1, speed: -1,
              timestamp: Date(timeIntervalSince1970: 1_700_000_000)
          )
      }

      private func makeInvalidLocation() -> CLLocation {
          CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
              altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1,
              course: -1, speed: -1,
              timestamp: Date(timeIntervalSince1970: 1_700_000_000)
          )
      }

      /// CRITICAL: two distinct seqs must differ ONLY in the SEQ bytes (8-9),
      /// CRC16 (10-11), and CRC32 (last 4) — payload + cmd bytes identical —
      /// AND each two-phase frame must equal the legacy build() byte-for-byte.
      /// This guards against the CRC-sharing trap (reusing a cached frame and
      /// patching seq bytes would ship corrupt CRCs).
      func testTwoPhaseFramesDifferOnlyInSeqAndCRCs() throws {
          let loc = makeValidLocation()
          let payload = GPSPushCommand.encodePayload(location: loc)

          let frameA = GPSPushCommand.frame(payload: payload, seq: 100)
          let frameB = GPSPushCommand.frame(payload: payload, seq: 200)

          XCTAssertEqual(frameA.count, frameB.count)
          let n = frameA.count
          let a = [UInt8](frameA)
          let b = [UInt8](frameB)

          // Indices that are allowed to differ: SEQ (8,9), CRC16 (10,11),
          // and CRC32 (last four bytes).
          let allowedToDiffer: Set<Int> = [8, 9, 10, 11, n - 4, n - 3, n - 2, n - 1]
          for i in 0..<n {
              if allowedToDiffer.contains(i) { continue }
              XCTAssertEqual(a[i], b[i],
                  "Byte \(i) must be identical across seqs (only seq + both CRCs may differ)")
          }
          // And the SEQ bytes themselves must actually differ (sanity).
          XCTAssertNotEqual(Data(a[8...9]), Data(b[8...9]), "SEQ bytes must differ")
      }

      func testTwoPhaseEqualsLegacyBuildByteForByte() {
          let loc = makeValidLocation()
          let payload = GPSPushCommand.encodePayload(location: loc)

          for seq: UInt16 in [0, 1, 7, 100, 65535] {
              let twoPhase = GPSPushCommand.frame(payload: payload, seq: seq)
              let legacy = GPSPushCommand.build(location: loc, seq: seq)
              XCTAssertEqual(twoPhase, legacy,
                  "Two-phase frame must equal legacy build() for seq \(seq)")
          }
      }

      func testSatelliteByteGatedOnValidFix() {
          // Payload satellite_number lives at payload offset 44.
          let valid = GPSPushCommand.encodePayload(location: makeValidLocation())
          let invalid = GPSPushCommand.encodePayload(location: makeInvalidLocation())

          // Field is a little-endian UInt32 at offset 44.
          XCTAssertEqual(valid[44], UInt8(GPSPushCommand.nominalSatelliteCount),
                         "Valid fix → nominal satellite count")
          XCTAssertEqual(valid[45], 0); XCTAssertEqual(valid[46], 0); XCTAssertEqual(valid[47], 0)

          XCTAssertEqual(invalid[44], 0, "Invalid fix → satellite count 0")
          XCTAssertEqual(invalid[45], 0); XCTAssertEqual(invalid[46], 0); XCTAssertEqual(invalid[47], 0)
      }
  ```
  > `FrameTests.swift` already imports XCTest + `@testable import DJIOsmoKit` (line 2). Add `import CoreLocation` at the top if not present.

- [ ] **Step 1a: Ensure CoreLocation is imported in FrameTests.**
  At the top of `/Users/payton/me/dev/djibt/DJIOsmoKitTests/FrameTests.swift`, after line 2 (`@testable import DJIOsmoKit`), add:
  ```swift
  import CoreLocation
  ```

- [ ] **Step 2: Confirm RED.**
  ```bash
  make test
  ```
  Expected: compile **FAILS** — `type 'GPSPushCommand' has no member 'encodePayload'` / `'frame'` / `'nominalSatelliteCount'`.

- [ ] **Step 3: Refactor `GPSPushCommand` into two phases + wrapper + gated satellite byte.**
  Replace the entire `build(location:seq:)` method (lines 22-78) in `/Users/payton/me/dev/djibt/DJIOsmoKit/Protocol/Commands/GPSPushCommand.swift` with:
  ```swift
      /// Nominal satellite count reported when a valid fix is present.
      /// CLLocation does not expose true satellite count; this is a sentinel the
      /// camera firmware accepts as "GPS healthy". Gated to 0 on invalid fix.
      static let nominalSatelliteCount: UInt32 = 8

      /// Phase 1 (per tick, shared across cameras): encode the 48-byte data
      /// payload from a `CLLocation`. This is the expensive part — notably the
      /// `Calendar.dateComponents` timestamp decomposition — and is identical
      /// for every camera in a push tick.
      static func encodePayload(location: CLLocation) -> Data {
          var payload = Data(count: 48)

          // -- Timestamp in DJI format (UTC) --
          var cal = Calendar(identifier: .gregorian)
          // Keep GPS timestamps stable and locale-independent; camera local-time sync is not exposed here.
          cal.timeZone = TimeZone(secondsFromGMT: 0)!
          let comps = cal.dateComponents(
              [.year, .month, .day, .hour, .minute, .second],
              from: location.timestamp
          )
          let year = comps.year ?? 0
          let month = comps.month ?? 0
          let day = comps.day ?? 0
          let ymd = Int32(year * 10000 + month * 100 + day)

          let hour = comps.hour ?? 0
          let minute = comps.minute ?? 0
          let second = comps.second ?? 0
          let hms = Int32(hour * 10000 + minute * 100 + second)
          payload.writeLE(ymd, at: 0)
          payload.writeLE(hms, at: 4)

          // -- Position (scaled integers) --
          payload.writeLE(Int32(clamping: Int64(location.coordinate.longitude * 1e7)), at: 8)
          payload.writeLE(Int32(clamping: Int64(location.coordinate.latitude * 1e7)), at: 12)
          payload.writeLE(Int32(clamping: Int64(location.altitude * 1000)), at: 16)  // millimetres

          // -- Speed decomposition using course --
          let speedMS = max(location.speed, 0)  // m/s; negative means invalid
          let courseRad = location.course >= 0
              ? location.course * .pi / 180.0
              : 0
          let northCMS = Float(speedMS * cos(courseRad) * 100)  // cm/s
          let eastCMS  = Float(speedMS * sin(courseRad) * 100)  // cm/s
          payload.writeLE(northCMS, at: 20)
          payload.writeLE(eastCMS, at: 24)
          payload.writeLE(Float(0), at: 28)  // speed_to_downward (unused)

          // -- Accuracy --
          let vAcc = UInt32(max(location.verticalAccuracy, 0) * 1000)     // mm
          let hAcc = UInt32(max(location.horizontalAccuracy, 0) * 1000)   // mm
          let sAcc: UInt32 = location.speedAccuracy >= 0
              ? UInt32(location.speedAccuracy * 100) : 0                  // cm/s
          payload.writeLE(vAcc, at: 32)
          payload.writeLE(hAcc, at: 36)
          payload.writeLE(sAcc, at: 40)
          // satellite_number: gated on fix validity (shared predicate).
          payload.writeLE(location.hasValidGPSFix ? nominalSatelliteCount : 0, at: 44)

          return payload
      }

      /// Phase 2 (per camera): wrap a pre-encoded payload in a frame with this
      /// camera's `seq`. SEQ sits in the header (bytes 8-9), so CRC16 (SOF→SEQ)
      /// and CRC32 (whole frame) both recompute here — they CANNOT be shared
      /// across cameras.
      static func frame(payload: Data, seq: UInt16) -> Data {
          FrameBuilder.build(OutgoingFrame(
              cmdType: 0x00,  // fire-and-forget, no response expected
              seq: seq,
              cmdSet: cmdSet,
              cmdID: cmdID,
              payload: payload
          ))
      }

      /// Convenience wrapper preserving the original single-call API.
      /// `frame(encodePayload(location), seq)`. Output is byte-identical to the
      /// pre-refactor implementation.
      static func build(location: CLLocation, seq: UInt16) -> Data {
          frame(payload: encodePayload(location: location), seq: seq)
      }
  ```

- [ ] **Step 4: Confirm GREEN.**
  ```bash
  make test
  ```
  Expected: **BUILD SUCCEEDED**. The CRITICAL test proves two seqs differ only in SEQ + both CRCs and each equals legacy `build` byte-for-byte; the gate test proves byte 44 is the nominal count on valid fix and 0 on invalid. The pre-existing `testRawFrameCommandAcceptsFormattedHex` (which builds a 0x00/0x17 frame) still passes since the wrapper is byte-identical.

- [ ] **Step 5: Commit.**
  ```bash
  git add DJIOsmoKit/Protocol/Commands/GPSPushCommand.swift DJIOsmoKitTests/FrameTests.swift
  git commit -m "GPSPushCommand: two-phase encodePayload/frame + fix-gated satellite byte

encodePayload(location:) does the shared per-tick Calendar decomposition + 48B
assembly; frame(payload:seq:) does the per-camera header + both CRCs (which
cannot be shared since seq invalidates CRC16 and CRC32). build(location:seq:)
stays as a byte-identical wrapper. Satellite byte now gated on hasValidGPSFix
(nominalSatelliteCount on valid, 0 on invalid). CRC-sharing-trap test added.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 1.6 — `OsmoCamera` send-health state (mirrors `rssiHistory`, reset on start)

Add the per-camera send-health counters and per-second sent-fraction history, mirroring the existing `rssiHistory` append/cap-16 pattern (lines 410-411). Session totals reset on each GPS `start()`.

**Files:**
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/Camera/OsmoCamera.swift` (state near lines 78-81; reset in `clearStatus()` ~lines 113-114)
- Modify (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`

- [ ] **Step 1: Write failing tests for the counters, the second-snapshot math, and reset.**
  Append to `GPSFixTests.swift` inside the class:
  ```swift
      // MARK: - OsmoCamera GPS send-health

      @MainActor
      func testRecordGPSSendUpdatesCountersForSent() {
          let cam = OsmoCamera(name: "Test")
          cam.recordGPSSend(sent: true)
          cam.recordGPSSend(sent: true)
          XCTAssertEqual(cam.gpsAttempted, 2)
          XCTAssertEqual(cam.gpsSkipped, 0)
          XCTAssertEqual(cam.gpsSecondAttempts, 2)
          XCTAssertEqual(cam.gpsSecondSent, 2)
      }

      @MainActor
      func testRecordGPSSendUpdatesCountersForSkipped() {
          let cam = OsmoCamera(name: "Test")
          cam.recordGPSSend(sent: true)
          cam.recordGPSSend(sent: false)
          XCTAssertEqual(cam.gpsAttempted, 2)
          XCTAssertEqual(cam.gpsSkipped, 1)
          XCTAssertEqual(cam.gpsSecondAttempts, 2)
          XCTAssertEqual(cam.gpsSecondSent, 1)
      }

      @MainActor
      func testSnapshotGPSSecondAppendsFractionAndResetsSecond() {
          let cam = OsmoCamera(name: "Test")
          cam.recordGPSSend(sent: true)
          cam.recordGPSSend(sent: true)
          cam.recordGPSSend(sent: false)   // 2/3 sent
          cam.snapshotGPSSecond()
          XCTAssertEqual(cam.gpsSendHistory.last!, 2.0 / 3.0, accuracy: 0.0001)
          // Per-second counters reset; session totals untouched.
          XCTAssertEqual(cam.gpsSecondAttempts, 0)
          XCTAssertEqual(cam.gpsSecondSent, 0)
          XCTAssertEqual(cam.gpsAttempted, 3)
          XCTAssertEqual(cam.gpsSkipped, 1)
      }

      @MainActor
      func testSnapshotGPSSecondAppendsNilWhenNoAttempts() {
          let cam = OsmoCamera(name: "Test")
          cam.snapshotGPSSecond()
          XCTAssertEqual(cam.gpsSendHistory.count, 1)
          XCTAssertNil(cam.gpsSendHistory.last!,
              "No attempts that second must append nil (gray), not 0.0 (red)")
      }

      @MainActor
      func testGPSSendHistoryCapsAt16() {
          let cam = OsmoCamera(name: "Test")
          for _ in 0..<20 { cam.snapshotGPSSecond() }   // all nil
          XCTAssertEqual(cam.gpsSendHistory.count, 16)
      }

      @MainActor
      func testResetGPSSendHealthClearsEverything() {
          let cam = OsmoCamera(name: "Test")
          cam.recordGPSSend(sent: true)
          cam.recordGPSSend(sent: false)
          cam.snapshotGPSSecond()
          cam.resetGPSSendHealth()
          XCTAssertEqual(cam.gpsAttempted, 0)
          XCTAssertEqual(cam.gpsSkipped, 0)
          XCTAssertEqual(cam.gpsSecondAttempts, 0)
          XCTAssertEqual(cam.gpsSecondSent, 0)
          XCTAssertTrue(cam.gpsSendHistory.isEmpty)
      }
  ```

- [ ] **Step 2: Confirm RED.**
  ```bash
  make test
  ```
  Expected: compile **FAILS** — `OsmoCamera` has no `recordGPSSend` / `gpsAttempted` / `gpsSendHistory` / etc.

- [ ] **Step 3: Add the state + methods.**
  In `/Users/payton/me/dev/djibt/DJIOsmoKit/Camera/OsmoCamera.swift`, add the new observable state immediately after the `rssiHistory` declaration (after line 81 `public internal(set) var rssiHistory: [Int] = []`). Insert:
  ```swift

      // MARK: - GPS Send Health (per-camera)

      /// Session total GPS frames attempted (reset on each GPS start()).
      public internal(set) var gpsAttempted: Int = 0
      /// Session total GPS frames skipped because the BLE link wasn't ready.
      public internal(set) var gpsSkipped: Int = 0
      /// Attempts in the current open 1-second bucket (snapshotted + reset by the tick).
      public internal(set) var gpsSecondAttempts: Int = 0
      /// Sends in the current open 1-second bucket.
      public internal(set) var gpsSecondSent: Int = 0
      /// Per-second sent fraction for the sparkline (max 16, newest last).
      /// nil = no attempts that second (gray), 0.0 = all skipped (red),
      /// 1.0 = all sent (green), 0.x = partial split bar.
      public internal(set) var gpsSendHistory: [Double?] = []

      /// Record one GPS send attempt. `sent` = the local CoreBluetooth stack
      /// accepted the write (canSendWriteWithoutResponse was true).
      func recordGPSSend(sent: Bool) {
          gpsAttempted += 1
          gpsSecondAttempts += 1
          if sent {
              gpsSecondSent += 1
          } else {
              gpsSkipped += 1
          }
      }

      /// Snapshot the current second into `gpsSendHistory` and reset the bucket.
      /// Called by the 1 Hz aggregation tick on OsmoLocationManager.
      func snapshotGPSSecond() {
          let fraction: Double? = gpsSecondAttempts > 0
              ? Double(gpsSecondSent) / Double(gpsSecondAttempts)
              : nil
          gpsSendHistory.append(fraction)
          if gpsSendHistory.count > 16 { gpsSendHistory.removeFirst() }
          gpsSecondAttempts = 0
          gpsSecondSent = 0
      }

      /// Reset all send-health state. Called on each GPS start() so the readout
      /// reflects the current run, not lifetime.
      func resetGPSSendHealth() {
          gpsAttempted = 0
          gpsSkipped = 0
          gpsSecondAttempts = 0
          gpsSecondSent = 0
          gpsSendHistory.removeAll()
      }
  ```

- [ ] **Step 4: Also clear send-health when the camera's status is cleared.**
  In `clearStatus()` (lines 102-116), after line 114 (`rssiHistory.removeAll()`), insert:
  ```swift
          resetGPSSendHealth()
  ```

- [ ] **Step 5: Confirm GREEN.**
  ```bash
  make test
  ```
  Expected: **BUILD SUCCEEDED**. All seven new send-health tests reference real members and assert the nil-vs-0.0 distinction, cap-16, and reset.

- [ ] **Step 6: Commit.**
  ```bash
  git add DJIOsmoKit/Camera/OsmoCamera.swift DJIOsmoKitTests/GPSFixTests.swift
  git commit -m "OsmoCamera: per-camera GPS send-health counters + history

gpsAttempted/gpsSkipped session totals, gpsSecondAttempts/gpsSecondSent open
bucket, gpsSendHistory:[Double?] cap-16 mirroring rssiHistory. snapshotGPSSecond
appends sent-fraction or nil (no attempts) — nil!=0.0 so 'no fix indoors' shows
gray not red. resetGPSSendHealth() clears all; also wired into clearStatus().

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 1.7 — `OsmoBLEConnection` GPS-send readiness + wire send-health through the GPS send path

Expose `canSendWriteWithoutResponse` to the GPS send path ONLY (not the generic `write`). `sendGPSData` consults readiness: ready → write + `recordGPSSend(sent: true)`; not ready → skip + `recordGPSSend(sent: false)` (don't call `writeValue` blindly). The generic `write(_:)` at lines 116-119 stays unchanged.

**Files:**
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/BLE/OsmoBLEConnection.swift` (add readiness property after `write` lines 116-119)
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/Camera/OsmoCamera.swift` (`sendGPSData` lines 568-573)
- Modify (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`

- [ ] **Step 1: Write a failing test that `sendGPSData` records a skip when there is no connection.**
  A camera with no `bleConnection` and `connectionState == .connected` can't actually be constructed cleanly in a unit test (connectionState is driven by the connection), so we test the observable contract that matters: when `sendGPSData` runs and the link can't accept the write, it records a skip rather than a send. We expose a seam `sendGPSData(_:payload:)` that takes a pre-encoded payload (used by the manager in Task 1.8) and routes through the same readiness check. Append to `GPSFixTests.swift`:
  ```swift
      // MARK: - sendGPSData readiness gating

      @MainActor
      func testSendGPSDataRecordsSkipWhenNotConnected() {
          let cam = OsmoCamera(name: "Test")
          // No connection established → not connected → send is skipped and counted.
          let payload = GPSPushCommand.encodePayload(location: CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
              altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
          ))
          cam.sendGPSData(payload: payload)
          // Not connected → no attempt recorded at all (early return before counters).
          XCTAssertEqual(cam.gpsAttempted, 0,
              "Disconnected camera records no attempt (the 1 Hz tick appends nil instead)")
      }
  ```
  > Rationale matching spec line 82/89: a disconnected camera makes **no attempt**, so its bucket stays empty and the 1 Hz tick (Task 1.8) appends `nil` (gray), not a skip (red). The skip path (red) is for *connected-but-link-not-ready*, which requires hardware to exercise — covered by the device checklist, spec line 115.

- [ ] **Step 2: Confirm RED.**
  ```bash
  make test
  ```
  Expected: compile **FAILS** — `OsmoCamera` has no `sendGPSData(payload:)`.

- [ ] **Step 3: Add the readiness property to `OsmoBLEConnection`.**
  In `/Users/payton/me/dev/djibt/DJIOsmoKit/BLE/OsmoBLEConnection.swift`, immediately after the `write(_:)` method (after line 119), insert:
  ```swift

      /// Whether the local CoreBluetooth stack will currently accept a
      /// `.withoutResponse` write. Consulted ONLY by the GPS send path
      /// (fire-and-forget, no ACK) to drive send-health counters — the generic
      /// `write(_:)` above stays unconditional. False when the connection-event
      /// scheduler is starving this link.
      var canSendGPSWrite: Bool {
          peripheral.canSendWriteWithoutResponse
      }
  ```

- [ ] **Step 4: Refactor `sendGPSData` to consult readiness and feed counters.**
  In `/Users/payton/me/dev/djibt/DJIOsmoKit/Camera/OsmoCamera.swift`, replace `sendGPSData(_:)` (lines 568-573):
  ```swift
      public func sendGPSData(_ location: CLLocation) {
          guard connectionState == .connected else { return }
          let seq = nextSeq()
          let frame = GPSPushCommand.build(location: location, seq: seq)
          try? send(frame: frame)
      }
  ```
  with two methods — a payload-taking variant (used by the per-tick manager path) plus the original kept as a wrapper:
  ```swift
      /// Send a pre-encoded GPS payload to this camera (fire-and-forget).
      /// Consults BLE readiness and records send-health. Per-camera seq means
      /// the frame (with both CRCs) is built here, not shared across cameras.
      public func sendGPSData(payload: Data) {
          guard connectionState == .connected else { return }  // no attempt; tick appends nil
          let ready = bleConnection?.canSendGPSWrite ?? false
          guard ready else {
              recordGPSSend(sent: false)   // link not ready → skip (red)
              return
          }
          let seq = nextSeq()
          let frame = GPSPushCommand.frame(payload: payload, seq: seq)
          do {
              try send(frame: frame)
              recordGPSSend(sent: true)
          } catch {
              recordGPSSend(sent: false)
          }
      }

      /// Convenience overload — encodes the payload then sends. Kept for callers
      /// that have a `CLLocation` rather than a pre-encoded payload.
      public func sendGPSData(_ location: CLLocation) {
          sendGPSData(payload: GPSPushCommand.encodePayload(location: location))
      }
  ```

- [ ] **Step 5: Confirm GREEN.**
  ```bash
  make test && make build-ci
  ```
  Expected: both **BUILD SUCCEEDED**. The test confirms a disconnected camera records no attempt; the readiness gate is now in place for the connected path.

- [ ] **Step 6: Commit.**
  ```bash
  git add DJIOsmoKit/BLE/OsmoBLEConnection.swift DJIOsmoKit/Camera/OsmoCamera.swift DJIOsmoKitTests/GPSFixTests.swift
  git commit -m "Gate GPS send on canSendWriteWithoutResponse; record send-health

OsmoBLEConnection exposes canSendGPSWrite (GPS path only — generic write stays
unconditional). sendGPSData(payload:) checks readiness: ready -> write + record
sent; not ready -> skip + record. Disconnected -> no attempt (tick appends nil).
Per-camera frame() built here so each seq gets correct CRC16+CRC32.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 1.8 — Single 1 Hz aggregation tick on `OsmoLocationManager` + per-tick payload encode + reset-on-start

Replace the temporary `aggregateGPSSecond()` stub (Task 1.3) with the real one: while GPS is active, each second snapshot every enabled camera's bucket (appending `nil` when no attempts). Also switch `pushGPSToAllCameras` to encode the payload **once per tick** and hand it to each camera (the build-once refactor consumer), and reset send-health on `start()`.

**Files:**
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/OsmoLocationManager.swift` (`start()` lines 59-72; `pushGPSToAllCameras` body; the stub from Task 1.3)
- Modify: `/Users/payton/me/dev/djibt/DJIOsmoKit/Camera/OsmoCameraManager.swift` (`pushGPS` lines 539-543 → per-tick encode)
- Modify (test): `/Users/payton/me/dev/djibt/DJIOsmoKitTests/GPSFixTests.swift`

- [ ] **Step 1: Write a failing test that the aggregation tick appends nil for a camera with no attempts.**
  The tick runs on a real Timer, which we don't want to spin in a unit test; instead test the per-tick logic directly via a `@testable` seam `_testAggregateOnce()` that does exactly what the timer calls. Append to `GPSFixTests.swift`:
  ```swift
      // MARK: - 1 Hz aggregation tick

      @MainActor
      func testAggregateAppendsNilForCameraWithNoAttempts() {
          let manager = OsmoCameraManager.makePreview()
          let mgr = OsmoLocationManager(cameraManager: manager)
          // Make at least one enabled camera visible to the aggregator.
          let cam = manager.enabledCameras.first ?? OsmoCamera(name: "Fallback")
          cam.resetGPSSendHealth()

          mgr._testSetActive(true, location: CLLocation(
              coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
              altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
          ))
          mgr._testAggregateOnce()

          // Every enabled camera with no attempts this second gets a nil bucket.
          XCTAssertEqual(cam.gpsSendHistory.last ?? .some(0), Double?.none,
              "No attempts → nil bucket (gray), advancing the sparkline")
      }

      @MainActor
      func testAggregateDoesNothingWhenInactive() {
          let manager = OsmoCameraManager.makePreview()
          let mgr = OsmoLocationManager(cameraManager: manager)
          let cam = manager.enabledCameras.first ?? OsmoCamera(name: "Fallback")
          cam.resetGPSSendHealth()
          // Not active.
          mgr._testAggregateOnce()
          XCTAssertTrue(cam.gpsSendHistory.isEmpty,
              "Aggregation only runs while GPS is active")
      }
  ```
  > `OsmoCameraManager.makePreview()` ships preview cameras; `enabledCameras` (line 551) returns the enabled ones. If preview has none enabled, the fallback keeps the test self-contained but the meaningful assertion is the nil-append over the enabled set, which the aggregator iterates.

- [ ] **Step 2: Confirm RED.**
  ```bash
  make test
  ```
  Expected: compile **FAILS** — `OsmoLocationManager` has no `_testAggregateOnce`.

- [ ] **Step 3: Implement the real aggregation tick, the test seam, and reset-on-start.**
  In `/Users/payton/me/dev/djibt/DJIOsmoKit/Location/OsmoLocationManager.swift`, replace the temporary stub added in Task 1.3 Step 3a:
  ```swift
      /// 1 Hz aggregation tick — fleshed out in Task 1.8.
      private func aggregateGPSSecond() { }
  ```
  with the real implementation plus a test seam:
  ```swift
      /// 1 Hz aggregation tick (owned here — single timer, no per-view timers).
      /// While active, snapshot each enabled camera's open second into its
      /// gpsSendHistory; a stall appends nil (gray) and the sparkline advances.
      private func aggregateGPSSecond() {
          guard isActive, let manager = cameraManager else { return }
          for camera in manager.enabledCameras {
              camera.snapshotGPSSecond()
          }
      }

      #if DEBUG
      /// Test-only: run one aggregation tick synchronously.
      func _testAggregateOnce() { aggregateGPSSecond() }
      #endif
  ```
  > Note: the timer body added in Task 1.3 already calls `aggregateGPSSecond()` every `1/rateHz` seconds. To make it a true **1 Hz** tick decoupled from `rateHz` (spec lines 84-90), gate it to fire once per wall-clock second. Update the timer closure in `restartTimer()` (added in Task 1.3 Step 3) — replace its body:
  ```swift
          pushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
              Task { @MainActor in
                  self?.pushGPSToAllCameras()
                  self?.aggregateGPSSecond()   // added in Task 1.8; harmless no-op until then
              }
          }
  ```
  with a version that only aggregates on a 1-second boundary:
  ```swift
          lastAggregateAt = Date()
          pushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
              Task { @MainActor in
                  guard let self else { return }
                  self.pushGPSToAllCameras()
                  if Date().timeIntervalSince(self.lastAggregateAt) >= 1.0 {
                      self.lastAggregateAt = Date()
                      self.aggregateGPSSecond()
                  }
              }
          }
  ```
  Add the `lastAggregateAt` backing store in the private section (after line 41 `private var pushTimer: Timer?`):
  ```swift
      private var lastAggregateAt = Date()
  ```

- [ ] **Step 4: Reset send-health on each `start()`, and encode the payload once per tick.**
  In `start()` (lines 59-72), reset each camera's send-health when activating. After `isActive = true` (line 63) and before `restartTimer()`, insert:
  ```swift
          cameraManager?.enabledCameras.forEach { $0.resetGPSSendHealth() }
  ```
  Then make `pushGPS` encode once per tick. In `/Users/payton/me/dev/djibt/DJIOsmoKit/Camera/OsmoCameraManager.swift`, replace `pushGPS(_:)` (lines 539-543):
  ```swift
      public func pushGPS(_ location: CLLocation) {
          for camera in enabledConnectedCameras {
              camera.sendGPSData(location)
          }
      }
  ```
  with the build-once version:
  ```swift
      public func pushGPS(_ location: CLLocation) {
          // Encode the 48-byte payload ONCE per tick (shared Calendar decomposition);
          // each camera wraps it with its own seq + CRCs (which cannot be shared).
          let payload = GPSPushCommand.encodePayload(location: location)
          for camera in enabledConnectedCameras {
              camera.sendGPSData(payload: payload)
          }
      }
  ```

- [ ] **Step 5: Confirm GREEN.**
  ```bash
  make test && make build-ci
  ```
  Expected: both **BUILD SUCCEEDED**. The aggregation tests confirm nil-on-no-attempts and inactive-noop; the per-tick encode now feeds `sendGPSData(payload:)` (the readiness-gated path from Task 1.7).

- [ ] **Step 6: Full Phase 1 regression run.**
  ```bash
  make test && make build-ci
  ```
  Expected: both **BUILD SUCCEEDED** with the entire `GPSFixTests` + `FrameTests` suites compiling clean.

- [ ] **Step 7: Commit.**
  ```bash
  git add DJIOsmoKit/Location/OsmoLocationManager.swift DJIOsmoKit/Camera/OsmoCameraManager.swift DJIOsmoKitTests/GPSFixTests.swift
  git commit -m "Single 1 Hz aggregation tick + build-once GPS push + reset-on-start

OsmoLocationManager owns one wall-clock 1 Hz tick (decoupled from rateHz) that
snapshots every enabled camera's second, appending nil on no-attempts so the
sparkline advances through stalls. pushGPS encodes the payload once per tick and
hands it to each camera's readiness-gated sendGPSData(payload:). start() resets
per-camera send-health (session = current run).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

## Phase 1 exit criteria

- `make test` compiles `DJIOsmoKitTests` clean with all new `GPSFixTests` + `FrameTests` methods.
- `make build-ci` compiles the app target clean (the manager/camera changes are source-compatible; the `App.init` rate read is added in Phase 2's wiring, but nothing in Phase 1 requires it — `rateHz` self-seeds at manager init).
- The CRITICAL CRC test (`testTwoPhaseFramesDifferOnlyInSeqAndCRCs` + `testTwoPhaseEqualsLegacyBuildByteForByte`) passes, proving the build-once refactor is byte-identical and the CRC-sharing trap is avoided.
- The nil-vs-0.0 distinction is enforced by `testSnapshotGPSSecondAppendsNilWhenNoAttempts` and `testAggregateAppendsNilForCameraWithNoAttempts`.
- Device-only behaviors (live rate-toggle cadence, red-on-throttle, gray-on-no-fix sparkline population) are deferred to the device checklist in spec line 115 — not unit-testable without hardware.

## Cross-phase notes for Phase 2/3 implementers

- `App.init` (`OsmoMultiApp.swift` lines 26-28) still only reads `gps_push_enabled`. No change is *required* there for rate (the manager self-seeds `rateHz` from `gps_push_hz` at init), but Phase 2's `SettingsView` Picker binds `locationManager.rateHz` directly. Auto-start path is unaffected.
- `GPSFixState` raw values (`"off"`/`"noFix"`/`"good"`) are the watch wire format — Phase 3 relays `locationManager.fixState.rawValue`.
- `OsmoCamera.gpsSendHistory: [Double?]` is the Phase 2 `GPSSendHealthView(history:)` input; cap-16 mirrors `rssiHistory` exactly so the row doesn't reflow.
---

# Phase 2 — iOS UI

Depends on Phase 1, which already added to `DJIOsmoKit`:
- `OsmoLocationManager.rateHz: Int`, `.fixState: GPSFixState` (`.off`/`.noFix`/`.good`), `.accuracy: Double?`, plus existing `.isActive`, `.lastPushAt`, `.lastLocation`.
- `OsmoCamera.gpsSendHistory: [Double?]`, `.gpsAttempted: Int`, `.gpsSkipped: Int`.
- `GPSFixState: String` enum (raw values `"off"`/`"noFix"`/`"good"`) — used here only as a Swift enum; the raw String is consumed in Phase 3.

SwiftUI views are not unit-testable in this environment (BLE + UI need a device). Every UI task therefore verifies via `make build-ci` (compile-only, no signing) and carries an explicit on-device verification note. The one piece of pure value-logic introduced in this phase — `GPSSendHealthView`'s split-bar fraction-to-rects mapping — is exercised by a `#Preview` you eyeball on device, since `Canvas` output is not assertable here.

`make build-ci` runs: `xcodebuild -project OsmoMulti.xcodeproj -scheme OsmoMulti -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build`. A clean compile ends with `** BUILD SUCCEEDED **`.

---

## Task 2.1 — Settings: reveal rate Picker + fix readout under the GPS toggle

**Files:**
- Modify: `/Users/payton/me/dev/djibt/OsmoMulti/Views/SettingsView.swift` — replace the Location `Section` (lines 64–80) so the toggle reveals a `1 Hz`/`10 Hz` segmented `Picker` bound to `locationManager.rateHz`, a live `TimelineView(.periodic(by: 1))` "±N m, last update Xs ago" / "No fix" readout, and a battery/BLE footer.
- Test: none (SwiftUI). Compile via `make build-ci`; device-verify per the note in Step 4.

Existing anchors (confirmed): `@Environment(OsmoLocationManager.self) var locationManager` (line 7), `@AppStorage("gps_push_enabled") private var gpsPushEnabled = false` (line 10). The Location `Section` is lines 64–80 and is the only block we touch.

- [ ] **Step 1: Replace the Location Section with toggle + revealed Picker + readout + footer.**
  In `/Users/payton/me/dev/djibt/OsmoMulti/Views/SettingsView.swift`, replace the entire block at lines 64–80:
  ```swift
                Section {
                    Toggle("Push GPS to Cameras", isOn: Binding(
                        get: { gpsPushEnabled },
                        set: { newValue in
                            gpsPushEnabled = newValue
                            if newValue {
                                locationManager.start()
                            } else {
                                locationManager.stop()
                            }
                        }
                    ))
                } header: {
                    Text("Location")
                } footer: {
                    Text("Feeds iPhone GPS coordinates to connected cameras for video geotagging at 1 Hz.")
                }
  ```
  with:
  ```swift
                Section {
                    Toggle("Push GPS to Cameras", isOn: Binding(
                        get: { gpsPushEnabled },
                        set: { newValue in
                            gpsPushEnabled = newValue
                            if newValue {
                                locationManager.start()
                            } else {
                                locationManager.stop()
                            }
                        }
                    ))

                    if gpsPushEnabled {
                        Picker("Update Rate", selection: Binding(
                            get: { locationManager.rateHz },
                            set: { locationManager.rateHz = $0 }
                        )) {
                            Text("1 Hz").tag(1)
                            Text("10 Hz").tag(10)
                        }
                        .pickerStyle(.segmented)

                        // Ticks once a second while Settings is open so the
                        // "Xs ago" counter advances even with no new GPS fix.
                        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                            LabeledContent("Fix") {
                                Text(fixReadout(at: timeline.date))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text(gpsPushEnabled
                        ? "Feeds iPhone GPS coordinates to connected cameras for video geotagging. 10 Hz uses more battery and BLE bandwidth, especially with many cameras."
                        : "Feeds iPhone GPS coordinates to connected cameras for video geotagging.")
                }
  ```

- [ ] **Step 2: Add the `fixReadout(at:)` helper that renders accuracy + age or "No fix".**
  In the same file, insert this method inside `struct SettingsView` immediately before `var body: some View {` (line 29). It reads only Phase-1 manager state — `fixState`, `accuracy`, `lastPushAt`:
  ```swift
      /// "±N m, last update Xs ago" when we have a usable fix, otherwise "No fix".
      /// `now` comes from the enclosing TimelineView so the age advances each second.
      private func fixReadout(at now: Date) -> String {
          guard locationManager.fixState != .noFix else { return "No fix" }
          guard let accuracy = locationManager.accuracy else { return "No fix" }
          let meters = Int(accuracy.rounded())
          guard let last = locationManager.lastPushAt else {
              return "±\(meters) m"
          }
          let age = max(0, Int(now.timeIntervalSince(last)))
          return "±\(meters) m, last update \(age)s ago"
      }
  ```
  Note: when `gpsPushEnabled` is true but the manager has not produced a fix yet, `fixState == .noFix` ⇒ "No fix" (the toggle being on means `isActive`, so `.off` won't appear while the readout is visible). `accuracy` is already gated on `hasValidGPSFix` in Phase 1, so it is non-nil only on a good fix.

- [ ] **Step 3: Compile.**
  Run: `make build-ci`
  Expected: ends with `** BUILD SUCCEEDED **`. If the compiler complains that `locationManager.rateHz` is immutable, confirm Phase 1 declared it as a settable `var rateHz: Int` (not `private(set)`) — it must be settable from the view since the Picker writes it.

- [ ] **Step 4: Commit.**
  ```bash
  git add OsmoMulti/Views/SettingsView.swift
  git commit -m "Settings: reveal 1/10 Hz GPS rate picker + live fix readout

Under the existing Push GPS toggle, show a segmented 1 Hz/10 Hz picker
bound to OsmoLocationManager.rateHz and a TimelineView-driven
'±N m, last update Xs ago' / 'No fix' readout. Footer warns 10 Hz is
heavier on battery/BLE with many cameras.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

> **Device verification (2.1):** On a physical device, open Settings. Toggle "Push GPS to Cameras" ON — the segmented `1 Hz / 10 Hz` picker and a "Fix" row appear; footer gains the battery/BLE warning. With no GPS fix yet (or indoors) the Fix row reads "No fix". Once a fix arrives it reads "±N m, last update 0s ago" and the seconds counter increments every second while the sheet stays open. Flip to 10 Hz and confirm (via the BLE log or the per-camera sparkline from 2.4) the push cadence changes live. Toggle OFF — picker + readout disappear; footer reverts.

---

## Task 2.2 — Top bar: phone-global GPS fix indicator (3rd `.topBarLeading` item)

**Files:**
- Modify: `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraListView.swift` — add `@Environment(OsmoLocationManager.self)` (after line 18), add a 3rd `.topBarLeading` `ToolbarItem` after the screen-lock item (which ends at line 61), and add a private `GPSTopBarIndicator` view mirroring the `ControlButton` icon-over-caption idiom from `GlobalControlsView` (lines 166–187).
- Test: none (SwiftUI). Compile via `make build-ci`; device-verify per Step 5.

Existing anchors (confirmed): `@State private var viewModel: CameraListViewModel` (line 18); the second `.topBarLeading` item (screen-lock toggle) spans lines 51–61; the `ControlButton` reference idiom is at `GlobalControlsView.swift` lines 166–187 (VStack spacing 3, Image `.title3` tinted, Text `.caption2` `.secondary`).

- [ ] **Step 1: Add the locationManager environment read.**
  In `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraListView.swift`, after line 18:
  ```swift
      @State private var viewModel: CameraListViewModel
  ```
  add:
  ```swift
      @Environment(OsmoLocationManager.self) private var locationManager
  ```
  (`locationManager` is injected at `OsmoMultiApp` body line 36 `.environment(locationManager)`, so it is in the environment for this view.)

- [ ] **Step 2: Add the 3rd `.topBarLeading` toolbar item after the screen-lock item.**
  Locate the screen-lock `ToolbarItem` that ends at line 61:
  ```swift
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.screenLockDisabled.toggle()
                    viewModel.showToast(viewModel.screenLockDisabled
                        ? "Screen sleep disabled"
                        : "Screen sleep enabled")
                } label: {
                    Image(systemName: viewModel.screenLockDisabled ? "lock.open.display" : "lock.display")
                        .foregroundStyle(viewModel.screenLockDisabled ? .yellow : .secondary)
                }
            }
  ```
  Insert immediately after its closing `}` (i.e. between line 61 and the `}` that closes `.toolbar`):
  ```swift
            ToolbarItem(placement: .topBarLeading) {
                GPSTopBarIndicator(fixState: locationManager.fixState)
            }
  ```

- [ ] **Step 3: Add the `GPSTopBarIndicator` private view (ControlButton idiom, non-interactive).**
  At the very end of `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraListView.swift`, after the closing `}` of `struct CameraListView` (line 157), append:
  ```swift

  // MARK: - GPSTopBarIndicator

  /// Phone-global GPS fix at-a-glance indicator for the toolbar.
  /// Mirrors GlobalControlsView's ControlButton icon-over-caption idiom, but is
  /// a passive status display (no action). Color is the single source of truth
  /// from OsmoLocationManager.fixState: gray = off, red = noFix, green = good.
  private struct GPSTopBarIndicator: View {
      let fixState: GPSFixState

      var body: some View {
          VStack(spacing: 1) {
              Image(systemName: "globe.americas.fill")
                  .font(.title3)
                  .foregroundStyle(tint)
              Text("GPS")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("GPS \(stateLabel)")
      }

      private var tint: Color {
          switch fixState {
          case .off:   return .gray
          case .noFix: return .red
          case .good:  return .green
          }
      }

      private var stateLabel: String {
          switch fixState {
          case .off:   return "off"
          case .noFix: return "no fix"
          case .good:  return "good"
          }
      }
  }
  ```
  Note: spacing is `1` (not `3`) here because a toolbar's vertical room is tighter than the bottom control bar; the icon-over-caption shape still matches `ControlButton`. Keep the `globe.americas.fill` symbol consistent with the per-camera satellite icon chosen in 2.4 so "GPS" reads identically top-bar and per-row.

- [ ] **Step 4: Compile.**
  Run: `make build-ci`
  Expected: `** BUILD SUCCEEDED **`. If it errors with "cannot find type 'GPSFixState'", confirm `import DJIOsmoKit` is present at the top of `CameraListView.swift` (it is — line 1) and that Phase 1 declared `GPSFixState` `public`.

- [ ] **Step 5: Commit.**
  ```bash
  git add OsmoMulti/Views/CameraListView.swift
  git commit -m "Top bar: phone-global GPS fix indicator

Add a 3rd .topBarLeading toolbar item right of the screen-lock toggle.
GPSTopBarIndicator mirrors GlobalControlsView's ControlButton
icon-over-caption idiom and colors a globe icon gray/red/green straight
from OsmoLocationManager.fixState — the primary at-a-glance indicator
while shooting.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

> **Device verification (2.2):** On a device, the top-left bar now shows three items: gear, screen-lock, and a "GPS" caption under a globe icon. With push OFF the globe is gray. Turn push ON in Settings: indoors/no-fix it turns red; once a real fix lands it turns green. It must track the *phone's* fix, not any single camera (disconnect a camera — the indicator color is unchanged).

---

## Task 2.3 — Delete `GPSStatusBadge` and its detail-view usage

**Files:**
- Delete: `/Users/payton/me/dev/djibt/OsmoMulti/Views/GPSStatusBadge.swift`
- Modify: `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraDetailView.swift` — remove the `GPS` `LabeledContent` block (lines 143–149) and the `validGPSAccuracy` computed prop (lines 81–84).
- Regenerate: run `make gen` so `OsmoMulti.xcodeproj/project.pbxproj` drops the four stale `GPSStatusBadge` references (build-file `8706D5083E5862825CAFE781`, file-ref `B505EB3D1A029831A83D5C12`).
- Test: none (SwiftUI). Compile via `make build-ci`; device-verify per Step 5.

Important correction to the fact sheet: `project.yml`'s OsmoMulti target globs the whole `OsmoMulti` directory (`sources: - path: OsmoMulti`, project.yml line 62), so `GPSStatusBadge.swift` *is* xcodegen-managed — it was picked up by the glob, not a manual `.pbxproj` edit. Therefore the correct removal is: delete the file from disk, then `make gen` to rewrite a clean `.pbxproj` (no manual `.pbxproj` surgery). Do **not** hand-edit `project.pbxproj`; `make gen` overwrites it wholesale.

- [ ] **Step 1: Remove the GPS `LabeledContent` block from `CameraDetailView`.**
  In `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraDetailView.swift`, delete lines 143–149:
  ```swift
                LabeledContent("GPS") {
                    GPSStatusBadge(
                        isPushing: locationManager.isActive && camera.connectionState == .connected,
                        accuracy: validGPSAccuracy,
                        lastPushAt: locationManager.lastPushAt
                    )
                }
  ```
  (This sat inside the `if hasLiveStatus {` block of `statusSection`; removing it leaves the surrounding `Storage`/`Time Remaining`/temperature-warning rows intact.)

- [ ] **Step 2: Remove the now-unused `validGPSAccuracy` computed prop.**
  In the same file, delete lines 81–84:
  ```swift
      private var validGPSAccuracy: Double? {
          guard let accuracy = locationManager.lastLocation?.horizontalAccuracy, accuracy >= 0 else { return nil }
          return accuracy
      }
  ```
  Leave the `@Environment(OsmoLocationManager.self) private var locationManager` declaration (line 11) in place — `CameraDetailView` is the parent that supplies the environment to its `SignalStrengthView` subtree and may be read elsewhere; removing the only two GPS usages does not require removing the environment read, and an unused `@Environment` does not warn. (If `make build-ci` later flags it as unused, it is safe to delete then.)

- [ ] **Step 3: Delete the file from disk.**
  ```bash
  git rm OsmoMulti/Views/GPSStatusBadge.swift
  ```

- [ ] **Step 4: Regenerate the project and compile.**
  ```bash
  make gen
  make build-ci
  ```
  Expected: `make gen` prints `Loaded project ... Created project at OsmoMulti.xcodeproj`; `make build-ci` ends with `** BUILD SUCCEEDED **`. Confirm the stale references are gone:
  ```bash
  grep -c GPSStatusBadge OsmoMulti.xcodeproj/project.pbxproj
  ```
  Expected: `0`. (If non-zero, `make gen` did not run or the file was not deleted — re-do Steps 3–4.)

- [ ] **Step 5: Commit (include the regenerated `.pbxproj`).**
  ```bash
  git add OsmoMulti/Views/CameraDetailView.swift OsmoMulti.xcodeproj/project.pbxproj
  git commit -m "Remove per-camera GPSStatusBadge

The badge bound phone-global fix values per-camera and rendered green
even with no valid fix. The phone-global truth now lives in the top-bar
indicator (OsmoLocationManager.fixState); delete the badge, its
CameraDetailView LabeledContent + validGPSAccuracy helper, and let
xcodegen drop the file reference.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

> **Device verification (2.3):** Open a connected camera's detail view. The Status section no longer has a "GPS" row; Connection/Signal/Battery/Resolution/etc. are unchanged and nothing reflows oddly. The app builds and installs (no missing-symbol or duplicate-source errors from the regenerated project).

---

## Task 2.4 — `GPSSendHealthView` split-bar sparkline + per-row icons (rule A)

**Files:**
- Create: `/Users/payton/me/dev/djibt/OsmoMulti/Views/GPSSendHealthView.swift` — a `Canvas` split-bar sparkline taking `history: [Double?]`, mirroring `SignalStrengthView`'s geometry (barWidth 1.5, gap 0.5, height 13, frame width `CGFloat(max(count,1)) * 2.0 - 0.5`). Includes a `#Preview` to eyeball the nil/red/green/split mapping on device.
- Modify: `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraRowView.swift` — add `@Environment(OsmoLocationManager.self)`; prefix the existing RSSI `SignalStrengthView` (lines 25–27) with an antenna icon; after `BatteryView` (line 28) add a satellite icon + `GPSSendHealthView(history: camera.gpsSendHistory)` shown only when `locationManager.isActive`, with `isEmpty` handling so the row does not reflow before the first tick.
- Test: none assertable (Canvas). Compile via `make build-ci`; eyeball the `#Preview` and device-verify per Step 6.

`SignalStrengthView` geometry to mirror (confirmed): `barWidth: CGFloat = 1.5` (line 24), `gap: CGFloat = 0.5` (line 25), `step = barWidth + gap` (line 26), per-bar `x = CGFloat(i) * step` (line 31), frame `width: CGFloat(max(history.count, 1)) * 2.0 - 0.5, height: 13` (line 41), `guard !history.isEmpty else { return }` (line 19). The difference: GPS bars are **full height** and **split** (green sent-fraction stacked under red skipped-remainder), and `nil` renders an empty/gray bar.

- [ ] **Step 1: Create `GPSSendHealthView.swift`.**
  Write `/Users/payton/me/dev/djibt/OsmoMulti/Views/GPSSendHealthView.swift`:
  ```swift
  import SwiftUI

  /// Per-camera GPS *send health* sparkline (up to ~16 one-second buckets).
  ///
  /// Each bucket is the fraction of attempted GPS writes the local CoreBluetooth
  /// stack accepted that second (canSendWriteWithoutResponse == true). This is a
  /// SEND-health proxy, not delivery — fire-and-forget writes are never ACKed.
  ///
  /// Per bucket value:
  ///   nil  → no attempts that second (GPS stalled / no fix / disconnected) → gray/empty
  ///   0.0  → attempted, all skipped/throttled → solid red
  ///   1.0  → all sent → solid green
  ///   0.7  → 7/10 sent → bottom 70% green, top 30% red (split bar)
  ///
  /// Geometry mirrors SignalStrengthView (1.5pt bars, 0.5pt gaps, 13pt tall) so
  /// the two sparklines line up; the satellite icon + split coloring distinguish
  /// it from RSSI's variable-height single-color bars.
  struct GPSSendHealthView: View {

      let history: [Double?]

      private static let trackColor = Color.gray.opacity(0.25)

      var body: some View {
          Canvas { context, size in
              guard !history.isEmpty else { return }

              let barWidth: CGFloat = 1.5
              let gap: CGFloat = 0.5
              let step = barWidth + gap

              for (i, fraction) in history.enumerated() {
                  let x = CGFloat(i) * step

                  guard let fraction else {
                      // No attempts that second — faint empty track, not red.
                      let rect = CGRect(x: x, y: 0, width: barWidth, height: size.height)
                      context.fill(Path(rect), with: .color(Self.trackColor))
                      continue
                  }

                  let clamped = min(max(fraction, 0), 1)
                  let greenHeight = size.height * clamped
                  let redHeight = size.height - greenHeight

                  // Red (skipped) on top.
                  if redHeight > 0 {
                      let redRect = CGRect(x: x, y: 0, width: barWidth, height: redHeight)
                      context.fill(Path(redRect), with: .color(.red))
                  }
                  // Green (sent) on the bottom.
                  if greenHeight > 0 {
                      let greenRect = CGRect(x: x, y: redHeight, width: barWidth, height: greenHeight)
                      context.fill(Path(greenRect), with: .color(.green))
                  }
              }
          }
          .frame(width: CGFloat(max(history.count, 1)) * 2.0 - 0.5, height: 13)
      }
  }

  #if DEBUG
  #Preview("Send health buckets") {
      VStack(alignment: .leading, spacing: 12) {
          // All sent (green), all skipped (red), splits, and nils (gray gaps).
          GPSSendHealthView(history: [1.0, 1.0, 0.7, 0.5, 0.2, 0.0, nil, nil, 1.0, 0.9])
          // Empty history — must render nothing (no crash, no reflow).
          GPSSendHealthView(history: [])
          // Single bucket — frame width floor exercised.
          GPSSendHealthView(history: [0.5])
      }
      .padding()
  }
  #endif
  ```
  Drawing convention check: SwiftUI `Canvas` y grows downward, so y=0 is the top. We draw red from the top (`y: 0`) and green from `y: redHeight` to the bottom — i.e. the green sent-fraction visually fills from the bottom up, matching the "more green = healthier" reading and RSSI's bottom-anchored bars.

- [ ] **Step 2: Register the new file and compile it in isolation.**
  The file lives under the globbed `OsmoMulti` source path, so regenerate the project, then compile:
  ```bash
  make gen
  make build-ci
  ```
  Expected: `** BUILD SUCCEEDED **`. (`make gen` is required because a brand-new file must be added to `project.pbxproj`; xcodegen picks it up via the directory glob.)

- [ ] **Step 3: Commit the standalone view.**
  ```bash
  git add OsmoMulti/Views/GPSSendHealthView.swift OsmoMulti.xcodeproj/project.pbxproj
  git commit -m "Add GPSSendHealthView split-bar sparkline

Canvas sparkline over [Double?] one-second send-fraction buckets,
mirroring SignalStrengthView geometry (1.5pt bars, 0.5pt gaps, 13pt).
nil=gray/empty (no attempts), 0.0=red, 1.0=green, partial=split
(green sent-fraction from the bottom, red skipped remainder on top).
DEBUG #Preview exercises the nil/red/green/split mapping.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

- [ ] **Step 4: Wire icons + sparkline into `CameraRowView`.**
  In `/Users/djibt`-rooted `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraRowView.swift`, first add the environment read. After line 7 (`let camera: OsmoCamera`) insert:
  ```swift
      @Environment(OsmoLocationManager.self) private var locationManager
  ```
  Then replace the connected/sleeping signal+battery block (lines 24–29):
  ```swift
                  // Signal + battery (show for connected and sleeping)
                  if camera.connectionState == .connected || camera.connectionState == .sleeping {
                      if !camera.rssiHistory.isEmpty {
                          SignalStrengthView(history: camera.rssiHistory)
                      }
                      BatteryView(percentage: camera.status.batteryPercentage)
                  }
  ```
  with:
  ```swift
                  // Signal + battery (show for connected and sleeping)
                  if camera.connectionState == .connected || camera.connectionState == .sleeping {
                      if !camera.rssiHistory.isEmpty {
                          // Antenna/radiowaves stands in for "BLE link" — there is no
                          // literal bluetooth SF Symbol.
                          Image(systemName: "antenna.radiowaves.left.and.right")
                              .font(.caption)
                              .foregroundStyle(.secondary)
                          SignalStrengthView(history: camera.rssiHistory)
                      }
                      BatteryView(percentage: camera.status.batteryPercentage)
                  }

                  // GPS send-health (rule A): present on EVERY row whenever GPS push
                  // is active, hidden entirely when off — independent of per-camera
                  // connection. Just-connected/no-history shows the icon + a 1-bar
                  // empty track (mirroring RSSI's isEmpty handling) so the row does
                  // not reflow when the first second's bucket arrives.
                  if locationManager.isActive {
                      Image(systemName: "globe.americas.fill")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      GPSSendHealthView(history: gpsHistoryForDisplay)
                  }
  ```

- [ ] **Step 5: Add the `gpsHistoryForDisplay` no-reflow helper.**
  In the same file, add this computed property to `struct CameraRowView`, immediately after the `private var statusColor: Color { ... }` block (which ends at line 66):
  ```swift
      /// Keeps the GPS sparkline a fixed minimum width before the first 1 Hz bucket
      /// arrives, so turning GPS on doesn't make the row reflow when bar #1 lands.
      /// `GPSSendHealthView` renders an empty Canvas for `[]`, so we feed a single
      /// placeholder `nil` bucket (gray/empty) until real history exists — same
      /// spirit as RSSI's `isEmpty` guard, applied here so the icon + track are
      /// stable from the moment GPS is active.
      private var gpsHistoryForDisplay: [Double?] {
          camera.gpsSendHistory.isEmpty ? [nil] : camera.gpsSendHistory
      }
  ```
  Note on observation: `CameraRowView` reads `camera.gpsSendHistory` directly. Because `OsmoCamera` is `@Observable` (Phase 1 appends to `gpsSendHistory` on the single 1 Hz `OsmoLocationManager` tick), each row re-renders only when *its own* camera's array mutates — exactly how `SignalStrengthView(history: camera.rssiHistory)` already works. Do **not** wrap `GPSSendHealthView` in a `TimelineView` — there is one model timer and zero view timers by design.

- [ ] **Step 5a: Inject `OsmoLocationManager` into the `CameraListView` #Preview so it doesn't trap at runtime.**
  Both `CameraListView` (Task 2.2) and `CameraRowView` (this task) now read `@Environment(OsmoLocationManager.self)`. A missing `@Environment` value is **not** a compile error — `make build-ci` passes — but the existing `#Preview("Camera List")` in `CameraListView.swift` (lines 4–12) renders both views and would **trap at runtime** in Xcode previews. Update that preview to inject one. In `/Users/payton/me/dev/djibt/OsmoMulti/Views/CameraListView.swift`, change the preview body (lines 5–11):
  ```swift
  #Preview("Camera List") {
      let manager = OsmoCameraManager.makePreview()
      NavigationStack {
          CameraListView(manager: manager)
      }
      .environment(manager)   // child views (SettingsView etc.) read from environment
  }
  ```
  to also inject a location manager:
  ```swift
  #Preview("Camera List") {
      let manager = OsmoCameraManager.makePreview()
      NavigationStack {
          CameraListView(manager: manager)
      }
      .environment(manager)
      .environment(OsmoLocationManager(cameraManager: manager))   // top-bar + row GPS reads this
  }
  ```

- [ ] **Step 6: Compile.**
  Run: `make build-ci`
  Expected: `** BUILD SUCCEEDED **`. (The app target injects the real `locationManager` at `OsmoMultiApp` body line 36; the preview now injects its own per Step 5a so it won't trap when rendered.)

- [ ] **Step 7: Commit.**
  ```bash
  git add OsmoMulti/Views/CameraRowView.swift
  git commit -m "CameraRowView: distinguish RSSI vs GPS sparklines with icons

Prefix the RSSI SignalStrengthView with an antenna icon (no literal
bluetooth glyph exists) and, when locationManager.isActive (rule A),
add a satellite/globe icon + GPSSendHealthView after BatteryView on
every row. A single placeholder nil bucket keeps the track a stable
width before the first 1 Hz bucket so the row doesn't reflow. GPS off
hides the icon + sparkline entirely.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

> **Device verification (2.4):** With GPS push OFF, rows show only the antenna + RSSI sparkline + battery (no GPS icon). Turn push ON: every row immediately gains a globe icon + an empty gray track (no reflow), then within ~1 s the first bucket appends. Under a good fix with one camera, bars go solid green. Force throttling (several cameras at 10 Hz) and confirm some rows show red or split bars while others stay green — the per-link unevenness the feature exists to surface. Leave GPS on indoors with no fix: bars advance as gray `nil` buckets (not solid red) — "didn't try," not "failed." Disconnect a camera with GPS on: its row keeps advancing gray. Compare the `#Preview` from Step 1 to confirm split/red/green/gray render as intended.

---

## Phase 2 exit criteria

- `make build-ci` ⇒ `** BUILD SUCCEEDED **` after every task.
- `grep -c GPSStatusBadge OsmoMulti.xcodeproj/project.pbxproj` ⇒ `0`; the file is gone from disk and detail view.
- Settings reveals the 1/10 Hz picker + live "±N m, last update Xs ago" / "No fix" readout under the GPS toggle.
- Top bar has a 3rd `.topBarLeading` GPS indicator coloring gray/red/green from `locationManager.fixState`.
- Each camera row shows an antenna-prefixed RSSI sparkline and, only while `locationManager.isActive`, a satellite-prefixed `GPSSendHealthView` that does not reflow the row.
- No `TimelineView`/per-view timer was added to `GPSSendHealthView` (single model timer drives `@Observable` re-renders).

All UI is on a device-verification footing because BLE + SwiftUI rendering are not exercisable in this environment; the only assertable logic added this phase (the split-bar mapping) is eyeballed via the `#Preview` from Task 2.4 Step 1.
---

## Phase 3 — Watch: GPS fix relay to the Apple Watch

**Preconditions (from Phase 1):** `OsmoLocationManager` exposes `var fixState: GPSFixState` where `enum GPSFixState { case off, noFix, good }`. The `OsmoMulti` (iOS) target links `DJIOsmoKit`, so `WatchBridge` can reference `GPSFixState`. The `OsmoWatch` target does **NOT** link `DJIOsmoKit` (verified in `project.yml` lines 95-107 — no `DJIOsmoKit` dependency), so all watch-side code (`WatchViewModel`, `WatchControlView`) MUST use the plain relayed strings `"off"` / `"noFix"` / `"good"` and never the `GPSFixState` enum.

**Why no XCTest in this phase:** every change here is either WatchConnectivity bridge plumbing (`WatchBridge`/`OsmoMultiApp` — needs a real paired watch + WCSession, not unit-testable in `DJIOsmoKitTests`) or SwiftUI watch views (`WatchViewModel`/`WatchControlView` — not unit-testable in this project). So each task verifies via `make build-ci` (compile-only, no signing) plus an explicit on-device verification note. Per `CLAUDE.md`, BLE/WCSession only work on physical hardware — device verification is manual after install.

**Build/verify commands used throughout:**
- Compile-only: `make build-ci` → builds via the `OsmoMulti` scheme for `generic/platform=iOS`, compiling both `OsmoMulti` and the embedded `OsmoWatch` target. Expected on success: `** BUILD SUCCEEDED **`.
- (No `make test` in this phase — no new framework unit logic.)

---

### Task 3.1 — Thread `OsmoLocationManager` into `WatchBridge`

**Files:**
- Modify: `/Users/payton/me/dev/djibt/OsmoMulti/Watch/WatchBridge.swift` (property after line 18; constructor signature + body lines 23-35)
- Modify: `/Users/payton/me/dev/djibt/OsmoMulti/App/OsmoMultiApp.swift` (line 24)
- Test: none (WCSession bridge — compile-only + device note)

- [ ] **Step 1: Add the stored `locationManager` property to `WatchBridge`.**
  In `/Users/payton/me/dev/djibt/OsmoMulti/Watch/WatchBridge.swift`, the current stored properties (lines 18-21) are:
  ```swift
      private let manager: OsmoCameraManager
      private let session: WCSession
      private var pushTimer: Timer?
      private var lastPushedContext: [String: Any] = [:]
  ```
  Replace with (adds `locationManager` directly under `manager`):
  ```swift
      private let manager: OsmoCameraManager
      private let locationManager: OsmoLocationManager
      private let session: WCSession
      private var pushTimer: Timer?
      private var lastPushedContext: [String: Any] = [:]
  ```

- [ ] **Step 2: Update the `WatchBridge` constructor signature + assignment.**
  The current constructor (lines 23-35) is:
  ```swift
      init(cameraManager: OsmoCameraManager) {
          self.manager = cameraManager
          self.session = WCSession.default
          super.init()
          guard WCSession.isSupported() else {
              log.warning("WCSession not supported on this device")
              return
          }
          log.info("WCSession supported — activating")
          session.delegate = self
          session.activate()
          startStatePushTimer()
      }
  ```
  Replace with (adds the `locationManager:` parameter and its assignment; note `OsmoLocationManager` is `@MainActor`/`@Observable`, and `WatchBridge` is already `@MainActor`, so storing the reference is safe — `super.init()` ordering is unchanged because both assignments precede it):
  ```swift
      init(cameraManager: OsmoCameraManager, locationManager: OsmoLocationManager) {
          self.manager = cameraManager
          self.locationManager = locationManager
          self.session = WCSession.default
          super.init()
          guard WCSession.isSupported() else {
              log.warning("WCSession not supported on this device")
              return
          }
          log.info("WCSession supported — activating")
          session.delegate = self
          session.activate()
          startStatePushTimer()
      }
  ```

- [ ] **Step 3: Update the call site in `OsmoMultiApp.init`.**
  In `/Users/payton/me/dev/djibt/OsmoMulti/App/OsmoMultiApp.swift`, line 24 is:
  ```swift
          watchBridge = WatchBridge(cameraManager: manager)
  ```
  Replace with (line 23 already initialized `locationManager`, so ordering is correct):
  ```swift
          watchBridge = WatchBridge(cameraManager: manager, locationManager: locationManager)
  ```

- [ ] **Step 4: Compile.**
  Run: `make build-ci`
  Expected: `** BUILD SUCCEEDED **`. (This catches the constructor mismatch — if the call site or signature were inconsistent it would fail with "missing argument for parameter 'locationManager'".)

- [ ] **Step 5: Commit.**
  ```bash
  git add OsmoMulti/Watch/WatchBridge.swift OsmoMulti/App/OsmoMultiApp.swift
  git commit -m "WatchBridge: inject OsmoLocationManager dependency

Add locationManager parameter to WatchBridge(cameraManager:locationManager:)
and thread it from OsmoMultiApp.init so the bridge can relay GPS fix state.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 3.2 — Relay `gpsFix` in `pushStateIfChanged` (dict + change-detection)

**Files:**
- Modify: `/Users/payton/me/dev/djibt/OsmoMulti/Watch/WatchBridge.swift` (context dict lines 56-62; change-detection block lines 72-78; new private helper near line 91)
- Test: none (WCSession push — compile-only + device note)

- [ ] **Step 1: Add a private `GPSFixState` → relay-string helper.**
  `OsmoWatch` does not link `DJIOsmoKit`, so the wire format must be a plain `String`. The spec mandates exactly `"off"` / `"noFix"` / `"good"` (L107). Phase 1 declared `GPSFixState: String` with exactly those raw values, so `locationManager.fixState.rawValue` would also work — but we map with an explicit `switch` so the watch wire format is decoupled from (and won't silently drift with) any future change to the enum's raw values. In `/Users/payton/me/dev/djibt/OsmoMulti/Watch/WatchBridge.swift`, the `availableIntents(for:)` helper currently begins at line 91-92:
  ```swift
      /// Keep the watch mode picker aligned with the iPhone global controls.
      private func availableIntents(for targets: [OsmoCamera]) -> [ModeIntent] {
  ```
  Insert this new helper immediately *above* that doc comment (so it sits between `pushStateIfChanged()` and `availableIntents(for:)`):
  ```swift
      /// Wire-format string for the watch GPS indicator. OsmoWatch does not link
      /// DJIOsmoKit, so the watch never sees `GPSFixState` — only these strings.
      private func gpsFixString() -> String {
          switch locationManager.fixState {
          case .off:   return "off"
          case .noFix: return "noFix"
          case .good:  return "good"
          }
      }

  ```

- [ ] **Step 2: Add `gpsFix` to the context dict.**
  The current dict literal (lines 56-62) is:
  ```swift
          var context: [String: Any] = [
              "connectedCount": connectedCameras.count,
              "enabledCount": enabledCount,
              "availableModes": availableIntents(for: connectedCameras).map(\.rawValue),
              "isRecording": connectedCameras.contains { $0.status.recordingStatus.isRecording },
              "timestamp": Date().timeIntervalSince1970
          ]
  ```
  Replace with (adds `gpsFix` as a non-optional `String` so it is always present — no `if let` guard needed because `gpsFixString()` never returns nil; `WCSession` only rejects `NSNull`/nil, not a plain `String`):
  ```swift
          var context: [String: Any] = [
              "connectedCount": connectedCameras.count,
              "enabledCount": enabledCount,
              "availableModes": availableIntents(for: connectedCameras).map(\.rawValue),
              "isRecording": connectedCameras.contains { $0.status.recordingStatus.isRecording },
              "gpsFix": gpsFixString(),
              "timestamp": Date().timeIntervalSince1970
          ]
  ```

- [ ] **Step 3: Add `gpsFix` to the explicit change-detection comparison.**
  This is the load-bearing step from the spec (L107): "Add `gpsFix` to BOTH the context dict AND the change-detection comparison ... omit it from the comparison and the watch never updates on GPS-only changes." The current block (lines 72-78) is:
  ```swift
          let changed = lastPushedContext.isEmpty
              || (lastPushedContext["connectedCount"] as? Int) != (context["connectedCount"] as? Int)
              || (lastPushedContext["enabledCount"] as? Int) != (context["enabledCount"] as? Int)
              || (lastPushedContext["availableModes"] as? [String]) != (context["availableModes"] as? [String])
              || (lastPushedContext["currentMode"] as? String) != (context["currentMode"] as? String)
              || (lastPushedContext["isRecording"] as? Bool) != (context["isRecording"] as? Bool)
              || (lastPushedContext["batteryPercent"] as? Int) != (context["batteryPercent"] as? Int)
  ```
  Replace with (appends the `gpsFix` comparison as a new final clause):
  ```swift
          let changed = lastPushedContext.isEmpty
              || (lastPushedContext["connectedCount"] as? Int) != (context["connectedCount"] as? Int)
              || (lastPushedContext["enabledCount"] as? Int) != (context["enabledCount"] as? Int)
              || (lastPushedContext["availableModes"] as? [String]) != (context["availableModes"] as? [String])
              || (lastPushedContext["currentMode"] as? String) != (context["currentMode"] as? String)
              || (lastPushedContext["isRecording"] as? Bool) != (context["isRecording"] as? Bool)
              || (lastPushedContext["batteryPercent"] as? Int) != (context["batteryPercent"] as? Int)
              || (lastPushedContext["gpsFix"] as? String) != (context["gpsFix"] as? String)
  ```

- [ ] **Step 4: Compile.**
  Run: `make build-ci`
  Expected: `** BUILD SUCCEEDED **`. (Verifies `gpsFixState()`/`fixState` resolve against the `GPSFixState` enum from Phase 1 and the switch is exhaustive — a non-exhaustive switch would fail with "switch must be exhaustive".)

- [ ] **Step 5: Device-verification note (manual, requires paired Apple Watch + iPhone with cameras).**
  Build + install to a physical iPhone and its paired watch (`make build` then `make install` + `make install-watch`, device IDs from `make devices`). Then, with the watch app open and `make logs` streaming the iPhone subsystem:
  1. Toggle "Push GPS to Cameras" ON in iOS Settings — within ~1-3 s expect a `pushState: pushed` log line, because `gpsFix` flipped `"off"` → `"noFix"`/`"good"` and the new comparison clause now detects it even when counts/recording are unchanged.
  2. Toggle GPS OFF — expect another `pushState: pushed` (`gpsFix` back to `"off"`). Before this task, a GPS-only change produced no push (proving the comparison clause is necessary).
  Acceptable lag: `updateApplicationContext` is system-coalesced, so the watch dot may trail by seconds (spec L110) — that is expected, not a bug.

- [ ] **Step 6: Commit.**
  ```bash
  git add OsmoMulti/Watch/WatchBridge.swift
  git commit -m "WatchBridge: relay GPS fixState as gpsFix string

Add gpsFixString() mapping GPSFixState -> off/noFix/good and include it in
both the WCSession context dict and the explicit change-detection block so
the watch updates on GPS-only changes (it would otherwise be ignored).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 3.3 — `WatchViewModel` reads `gpsFix` (default `"off"`)

**Files:**
- Modify: `/Users/payton/me/dev/djibt/OsmoWatch/ViewModels/WatchViewModel.swift` (property after line 18; `applyContext` lines 59-67)
- Test: none (watch `@Observable` view model — compile-only + device note)

- [ ] **Step 1: Add the `gpsFix` observable property.**
  In `/Users/payton/me/dev/djibt/OsmoWatch/ViewModels/WatchViewModel.swift`, the current observable properties (lines 12-19) are:
  ```swift
      var connectedCount: Int = 0
      var enabledCount: Int = 0
      var currentMode: String?
      /// Raw `ModeIntent` values supplied by the iPhone so watch mode choices match the main app.
      var availableModes: [String] = WatchMode.allCases.map(\.value)
      var isRecording: Bool = false
      var batteryPercent: Int?
      var isReachable: Bool = false
  ```
  Replace with (adds `gpsFix` after `batteryPercent`; default `"off"` so the indicator is hidden before any context arrives — matches the spec's "default off when absent", L108):
  ```swift
      var connectedCount: Int = 0
      var enabledCount: Int = 0
      var currentMode: String?
      /// Raw `ModeIntent` values supplied by the iPhone so watch mode choices match the main app.
      var availableModes: [String] = WatchMode.allCases.map(\.value)
      var isRecording: Bool = false
      var batteryPercent: Int?
      /// Relayed GPS fix state from the iPhone: "off" / "noFix" / "good". Plain String
      /// because OsmoWatch does not link DJIOsmoKit and never sees GPSFixState.
      var gpsFix: String = "off"
      var isReachable: Bool = false
  ```

- [ ] **Step 2: Read `gpsFix` in `applyContext`.**
  The current `applyContext` (lines 59-67) is:
  ```swift
      private func applyContext(_ context: [String: Any]) {
          connectedCount = context["connectedCount"] as? Int ?? 0
          enabledCount = context["enabledCount"] as? Int ?? 0
          currentMode = context["currentMode"] as? String
          availableModes = context["availableModes"] as? [String] ?? WatchMode.allCases.map(\.value)
          isRecording = context["isRecording"] as? Bool ?? false
          batteryPercent = context["batteryPercent"] as? Int
          log.info("applyContext: enabled=\(self.enabledCount) connected=\(self.connectedCount) mode=\(self.currentMode ?? "nil", privacy: .public) modes=\(self.availableModes.count) recording=\(self.isRecording)")
      }
  ```
  Replace with (reads `gpsFix` with `?? "off"`, and adds it to the log line for device debugging):
  ```swift
      private func applyContext(_ context: [String: Any]) {
          connectedCount = context["connectedCount"] as? Int ?? 0
          enabledCount = context["enabledCount"] as? Int ?? 0
          currentMode = context["currentMode"] as? String
          availableModes = context["availableModes"] as? [String] ?? WatchMode.allCases.map(\.value)
          isRecording = context["isRecording"] as? Bool ?? false
          batteryPercent = context["batteryPercent"] as? Int
          gpsFix = context["gpsFix"] as? String ?? "off"
          log.info("applyContext: enabled=\(self.enabledCount) connected=\(self.connectedCount) mode=\(self.currentMode ?? "nil", privacy: .public) modes=\(self.availableModes.count) recording=\(self.isRecording) gps=\(self.gpsFix, privacy: .public)")
      }
  ```

- [ ] **Step 3: Compile.**
  Run: `make build-ci`
  Expected: `** BUILD SUCCEEDED **`. (Compiles the embedded `OsmoWatch` target — verifies the new property + `applyContext` line type-check on watchOS.)

- [ ] **Step 4: Commit.**
  ```bash
  git add OsmoWatch/ViewModels/WatchViewModel.swift
  git commit -m "WatchViewModel: read relayed gpsFix string (default off)

Add gpsFix observable property and parse context[\"gpsFix\"] in applyContext,
defaulting to \"off\" when the key is absent. Plain String — OsmoWatch does
not link DJIOsmoKit.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Task 3.4 — `WatchControlView` satellite indicator (icon + color, no text, hidden when off)

**Files:**
- Modify: `/Users/payton/me/dev/djibt/OsmoWatch/Views/WatchControlView.swift` (`statusSection` lines 68-83; new computed `gpsIndicator` + helper in the Helpers section near line 133)
- Test: none (SwiftUI watch view — compile-only + device note)

- [ ] **Step 1: Add the GPS indicator into `statusSection`.**
  The spec (L109) requires: small satellite icon, tri-state color, NO text label, hidden entirely when `"off"` (red = `"noFix"`, green = `"good"`). The current `statusSection` (lines 68-83) is:
  ```swift
      private var statusSection: some View {
          HStack {
              Image(systemName: "camera.sensor.tag.radiowaves.left.and.right.fill")
                  .foregroundStyle(.secondary)
              Text("\(viewModel.connectedCount)/\(viewModel.enabledCount)")
                  .font(.headline)
              Spacer()
              if let battery = viewModel.batteryPercent {
                  Image(systemName: batterySymbol(for: battery))
                      .foregroundStyle(batteryColor(for: battery))
                  Text("\(battery)%")
                      .font(.subheadline)
                      .foregroundStyle(.secondary)
              }
          }
      }
  ```
  Replace with (inserts `gpsIndicator` to the right of the battery readout, after the `if let battery` block, still inside the same `HStack`; placement mirrors the spec note "likely right of battery"):
  ```swift
      private var statusSection: some View {
          HStack {
              Image(systemName: "camera.sensor.tag.radiowaves.left.and.right.fill")
                  .foregroundStyle(.secondary)
              Text("\(viewModel.connectedCount)/\(viewModel.enabledCount)")
                  .font(.headline)
              Spacer()
              if let battery = viewModel.batteryPercent {
                  Image(systemName: batterySymbol(for: battery))
                      .foregroundStyle(batteryColor(for: battery))
                  Text("\(battery)%")
                      .font(.subheadline)
                      .foregroundStyle(.secondary)
              }
              gpsIndicator
          }
      }

      /// Tri-state GPS fix dot: hidden when "off", red for "noFix", green for "good".
      /// Icon + color only — no text label (small-screen budget, spec L109).
      @ViewBuilder
      private var gpsIndicator: some View {
          if let color = gpsColor(for: viewModel.gpsFix) {
              Image(systemName: "location.fill")
                  .font(.subheadline)
                  .foregroundStyle(color)
                  .accessibilityLabel(viewModel.gpsFix == "good" ? "GPS fix" : "No GPS fix")
          }
      }
  ```
  Note on the SF Symbol: `"location.fill"` is the GPS/positioning glyph guaranteed across watchOS versions. If a literal satellite glyph (e.g. `"dot.radiowaves.up.forward"`) is preferred and confirmed available on the target watchOS at device-verify time, swap the `systemName` string only — the color/visibility logic is unaffected.

- [ ] **Step 2: Add the `gpsColor(for:)` helper.**
  The current Helpers section (lines 133-151) ends with `batteryColor(for:)`:
  ```swift
      // MARK: - Helpers

      private func batterySymbol(for percent: Int) -> String {
          switch percent {
          case 76...100: return "battery.100"
          case 51...75: return "battery.75"
          case 26...50: return "battery.50"
          case 1...25: return "battery.25"
          default: return "battery.0"
          }
      }

      private func batteryColor(for percent: Int) -> Color {
          switch percent {
          case 0...15: return .red
          case 16...30: return .orange
          default: return .green
          }
      }
  }
  ```
  Replace that whole block with (adds `gpsColor(for:)` after `batteryColor(for:)`; returns `nil` for `"off"` and any unknown value so the indicator is hidden — the `if let color` in Step 1 drives visibility):
  ```swift
      // MARK: - Helpers

      private func batterySymbol(for percent: Int) -> String {
          switch percent {
          case 76...100: return "battery.100"
          case 51...75: return "battery.75"
          case 26...50: return "battery.50"
          case 1...25: return "battery.25"
          default: return "battery.0"
          }
      }

      private func batteryColor(for percent: Int) -> Color {
          switch percent {
          case 0...15: return .red
          case 16...30: return .orange
          default: return .green
          }
      }

      /// nil => indicator hidden (GPS off / unknown). red => noFix, green => good.
      private func gpsColor(for fix: String) -> Color? {
          switch fix {
          case "noFix": return .red
          case "good":  return .green
          default:      return nil   // "off" and any unexpected value: hidden
          }
      }
  }
  ```

- [ ] **Step 3: Compile.**
  Run: `make build-ci`
  Expected: `** BUILD SUCCEEDED **`. (Type-checks the new `@ViewBuilder` computed property + helper on watchOS.)

- [ ] **Step 4: Device-verification note (manual, requires paired Apple Watch + iPhone with cameras).**
  Install to device + watch (`make build`, `make install`, `make install-watch`). With the watch app foregrounded:
  1. GPS push OFF on iPhone → watch `statusSection` shows NO satellite dot (hidden). Confirm no empty gap is reserved (the `if let` removes the view entirely).
  2. GPS push ON, indoors / before fix → dot appears RED (`gpsFix == "noFix"`).
  3. Move where a valid fix lands (`horizontalAccuracy >= 0`) → dot turns GREEN (`gpsFix == "good"`).
  4. Toggle GPS OFF → dot disappears again.
  Lag of a few seconds on each transition is expected (system-coalesced `updateApplicationContext`, spec L110).

- [ ] **Step 5: Commit.**
  ```bash
  git add OsmoWatch/Views/WatchControlView.swift
  git commit -m "WatchControlView: tri-state GPS satellite indicator

Add an icon-only GPS fix dot to statusSection: hidden when off, red for
noFix, green for good. No text label per design (small-screen budget).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  ```

---

### Phase 3 exit criteria

- `make build-ci` → `** BUILD SUCCEEDED **` after every task (iOS + embedded watch compile clean).
- `WatchBridge(cameraManager:locationManager:)` is the only constructor; `OsmoMultiApp.init` passes both.
- `gpsFix` appears in BOTH the `pushStateIfChanged` context dict AND the explicit change-detection comparison.
- `WatchViewModel.gpsFix` defaults to `"off"` and is set from `context["gpsFix"]`.
- On device: watch satellite dot hidden when off, red on noFix, green on good (a few-second relay lag is acceptable).