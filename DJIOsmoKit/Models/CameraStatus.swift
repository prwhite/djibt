import Foundation

/// Decoded payload from the camera status push notification (CmdSet 0x1D, CmdID 0x02).
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

    // MARK: - Properties

    public let mode: CameraMode?
    public let recordingStatus: RecordingStatus
    /// Current recording duration in seconds. Only meaningful when `recordingStatus == .recording`.
    public let recordingSeconds: Int
    /// Battery charge level, 0–100.
    public let batteryPercentage: Int
    /// Raw mode byte; useful when `mode` is nil (unknown/future mode).
    public let rawMode: UInt8

    // MARK: - Sentinel

    public static let unknown = CameraStatus(
        mode: nil,
        recordingStatus: .screenOff,
        recordingSeconds: 0,
        batteryPercentage: 0,
        rawMode: 0xFF
    )

    // MARK: - Init

    public init(
        mode: CameraMode?,
        recordingStatus: RecordingStatus,
        recordingSeconds: Int,
        batteryPercentage: Int,
        rawMode: UInt8
    ) {
        self.mode = mode
        self.recordingStatus = recordingStatus
        self.recordingSeconds = recordingSeconds
        self.batteryPercentage = batteryPercentage
        self.rawMode = rawMode
    }

    /// Parse from the raw DATA payload bytes (after CmdSet + CmdID have been stripped).
    static func parse(from bytes: [UInt8]) -> CameraStatus? {
        // Minimum payload: at least mode(1) + recordingStatus(1) + battery(1) + ...
        guard bytes.count >= 6 else { return nil }
        let rawMode = bytes[0]
        let mode = CameraMode(rawValue: rawMode)
        let recordingStatus = RecordingStatus(rawValue: bytes[1]) ?? .screenOff
        let batteryPercentage = Int(bytes[5])
        // Recording time is a UInt16 at bytes[3..4] (little-endian)
        let recordingSeconds = Int(bytes[3]) | (Int(bytes[4]) << 8)
        return CameraStatus(
            mode: mode,
            recordingStatus: recordingStatus,
            recordingSeconds: recordingSeconds,
            batteryPercentage: batteryPercentage,
            rawMode: rawMode
        )
    }
}
