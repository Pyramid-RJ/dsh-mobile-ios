import Foundation

/// Shell-side workarounds for two composer bugs in the page (docs/10).
///
/// Both are narrow, both no-op if the upstream markup changes, and both should be
/// deleted once the fixes land upstream.
///
/// 1. **Command chips cannot be deleted.** The editor clears the chip selection
///    in a microtask queued from keydown, and the deletion only arrives
///    afterwards as `beforeinput`, so the chip is reselected forever. Keeping
///    that one keydown away from the editor lets the input event delete it.
///
/// 2. **The keyboard comes back over the open attachment menu.** The mobile
///    layout withholds the IME (`inputmode="none"`) when the Add trigger is
///    pressed, then restores it on *any* other pointerdown — including a finger
///    sliding over the menu it just opened. The keyboard then covers the menu,
///    the layout reflows, and the next slide hides it again. While the menu is
///    open, the restore is suppressed so the menu stays put.
enum ComposerShim {
    static let script = """
    (() => {
      // --- 1. command chip deletion -------------------------------------------
      const SELECTED = '[data-composer-chip-selected]';
      const DELETION_KEYS = new Set(['Backspace', 'Delete']);

      document.addEventListener('keydown', (event) => {
        if (!DELETION_KEYS.has(event.key)) { return; }
        const root = document.querySelector(SELECTED);
        if (!root || !root.contains(event.target)) { return; }
        event.stopPropagation();
      }, true);

      // --- 2. keep the IME withheld while the command menu is open ------------
      const TRIGGER = '[data-composer-card] button[aria-haspopup="listbox"]';
      const EDITOR = '[data-composer-input]';

      const menuIsOpen = () => {
        const trigger = document.querySelector(TRIGGER);
        return trigger !== null && trigger.getAttribute('aria-expanded') === 'true';
      };

      document.addEventListener('pointerdown', (event) => {
        if (!menuIsOpen()) { return; }
        const target = event.target instanceof Element ? event.target : null;
        if (target === null) { return; }
        // The trigger's own tap has to reach the page: that is what withholds
        // the IME. Tapping the editor again is the user asking for the keyboard.
        if (target.closest(TRIGGER) !== null) { return; }
        if (target.closest(EDITOR) !== null) { return; }
        event.stopImmediatePropagation();
      }, true);
    })();
    """
}
