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

All agents work against the same `OsmoMulti.xcodeproj`. Build with:
```bash
# iOS targets (DJIOsmoKit, OsmoMulti)
xcodebuild -project OsmoMulti.xcodeproj -target <Target> -sdk iphoneos26.2 \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# watchOS target
xcodebuild -project OsmoMulti.xcodeproj -target OsmoWatch -sdk watchos26.2 \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

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


