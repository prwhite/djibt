# Cam Control for DJI Osmo

A native iOS app to control multiple DJI Osmo cameras simultaneously over Bluetooth Low Energy.

Implements the [DJI Osmo Bluetooth protocol](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) in native Swift, based on DJI's ESP32 reference code. No official DJI SDK dependency.

## Features

- **Multi-camera management** — connect, monitor, and control up to 10+ cameras at once
- **Global controls** — start/stop recording, capture photos, switch modes, and sleep all cameras simultaneously
- **Live status** — real-time battery, resolution, frame rate, stabilization mode, storage/time remaining, GPS push state, and recording state for every connected camera
- **Recording timer** — per-camera elapsed recording time displayed in the camera list
- **GPS geotagging** — pushes iPhone GPS coordinates to cameras at 10 Hz for accurate video location metadata
- **Apple Watch companion** — status, mode switching, and shutter control from your wrist via WatchConnectivity
- **Siri Shortcuts** — "Start recording with Cam Control", "Stop recording", and "Sleep cameras" via AppIntents
- **Haptic feedback** — tactile response on shutter/record/stop actions and camera connection state changes
- **Connection resilience** — automatic reconnection with configurable watchdog timeout and retry limits
- **Camera diagnostics** — per-camera detail view with connection state, RSSI signal strength, firmware version, product ID, raw frame sender, and force-reconnect
- **Expanded mode support** — Video, Subject Tracking, Photo, Slow Motion, SuperNight, Timelapse, Hyperlapse, and Osmo 360 panoramic/single-lens mode mapping

## Requirements

- iOS 26.0+ / watchOS 26.0+
- Physical iOS device (BLE does not work in the Simulator)
- Apple Watch (optional, for companion app)
- One or more DJI Osmo cameras (tested with Action 4, Action 5, Osmo 360)

## Architecture

The project is split into three layers:

```
DJIOsmoKit/          Framework — all BLE + protocol logic
  ├── BLE/           Scanner and per-peripheral GATT connection
  ├── Camera/        OsmoCamera (single camera) + OsmoCameraManager (coordinator)
  ├── Location/      Core Location wrapper for GPS push
  ├── Models/        CameraMode, CameraStatus, ConnectionState
  └── Protocol/      CRC, frame builder/parser, command implementations

OsmoMulti/           iOS app — SwiftUI views, view models, WatchConnectivity bridge
  ├── App/           Entry point + environment wiring
  ├── Views/         CameraListView, CameraDetailView, GlobalControlsView, etc.
  ├── ViewModels/    CameraListViewModel
  ├── Intents/       AppIntents for Siri Shortcuts (Shutter, Stop, Sleep)
  └── Watch/         WatchBridge — relays commands and state between watch and cameras

OsmoWatch/           watchOS companion app
  ├── App/           Entry point
  ├── Views/         WatchControlView — status, mode picker, shutter button
  └── ViewModels/    WatchViewModel — WCSession delegate
```

**DJIOsmoKit** is an embedded framework in the same Xcode project. It exposes `OsmoCameraManager` as the main entry point — an `@Observable @MainActor` singleton that manages all camera connections, BLE scanning, and command dispatch.

**OsmoMulti** is a SwiftUI client that observes the framework's state and presents the UI. It also hosts `WatchBridge`, which bridges camera state and commands to the watch app via WatchConnectivity.

**OsmoWatch** is a minimal watchOS companion that shows camera status (connected count, battery), a mode picker, and a shutter button. It cannot use CoreBluetooth directly — watchOS BLE is foreground-only and disconnects on wrist-down. Instead, commands go to the iPhone via `sendMessage`, and state arrives via `updateApplicationContext`.

## Building

