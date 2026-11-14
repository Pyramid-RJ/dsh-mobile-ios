# 10 上游问题记录：文本框里的模式词条删不掉

> 记录 2026-11-14 用户在 iOS 端反馈的问题：从「+」命令菜单里选「计划」或「目标」后，文本框里会出现一个词条（`/plan`、`/goal` 的引用 chip），**按退格删不掉**。
>
> 结论：根因在 DSH 前端 `dsh-client-ui-conversation` 的命令 chip 删除逻辑（keydown 兜底抢在 `beforeinput` 之前清掉选中态），**与 iOS 壳无关**。本文记录证据、影响面、临时绕法、建议的上游补丁，以及壳侧已经落地的临时缓解。

## 1 现象

| 操作 | 期望 | 实际（iOS，0.9.0 壳 + dsh-mobile 0.8.8） |
| --- | --- | --- |
| 「+」菜单 → 计划 | 文本框出现 `/plan` 词条，退格可删 | 词条出现，退格**只是高亮，再按也删不掉** |
| 「+」菜单 → 目标 | 同上（`/goal` 词条） | 同上 |
| 桌面浏览器 | 退格两次删除 | **未验证**；按源码推断同样删不掉（见 §3 末尾） |

## 2 为什么不是 iOS 壳

iOS 壳（本仓库）对页面只做三件事：注入 `window.__DSH_MOBILE_NATIVE__`（`BridgeScript.swift`）、改写 `meta viewport`（`BridgeHost.applyViewport`）、装 Cookie。**不碰编辑器 DOM，不拦键盘事件**。文本框是页面自己的 Lexical 编辑器，词条是它的 `CommandChipNode`。

## 3 根因（读已安装的 DSH 源码得出）

相关文件（`resources/app.asar` 内）：

- `@deepseek-ai/dsh-client-ui-conversation/src/client/input/editor/command-chip-selection.ts`
- `.../input/editor/chip-node.tsx`

设计是**两步删除**：光标贴着词条时，第一次退格只「选中」词条（`data-selected`），第二次才真正删掉。`chip-node.tsx` 里 `isKeyboardSelectable()` 返回 `false`，所以删除完全依赖 `command-chip-selection.ts` 的两条路径：

| 路径 | 触发 | 实际情况 |
| --- | --- | --- |
| `DELETE_CHARACTER_COMMAND` | Lexical 键位表在 keydown 内同步派发 | **不会发生**：编辑器用 `registerPlainText`，键位表（`keymap.ts`）只处理方向键/Tab/Esc/空格/回车，没有 Backspace |
| `BEFORE_INPUT_COMMAND` | 浏览器 `beforeinput`（`deleteContentBackward`） | 所有引擎都走这条 |

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

结果：**每次退格都在「选中 → 清掉 → 再选中」之间循环，永远走不到真正删除那一步**。

**这不是 iOS 独有的**：编辑器用的是 Lexical 的 `registerPlainText`（`runtime.ts:108`），而它的键位表（`keymap.ts`）只处理方向键/Tab/Esc/空格/回车，**没有注册 Backspace**，所以删除在任何引擎上都只能以 `beforeinput` 到达——第 2 步的清掉在桌面浏览器同样会发生。iOS 只是最先被报告的地方。

`PASSIVE_KEYS` 里只列了 `Shift/Control/Alt/Meta/Unidentified/Process`，注释也写了「IME 或虚拟键盘的删除会以 input 事件后到」——但 iOS 的退格 keydown 报的是 `Backspace`，不在这个集合里，于是被当成「没产生删除的键」清掉了。

## 4 临时绕法（现在就能用）

1. **全选再删**：长按/双击选中全部文本后删除。范围选择不是折叠光标，`$commandChipBesideCaret` 直接返回 null，删除照常生效；
2. **计划模式**：点输入框工具条上的「计划模式」chip（它是按钮，走 `/plan off`），或直接发 `/plan off`；
3. **目标**：发 `/goal clear`；
4. 装 0.9.1 及以后的壳：壳侧已加临时缓解（§4.1），退格两次即可删除。

### 4.1 壳侧临时缓解（0.9.1 真机已验证）

`ios/App/Web/ComposerShim.swift` 在文档开始时注入一个**捕获阶段**的 keydown 监听：当编辑器报告有词条被选中（根元素带 `data-composer-chip-selected`）、且按键是 `Backspace`/`Delete`、且事件发生在该编辑器内时，`stopPropagation()` 掉这次 keydown。

这样编辑器的 keydown 兜底不会排队那个清选中的 microtask，选中态保留；随后 WebKit 照常派发 `beforeinput`，`$decide` 看到「已选中」直接放行，词条被删掉。

边界：

