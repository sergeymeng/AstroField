import Foundation

/// Backoff schedule for an ICC session that closed underneath a running app.
///
/// The default tries five times after 1 s, 2 s and 5 s; the last two attempts
/// reuse the 5 s step. The schedule is a value type so the UI and tests use the
/// same numbers.
public struct ReconnectPolicy: Equatable, Sendable {
    public var delays: [TimeInterval]

    public var maxAttempts: Int { delays.count }

    public init(delays: [TimeInterval] = [1, 2, 5, 5, 5]) {
        self.delays = delays.filter { $0 >= 0 }
    }

    public static let `default` = ReconnectPolicy()

    /// Delay before a 1-based attempt, or nil when the attempt is out of range.
    public func delay(beforeAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}
