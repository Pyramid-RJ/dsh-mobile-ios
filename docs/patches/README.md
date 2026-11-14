# 上游补丁：命令词条在 iOS 上删不掉

对应 [10 上游问题记录](../10-upstream-issues.md)。这里放的是**可直接交给上游**的两件东西，不是本仓库的代码。

| 文件 | 用途 |
| --- | --- |
| `command-chip-selection.patch` | 针对 `@deepseek-ai/dsh-client-ui-conversation` 的 `command-chip-selection.ts` 的补丁 |
| `simulate-chip-delete.js` | 不依赖浏览器的事件时序模型，用来验证「旧代码在 WebKit 上永远删不掉、新代码可以」 |

## 补丁怎么用

文件路径按包内相对路径写的（`src/client/input/editor/command-chip-selection.ts`）。在 DSH 仓库里按实际位置调整：

```bash
# 在包含该包的目录下（路径按仓库实际结构调整）
git apply --directory=packages/client/ui-conversation docs/patches/command-chip-selection.patch
# 或者只做检查
git apply --check -p1 docs/patches/command-chip-selection.patch
```

补丁只做一件事：把 `Backspace` / `Delete` 加进 `PASSIVE_KEYS`，让 keydown 的「没产生删除就清选中」兜底不再抢在 WebKit 的 `beforeinput` 之前清掉词条选中态。

## 模拟怎么跑

```bash
node docs/patches/simulate-chip-delete.js
```

输出（2026-11-14 实测）：

```text
chromium + old PASSIVE_KEYS  presses=2 deleted=1 chipLeft=no
chromium + new PASSIVE_KEYS  presses=2 deleted=1 chipLeft=no
webkit + old PASSIVE_KEYS    presses=2 deleted=0 chipLeft=yes
webkit + new PASSIVE_KEYS    presses=2 deleted=1 chipLeft=no

expectation: chromium deletes either way; webkit only deletes with the fix
RESULT: matches the diagnosis
```

它证明的是**状态机层面**的结论：Chromium 的同步删除路径不受影响（无回归），WebKit 的「keydown → microtask → beforeinput」顺序在旧代码下会把选中态清掉、新代码下可以正常两步删除。

它**不能**代替真机验证：iOS 上 `beforeinput` 的实际触发时机、以及 Lexical 在 WKWebView 里的键位表行为，仍需上游在真机上复测两条路径——「退格两次删除」和「方向键跨过词条」。
