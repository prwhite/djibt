import Foundation

/// Camera shooting mode as reported by the DJI status notification (0x1D, 0x02).
public enum CameraMode: UInt8, CaseIterable, Equatable {
    // Standard modes (Action 4/5 Pro)
    case slowMotion    = 0x00
    case video         = 0x01
    case timelapse     = 0x02
    case photo         = 0x05
    case hyperlapse    = 0x0A
    case livestream    = 0x1A
    case uvc           = 0x23
    case lowLight      = 0x28
    case subjectFollow = 0x34
    // 360° modes (Osmo 360 — dual lens)
    case panoVideo      = 0x38  // 360° Video
    case panoTimelapse  = 0x3B  // 360° Timelapse
    case panoSelfie     = 0x3C  // 360° Selfie (auto-reframe)
    case panoPhoto      = 0x3F  // 360° Photo
    // Single-lens modes (Osmo 360 — one lens, flat output)
    case singleBoost    = 0x41  // Single Lens Boost (up to 4K/120fps wide-angle)
    case panoVortex     = 0x43  // 360° Vortex (spinning slo-mo effect)
    case panoSupernight = 0x44  // 360° Super Night
    case singleSupernight = 0x4A // Single Lens Super Night

    public var displayName: String {
        switch self {
        case .slowMotion:       return "Slow Motion"
        case .video:            return "Video"
        case .timelapse:        return "Timelapse"
        case .photo:            return "Photo"
        case .hyperlapse:       return "Hyperlapse"
        case .livestream:       return "Live Stream"
        case .uvc:              return "UVC"
        case .lowLight:         return "Low Light"
        case .subjectFollow:    return "Subject Follow"
        case .panoVideo:        return "360° Video"
        case .panoTimelapse:    return "360° Timelapse"
        case .panoSelfie:       return "360° Selfie"
        case .panoPhoto:        return "360° Photo"
        case .panoVortex:       return "360° Vortex"
        case .panoSupernight:   return "360° Super Night"
        case .singleBoost:      return "Single Lens Boost"
        case .singleSupernight: return "Single Lens Night"
        }
    }

    /// Whether the mode supports video recording.
    public var supportsRecording: Bool {
        switch self {
        case .video, .hyperlapse, .timelapse, .slowMotion, .livestream,
             .panoVideo, .panoTimelapse, .panoSelfie, .panoVortex, .panoSupernight,
             .singleBoost, .singleSupernight:
            return true
        default:
            return false
        }
    }

    /// Whether this is a photo (still) mode.
    public var isPhotoMode: Bool {
        switch self {
        case .photo, .panoPhoto: return true
        default: return false
        }
    }

    /// Whether this is a 360°/panoramic variant (dual-lens capture).
    public var isPanoMode: Bool {
        switch self {
        case .panoVideo, .panoPhoto, .panoTimelapse, .panoSelfie, .panoVortex, .panoSupernight:
            return true
        default:
            return false
        }
    }

    /// Whether this mode only exists on the Osmo 360 hardware (pano or single-lens).
    public var is360Exclusive: Bool {
        switch self {
        case .panoVideo, .panoPhoto, .panoTimelapse, .panoSelfie, .panoVortex, .panoSupernight,
             .singleBoost, .singleSupernight:
            return true
        default:
            return false
        }
    }

    /// The high-level mode intent this native mode maps to.
    public var intent: ModeIntent? {
        switch self {
        case .video, .panoVideo, .livestream, .singleBoost: return .video
        case .photo, .panoPhoto:                            return .photo
        case .slowMotion, .lowLight:                        return .slowMotion
        case .timelapse, .panoTimelapse:                    return .timelapse
        case .hyperlapse:                                   return .hyperlapse
        case .uvc, .subjectFollow:                          return nil
        case .panoSelfie, .panoVortex, .panoSupernight, .singleSupernight: return nil
        }
    }

