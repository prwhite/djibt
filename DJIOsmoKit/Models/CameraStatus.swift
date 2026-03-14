import Foundation
import OSLog

/// Decoded payload from the camera status push notification (CmdSet 0x1D, CmdID 0x02).
///
/// Layout matches `camera_status_push_command_frame` (packed, 38 bytes):
/// ```
/// [0]     camera_mode
/// [1]     camera_status (RecordingStatus)
/// [2]     video_resolution
/// [3]     fps_idx
/// [4]     eis_mode
/// [5..6]  record_time (UInt16 LE, seconds)
/// [7]     fov_type
/// [8]     photo_ratio
/// [9..10] real_time_countdown (UInt16 LE)
/// [11..12] timelapse_interval (UInt16 LE)
/// [13..14] timelapse_duration (UInt16 LE)
/// [15..18] remain_capacity (UInt32 LE, MB)
/// [19..22] remain_photo_num (UInt32 LE)
/// [23..26] remain_time (UInt32 LE, seconds)
/// [27]    user_mode
/// [28]    power_mode (0=normal, 3=sleep)
/// [29]    camera_mode_next_flag
/// [30]    temp_over
/// [31..34] photo_countdown_ms (UInt32 LE)
/// [35..36] loop_record_sends (UInt16 LE)
/// [37]    camera_bat_percentage
/// ```
public struct CameraStatus: Equatable {

    // MARK: - Nested Types

    public enum RecordingStatus: UInt8, Equatable {
        case screenOff     = 0x00
        case liveView      = 0x01
        case playback      = 0x02
        case recording     = 0x03
        case preRecording  = 0x05

        public var isRecording: Bool { self == .recording }
    }

    public enum PowerMode: UInt8, Equatable {
        case normal = 0x00
        case sleep  = 0x03
    }

    public enum VideoResolution: UInt8, Equatable {
        case res1080p      = 10
        case res4K_16_9    = 16
        case res2K7_16_9   = 45
        case res1080p_9_16 = 66
        case res2K7_9_16   = 67
        case res2K7_4_3    = 95
        case res4K_4_3     = 103
        case res4K_9_16    = 109
        case res360        = 111   // Osmo 360 equirectangular capture

        public var displayName: String {
            switch self {
            case .res1080p:      return "1080P"
            case .res4K_16_9:    return "4K 16:9"
            case .res2K7_16_9:   return "2.7K 16:9"
            case .res1080p_9_16: return "1080P 9:16"
            case .res2K7_9_16:   return "2.7K 9:16"
            case .res2K7_4_3:    return "2.7K 4:3"
            case .res4K_4_3:     return "4K 4:3"
            case .res4K_9_16:    return "4K 9:16"
            case .res360:        return "360°"
            }
        }
    }

    public enum FrameRate: UInt8, Equatable {
        case fps24  = 1
        case fps25  = 2
        case fps30  = 3
        case fps48  = 4
        case fps50  = 5
        case fps60  = 6
        case fps120 = 7
        case fps240 = 8
        case fps100 = 10
        case fps200 = 19

        public var displayName: String {
            switch self {
            case .fps24:  return "24 fps"
            case .fps25:  return "25 fps"
            case .fps30:  return "30 fps"
            case .fps48:  return "48 fps"
            case .fps50:  return "50 fps"
            case .fps60:  return "60 fps"
            case .fps100: return "100 fps"
            case .fps120: return "120 fps"
            case .fps200: return "200 fps"
            case .fps240: return "240 fps"
            }
        }
    }

    public enum PhotoRatio: UInt8, Equatable {
        case ratio4_3  = 0
        case ratio16_9 = 1
        case ratio2_1  = 4   // Equirectangular (360°)

        public var displayName: String {
            switch self {
            case .ratio4_3:  return "4:3"
            case .ratio16_9: return "16:9"
            case .ratio2_1:  return "2:1"
            }
        }
    }

    public enum StabilizationMode: UInt8, Equatable {
        case off    = 0
        case rs     = 1
        case hs     = 2
        case rsPlus = 3
        case hb     = 4

        public var displayName: String {
            switch self {
            case .off:    return "EIS Off"
            case .rs:     return "RockSteady"
            case .hs:     return "HorizonSteady"
            case .rsPlus: return "RockSteady+"
            case .hb:     return "HorizonBalancing"
            }
        }
    }

    // MARK: - Properties

    public let mode: CameraMode?
    public let recordingStatus: RecordingStatus
    /// Current recording duration in seconds. Only meaningful when `recordingStatus == .recording`.
    public let recordingSeconds: Int
    /// Battery charge level, 0–100.
    public let batteryPercentage: Int
    /// Power mode: `.normal` (working) or `.sleep`.
    public let powerMode: PowerMode
    /// Raw mode byte; useful when `mode` is nil (unknown/future mode).
    public let rawMode: UInt8
    /// Video resolution setting reported by the camera.
    public let videoResolution: VideoResolution?
    /// Frame rate setting reported by the camera.
    public let frameRate: FrameRate?
    /// Electronic image stabilization mode.
    public let stabilizationMode: StabilizationMode?
    /// Raw EIS byte; useful when `stabilizationMode` is nil (unknown/future mode).
    public let rawStabilization: UInt8
    /// Photo aspect ratio setting reported by the camera.
    public let photoRatio: PhotoRatio?
    /// Remaining photos the camera estimates it can store.
    public let remainingPhotoCount: UInt32
    /// Remaining storage capacity in megabytes.
    public let remainingStorageMB: UInt32
    /// Remaining recording time in seconds (estimated by camera).
    public let remainingRecordTimeSec: UInt32
    /// Temperature warning level. 0 = normal, >0 = overheating warning.
    public let temperatureWarning: UInt8

