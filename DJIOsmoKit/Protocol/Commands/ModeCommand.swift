import Foundation

/// Builds camera mode switch frames (CmdSet 0x1D, CmdID 0x04).
///
/// Use this to switch directly to a known mode instead of cycling via quick-switch.
enum ModeCommand {

    static let cmdSet: UInt8 = 0x1D
    static let cmdID: UInt8  = 0x04

    static func build(mode: CameraMode, deviceID: UInt8 = 0x01, seq: UInt16) -> Data {
        let payload = Data([deviceID, mode.rawValue, 0x00, 0x00])
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
