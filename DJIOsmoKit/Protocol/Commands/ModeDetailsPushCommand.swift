import Foundation

/// Parses the newer camera mode detail push notification (CmdSet 0x1D, CmdID 0x06).
///
/// This push usually follows a regular `CameraStatus` push for newer modes and provides
/// display-ready mode name and parameter text from the camera firmware.
enum ModeDetailsPushCommand {

    static let cmdSet: UInt8 = 0x1D
    static let cmdID: UInt8  = 0x06

    struct Details: Equatable {
        let modeName: String?
        let modeParameters: String?
    }

    static func parse(from payload: Data) -> Details? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2, bytes[0] == 0x01 else { return nil }

        let modeName = parseASCIIField(bytes, lengthOffset: 1, valueOffset: 2, maxLength: 21)

        var modeParameters: String?
        if bytes.count >= 25, bytes[23] == 0x02 {
            modeParameters = parseASCIIField(bytes, lengthOffset: 24, valueOffset: 25, maxLength: 21)
        }

        guard modeName != nil || modeParameters != nil else { return nil }
        return Details(modeName: modeName, modeParameters: modeParameters)
    }

    private static func parseASCIIField(
        _ bytes: [UInt8],
        lengthOffset: Int,
        valueOffset: Int,
        maxLength: Int
    ) -> String? {
        guard bytes.indices.contains(lengthOffset), valueOffset < bytes.count else { return nil }

        let requestedLength = min(Int(bytes[lengthOffset]), maxLength)
        guard requestedLength > 0 else { return nil }

        let availableLength = min(requestedLength, bytes.count - valueOffset)
        guard availableLength > 0 else { return nil }

        let fieldBytes = bytes[valueOffset..<valueOffset + availableLength]
            .prefix { $0 != 0 }
        let value = String(bytes: fieldBytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
