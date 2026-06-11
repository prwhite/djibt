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
