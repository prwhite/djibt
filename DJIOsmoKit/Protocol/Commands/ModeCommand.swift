import Foundation

/// Builds camera mode switch frames (CmdSet 0x1D, CmdID 0x04).
///
/// Use this to switch directly to a known mode instead of cycling via quick-switch.
enum ModeCommand {

    static let cmdSet: UInt8 = 0x1D
    static let cmdID: UInt8  = 0x04

    static func build(mode: CameraMode, deviceID: UInt32 = 0x01, seq: UInt16) -> Data {
        // Payload: device_id (uint32_t LE) + mode (uint8_t) + reserved (4 bytes) = 9 bytes
        var payload = Data(count: 9)
        payload[0] = UInt8(deviceID & 0xFF)
        payload[1] = UInt8((deviceID >> 8) & 0xFF)
        payload[2] = UInt8((deviceID >> 16) & 0xFF)
        payload[3] = UInt8((deviceID >> 24) & 0xFF)
        payload[4] = mode.rawValue
        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x02,
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: payload
        ))
    }

    static func parseResponse(_ frame: IncomingFrame) -> Bool {
        guard frame.cmdSet == cmdSet, frame.cmdID == cmdID, frame.isResponse else { return false }
        return frame.payload.first == 0x00
    }
}
