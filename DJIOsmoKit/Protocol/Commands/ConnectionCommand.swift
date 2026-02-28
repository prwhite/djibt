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
        // Payload matches connection_request_command_frame (packed, 33 bytes):
        //   uint32_t device_id       — controller type (1 = external controller)
        //   uint8_t  mac_addr_len    — length of identifier that follows
        //   int8_t   mac_addr[16]    — device identifier (iOS vendor UUID, 16 bytes)
        //   uint32_t fw_version      — 0 suppresses firmware upgrade prompts
        //   uint8_t  conidx          — connection index (0)
        //   uint8_t  verify_mode     — 0 = no verification
        //   uint16_t verify_data     — 0
        //   uint8_t  reserved[4]     — padding
        var payload = Data()

        payload.appendLE(UInt32(deviceID))          // device_id (4 bytes)

        var identifier = Data(deviceUUID.prefix(16))
        while identifier.count < 16 { identifier.append(0x00) }
        payload.append(UInt8(identifier.count))     // mac_addr_len = 16
        payload.append(contentsOf: identifier)      // mac_addr[16]

        payload.appendLE(UInt32(0))                 // fw_version = 0
        payload.append(0x00)                        // conidx = 0
        payload.append(0x00)                        // verify_mode = 0
        payload.appendLE(UInt16(0))                 // verify_data = 0
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // reserved[4]

        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x02,  // mandatory response
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: payload
        ))
    }

    /// Parse the connection request response. Returns `true` on success (return code == 0).
    ///
    /// Response layout (connection_request_response_frame, packed):
    ///   uint32_t device_id  — camera's device ID (4 bytes)
    ///   uint8_t  ret_code   — 0 = success
    ///   uint8_t  reserved[4]
    static func parseResponse(_ frame: IncomingFrame) -> Bool {
        guard frame.cmdSet == cmdSet, frame.cmdID == cmdID, frame.isResponse else { return false }
        guard frame.payload.count >= 5 else { return false }
        // ret_code is at offset 4, after device_id (4 bytes)
        return frame.payload[4] == 0x00
    }

    /// Parse a connection command frame sent by the camera (step 3 of the 3-way handshake).
    /// Returns verify_mode and verify_data, or `nil` if the frame can't be parsed.
    ///
    /// Command layout (connection_request_command_frame, packed, 33 bytes):
    ///   uint32_t device_id       [0..3]
    ///   uint8_t  mac_addr_len    [4]
    ///   int8_t   mac_addr[16]    [5..20]
    ///   uint32_t fw_version      [21..24]
    ///   uint8_t  conidx          [25]
    ///   uint8_t  verify_mode     [26]
    ///   uint16_t verify_data     [27..28]
    ///   uint8_t  reserved[4]     [29..32]
    static func parseCommand(_ frame: IncomingFrame) -> (verifyMode: UInt8, verifyData: UInt16)? {
        guard frame.cmdSet == cmdSet, frame.cmdID == cmdID, !frame.isResponse else { return nil }
        guard frame.payload.count >= 29 else { return nil }
        let verifyMode = frame.payload[26]
        let verifyData = UInt16(frame.payload[27]) | (UInt16(frame.payload[28]) << 8)
        return (verifyMode, verifyData)
    }

    /// Build an ACK response frame for the camera's connection command (step 4 of the handshake).
    ///
    /// Response layout (connection_request_response_frame, packed):
    ///   uint32_t device_id  — our controller device ID
    ///   uint8_t  ret_code   — 0 = accepted
    ///   uint8_t  reserved[4]
    static func buildResponse(seq: UInt16, retCode: UInt8 = 0, cameraReserved: UInt8 = 0) -> Data {
        var payload = Data()
        payload.appendLE(UInt32(deviceID))                          // device_id
        payload.append(retCode)                                     // ret_code
        payload.append(contentsOf: [cameraReserved, 0x00, 0x00, 0x00])  // reserved[4]

        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x20,   // ACK, no further response expected
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: payload
        ))
    }
}
