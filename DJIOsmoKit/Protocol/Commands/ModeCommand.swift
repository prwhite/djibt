import Foundation

/// Builds camera mode switch frames (CmdSet 0x1D, CmdID 0x04).
///
/// Use this to switch directly to a known mode instead of cycling via quick-switch.
enum ModeCommand {

    static let cmdSet: UInt8 = 0x1D
    static let cmdID: UInt8  = 0x04

    static func build(mode: CameraMode, seq: UInt16) -> Data {
        // DJI's demo sends 1D04 as response-or-not and uses this controller/device marker.
        var payload = Data()
        payload.appendLE(UInt32(0xFF330000))
        payload.append(mode.rawValue)
        payload.append(contentsOf: [0x01, 0x47, 0x39, 0x36])
        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x01,
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
