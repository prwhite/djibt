import Foundation

/// Builds key report frames (CmdSet 0x00, CmdID 0x11).
///
/// The key report command simulates physical button presses on the camera.
/// This is the preferred way to trigger recording and snapshots (vs the raw
/// recording control command) because it avoids needing to track recording state.
enum KeyReportCommand {

    static let cmdSet: UInt8 = 0x00
    static let cmdID: UInt8  = 0x11

    // Key codes as defined in the DJI R SDK protocol
    enum KeyCode: UInt8 {
        case shutter = 0x01  // Record / snapshot button
        case qs      = 0x06  // Quick-switch mode button
    }

    enum ReportMode: UInt8 {
        case singleClick = 0x01
        case longPress   = 0x02
        case release     = 0x04
    }

    static func build(keyCode: KeyCode, reportMode: ReportMode,
                      keyValue: UInt8 = 0x01, seq: UInt16) -> Data {
        let payload = Data([keyCode.rawValue, reportMode.rawValue, keyValue])
        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x02,
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: payload
        ))
    }

    /// Convenience: single-click shutter (starts/stops recording or takes a photo).
    static func shutter(seq: UInt16) -> Data {
        build(keyCode: .shutter, reportMode: .singleClick, seq: seq)
    }

    /// Convenience: single-click quick-switch (cycles to next preset mode).
    static func quickSwitch(seq: UInt16) -> Data {
        build(keyCode: .qs, reportMode: .singleClick, seq: seq)
    }

    static func parseResponse(_ frame: IncomingFrame) -> Bool {
        guard frame.cmdSet == cmdSet, frame.cmdID == cmdID, frame.isResponse else { return false }
        return frame.payload.first == 0x00
    }
}
