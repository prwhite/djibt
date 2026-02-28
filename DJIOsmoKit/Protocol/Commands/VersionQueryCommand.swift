import Foundation

/// Queries camera firmware version and product identifier (CmdSet 0x00, CmdID 0x00).
///
/// Request has an empty payload. The response contains a 2-byte ack result,
/// a 16-byte null-terminated ASCII product ID (e.g. "OA5PRO"), and the
/// remaining bytes as a null-terminated ASCII SDK/firmware version string.
enum VersionQueryCommand {

    static let cmdSet: UInt8 = 0x00
    static let cmdID: UInt8  = 0x00

    static func build(seq: UInt16) -> Data {
        // Empty payload — just the frame header
        return FrameBuilder.build(OutgoingFrame(
            cmdType: 0x02,
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: Data()
        ))
    }

    struct VersionInfo {
        let productID: String
        let sdkVersion: String
    }

    static func parseResponse(_ frame: IncomingFrame) -> VersionInfo? {
        guard frame.cmdSet == cmdSet, frame.cmdID == cmdID, frame.isResponse else { return nil }
        let payload = frame.payload
        guard payload.count >= 18 else { return nil }  // 2 (ack) + 16 (product_id) minimum

        // Skip ack_result (2 bytes)
        let productBytes = payload[2..<18]
        let productID = String(bytes: productBytes.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""

        let sdkVersion: String
        if payload.count > 18 {
            let sdkBytes = payload[18...]
            sdkVersion = String(bytes: sdkBytes.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""
        } else {
            sdkVersion = ""
        }

        return VersionInfo(productID: productID, sdkVersion: sdkVersion)
    }
}