    /// Modes the user can switch to from the controller UI (standard cameras).
    public static let switchable: [CameraMode] = [.video, .photo, .slowMotion, .timelapse, .hyperlapse]

    /// 360° dual-lens modes (switchable within this group).
    public static let switchablePano360: [CameraMode] = [
        .panoVideo, .panoPhoto, .panoTimelapse, .panoSelfie, .panoVortex, .panoSupernight
    ]

    /// 360° single-lens modes (switchable within this group).
    public static let switchablePanoSingleLens: [CameraMode] = [
        .video, .photo, .singleBoost, .singleSupernight
    ]

    /// Returns the switchable modes for the camera's current state.
    /// The 360 has two lens groups that require a separate toggle to switch between;
    /// mode commands only work within the active group.
    // TODO: Reverse-engineer the 360's lens group toggle command so we can switch
    // between 360° and single-lens groups via BLE (currently only possible on-camera).
    public static func switchableModes(isPano: Bool, currentMode: CameraMode?) -> [CameraMode] {
        guard isPano else { return switchable }
        if let mode = currentMode, !mode.isPanoMode {
            return switchablePanoSingleLens
        }
        return switchablePano360
    }

    /// SF Symbol name for mode picker display.
    public var systemImage: String {
        switch self {
        case .video:            return "video"
        case .photo:            return "camera"
        case .slowMotion:       return "slowmo"
        case .timelapse:        return "timelapse"
        case .hyperlapse:       return "figure.walk"
        case .livestream:       return "antenna.radiowaves.left.and.right"
        case .uvc:              return "cable.connector"
        case .lowLight:         return "moon.stars"
        case .subjectFollow:    return "person.fill.viewfinder"
        case .panoVideo:        return "video.badge.ellipsis"
        case .panoPhoto:        return "camera.badge.ellipsis"
        case .panoTimelapse:    return "timelapse"
        case .panoSelfie:       return "person.fill.viewfinder"
        case .panoVortex:       return "arrow.trianglehead.2.counterclockwise.rotate.90"
        case .panoSupernight:   return "moon.stars"
        case .singleBoost:      return "bolt.fill"
        case .singleSupernight: return "moon.stars.fill"
        }
    }

    /// Resolve a mode intent into a native camera mode.
    /// For 360 cameras, respects the current lens group: if the camera is in single-lens
    /// mode, maps to standard modes; if in 360° mode (or unknown), maps to pano variants.
    public static func nativeMode(for intent: ModeIntent, isPano: Bool, currentMode: CameraMode?) -> CameraMode {
        // 360 camera in single-lens group → use standard mode bytes
        let inSingleLens = isPano && (currentMode.map { !$0.isPanoMode } ?? false)
        switch intent {
        case .video:      return (isPano && !inSingleLens) ? .panoVideo : .video
        case .photo:      return (isPano && !inSingleLens) ? .panoPhoto : .photo
        case .slowMotion: return .slowMotion
        case .timelapse:  return (isPano && !inSingleLens) ? .panoTimelapse : .timelapse
        case .hyperlapse: return .hyperlapse
        }
    }
}

// MARK: - ModeIntent

/// High-level mode intent used by the global controls.
///
/// Maps 1:1 to the user-facing mode picker. Each camera resolves the intent
/// to its native `CameraMode` (e.g. `.video` on Action cameras, `.panoVideo` on 360).
public enum ModeIntent: String, CaseIterable, Equatable {
    case video
    case photo
    case slowMotion
    case timelapse
    case hyperlapse

    public var displayName: String {
        switch self {
        case .video:      return "Video"
        case .photo:      return "Photo"
        case .slowMotion: return "Slow Motion"
        case .timelapse:  return "Timelapse"
        case .hyperlapse: return "Hyperlapse"
        }
    }

    public var systemImage: String {
        switch self {
        case .video:      return "video"
        case .photo:      return "camera"
        case .slowMotion: return "slowmo"
        case .timelapse:  return "timelapse"
        case .hyperlapse: return "figure.walk"
        }
    }
}
