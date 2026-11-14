# 10 上游问题记录：文本框里的模式词条删不掉

> 记录 2026-11-14 用户在 iOS 端反馈的问题：从「+」命令菜单里选「计划」或「目标」后，文本框里会出现一个词条（`/plan`、`/goal` 的引用 chip），**按退格删不掉**。
>
> 结论：**不是 iOS 壳的问题**，是 DSH 前端 `dsh-client-ui-conversation` 的命令 chip 删除逻辑在 iOS WebKit 上的时序缺陷。本文记录证据、影响面、临时绕法和建议的上游补丁。

## 1 现象

| 操作 | 期望 | 实际（iOS，0.9.0 壳 + dsh-mobile 0.8.8） |
| --- | --- | --- |
| 「+」菜单 → 计划 | 文本框出现 `/plan` 词条，退格可删 | 词条出现，退格**只是高亮，再按也删不掉** |
| 「+」菜单 → 目标 | 同上（`/goal` 词条） | 同上 |
| 桌面浏览器 | 退格两次删除 | 正常 |

## 2 为什么不是 iOS 壳

iOS 壳（本仓库）对页面只做三件事：注入 `window.__DSH_MOBILE_NATIVE__`（`BridgeScript.swift`）、改写 `meta viewport`（`BridgeHost.applyViewport`）、装 Cookie。**不碰编辑器 DOM，不拦键盘事件**。文本框是页面自己的 Lexical 编辑器，词条是它的 `CommandChipNode`。

## 3 根因（读已安装的 DSH 源码得出）

相关文件（`resources/app.asar` 内）：

- `@deepseek-ai/dsh-client-ui-conversation/src/client/input/editor/command-chip-selection.ts`
- `.../input/editor/chip-node.tsx`

设计是**两步删除**：光标贴着词条时，第一次退格只「选中」词条（`data-selected`），第二次才真正删掉。`chip-node.tsx` 里 `isKeyboardSelectable()` 返回 `false`，所以删除完全依赖 `command-chip-selection.ts` 的两条路径：

| 路径 | 触发 | 桌面 | iOS |
| --- | --- | --- | --- |
| `DELETE_CHARACTER_COMMAND` | Lexical 键位表在 **keydown 内同步**派发 | ✅ 同步，`$decide` 立刻看到选中状态 | ❌ 不派发 |
| `BEFORE_INPUT_COMMAND` | 浏览器 `beforeinput`（`deleteContentBackward`） | 备用 | ✅ 走这条 |

问题出在 `KEY_DOWN_COMMAND` 里这段「按键没产生删除就清掉选中」的兜底：

```ts
keyWithoutDeletion = true
queueMicrotask(() => {
  if (!keyWithoutDeletion) return
  keyWithoutDeletion = false
  clear()          // ← 清掉词条选中态
})
```

iOS 上退格的时序是 **keydown → microtask → beforeinput**：

1. keydown：`keyWithoutDeletion = true`，排一个 microtask；
2. microtask 先跑：此时还没有任何删除，于是 `clear()` 把选中态清掉；
3. beforeinput 才到：`$decide` 发现词条没被选中 → 重新「选中」并 `preventDefault()`。

结果：**每次退格都在「选中 → 清掉 → 再选中」之间循环，永远走不到真正删除那一步**。桌面上第 2 步不存在（删除在 keydown 内同步发生，`$decide` 已把 `keyWithoutDeletion` 置回 false），所以只有移动端 WebKit 中招。

`PASSIVE_KEYS` 里只列了 `Shift/Control/Alt/Meta/Unidentified/Process`，注释也写了「IME 或虚拟键盘的删除会以 input 事件后到」——但 iOS 的退格 keydown 报的是 `Backspace`，不在这个集合里，于是被当成「没产生删除的键」清掉了。

## 4 临时绕法（现在就能用）

1. **全选再删**：长按/双击选中全部文本后删除。范围选择不是折叠光标，`$commandChipBesideCaret` 直接返回 null，删除照常生效；
2. **计划模式**：点输入框工具条上的「计划模式」chip（它是按钮，走 `/plan off`），或直接发 `/plan off`；
3. **目标**：发 `/goal clear`；
4. 桌面浏览器上不存在此问题。

## 5 建议的上游补丁（一行）

把 `Backspace` / `Delete` 也当作「删除由引擎稍后以 input 事件送达」的键，不再用 keydown 兜底清选中：

```ts
const PASSIVE_KEYS = new Set([
  'Shift', 'Control', 'Alt', 'Meta', 'Unidentified', 'Process',
  // iOS WebKit 的退格 keydown 报 'Backspace'，真正的删除随后以
  // beforeinput(deleteContentBackward) 到达；若在这里清掉选中态，
  // $decide 会把它重新选中，词条永远删不掉。
  'Backspace', 'Delete',
])
```

桌面行为不变：keydown 后 Lexical 键位表同步派发 `DELETE_CHARACTER_COMMAND`，`$decide` 自己会 `clear()` 并放行删除，不依赖这段兜底。

**未验证**：本机没有可运行的 DSH 开发环境，改动只做了代码层面推演；需要上游在真机 iOS 上复测「退格两次删除」与「方向键跨过词条」两条路径。

## 6 复现与取证方法

iOS 端：装 0.9.0 壳 → 打开页面 → 「+」→ 计划 → 在文本框里连按退格 → 词条只变高亮不消失。桥日志里不会出现任何 `invoke`（与桥无关），可作为「壳未介入」的旁证。