- 只在「有词条被选中 + 退格/删除键 + 编辑器内」时介入，其它按键与其它区域完全不受影响；
- 属性名一旦被上游改掉，shim 自动失效（不报错、不误伤）；
- 上游修好之后**应当删除**这个脚本，`GatewayWebView.swift` 里的注入点和这里一起删。

**真机结果（2026-11-14，iPhone19,7 / iOS 27.0.1，0.9.1 build 50）**：`/plan`、`/goal` 词条都能正常删除了。这是本条问题唯一的验收证据——0.9.0（build 49）上同样的操作删不掉。

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

补丁与验证脚本放在 [`docs/patches/`](patches/README.md)：

- `command-chip-selection.patch` —— 可直接 `git apply` 的 diff；
- `simulate-chip-delete.js` —— 事件时序模型，实测输出：

```text
chromium + old PASSIVE_KEYS  presses=2 deleted=1 chipLeft=no
chromium + new PASSIVE_KEYS  presses=2 deleted=1 chipLeft=no
webkit + old PASSIVE_KEYS    presses=2 deleted=0 chipLeft=yes
webkit + new PASSIVE_KEYS    presses=2 deleted=1 chipLeft=no
RESULT: matches the diagnosis
```

即：Chromium 两条路径都能删（无回归），WebKit 旧代码**永远删不掉**、新代码第二次退格即可删除。

**状态**：壳侧缓解已在真机验证（§4.1）。上游补丁本身仍未提交给上游，也**没有**在真机上单独验证过——它和壳侧 shim 修的是同一处，两者共存不会冲突（见 `docs/patches/` 的模拟输出）。

## 6 复现与取证方法

iOS 端：装 0.9.0 壳 → 打开页面 → 「+」→ 计划 → 在文本框里连按退格 → 词条只变高亮不消失。桥日志里不会出现任何 `invoke`（与桥无关），可作为「壳未介入」的旁证。

## 7 `share` 在页面上没有入口（2026-11-14 确认）

壳的 `share` 已经实现（`SharePresenter` → `UIActivityViewController`），但**页面从不调用它**，所以 UI 上找不到「分享」，P1-04 无法验证。

证据（读 `~/.dsh/profiles/desktop/node_modules/dsh-mobile/lib/client.js`，dsh-mobile 0.8.8）：

- 页面里唯一和 `share` 有关的是**降级适配器**：没有原生桥时 `invoke('share')` 走 `navigator.share`；
- 除这段适配器外，整个插件只有 3 处 `share` 字样，全是「Shared token」「Shared 32-bit …」这类无关文案；
- 全仓库 grep `invoke("share"` / `action: "share"` 无命中 —— **没有任何按钮或菜单项发起它**。

对比一下：`camera.capture` 有明确调用点（`bridge.invoke("camera.capture", {})`），`files.pick` 由附件选择器走同一适配器，而 `share` 只有适配器、没有调用者。

因此：

- 长按消息出现的是**系统文本选择器**，那是 WebKit 自带行为，与桥无关；
- 想分享只能先选中文本、用系统菜单里的「拷贝」，再自己粘贴；
- `capabilities()` 里继续报 `share` 不会造成「点了没反应的按钮」（页面根本没渲染这个按钮），但也没意义——等上游加了入口再验证。

**决定（2026-11-14）**：不做壳侧入口。`share` 的实现保留（上游一旦调用即可用），但不额外造 UI；P1-04 记为「页面无入口」，不算未完成项。

## 8 附件菜单弹出时键盘反复出现（2026-11-15）

**现象**：在输入框里打字时点「+」想加附件，键盘收起；随后手指在弹出菜单上滑动，键盘又回来，把菜单顶掉一半；再滑动又收起——输入框反复重排，选文件体验很差。

**根因**（`dsh-mobile/lib/mobile-layout.js`，0.8.8）：

- 点「+」时 `applyComposerImePolicy` 判定为 `withhold`：给编辑器加 `inputmode="none"`，**不移动焦点**地收起键盘（设计如此）；
- 但 `resolveComposerImePolicy` 对**任何其他** pointerdown 都返回 `restore`，直接删掉 `inputmode="none"`；
- 菜单是覆盖在编辑器上的一层，手指在菜单上滑动同样触发 pointerdown → `restore` → 编辑器仍持有焦点 → 键盘重新弹出 → 布局被顶起 → 菜单显示不全。

**壳侧缓解（0.9.13）**：壳把真实键盘状态发布到页面——`window.__DSH_MOBILE_KEYBOARD_STATE__ = { imeVisible, noHardwareKeyboard }`，由 `keyboardWillChangeFrame` 的结束 frame 判定（补上 docs/03 §7 的 `keyboard.state` 契约）。`ComposerShim` 让页面的两次写入不改变当前状态：

