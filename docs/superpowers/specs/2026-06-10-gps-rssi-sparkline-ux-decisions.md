# GPS / RSSI Sparkline UX + Top-Bar Toggle — Decisions

**Date:** 2026-06-10
**Context:** Device-verification of the GPS feature (branch `feature/gps-ui-and-plumbing`) surfaced UX issues in the per-camera RSSI/GPS sparklines and the top-bar GPS indicator. Decided via brainstorming; implemented inline (rapid device-iteration phase).

## Problems observed on-device
1. RSSI sparkline absent for non-connected cameras; GPS sparkline present even when disconnected → inconsistent.
2. GPS sparkline visibly **resets** (fills with empty/nil buckets, then wipes to empty and rebuilds from the left) — caused by `clearStatus()` wiping `gpsSendHistory` on every disconnect during reconnect-retry cycles, AND `aggregateGPSSecond()` appending nil to disconnected cameras so real history scrolls off in 16s.
3. Top-bar GPS indicator is a passive status glyph but looks tappable.

## Decisions

**Q1 (visibility model) = A — always show both sparklines per camera, state-driven appearance.** Never appear/disappear once shown; appearance changes by state. Combined with the fixed-capacity 16-bar frame (already shipped) → constant width.

**Q2 (disconnect history) = A — freeze + dim, preserve history.** On disconnect: stop appending, keep last bars but desaturated (~0.4 opacity, both icon + bars). History preserved **indefinitely** for troubleshooting. Rationale: option C (keep appending nil) would erase pre-disconnect evidence within 16s — exactly when someone returns to their phone to see why a camera dropped.

**Q3 (top-bar toggle) = yes — indicator becomes a GPS on/off button.** Tap toggles GPS push on/off; deeper tweaks stay in Settings. Single owner: new `OsmoLocationManager.toggle()` / `setEnabled(_:)` that does start()/stop() AND persists `gps_push_enabled`. Both the top-bar button and the Settings toggle call it; both read `isActive`. Reversible → no confirm. Color stays `fixState`-driven (gray=off, red=noFix, green=good).

**Q4 (GPS gated on global toggle) = B — GPS push is the master switch for the GPS sparkline's existence.** GPS off → no satellite icon/sparkline (RSSI still shows). GPS on → GPS sparkline appears, then follows the same per-camera states as RSSI. Avoids clutter for non-GPS users.

**Q4a (states look) = both dimmed.** "Disabled" (never-connected) and "frozen" (disconnected-after-data) both render dimmed — no extra distinct state for now (more states = more confusing).

**Q4b = both sparklines get identical state treatment** (RSSI + GPS consistent).

**Row ordering (key layout insight) = `[GPS] [RSSI] [battery] [recording]`** after `Spacer()`. GPS leftmost in the right-pinned cluster → when GPS push turns off and the GPS group collapses, `Spacer()` absorbs the freed width and RSSI/battery/recording **don't move**. (GPS in the middle would shove RSSI sideways.) No opacity-reserve needed for GPS — genuine collapse is fine because it's leftmost.

## Implementation outline

- **`OsmoLocationManager`**: add `setEnabled(_:)` + `toggle()` (single owner of enable-state + `gps_push_enabled` persistence + start/stop). `isActive` stays the read-source.
- **`OsmoCamera`**: remove `rssiHistory`/`gpsSendHistory` clearing from `clearStatus()` (the disconnect path). Add `clearHistory()` called only on clean actions (GPS `start()` new session, camera disable/remove, clear-all). History survives a disconnect/reconnect flap.
- **`OsmoCameraManager.aggregateGPSSecond()`** (actually on OsmoLocationManager): snapshot only **connected** cameras, so a disconnected camera's history **freezes** instead of bleeding to nil.
- **`SignalStrengthView` / `GPSSendHealthView`**: add an `isStale`/dimmed flag → desaturate + reduce opacity; keep the fixed 16-bar frame; render dimmed-empty when no data.
- **`CameraRowView`**: reorder trailing cluster to GPS → RSSI → battery → recording. RSSI always present; GPS present only when `locationManager.isActive`. Both pass a stale flag derived from `connectionState`. Battery gets the reserved-slot opacity treatment (like recording).
- **`SettingsView`**: toggle calls `locationManager.toggle()` (or setEnabled) instead of inline start/stop.
- **`CameraListView`**: wrap `GPSTopBarIndicator` in a `Button` calling `locationManager.toggle()`.

## Out of scope
- The forever-"reconnecting" UI state after max-retries exhausts → passive CB reconnect (pre-existing, not a regression; max-retries DOES stop active retries at 5). Noted, not touched.
