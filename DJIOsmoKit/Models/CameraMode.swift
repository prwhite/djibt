import Foundation

/// Camera shooting mode as reported by the DJI status notification (0x1D, 0x02).
public enum CameraMode: UInt8, CaseIterable, Equatable {
    case slowMotion    = 0x00
    case video         = 0x01
    case timelapse     = 0x02
    case photo         = 0x05
    case hyperlapse    = 0x0A
    case livestream    = 0x1A
    case uvc           = 0x23
    case lowLight      = 0x28
    case subjectFollow = 0x34

    public var displayName: String {
        switch self {
        case .slowMotion:    return "Slow Motion"
        case .video:         return "Video"
        case .timelapse:     return "Timelapse"
        case .photo:         return "Photo"
        case .hyperlapse:    return "Hyperlapse"
        case .livestream:    return "Live Stream"
        case .uvc:           return "UVC"
        case .lowLight:      return "Low Light"
        case .subjectFollow: return "Subject Follow"
        }
    }

    /// Whether the mode supports video recording.
    public var supportsRecording: Bool {
        switch self {
        case .video, .hyperlapse, .timelapse, .slowMotion, .livestream: return true
        default: return false
        }
    }
}