    /// Logs unmapped enum bytes once per unique value — prevents per-second log spam.
    nonisolated(unsafe) private static var stabilizationLogger = FirstSeenLogger<UInt8>()

    // MARK: - Sentinel

    public static let unknown = CameraStatus(
        mode: nil,
        recordingStatus: .screenOff,
        recordingSeconds: 0,
        batteryPercentage: 0,
        powerMode: .normal,
        rawMode: 0xFF,
        videoResolution: nil,
        frameRate: nil,
        stabilizationMode: nil,
        rawStabilization: 0xFF,
        photoRatio: nil,
        remainingPhotoCount: 0,
        remainingStorageMB: 0,
        remainingRecordTimeSec: 0,
        temperatureWarning: 0
    )

    // MARK: - Init

    public init(
        mode: CameraMode?,
        recordingStatus: RecordingStatus,
        recordingSeconds: Int,
        batteryPercentage: Int,
        powerMode: PowerMode,
        rawMode: UInt8,
        videoResolution: VideoResolution?,
        frameRate: FrameRate?,
        stabilizationMode: StabilizationMode?,
        rawStabilization: UInt8,
        photoRatio: PhotoRatio?,
        remainingPhotoCount: UInt32,
        remainingStorageMB: UInt32,
        remainingRecordTimeSec: UInt32,
        temperatureWarning: UInt8
    ) {
        self.mode = mode
        self.recordingStatus = recordingStatus
        self.recordingSeconds = recordingSeconds
        self.batteryPercentage = batteryPercentage
        self.powerMode = powerMode
        self.rawMode = rawMode
        self.videoResolution = videoResolution
        self.frameRate = frameRate
        self.stabilizationMode = stabilizationMode
        self.rawStabilization = rawStabilization
        self.photoRatio = photoRatio
        self.remainingPhotoCount = remainingPhotoCount
        self.remainingStorageMB = remainingStorageMB
        self.remainingRecordTimeSec = remainingRecordTimeSec
        self.temperatureWarning = temperatureWarning
    }

    /// Parse from the raw DATA payload bytes (after CmdSet + CmdID have been stripped).
    static func parse(from bytes: [UInt8]) -> CameraStatus? {
        guard bytes.count >= 38 else { return nil }
        let rawMode = bytes[0]
        let mode = CameraMode(rawValue: rawMode)
        let recordingStatus = RecordingStatus(rawValue: bytes[1]) ?? .screenOff
        let videoResolution = VideoResolution(rawValue: bytes[2])
        let frameRate = FrameRate(rawValue: bytes[3])
        let rawStabilization = bytes[4]
        let stabilizationMode = StabilizationMode(rawValue: rawStabilization)
        let recordingSeconds = Int(bytes[5]) | (Int(bytes[6]) << 8)
        let photoRatio = PhotoRatio(rawValue: bytes[8])
        let remainingPhotoCount = UInt32(bytes[19])
            | (UInt32(bytes[20]) << 8)
            | (UInt32(bytes[21]) << 16)
            | (UInt32(bytes[22]) << 24)
        let remainingStorageMB = UInt32(bytes[15])
            | (UInt32(bytes[16]) << 8)
            | (UInt32(bytes[17]) << 16)
            | (UInt32(bytes[18]) << 24)
        let remainingRecordTimeSec = UInt32(bytes[23])
            | (UInt32(bytes[24]) << 8)
            | (UInt32(bytes[25]) << 16)
            | (UInt32(bytes[26]) << 24)
        let powerMode = PowerMode(rawValue: bytes[28]) ?? .normal
        let temperatureWarning = bytes[30]
        let batteryPercentage = min(100, max(0, Int(bytes[37])))
        if stabilizationMode == nil && rawStabilization != 0 && stabilizationLogger.insertIfNew(rawStabilization) {
            OsmoLog.camera.info("Unmapped stabilization byte: 0x\(String(rawStabilization, radix: 16), privacy: .public) (mode=0x\(String(rawMode, radix: 16), privacy: .public))")
        }
        return CameraStatus(
            mode: mode,
            recordingStatus: recordingStatus,
            recordingSeconds: recordingSeconds,
            batteryPercentage: batteryPercentage,
            powerMode: powerMode,
            rawMode: rawMode,
            videoResolution: videoResolution,
            frameRate: frameRate,
            stabilizationMode: stabilizationMode,
            rawStabilization: rawStabilization,
            photoRatio: photoRatio,
            remainingPhotoCount: remainingPhotoCount,
            remainingStorageMB: remainingStorageMB,
            remainingRecordTimeSec: remainingRecordTimeSec,
            temperatureWarning: temperatureWarning
        )
    }
}
