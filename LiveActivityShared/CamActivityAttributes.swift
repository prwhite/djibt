import ActivityKit
import Foundation

/// Shared between the iOS app (starts/updates the activity) and the OsmoWidgets
/// extension (renders it). Deliberately framework-free: the widget target does
/// not link DJIOsmoKit, so this file carries plain value types only.
struct CamActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        /// Connected / enabled camera counts ("3/5").
        var connected: Int
        var enabled: Int
        /// True when any connected camera is recording.
        var isRecording: Bool
        /// Wall-clock start of the current recording — drives the auto-ticking
        /// timer in the activity UI without needing per-second updates. Set once
        /// at the not-recording → recording transition and carried forward.
        var recordingStart: Date?
        /// Lowest battery across connected cameras (the one you care about).
        var batteryPercent: Int?
        /// Phone GPS fix relayed for geotagging confidence: "off"/"standby"/"noFix"/"good".
        var gpsFix: String
        /// True when the representative camera is in a photo mode — drives both the
        /// segmented mode control's highlight and the shutter's capture-vs-record icon.
        var isPhotoMode: Bool
    }

    // No fixed attributes: everything interesting is live state.
}
