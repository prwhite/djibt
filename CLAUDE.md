# Cam Control for DJI Osmo

iOS + watchOS app to control multiple DJI Osmo cameras simultaneously over Bluetooth Low Energy. Implements the [DJI Osmo BT protocol](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) in native Swift.

## Architecture

Three-layer structure:
1. **DJIOsmoKit** — embedded framework with all BLE + protocol logic (`OsmoCamera`, `OsmoCameraManager`)
2. **OsmoMulti** — SwiftUI iOS app (views, view models, WatchBridge, AppIntents)
3. **OsmoWatch** — watchOS companion (proxies commands through iPhone via WatchConnectivity)

See `README.md` for full architecture details and protocol documentation.

## Supported Cameras

Tested with DJI Osmo Action 4, Action 5, and Osmo 360. The 360 uses panoramic modes (panoVideo/panoPhoto/panoTimelapse) mapped via `ModeIntent`.

## Agent Team

The project uses a team-lead + specialist model, where Claude (as team-lead) coordinates specialists.

### Current Team Structure

| Agent | Speciality | Typical Tasks |
|---|---|---|
| **team-lead** (Claude) | Architecture, coordination | Reviews, wires things together, resolves cross-cutting issues |
| **protocol-engineer** | DJIOsmoKit framework internals | CRC, frame parsing, BLE layer, command implementations |
| **ui-engineer** | SwiftUI views & view models | List views, detail views, modal flows, animations |
| **integrator** | Cross-layer wiring + testing | Connects framework ↔ UI, ensures compilation, writes integration tests |

### When to Use the Team

Spawn agents when a task is clearly scoped to one layer and won't require coordination:
- Protocol tweaks → protocol-engineer
- UI changes → ui-engineer
- Cross-layer changes → do yourself or use integrator

All agents work against the same `OsmoMulti.xcodeproj`. Prefer the Makefile (`make help` lists targets); raw commands:
```bash
xcodegen generate            # make gen — after editing project.yml

# Signed device build — app + valid embedded watch app (automatic signing, team L485BLVU52)
xcodebuild -project OsmoMulti.xcodeproj -scheme OsmoMulti \
  -destination 'generic/platform=iOS' -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build                # make build

# Compile-only check, no signing — add: CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""  # make build-ci

# Install built app / embedded watch app to a device (see 'make devices' for IDs)
xcrun devicectl device install app --device <id> build/Build/Products/Debug-iphoneos/OsmoMulti.app             # make install / deploy
xcrun devicectl device install app --device <id> build/Build/Products/Debug-iphoneos/OsmoMulti.app/Watch/OsmoWatch.app  # make install-watch
```

> **⚠️ Build via the scheme, NOT `-target OsmoMulti -sdk iphoneos`.** `-sdk iphoneos` forces *every* target in the graph — including the embedded `OsmoWatch` — through the iOS SDK, which omits the `WKApplication` Info.plist key. The build & signing succeed, but on-device install fails with `InvalidWatchKitApp` / `CoreDeviceError 3002`. (Archive/TestFlight builds are unaffected — they build each target for its own platform, which is why beta builds were always valid.) The scheme + `generic/platform=iOS` form builds each target for its correct platform. Keep `-sdk` **unpinned** (not `iphoneos26.4`) so builds survive Xcode SDK bumps.
>
> **Fresh-machine gotcha:** builds need the **matching iOS _and_ watchOS Simulator runtimes installed — even for device builds.** The app icon is an Icon Composer `.icon`, and `actool` needs the runtime matching the active SDK or the build dies with *"No simulator runtime … available."* The scheme also embeds + builds the watch app, so the watchOS SDK + runtime are mandatory. Install both via `xcodebuild -downloadPlatform iOS && xcodebuild -downloadPlatform watchOS` (`make runtimes`).

## xcodegen

Project generated from `project.yml` at root. Regenerate with: `xcodegen generate`

**Important:** All project settings (targets, schemes, icon references, Info.plist properties) must be defined in `project.yml`. Running `xcodegen generate` overwrites the `.xcodeproj` entirely — any manual Xcode changes will be lost.

Schemes are defined in the top-level `schemes:` section of `project.yml`. Both OsmoMulti and OsmoWatch use Release config for Run (set via `run: config: Release`). The OsmoWatch scheme specifies `executable: OsmoWatch` to launch the watch app instead of the iOS app.

## Workflow

### Screenshots for UI feedback

Always run on a **physical device** (BLE doesn't work in the simulator).

Use **Xcode → Window → Devices and Simulators → select device → camera icon** — saves to Desktop automatically.

Then say "screenshot is on the Desktop" and Claude will read the newest `.png` from `~/Desktop/`.

### Logs (device attached via USB or same Wi-Fi)
```bash
# iPhone app
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl"' --level debug
# Filter by category:
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl" AND category == "BLE.Conn"' --level debug
# Watch app
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl.watchkitapp"' --level debug
```


