/// Tracks unique values to enable log-once-per-value patterns.
///
/// Use this to avoid flooding logs at 1 Hz with repeated status values.
/// Thread safety is the caller's responsibility (e.g. `@MainActor` or `nonisolated(unsafe)`).
struct FirstSeenLogger<Value: Hashable> {

    private var seen: Set<Value> = []

    /// Returns `true` if this value hasn't been seen before (i.e. it was inserted).
    @discardableResult
    mutating func insertIfNew(_ value: Value) -> Bool {
        seen.insert(value).inserted
    }

    mutating func reset() {
        seen.removeAll()
    }
}
