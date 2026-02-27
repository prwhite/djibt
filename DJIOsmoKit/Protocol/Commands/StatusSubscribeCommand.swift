import Foundation

/// Builds the camera status subscription frame (CmdSet 0x1D, CmdID 0x05).
///
/// After subscribing, the camera sends periodic `CameraStatusPush` notifications
/// on characteristic 0xFFF4.
enum StatusSubscribeCommand {

    static let cmdSet: UInt8 = 0x1D
    static let cmdID: UInt8  = 0x05

    /// Push mode: 0=disable, 1=on-change, 2=periodic, 3=both
    static let defaultPushMode: UInt8 = 0x03
    /// Push frequency in units of 0.1 Hz. 10 = 1 Hz.
    static let defaultFrequency: UInt8 = 0x0A   // 1 Hz

    static func build(seq: UInt16, pushMode: UInt8 = defaultPushMode,
                      frequency: UInt8 = defaultFrequency) -> Data {
        let payload = Data([pushMode, frequency])
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