| 当前键盘 | 页面动作 | 结果 |
| --- | --- | --- |
| 弹着 | `withhold`（加 `inputmode="none"`） | **丢弃**，键盘保持弹着 |
| 收起 | `withhold` | 放行（这是「+」focus 编辑器却不唤起键盘的机制） |
| 收起 | `restore`（删 `inputmode="none"`） | **丢弃**，避免手指划过菜单时把键盘叫起来 |
| 收起 | 用户点编辑器 | 放行，键盘正常弹出 |

版本演进（都记在这里，避免下次再走一遍）：

- 0.9.10 全拦 → 键盘收起时点「+」反而唤起（页面靠 withhold 压住 focus）；
- 0.9.11 连 `restore` 也拦 → `inputmode="none"` 卡死，回车失效、菜单回车直接激活默认项；
- 0.9.12 只拦 withhold → 回车仍失效（**说明回车问题与拦截无关**），且滑菜单会唤起键盘；
- 0.9.13 恢复「收起时拦 restore」，并**给键盘状态加了桥日志**（`keyboard state imeVisible=…`、`page sees keyboard …`），用来定位回车为什么没走换行分支。

**边界**：只依赖 `data-composer-input` 这一个既有属性与壳发布的键盘状态；上游改了标记就自动失效，不会误伤。上游修好（`resolveComposerImePolicy` 不再改 `inputmode`）之后应删除这段。

## 9 回车不换行（2026-11-15）

页面自己的换行翻译在 `dsh-mobile/lib/client.js` 的 `bindComposerSoftEnter`：软键盘回车时 `preventDefault()`，再派发一个 `shiftKey: true` 的合成 keydown 让编辑器插入换行。触发条件是 `isSoftKeyboardEnterLineBreak`，要求 `nativeState.imeVisible === true`、`noHardwareKeyboard === true`、编辑器 `contenteditable="true"`、`event.isTrusted` 等。

壳侧已经把 `imeVisible` 发布正确（0.9.13 日志可见 `imeVisible=true/false` 随键盘正确切换），但回车仍不换行，说明条件里还有一项不满足（很可能是编辑器属性或事件被别处 `preventDefault`）。

**壳侧兜底（0.9.15）**：键盘弹出时在**键盘正上方**显示一条工具条（`safeAreaInset` + `keyboardWillChangeFrame` 的高度），里面有「换行」和「完成」。「换行」用 `document.execCommand('insertLineBreak')`（失败回退 `insertText`）在焦点编辑器里插入换行——走 WebKit 的编辑管线，编辑器能收到，不依赖 `isTrusted` 的合成事件。

> 0.9.14 先把按钮放在网页顶栏，用户要求改成贴着键盘的位置，0.9.15 移到键盘上方。系统输入法自带的「换行」属于系统编辑菜单，WebView 里加不进去。

**诊断**：打开「桥日志」时会执行一次 `composer probe`，记录 `[data-composer-input]` 的数量、`contenteditable` 属性、`isContentEditable`、桥对象类型与键盘状态，用来定位页面的换行条件到底卡在哪一项。

## 10 回车不换行的真正原因：`inputmode="none"` 卡住（2026-11-15）

`composer probe` 显示编辑器是 `contenteditable="true"`、`isContentEditable=true`、桥对象正常，但回车仍不换行。回到 `dsh-mobile/lib/client.js` 的 `editable` 判定：

```js
editable: editor.isConnected
  && editor.getAttribute("contenteditable") === "true"
  && editor.getAttribute("aria-disabled") !== "true"
  && editor.getAttribute("aria-haspopup") !== "menu"
  && composerCard.getAttribute("aria-busy") !== "true"
  && editor.getAttribute("inputmode") !== "none"        // ← 这里
```

页面点「+」时加的 `inputmode="none"`（withhold）**只有在后续 pointerdown 时才会被 restore 掉**。如果用户点完「+」直接打字、没有在别处点一下，`inputmode="none"` 就一直留着 → `editable === false` → 回车永远走桌面逻辑（发送 / 在菜单里激活默认项）。

**修复（0.9.16）**：`ComposerShim` 接管 `window.__DSH_MOBILE_KEYBOARD_STATE__` 的赋值，一旦 `imeVisible` 变成 `true`，就清掉所有 `[data-composer-input]` 上的 `inputmode="none"`。这样：

- 键盘收起时 withhold 仍然生效（点「+」不会唤起键盘）；
- 键盘一弹起来，残留的 withhold 立刻被清掉，`editable` 恢复为 true，回车重新变成换行。

`composer probe` 也补上了 `inputmode` 与 `aria-haspopup` 两个字段，下次可以直接看到是否卡住。

## 11 键盘相关改动总表（2026-11-15 收尾）

