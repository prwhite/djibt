import Foundation

/// Result shown by the diagnostic raw-frame sender.
public struct RawFrameCommandResult: Sendable, Equatable {
    public let summary: String
    public let responsePayloadHex: String?
}

/// User-facing validation failures for manually entered DJI protocol frames.
public enum RawFrameCommandError: LocalizedError, Equatable {
    case emptyInput
    case oddHexDigitCount
    case malformedFrame(String)
    case responseFrameNotAllowed
    case unsupportedCommandType(UInt8)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Enter a raw DJI frame, for example AA..."
        case .oddHexDigitCount:
            return "Raw frame has an odd number of hex digits."
        case .malformedFrame(let reason):
            return "Raw frame is not a valid DJI frame: \(reason)"
        case .responseFrameNotAllowed:
            return "Raw sender expects a command frame, not a response frame."
        case .unsupportedCommandType(let cmdType):
            return String(format: "Unsupported command type 0x%02X.", cmdType)
        case .notConnected:
            return "Camera is not connected."
        }
    }
}

enum RawFrameCommand {

    /// Parsed command data plus the DJI cmdType response mode used by `sendRawHexFrame`.
    struct PreparedFrame {
        let data: Data
        let parsedFrame: IncomingFrame
        let responseMode: UInt8
    }

    /// Normalizes hex input, validates the AA-frame envelope/CRC, and rejects response frames.
    static func prepare(_ rawDataString: String) throws -> PreparedFrame {
        let data = try parseHex(rawDataString)
        let parsedFrame: IncomingFrame

        do {
            guard let parsed = try FrameParser.parse(data) else {
                throw RawFrameCommandError.malformedFrame("0x55-prefixed telemetry frames cannot be sent as DJI commands.")
            }
            parsedFrame = parsed
        } catch let error as RawFrameCommandError {
            throw error
        } catch let error as FrameParseError {
            throw RawFrameCommandError.malformedFrame(error.description)
        } catch {
            throw RawFrameCommandError.malformedFrame(error.localizedDescription)
        }

        guard !parsedFrame.isResponse else { throw RawFrameCommandError.responseFrameNotAllowed }

        let responseMode = parsedFrame.cmdType & 0x1F
        guard responseMode == 0x00 || responseMode == 0x01 || responseMode == 0x02 else {
            throw RawFrameCommandError.unsupportedCommandType(parsedFrame.cmdType)
        }

        return PreparedFrame(data: data, parsedFrame: parsedFrame, responseMode: responseMode)
    }

    /// Accepts pasted frames with spaces, separators, and optional 0x byte prefixes.
    static func parseHex(_ rawDataString: String) throws -> Data {
        let withoutPrefixes = rawDataString.replacingOccurrences(
            of: "0x",
            with: "",
            options: [.caseInsensitive]
        )
        let compactHex = withoutPrefixes.replacingOccurrences(
            of: "[^0-9A-Fa-f]",
            with: "",
            options: .regularExpression
        )

        guard !compactHex.isEmpty else { throw RawFrameCommandError.emptyInput }
        guard compactHex.count.isMultiple(of: 2) else { throw RawFrameCommandError.oddHexDigitCount }

        var data = Data(capacity: compactHex.count / 2)
        var index = compactHex.startIndex
        while index < compactHex.endIndex {
            let nextIndex = compactHex.index(index, offsetBy: 2)
            let byteString = compactHex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw RawFrameCommandError.malformedFrame("Invalid hex byte \(byteString).")
            }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    static func formatHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func sentSummary(for frame: IncomingFrame, noResponse: Bool) -> RawFrameCommandResult {
        let mode = noResponse ? "without waiting" : "with optional response timeout"
        let summary = String(
            format: "TX %@: cmd=0x%02X/0x%02X seq=%u payload=%dB",
            mode,
            frame.cmdSet,
            frame.cmdID,
            frame.seq,
            frame.payload.count
        )
        return RawFrameCommandResult(summary: summary, responsePayloadHex: nil)
    }

    static func responseSummary(for response: IncomingFrame) -> RawFrameCommandResult {
        let payloadHex = formatHex(response.payload)
        let summary = String(
            format: "RX: cmd=0x%02X/0x%02X seq=%u payload=%dB%@",
            response.cmdSet,
            response.cmdID,
            response.seq,
            response.payload.count,
            payloadHex.isEmpty ? "" : " " + payloadHex
        )
        return RawFrameCommandResult(summary: summary, responsePayloadHex: payloadHex.isEmpty ? nil : payloadHex)
    }
}
