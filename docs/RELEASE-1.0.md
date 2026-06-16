# Cam Control for DJI Osmo — 1.0 App Store Release Checklist

Working checklist for the first public App Store release. App record: **6760480891**
(`net.prehiti.payton.CamControl`, personal team L485BLVU52). iPhone-only, with an
embedded Apple Watch app. Distribution build comes from Xcode Cloud (push to `main`).

> **Current state (2026-06-16):** Shipping 0.9.5 on TestFlight (ext group). Phantom
> "Cam Connect" record already deleted. Export-compliance is pre-answered in the
> Info.plist (`ITSAppUsesNonExemptEncryption=false`). Privacy usage strings present.
> Marketing/Support URLs point at the public github.com/prwhite/djibt.

---

## Phase 0 — Code & build pre-flight

- [ ] Final functional pass on a physical rig (multi-cam connect, record/photo, mode, GPS, watch, Live Activity, drop alerts).
- [ ] Decide the **1.0 marketing version**: bump `MARKETING_VERSION` `0.9.5 → 1.0` in `project.yml`, `xcodegen generate`, stage regenerated artifacts (pbxproj + Info.plists).
- [ ] Confirm `make build-ci` is clean (no warnings — widget version now tracks the app).
- [ ] Commit + push `main` → Xcode Cloud build. Verify it SUCCEEDS (run watcher / `asc xcode-cloud builds`).
- [ ] Install the 1.0 build from TestFlight; smoke-test iPhone **and** watch (watch build-version footer should read `v1.0`).

## Phase 1 — ASC: create the 1.0 version

- [ ] In App Store Connect → app 6760480891 → **(+) iOS App** version, set version string **1.0**.
- [ ] Once ASC finishes processing the 1.0 build, **attach the build** to the version.
- [ ] Confirm the embedded **Apple Watch app** is detected on the build.

## Phase 2 — Metadata (per locale: en-US)

- [ ] **Name** (≤30 chars) — "Cam Control for DJI Osmo" (check length / consider a shorter display name).
- [ ] **Subtitle** (≤30 chars).
- [ ] **Promotional text** (≤170, updatable without review).
- [ ] **Description**.
- [ ] **Keywords** (≤100 chars, comma-separated, no spaces).
- [ ] **Support URL** + **Marketing URL** (github repo — public, fine for review).
- [ ] **Primary / secondary category** (e.g. Photo & Video / Utilities).
- [ ] **Copyright**, **What's New** (for 1.0 can be a launch blurb).

## Phase 3 — App Privacy, ratings & compliance

- [ ] **App Privacy "nutrition label":** verify there are no analytics/3rd-party SDKs that transmit data. Location is used **on-device and pushed to the user's own camera over BLE — it never reaches us or a third party**, so the honest answer is almost certainly **"Data Not Collected."** Confirm and fill the questionnaire accordingly.
- [ ] **Age rating** questionnaire (expected 4+).
- [ ] **Export compliance:** pre-answered via `ITSAppUsesNonExemptEncryption=false` → no per-build CCATS/docs. Confirm no prompt appears.
- [ ] **Content rights**: contains no third-party content (or declare).
- [ ] **IDFA / advertising**: No (no ads, no tracking).

## Phase 4 — Visual assets

**iPhone screenshots** (1–10; Apple now scales from the largest, so upload the 6.9″ set):
- [ ] Capture at **6.9″ portrait = 1320×2868** (iPhone 16/17 Pro Max class). Optional smaller: 6.5″ 1284×2778, 5.5″ 1242×2208.
- [ ] Cover the headline flows: multi-cam list, detail/telemetry, GPS, Live Activity / Dynamic Island, watch companion.

**Apple Watch screenshots** (required because the watch app is included):
- [ ] Capture at the largest watch size (Ultra ~410×502); ASC's uploader states the exact px it wants.

**App Preview video** (optional — you're redoing the capture script):
- [ ] **886×1920**, **15–30 s**, `.mov`/`.mp4`, **H.264 High (≤L4.0)** or ProRes 422 HQ. (HEVC/H.265, Main/Baseline, VP9, AV1 are rejected.)
- [ ] **Must include an audio track even if silent** (a silent stereo AAC track satisfies it).
- [ ] Upload only the largest device per family; ASC scales down.

**App icon:**
- [ ] 1024×1024 marketing icon present (from the Icon Composer `.icon`, delivered with the build). Confirm it shows in ASC.

## Phase 5 — Pricing & availability

- [ ] **Price tier** (Free?).
- [ ] **Availability** territories.
- [ ] Release option: **Manual**, **Automatic**, or **Phased** release after approval.

## Phase 6 — App Review information ⚠️

- [ ] **Sign-in:** none required → no demo account.
- [ ] **⚠️ Hardware-dependency note (the #1 review risk):** the app does nothing visible without a physical DJI Osmo camera over BLE — which **App Review cannot pair, and BLE doesn't work in the Simulator.** Write thorough review notes explaining this, and **attach a demo video** showing the full flow (connect → record/photo → mode → GPS → watch/Live Activity). Without this, expect a "we couldn't evaluate the functionality" rejection. Consider noting the supported cameras (Action 4/5, Osmo 360).
- [ ] **Review notes:** mention Bluetooth + Location are core (geotag), and that location stays on-device → camera.
- [ ] **Contact** name / phone / email.

## Phase 7 — Submit & release

- [ ] Submit for review.
- [ ] Watch status; respond fast to any reviewer messages (the hardware note is the likely snag).
- [ ] On approval: release per the Phase 5 choice.
- [ ] Post-release: confirm live on the Store; sanity-download.

---

## Reference — verified specs (2026)

| Asset | Spec |
|---|---|
| iPhone screenshot (6.9″) | 1320×2868 portrait (or 1290×2796 / 1260×2736); largest set only, ASC scales down |
| iPhone screenshot (6.5″ fallback) | 1284×2778 or 1242×2688 |
| App preview (iPhone) | 886×1920, 15–30 s, H.264 High ≤L4.0 / ProRes 422 HQ, **audio track required** |
| App icon | 1024×1024 |

Sources: Apple screenshot/preview specs as of 2026 — see MobileAction & Matte spec guides.

## Known risks / open items
- **App Review hardware dependency** (Phase 6) — biggest risk; mitigate with a demo video + clear notes.
- **App Privacy answer** — confirm "Data Not Collected" (no analytics SDKs; location is device→camera only).
- **Watch screenshots** — confirm exact px Apple wants in the uploader.