回车换行最终放弃：页面的换行分支要求 `imeVisible === true && noHardwareKeyboard === true && inputmode !== "none"`，而它自己的 withhold 会把 `inputmode` 写成 `none`，两者互相打架，真机上始终不稳定。**决定：回车恢复原始语义（发送）**，换行改由键盘上方工具条的「换行」按钮提供（`execCommand('insertLineBreak')`，日志验证过 `ok`）。

为此壳发布的状态改成 `noHardwareKeyboard: false`——页面的换行翻译因此永不触发，回车就是发送。

| 版本 | 改动 | 结果 |
| --- | --- | --- |
| 0.9.9 | `ComposerShim` 捕获阶段拦 pointerdown，菜单打开时阻止页面 `restore` | 键盘收起时点「+」仍会唤起；已废弃 |
| 0.9.10 | 改为接管 `setAttribute/removeAttribute`，窗口内忽略所有 `inputmode` 写入 | 键盘收起时点「+」反而唤起（withhold 被拦）；已废弃 |
| 0.9.11 | 只拦 withhold 不拦 restore，并发布 `__DSH_MOBILE_KEYBOARD_STATE__` | 滑菜单会唤起键盘；`inputmode="none"` 卡死；已废弃 |
| 0.9.12 | 只拦 withhold（键盘弹着时） | 回车仍失效（根因不在拦截）；滑菜单唤起键盘 |
| 0.9.13 | 恢复「收起时拦 restore」+ 键盘状态日志 | 键盘行为基本稳定，回车仍失效 |
| 0.9.14 | 顶栏「换行」按钮 + `composer probe` 探针 | 换行可用；探针定位到 `inputmode` 卡死 |
| 0.9.15 | 换行按钮移到键盘上方工具条（含「完成」） | 符合用户要求的形态 |
| 0.9.16 | `imeVisible` 变 true 时清掉残留 `inputmode="none"` | 回车理论上恢复，但真机仍不稳定 |
| 0.9.17 | `noHardwareKeyboard: false`，回车恢复发送；保留工具条「换行」 | 本轮最终状态 |

**当前生效的行为**：

- 键盘弹着时点「+」→ 不收起（0.9.13 起）；
- 键盘收起时点「+」→ 不唤起；在菜单上滑动 → 不唤起（0.9.13 起）；
- 回车 → **发送**（0.9.17 起）；
- 需要换行 → 键盘上方工具条的「换行」；
- 键盘上方工具条还有「完成」用于收起键盘。

## 12 键盘改动已全部撤回（0.9.18）

按用户要求，0.9.9–0.9.17 针对键盘的改动**全部撤回**，代码回到 0.9.8 的状态：

| 撤回项 | 说明 |
| --- | --- |
| `window.__DSH_MOBILE_KEYBOARD_STATE__` 发布 | 不再向页面发布键盘状态 |
| `ComposerShim` 的 `inputmode` 拦截 | 页面自己的 withhold/restore 原样生效 |
| 键盘上方「换行 / 完成」工具条 | 已删除 |
| 顶栏「换行」按钮 | 已删除 |
| `composer probe` 诊断 | 已删除 |
| `BridgeHost.runInPage` | 随之删除 |

**保留**：`ComposerChipShim`（命令词条 `/plan`、`/goal` 的退格删除，0.9.1 真机验证过）。

结论：键盘行为回到页面原本的逻辑（点「+」会收起键盘、滑菜单会再唤出、回车按页面默认处理）。如果以后还要改，`§11` 里记录了 0.9.9–0.9.17 每条路为什么失败，不必重走。

## 13 P0-09 撤销检测：真机反馈与修复（0.9.19）

真机验证结果（0.9.6）：

| 场景 | 结果 |
| --- | --- |
| 已连接时电脑端移除设备 | ✅ 自动退回设备列表、红色「已移除」徽章、首页橙色横幅 |
| 未连接时点连接 | ✅ 提示「电脑端已移除这台设备，请重新配对」 |
| 重新配对后标记自动清除 | ❌ **未达成** |
| 只有一台设备且已撤销时启动 | ⚠️ 只显示「所有电脑都已移除本机设备」，没有横幅 |

**原因**：`revoked` 是 `AppModel` 的内存集合，重新配对走的是 `PairingCoordinator`，它只写 Keychain；`AppModel` 既没重新读盘，也没清掉那条 id 的标记。启动时「全部已撤销」的分支只改了 `status`，没有设置 `connection = .revoked`，所以横幅不出现。

**修复**：

- 新增 `AppModel.adoptPairedGateway(origin:)`：配对成功后重新读 Keychain、刷新 `devices`、清掉该 origin 的 `revoked` 标记与可达性状态，并把 `connection` 从 `.revoked` 复位；
- 配对的**两个入口**（「配对并打开」按钮、扫码）在 `pairing.session != nil` 时都调用它；
- `restore()` 在「所有电脑都已撤销」时把 `connection` 置为 `.revoked(第一台)`，让横幅与状态行一致。
