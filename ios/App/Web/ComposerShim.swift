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
///    back. Each flip reflows the composer, which is slow. The fix is to ignore
///    those `inputmode` writes while the user is working in the composer: the
///    keyboard then simply stays as it is. Writes made outside that window (for
///    example the drawer's own IME handling) still go through.
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

      // --- 2. leave the keyboard alone while the composer is in use -----------
      const CARD = '[data-composer-card]';
      const TRIGGER = CARD + ' button[aria-haspopup="listbox"]';
      const EDITOR = '[data-composer-input]';

      // A tap on any composer control opens a short window: the page's IME
      // policy runs synchronously inside that same pointerdown.
      let guardUntil = 0;
      document.addEventListener('pointerdown', (event) => {
        const target = event.target instanceof Element ? event.target : null;
        if (target !== null && target.closest(CARD) !== null) {
          guardUntil = performance.now() + 600;
        }
      }, true);

      const menuIsOpen = () => {
        const trigger = document.querySelector(TRIGGER);
        return trigger !== null && trigger.getAttribute('aria-expanded') === 'true';
      };

      const guarded = () => menuIsOpen() || performance.now() < guardUntil;

      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (String(name).toLowerCase() === 'inputmode'
            && this instanceof Element && this.matches(EDITOR) && guarded()) {
          return;
        }
        return setAttribute.call(this, name, value);
      };

      const removeAttribute = Element.prototype.removeAttribute;
      Element.prototype.removeAttribute = function (name) {
        if (String(name).toLowerCase() === 'inputmode'
            && this instanceof Element && this.matches(EDITOR) && guarded()) {
          return;
        }
        return removeAttribute.call(this, name);
      };
    })();
    """
}
