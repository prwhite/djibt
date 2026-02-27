import Foundation

/// Builds recording control frames (CmdSet 0x1D, CmdID 0x03).
///
/// Note: `KeyReportCommand.shutter()` is preferred for record start/stop since
/// it avoids needing to track the current recording state. Use this command
/// when you need explicit control (e.g., stop-only without toggling).
enum RecordingCommand {

    static let cmdSet: UInt8 = 0x1D
    static let cmdID: UInt8  = 0x03

    static func buildStart(deviceID: UInt8 = 0x01, seq: UInt16) -> Data {
        build(deviceID: deviceID, control: 0x00, seq: seq)
    }

    static func buildStop(deviceID: UInt8 = 0x01, seq: UInt16) -> Data {
        build(deviceID: deviceID, control: 0x01, seq: seq)
    }

    private static func build(deviceID: UInt8, control: UInt8, seq: UInt16) -> Data {
        let payload = Data([deviceID, control, 0x00, 0x00])
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
