import Foundation

/// Shell-side mitigation for an upstream composer bug (docs/10).
///
/// The composer's command chips (`/plan`, `/goal`) cannot be deleted with
/// Backspace: the editor's own keydown handler clears the chip selection in a
/// microtask, and the deletion itself only arrives afterwards as
/// `beforeinput`, so the chip is reselected forever. See
/// `docs/10-upstream-issues.md` for the full trace.
///
/// Keeping that one keydown away from the editor leaves the selection alone and
/// lets the input event delete the chip. The listener is narrow on purpose:
/// only Backspace/Delete, only while the editor reports a selected chip
/// (`data-composer-chip-selected`), and only inside that editor. If upstream
/// renames the attribute the shim does nothing, and it can be deleted once the
/// fix lands upstream.
enum ComposerChipShim {
    static let script = """
    (() => {
      const SELECTED = '[data-composer-chip-selected]';
      const DELETION_KEYS = new Set(['Backspace', 'Delete']);

      document.addEventListener('keydown', (event) => {
        if (!DELETION_KEYS.has(event.key)) { return; }
        const root = document.querySelector(SELECTED);
        if (!root || !root.contains(event.target)) { return; }
        // The editor clears the chip selection in a microtask queued from this
        // keydown; the deletion only arrives afterwards as beforeinput, so the
        // chip would be reselected and never removed. Let the input event do
        // the work instead of the keydown handler.
        event.stopPropagation();
      }, true);
    })();
    """
}
