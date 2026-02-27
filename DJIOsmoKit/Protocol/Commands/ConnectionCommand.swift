import Foundation

/// Builds the connection request frame (CmdSet 0x00, CmdID 0x19).
///
/// This is the DJI protocol handshake. The camera must respond with return code 0
/// before any other commands are accepted.
enum ConnectionCommand {

    static let cmdSet: UInt8 = 0x00
    static let cmdID: UInt8  = 0x19

    /// The device type identifier used in the connection request.
    static let deviceID: UInt8 = 0x01

    /// Builds the connection request frame payload.
    ///
    /// - Parameters:
    ///   - deviceUUID: A stable 16-byte identifier for this iOS device.
    ///     Use `UIDevice.current.identifierForVendor` bytes, padded/truncated to 16 bytes.
    ///   - seq: The sequence number for this command.
    static func build(deviceUUID: Data, seq: UInt16) -> Data {
        var payload = Data()
        payload.append(deviceID)

        // 16-byte device identifier (MAC address / UUID field)
        var identifier = deviceUUID.prefix(16)
        while identifier.count < 16 { identifier.append(0x00) }
        payload.append(contentsOf: identifier)

        // firmware_version = 0 suppresses upgrade prompts on the camera
        payload.append(0x00)
        // verification_mode = 0 (no verification)
        payload.append(0x00)

        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x02,  // mandatory response
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: payload
        ))
    }

    /// Parse the connection request response. Returns `true` on success (return code == 0).
    static func parseResponse(_ frame: IncomingFrame) -> Bool {
        guard frame.cmdSet == cmdSet, frame.cmdID == cmdID, frame.isResponse else { return false }
        guard !frame.payload.isEmpty else { return false }
        // First byte of response data is the return code; 0 = success
        return frame.payload[0] == 0x00
    }
}
