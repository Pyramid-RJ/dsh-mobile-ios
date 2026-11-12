import Foundation

/// Tracks in-flight requests so duplicates and over-limit concurrency are
/// rejected with bad_message instead of leaking pending entries.
public final class BridgePendingTracker {
    public let limit: Int
    private var pending: Set<String> = []

    public init(limit: Int = BridgeLimits.maxPendingRequests) {
        self.limit = limit
    }

    public var count: Int { pending.count }

    /// Returns false when the id is already pending or the limit is reached.
    public func begin(_ requestId: String) -> Bool {
        guard pending.count < limit, !pending.contains(requestId) else { return false }
        pending.insert(requestId)
        return true
    }

    public func finish(_ requestId: String) {
        pending.remove(requestId)
    }

    public func contains(_ requestId: String) -> Bool {
        pending.contains(requestId)
    }
}
