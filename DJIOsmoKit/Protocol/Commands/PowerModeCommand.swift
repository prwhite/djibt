import Foundation

/// Builds power mode (sleep) frames (CmdSet 0x00, CmdID 0x1A).
///
/// IMPORTANT: Do not send any other commands while the camera is in sleep mode.
/// Waking requires a BLE broadcast manufacturer-data advertisement (0xFF,"WKP",<MAC_reversed>)
/// which iOS cannot send. The user must physically press any button on the camera to wake it.
enum PowerModeCommand {

    static let cmdSet: UInt8 = 0x00
    static let cmdID: UInt8  = 0x1A

    enum PowerMode: UInt8 {
        case normal = 0x00
        case sleep  = 0x03
    }

    static func buildSleep(seq: UInt16) -> Data {
        let payload = Data([PowerMode.sleep.rawValue])
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
