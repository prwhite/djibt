import Foundation

/// Builds power mode (sleep/wake) frames (CmdSet 0x00, CmdID 0x1A).
///
/// IMPORTANT: Do not send any other commands while the camera is in sleep mode.
/// The camera will wake on any physical button press; use `wake()` to do so programmatically.
enum PowerModeCommand {

    static let cmdSet: UInt8 = 0x00
    static let cmdID: UInt8  = 0x1A

    enum PowerMode: UInt8 {
        case normal = 0x00
        case sleep  = 0x03
    }

    static func buildSleep(seq: UInt16) -> Data {
        build(mode: .sleep, seq: seq)
    }

    static func buildWake(seq: UInt16) -> Data {
        build(mode: .normal, seq: seq)
    }

    private static func build(mode: PowerMode, seq: UInt16) -> Data {
        let payload = Data([mode.rawValue])
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
