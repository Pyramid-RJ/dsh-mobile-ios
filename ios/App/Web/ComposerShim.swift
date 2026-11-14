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
/// 2. **The keyboard changes state whenever the composer controls are touched.**
///    The mobile layout withholds the IME (`inputmode="none"`) when the Add
///    trigger is pressed and restores it on any other pointerdown, so opening
///    the attachment menu drops the keyboard and sliding over the menu brings it
///    back. Each flip reflows the composer, which is slow.
///
///    The shell publishes `window.__DSH_MOBILE_KEYBOARD_STATE__` from the real
///    keyboard frame, so the shim can drop exactly one write: withholding while
///    the keyboard is already up. Every restore still runs, which keeps
///    `inputmode` from getting stuck (a stuck `inputmode="none"` makes WebKit
///    treat Enter as a hardware key and breaks newlines).
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

      // --- 2. keep the keyboard in the state the user is in ------------------
      // The page withholds the IME (inputmode="none") when the Add trigger is
      // pressed and restores it on any other pointerdown. Each write changes the
      // keyboard, so the shim keeps them from flipping the current state:
      //   * keyboard up   -> drop the withhold, the keyboard stays up
      //   * keyboard down -> drop the restore, so a finger sliding over the menu
      //                      cannot raise it; a tap on the editor still may
      const EDITOR = '[data-composer-input]';

      let pointerInEditor = false;
      document.addEventListener('pointerdown', (event) => {
        const target = event.target instanceof Element ? event.target : null;
        pointerInEditor = target !== null && target.closest(EDITOR) !== null;
      }, true);

      const keyboardVisible = () => {
        const state = window.__DSH_MOBILE_KEYBOARD_STATE__;
        return state !== void 0 && state !== null && state.imeVisible === true;
      };

      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (String(name).toLowerCase() === 'inputmode'
            && String(value).toLowerCase() === 'none'
            && this instanceof Element && this.matches(EDITOR)
            && keyboardVisible()) {
          return;
        }
        return setAttribute.call(this, name, value);
      };

      const removeAttribute = Element.prototype.removeAttribute;
      Element.prototype.removeAttribute = function (name) {
        if (String(name).toLowerCase() === 'inputmode'
            && this instanceof Element && this.matches(EDITOR)
            && !keyboardVisible() && !pointerInEditor) {
          return;
        }
        return removeAttribute.call(this, name);
      };
    })();
    """
}
