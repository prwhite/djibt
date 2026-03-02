# Multi DJI OSMO Controller iOS app.

We are building an iOS app to control multiple DJI Osmo cameras simultaneously over the DJI Osmo Bluetooth protocol.

## Reference for the DJI BT protocol:

Project home: https://github.com/dji-sdk/Osmo-GPS-Controller-Demo

Supporting docs: https://github.com/dji-sdk/Osmo-GPS-Controller-Demo/blob/main/docs/getting_started_guide.md

* This example project is written for ESP32, but that's not an ideal platform for this for more general use.
* This is written for managing a _single camera_, which is not enough for a lot of advanced users. So we will develop _from the start_ the structure to handle multiple cameras (maybe 10 is a good practical max to think about, but that's not a hard limit).

## Architecture

* As we reinterpret the ESP32 code and the spec into Swift code, we should build a library encapsulating the communication protocol. Use Apple/Swift idioms for thread management/async operation, event emission, etc.
  * The library should have an class that represents a single camera connection, and then a manager class that manages all instances of cameras. Then the UI will be a client of these types.
* I get the feeling the way the protocol works, we will maybe have to round-robin connections to each camera (but maybe that's a bad assumption simply based on how the ESP32 example code is built). We should definitely be showing in the UI the recency of when a camera has been communicated with. And this should be a property (or set of properties) available in the API.

## UX

* The main interface is a list view of all paired cameras showing their brief status.
* Clicking on a camera in the list view will go to more info, and potentially have troubleshooting UI. One of the big problems with this protocol is cameras drop in and out of communication all the time. So diagnosing and healing these cases will have great value. Potentially, if we can automatically heal stuff, we won't need so much troubleshooting interface.
* Keeping in mind iOS platform norms, the main view should also include a "+" button to add new camera pairings. This should probably bring up a modal to do the pairing operation.
* At the top(?) of the UI will be controls for: 1) start/stop video recording, take picture, sleep, wake, force reconnect (maybe) that will apply to the set of paired cameras.
* The list view of cameras will have to sub sections 1) enabled cameras and 2) disabled cameras. By doing a left swipe on an enabled item, it will become disabled, and vice versa. The definition of "enabled" is a camera that the app is actively communicating with. A user would "disable" a camera that's paired if it wasn't necessary for a particular session, etc. This makes it easy to re-enable a camera in a future session rather than going through the pairing sequence again. We'll have to pivot this plan if we don't think this is possible with the protocol as we get deeper into reading the docs and doing dev/testing.
* Stretch goal: It would be nice to show periodically updated images from the cameras... if not for all cameras in the list view, at least when you browse to a specific camera's view. I don't know if this is available in the protocol though. Maybe we RE this as we complete other tasks.
  * Maybe in lieu of this, in the list view we show product images for the particular type of camera connected. 

## UI

* Let's do best-practices for iOS, including using SwiftUI and aligning with system day/night mode setting.
* We don't want to use DJI's Mimo app as a model for our UI... there stuff tends to be clunky and not in line with iOS idioms.

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

## Workflow

### Screenshots for UI feedback

Always run on a **physical device** (BLE doesn't work in the simulator).

Use **Xcode → Window → Devices and Simulators → select device → camera icon** — saves to Desktop automatically.

Then say "screenshot is on the Desktop" and Claude will read the newest `.png` from `~/Desktop/`.

### Logs (device attached via USB or same Wi-Fi)
```bash
# iPhone app
log stream --predicate 'subsystem == "me.payton.OsmoMulti"' --level debug
# Filter by category:
log stream --predicate 'subsystem == "me.payton.OsmoMulti" AND category == "BLE.Conn"' --level debug
# Watch app
log stream --predicate 'subsystem == "me.payton.OsmoMulti.watchkitapp"' --level debug
```


