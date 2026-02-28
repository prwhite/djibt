import Foundation

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

    // MARK: - Sentinel

    public static let unknown = CameraStatus(
        mode: nil,
        recordingStatus: .screenOff,
        recordingSeconds: 0,
        batteryPercentage: 0,
        powerMode: .normal,
        rawMode: 0xFF
    )

    // MARK: - Init

    public init(
        mode: CameraMode?,
        recordingStatus: RecordingStatus,
        recordingSeconds: Int,
        batteryPercentage: Int,
        powerMode: PowerMode,
        rawMode: UInt8
    ) {
        self.mode = mode
        self.recordingStatus = recordingStatus
        self.recordingSeconds = recordingSeconds
        self.batteryPercentage = batteryPercentage
        self.powerMode = powerMode
        self.rawMode = rawMode
    }

    /// Parse from the raw DATA payload bytes (after CmdSet + CmdID have been stripped).
    static func parse(from bytes: [UInt8]) -> CameraStatus? {
        guard bytes.count >= 38 else { return nil }
        let rawMode = bytes[0]
        let mode = CameraMode(rawValue: rawMode)
        let recordingStatus = RecordingStatus(rawValue: bytes[1]) ?? .screenOff
        let recordingSeconds = Int(bytes[5]) | (Int(bytes[6]) << 8)
        let powerMode = PowerMode(rawValue: bytes[28]) ?? .normal
        let batteryPercentage = Int(bytes[37])
        return CameraStatus(
            mode: mode,
            recordingStatus: recordingStatus,
            recordingSeconds: recordingSeconds,
            batteryPercentage: batteryPercentage,
            powerMode: powerMode,
            rawMode: rawMode
        )
    }
}
