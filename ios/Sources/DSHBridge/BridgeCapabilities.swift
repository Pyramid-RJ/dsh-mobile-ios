import Foundation

/// The honest capability list handed to the page.
///
/// Only actions a handler can actually serve belong here: reporting a capability
/// that does nothing produces a UI control that silently fails (docs/03 section 6.2).
public struct BridgeCapabilities {
    public let actions: [BridgeAction]

    public init(implemented: Set<BridgeAction>) {
        actions = implemented.sorted { $0.rawValue < $1.rawValue }
    }

    public var values: [String] {
        actions.map { $0.rawValue }
    }

    public func includes(_ action: BridgeAction) -> Bool {
        actions.contains(action)
    }
}
