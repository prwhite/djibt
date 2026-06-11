# GPS Staleness + Void Frames — Decisions

**Date:** 2026-06-12
**Context:** Device-verification of recorded photos/videos (branch work on `main`)
showed the cameras embedding a **stale GPS position** in two situations. This doc
captures the resulting behavior so the "current GPS take" is written down.

## Problems observed on-device

1. **We pushed valid-but-old fixes.** A photo session at a desk (indoors, no fresh
   GPS) embedded a **~15-hour-old** coordinate: CoreLocation kept handing back the
   last good `lastLocation`, and we pushed it because it had valid accuracy. Our
   push guard checked `hasValidGPSFix` (accuracy ≥ 0) but **not age**.
2. **The camera caches the last fix.** With GPS push turned **off**, the camera
   kept embedding its last-known position (confirmed: identical lat/lon across a
   15-hour gap, while the barometer-fused altitude drifted). "GPS off" did **not**
   mean "no geotag" — it meant "stale geotag".

Both are camera/firmware-driven (the camera re-encodes position into its own `djmd`
protobuf and latches the last value), but #1 is also on us — we fed it the old fix.

## The mechanism we use: the satellite-number gate

The 48-byte GPS push payload carries `satellite_number` at offset 44. The camera
treats **`satellite_number = 0` as "no valid fix" → it marks GPS `Measurement Void`
and drops the position** (embeds `0,0`). We verified this on-device: blasting a few
0-sat frames flips a cached `Active` fix to `Void`. So an explicit 0-sat ("Void")
frame is how we tell the camera to stop trusting its cache. (The faked
`nominalSatelliteCount = 8` we send on a good fix is **gate-only** — no DJI
extraction tool surfaces a satellite count, so it never reaches recorded telemetry.)

## Decisions

**Freshness = valid AND recent.** `OsmoLocationManager.hasFreshFix` is the single
source of truth: `lastLocation.hasValidGPSFix && age < maxFixAge`. It drives both
the push decision and `fixState` (so the top-bar dot and Settings readout go honest
— a stale fix reads **No fix**, not green).

**`maxFixAge = 20 s`.** Apple's sample-code convention for rejecting stale/cached
locations is ~15 s. We use **20 s** for margin: even a *healthy stationary* fix ages
to ~14–15 s between CL deliveries, because CoreLocation is **change-driven** (a still
phone reports sparsely; moving reports every 3–6 s). 20 s clears the observed
stationary gap, and the real failure case (a 15-hour-old fix, or signal loss) is
astronomically past it.

**Kept it a single age threshold — no motion/speed gating.** A speed-gated approach
(stationary = never stale, moving = tighter) was considered and **rejected**: it just
shifts the problem to tuning a speed threshold that's much harder to test, for a case
the simple 20 s cap already handles. Simplicity wins.

**What we send, per push tick (while GPS push is on):**
- **Fresh fix** → push the real fix (`satellite_number = 8`) at the selected rate.
- **No fresh fix** (cold start before first fix, signal lost, or stale) → push a
  **Void** frame (`0,0`, `satellite_number = 0`), throttled to ~1 Hz. Continuous (not
  edge-triggered) so it covers cold-start, where there's no Live→Lost transition.
- **GPS toggled off** → a short **Void burst** before `stop()` tears down the timer,
  so the camera clears its cache instead of latching the last real fix.

**`pausesLocationUpdatesAutomatically = false`** — set, but it did **not** change the
stationary gaps (they're CL's change-driven nature, not auto-pause). Kept anyway as a
sensible setting for a continuous-geotagging app.

## Verified on-device

Photo sequence (on → off → on): real `Active` fix ×3 → `0,0 / Void` ×3 → real
`Active` ×2. Video positive case: 463-sample timed GPS track embeds correctly.

## Out of scope / deferred

- **3-region send-health sparkline** (green sent / red link-dropped / gray void).
  Today Void frames still record as *sent* (green), so the per-camera graph reads
  green during a stale state — mildly misleading, but the top-bar dot is honest.
  Parked in `BACKLOG.md` (needs a send-health model change).
