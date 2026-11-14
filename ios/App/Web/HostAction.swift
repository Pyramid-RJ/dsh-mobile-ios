import Foundation

/// Actions the app itself asks the bridge host for.
///
/// They live outside `BridgeAction` on purpose: that enum is the capability list
/// advertised to the page (docs/03 section 6.2), and a host-only request must
/// never show up there.
enum HostAction {
    /// Device facts for the in-app diagnostics screen.
    static let diagnostics = "host.diagnostics"
}
