// Model of the upstream two-step command-chip deletion, used to check the
// proposed fix against the two event orderings the real engines produce.
//
// The state machine mirrors
// @deepseek-ai/dsh-client-ui-conversation/src/client/input/editor/command-chip-selection.ts
// (selected chip + keyWithoutDeletion fallback), with the editor reduced to
// "a chip exists beside a collapsed caret".
//
//   node .tmp/simulate-chip-delete.js
const OLD = new Set(["Shift", "Control", "Alt", "Meta", "Unidentified", "Process"]);
const NEW = new Set([...OLD, "Backspace", "Delete"]);

function makeEditor(passiveKeys) {
  let selected = null; // { isBackward }
  let keyWithoutDeletion = false;
  let chipPresent = true;
  let deletions = 0;

  const clear = () => {
    if (selected !== null) selected = null;
    return false;
  };

  // $decide(isBackward, clearOnPass)
  const decide = (isBackward, clearOnPass) => {
    keyWithoutDeletion = false;
    if (!chipPresent) return clear();
    if (selected !== null && selected.isBackward === isBackward) {
      return clearOnPass ? clear() : false;
    }
    selected = { isBackward };
    return true;
  };

  const removeChip = () => {
    if (!chipPresent) return;
    chipPresent = false;
    deletions += 1;
  };

  return {
    get selected() {
      return selected;
    },
    get deletions() {
      return deletions;
    },
    // KEY_DOWN_COMMAND
    keydown(key) {
      if (selected === null || passiveKeys.has(key)) return;
      keyWithoutDeletion = true;
      this.pendingMicrotask = () => {
        if (!keyWithoutDeletion) return;
        keyWithoutDeletion = false;
        clear();
      };
    },
    runMicrotask() {
      if (this.pendingMicrotask) {
        this.pendingMicrotask();
        this.pendingMicrotask = null;
      }
    },
    // DELETE_CHARACTER_COMMAND (dispatched inside keydown by the keymap)
    deleteCharacter(isBackward) {
      const consumed = decide(isBackward, true);
      if (!consumed) removeChip();
    },
    // BEFORE_INPUT_COMMAND
    beforeInput(isBackward) {
      const consumed = decide(isBackward, false);
      if (!consumed) removeChip();
    },
  };
}

// One press on Chromium: keydown dispatches the deletion synchronously, so no
// beforeinput follows (the keymap calls preventDefault when it consumes).
function pressChromium(editor) {
  editor.keydown("Backspace");
  if (editor.selected !== null || true) {
    // Lexical's keymap runs inside the keydown; the editor decides there.
    editor.deleteCharacter(true);
  }
  editor.runMicrotask();
}

// One press on WebKit: keydown, then the microtask, then beforeinput.
function pressWebKit(editor) {
  editor.keydown("Backspace");
  editor.runMicrotask();
  editor.beforeInput(true);
}

function run(label, passiveKeys, press, presses = 2) {
  const editor = makeEditor(passiveKeys);
  for (let i = 0; i < presses; i += 1) press(editor);
  console.log(
    `${label.padEnd(28)} presses=${presses} deleted=${editor.deletions} ` +
      `chipLeft=${editor.deletions === 0 ? "yes" : "no"}`,
  );
  return editor.deletions;
}

const results = {
  "chromium+old": run("chromium + old PASSIVE_KEYS", OLD, pressChromium),
  "chromium+new": run("chromium + new PASSIVE_KEYS", NEW, pressChromium),
  "webkit+old": run("webkit + old PASSIVE_KEYS", OLD, pressWebKit),
  "webkit+new": run("webkit + new PASSIVE_KEYS", NEW, pressWebKit),
};

const ok =
  results["chromium+old"] === 1 &&
  results["chromium+new"] === 1 &&
  results["webkit+old"] === 0 &&
  results["webkit+new"] === 1;

console.log("");
console.log("expectation: chromium deletes either way; webkit only deletes with the fix");
console.log(ok ? "RESULT: matches the diagnosis" : "RESULT: does NOT match the diagnosis");
process.exit(ok ? 0 : 1);
