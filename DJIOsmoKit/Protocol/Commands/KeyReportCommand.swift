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
        case qs      = 0x02  // Quick-switch mode button
    }

    /// Report mode: selects how key events are interpreted.
    ///   0x00 — press/release status (keyValue: 0=pressed, 1=released)
    ///   0x01 — key events (keyValue: 0=short press, 1=long press, 2=double click, …)
    enum ReportMode: UInt8 {
        case pressRelease = 0x00
        case event        = 0x01
    }

    /// Key event values when using ReportMode.event
    enum KeyEvent: UInt16 {
        case shortPress  = 0x0000
        case longPress   = 0x0001
        case doubleClick = 0x0002
    }

    /// Payload matches key_report_command_frame_t (packed, 4 bytes):
    ///   uint8_t  key_code
    ///   uint8_t  mode
    ///   uint16_t key_value (LE)
    static func build(keyCode: KeyCode, mode: ReportMode,
                      keyValue: UInt16, seq: UInt16) -> Data {
        var payload = Data()
        payload.append(keyCode.rawValue)
        payload.append(mode.rawValue)
        payload.appendLE(keyValue)
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
        build(keyCode: .shutter, mode: .event, keyValue: KeyEvent.shortPress.rawValue, seq: seq)
    }

    /// Convenience: single-click quick-switch (cycles to next preset mode).
    static func quickSwitch(seq: UInt16) -> Data {
        build(keyCode: .qs, mode: .event, keyValue: KeyEvent.shortPress.rawValue, seq: seq)
    }

    static func parseResponse(_ frame: IncomingFrame) -> Bool {
        guard frame.cmdSet == cmdSet, frame.cmdID == cmdID, frame.isResponse else { return false }
        return frame.payload.first == 0x00
    }
}
