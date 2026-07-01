import Foundation

/// A decodable camera-status field that can carry a value this build doesn't recognize.
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

/// A running **history** of the distinct unmapped camera-status codes seen this session —
/// each distinct (field, code) recorded once, in first-seen order, most recent last.
///
/// A tester can cycle a camera through its modes and watch the list grow, then copy it out
/// of the detail view (no log-diving). Populated live from each status frame's unmapped
/// map as pushes arrive; resets on app restart (session state, not persisted).
public struct DiagnosticUnknowns: Equatable {

    public struct Entry: Hashable, Sendable {
        public let field: StatusField
        public let code: UInt8
        public init(field: StatusField, code: UInt8) { self.field = field; self.code = code }
    }

    /// Distinct entries in first-seen order (oldest first, newest appended at the end).
    public private(set) var history: [Entry] = []

    public init() {}

    public var isEmpty: Bool { history.isEmpty }

    /// Fold one status frame's unmapped codes into the history, appending any not seen yet.
    /// Returns `true` if anything new was added. Within a frame, fields are ordered by
    /// `StatusField.allCases` for stable output; across frames, order is chronological.
    @discardableResult
    public mutating func merge(_ unmapped: [StatusField: UInt8]) -> Bool {
        var added = false
        for field in StatusField.allCases {
            guard let code = unmapped[field] else { continue }
            let entry = Entry(field: field, code: code)
            if !history.contains(entry) {
                history.append(entry)
                added = true
            }
        }
        return added
    }

    public mutating func reset() {
        history.removeAll()
    }

    /// One line per distinct unmapped code, in first-seen order (most recent last) —
    /// e.g. "resolution  0x2a". Rendered one-per-line in the diagnostics section.
    public var reportLines: [String] {
        history.map { "\($0.field.label)  0x\(String($0.code, radix: 16))" }
    }
}
