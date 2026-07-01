import Foundation

/// A decodable camera-status field that can carry a value this build doesn't recognize.
/// `allCases` order drives the diagnostics report order.
public enum StatusField: CaseIterable, Hashable, Sendable {
    case mode, resolution, frameRate, stabilization, photoRatio

    public var label: String {
        switch self {
        case .mode:          return "mode"
        case .resolution:    return "resolution"
        case .frameRate:     return "frame rate"
        case .stabilization: return "stabilization"
        case .photoRatio:    return "photo ratio"
        }
    }
}

/// Accumulates the distinct unmapped camera-status codes seen this session, per field.
///
/// A tester can cycle a camera through its modes and collect every code this build can't
/// yet name into one place, then copy it out of the camera detail view — no log-diving,
/// no Mac. Populated live from each status frame's unmapped map as pushes arrive; resets
/// on app restart (it's session state, not persisted).
public struct DiagnosticUnknowns: Equatable {
    /// field → distinct raw codes seen that this build couldn't name. Only non-empty
    /// entries are stored, so `isEmpty` is simply `codes.isEmpty`.
    public private(set) var codes: [StatusField: Set<UInt8>] = [:]

    public init() {}

    public var isEmpty: Bool { codes.isEmpty }

    /// Fold one status frame's unmapped codes into the running sets.
    /// Returns `true` if anything new was added (so callers can skip redundant work).
    @discardableResult
    public mutating func merge(_ unmapped: [StatusField: UInt8]) -> Bool {
        var added = false
        for (field, code) in unmapped {
            if codes[field, default: []].insert(code).inserted { added = true }
        }
        return added
    }

    public mutating func reset() {
        codes.removeAll()
    }

    /// One line per field that has collected any unknowns (sorted hex), for the
    /// diagnostics box / copy blob. Empty when nothing is unmapped.
    public var reportLines: [String] {
        StatusField.allCases.compactMap { field in
            guard let set = codes[field], !set.isEmpty else { return nil }
            let hex = set.sorted().map { "0x" + String($0, radix: 16) }.joined(separator: ", ")
            return "\(field.label): \(hex)"
        }
    }
}
