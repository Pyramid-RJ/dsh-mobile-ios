// Model of the upstream two-step command-chip deletion, used to check the
// proposed upstream fix and the shell-side mitigation against the event
// ordering the composer actually produces.
//
// The state machine mirrors
// @deepseek-ai/dsh-client-ui-conversation/src/client/input/editor/command-chip-selection.ts
// (selected chip + keyWithoutDeletion fallback), with the editor reduced to
// "a chip exists beside a collapsed caret".
//
// The composer is built on Lexical's plain-text binding, whose keymap does not
// handle Backspace/Delete, so the deletion always arrives as beforeinput — on
// every engine. That is why the bug is not iOS-only; iOS is just where it was
// reported.
//
//   node docs/patches/simulate-chip-delete.js
const OLD = new Set(["Shift", "Control", "Alt", "Meta", "Unidentified", "Process"]);
const NEW = new Set([...OLD, "Backspace", "Delete"]);

function makeEditor(passiveKeys, shim) {
  let selected = null; // { isBackward }
  let keyWithoutDeletion = false;
  let chipPresent = true;
  let deletions = 0;
  let pendingMicrotask = null;

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
      // The shell shim stops this keydown before the editor sees it while a
      // chip is selected, so the clearing microtask is never queued.
      if (shim && selected !== null) return;
      if (selected === null || passiveKeys.has(key)) return;
      keyWithoutDeletion = true;
      pendingMicrotask = () => {
        if (!keyWithoutDeletion) return;
        keyWithoutDeletion = false;
        clear();
      };
    },
    runMicrotask() {
      if (pendingMicrotask) {
        pendingMicrotask();
        pendingMicrotask = null;
      }
    },
    // DELETE_CHARACTER_COMMAND (only dispatched by a rich-text keymap)
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

// One press with the plain-text binding: keydown, then the microtask, then the
// deletion as beforeinput.
function press(editor) {
  editor.keydown("Backspace");
  editor.runMicrotask();
  editor.beforeInput(true);
}

function run(label, passiveKeys, shim, presses = 2) {
  const editor = makeEditor(passiveKeys, shim);
  for (let i = 0; i < presses; i += 1) press(editor);
  console.log(
    `${label.padEnd(34)} presses=${presses} deleted=${editor.deletions} ` +
      `chipLeft=${editor.deletions === 0 ? "yes" : "no"}`,
  );
  return editor.deletions;
}

const results = {
  "no-fix": run("plain text, old PASSIVE_KEYS", OLD, false),
  "upstream-fix": run("plain text, new PASSIVE_KEYS", NEW, false),
  "shim": run("plain text, shell shim", OLD, true),
  "shim+fix": run("plain text, shim + new PASSIVE_KEYS", NEW, true),
};

const ok =
  results["no-fix"] === 0 &&
  results["upstream-fix"] === 1 &&
  results["shim"] === 1 &&
  results["shim+fix"] === 1;

console.log("");
console.log("expectation: without a fix the chip never goes away; the upstream patch");
console.log("and the shell shim each make the second Backspace delete it, and they");
console.log("do not interfere when both are present.");
console.log(ok ? "RESULT: matches the diagnosis" : "RESULT: does NOT match the diagnosis");
process.exit(ok ? 0 : 1);