The Xcode project is generated from `project.yml` using [xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
# Generate the Xcode project
xcodegen generate

# Build the iOS app
xcodebuild -project OsmoMulti.xcodeproj -target OsmoMulti \
  -sdk iphoneos build

# Build the watchOS app
xcodebuild -project OsmoMulti.xcodeproj -target OsmoWatch \
  -sdk watchos build

# Run unit tests
xcodebuild -project OsmoMulti.xcodeproj -target DJIOsmoKitTests \
  -sdk iphoneos build
```

Or open `OsmoMulti.xcodeproj` in Xcode and build/run on a connected device. Deploy the watch app via the OsmoWatch scheme.

## DJI Osmo BLE Protocol

This app implements the DJI R SDK Bluetooth protocol as documented in the [Osmo GPS Controller Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo). Key details:

| Parameter | Value |
|---|---|
| Service UUID | `0xFFF0` |
| Write Characteristic | `0xFFF5` |
| Notify Characteristic | `0xFFF4` |
| Frame minimum size | 18 bytes |
| CRC-16 | Init `0x3AA3`, poly `0xA001` |
| CRC-32 | Init `0x3AA3`, poly `0xEDB88320` |

### Implemented Commands

| Command | CmdSet | CmdID | Description |
|---|---|---|---|
| Connection | `0x00` | `0x19` | 3-way handshake |
| Version Query | `0x00` | `0x00` | Firmware + product ID |
| Key Report | `0x00` | `0x11` | Shutter / button press |
| GPS Push | `0x00` | `0x17` | Location data for geotagging |
| Power Mode | `0x00` | `0x1A` | Sleep camera |
| Camera Status Push | `0x1D` | `0x02` | Parse live mode, recording, resolution, storage, battery, and power state |
| Recording | `0x1D` | `0x03` | Start/stop recording |
| Mode Switch | `0x1D` | `0x04` | Change camera mode |
| Status Subscribe | `0x1D` | `0x05` | Enable 1 Hz status push |
| Mode Details Push | `0x1D` | `0x06` | Parse newer display-ready mode name and parameter text |
| Raw Frame Sender | any | any | Diagnostic sender for complete `AA...CRC32` DJI frames |

### Connection Flow

1. **Scan** — filter by DJI manufacturer data signature (`0xAA`, `0x08`, `0xFA`)
2. **Connect** — GATT connection, discover service `0xFFF0`, subscribe to notify `0xFFF4`
3. **Handshake** — 3-way exchange: controller request → camera response → camera command → controller ACK
4. **Subscribe** — enable status push notifications
5. **Parse status** — decode `1D02` live status (38-byte payload at 1 Hz) and optional `1D06` mode detail text
6. **Version Query** — request product name and SDK version (non-fatal if it fails)

## Debugging

Attach a device via USB and stream logs:

```bash
# All iPhone app logs
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl"' --level debug

# Filter by category
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl" AND category == "BLE.Conn"' --level debug
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl" AND category == "Camera"' --level debug
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl" AND category == "Location"' --level debug

# Watch app logs
log stream --predicate 'subsystem == "net.prehiti.payton.CamControl.watchkitapp"' --level debug
```

Log categories (iPhone): `BLE.Scan`, `BLE.Conn`, `Camera`, `Manager`, `Protocol`, `Location`, `WatchBridge`
Log categories (Watch): `WatchVM`

A preview mode is available for UI development without real cameras:

```
Edit Scheme → Run → Arguments → Add "--preview-mode"
```

## Known Limitations

- **Wake from iOS is not possible.** The DJI protocol wakes cameras via a broadcast manufacturer-data BLE advertisement, which iOS does not support. Users must press a button on the camera to wake it from sleep.
- **Resolution changes are not implemented.** The public DJI BLE demo reports current resolution/fps in status, but does not document a set-resolution or set-fps command.
- **Video download is not supported.** DJI Osmo cameras transfer video over direct Wi-Fi, using an undocumented protocol. This feature is not implemented.
- **Mode switching is limited to modes accepted by the camera.** The app learns unsupported modes when `1D02` does not confirm a switch and hides them for that session.
- **Osmo 360 lens-group switching is not implemented.** The app maps mode intents within the camera's current panoramic or single-lens group; changing that group still needs to happen on-camera.
- Osmo Camera internal clock is not synchronized from GPS push due to SDK limitation (see [Setting clock and Time Code dji-sdk/Osmo-GPS-Controller-Demo#13](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo/issues/13)). 
- Timestamps in MP4 metadata depend on camera RTC when using DJI Mimo dashboard, not on pushed GPS timestamps.

## Privacy Policy

This app does not collect, store, or transmit any personal data beyond device-local BLE pairing and on-device location for geotagging. Location data is sent only to connected cameras over Bluetooth and is never transmitted to any server.

## License

MIT License. See [LICENSE](LICENSE) for details.

This project is not affiliated with or endorsed by DJI. The DJI Osmo Bluetooth protocol implementation is based on [DJI's open-source reference implementation](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo), licensed under MIT by SZ DJI Technology Co., Ltd. See [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES) for full attribution.
