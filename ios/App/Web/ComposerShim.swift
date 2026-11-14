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

      // --- 2. do not hide a keyboard that is already up ----------------------
      // The page withholds the IME (inputmode="none") when the Add trigger is
      // pressed, which is right while the keyboard is down: it lets the button
      // focus the draft without raising the keyboard. It is wrong while the
      // keyboard is already up, because withholding hides it and the composer
      // reflows. Only that one write is dropped; every restore still runs, so
      // inputmode can never get stuck and Enter keeps its normal behaviour.
      const EDITOR = '[data-composer-input]';

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
    })();
    """
}
