# 11 与上游源码的契约对照（2026-11-15）

对照对象：

- 页面侧：`~/.dsh/profiles/desktop/node_modules/dsh-mobile/lib/client.js`（dsh-mobile **0.8.8**，18319 行）
- 壳侧：本仓库 `ios/App/Web/BridgeScript.swift`（注入的适配层）、`ios/App/Web/BridgeHost.swift`（原生处理）、`ios/Sources/DSHBridge/*`

结论先说：**主链路完全对得上**（桥对象、报文、能力表、相机/文件/缩放/切换电脑/撤销都跑通了），差异集中在 4 处，其中 2 处是真实缺口。

## 1 一致的约定

| 约定 | 页面要求（行号） | 壳实现 |
| --- | --- | --- |
| 桥对象形状 | `window.__DSH_MOBILE_NATIVE__` 必须有 `capabilities()` 与 `invoke()`（3788） | ✅ `BridgeScript` |
| `capabilities()` 返回字符串数组 | `capabilities().includes(...)` 做开关 | ✅ `BridgeCapabilities.values` |
| 请求报文 | `{version:1, requestId, action, input}` | ✅ `BridgeRequest.parse` |
| 回执 | `{requestId, ok:true, value}` / `{requestId, ok:false, code, message}` | ✅ `BridgeReply` |
| `auth.renew` 回执 | 必须 `result.renewed === true`（9290） | ✅ `["renewed": true]` |
| 显示缩放回执 | `{percent, minPercent, maxPercent}`，整数、80–125、含 100（7263） | ✅ `DisplayScalePolicy.reply` |
| `device.revoked` | 页面直接 `invoke`，不查能力表，忽略回执（3863） | ✅ 0.9.6 起实现 |
| 相机调用 | `bridge.invoke("camera.capture", {})`，回执须是 `File`（5661） | ✅ 适配层还原成 `File` |
| 能力表诚实 | 页面按 `includes` 隐藏功能 | ✅ 只报实现的；`notification.*` 不报 |

## 2 差异

### 2.1 `auth.renew` 的失败码不匹配（**已在 0.9.20 修复**）

页面（9235）：

```js
credentialsRejected = error.code === "device_revoked"
  || error.code === "device_expired"
  || error.code === "authentication_failed";
```

壳（`BridgeHost.handle` 的 `authRenew` 分支）任何失败都回 `code: "failed"`。于是页面**永远看不到**这三个码，`credentialsRejected` 一直是 false——续期被拒时页面不会进入「凭据失效」分支，只会继续重试。

**修复（0.9.20）**：`BridgeFailureCode` 增加 `device_revoked` / `device_expired` / `authentication_failed`；`BridgeHost.bridgeCode(for:)` 把 `MobileAccessFailure` 映射过去（`.pairingExpired` → `authentication_failed`），单测覆盖三个码的原始值。

### 2.2 活动类请求的超时短了一半（**已在 0.9.20 修复**）

页面契约（docs/03 §5.4）：`files.pick` / `camera.capture` 的页面侧超时是 **305 s**，其它 60 s。

但页面调用时**不传 options**（`bridge.invoke(action, input)`，8881），我们的适配层只能用默认值：

```js
const timeoutMs = opts.timeoutMs || 60000;   // BridgeScript.swift
```

所以选文件超过 60 s 时，**JS 侧先超时**（native 还在等），页面报 timeout，回执回来时 pending 已经删掉。相机有原生 60 s 兜底，问题不大；`files.pick` 是真问题。

**修复（0.9.20）**：适配层按 action 取默认超时——`files.pick` / `camera.capture` 用 305 s，其余 60 s。

### 2.3 文件回执的形状与上游不同（能跑，但不是契约形状）

页面（17153）：

```js
const materializeNativeFile = (value) => {
  if (typeof value !== "object" || value === null || !("base64" in value) || !("name" in value)) return value;
  ... // 顶层 base64 + name（+ mime）→ 造 File
};
```

即上游约定的回执是**扁平的** `{ name, mime, base64 }`。我们回的是 `{ "__file": { name, mime, base64 } }`，靠注入的适配层 `decodeFile` 先转成 `File`，页面拿到 `File` 后 `materializeNativeFile` 原样返回，所以能用。

风险：如果哪天适配层没注入（或顺序变了），页面收到的是 `{__file:…}`，`materializeNativeFile` 判不出 `base64`，会把它当普通对象塞进附件——静默坏掉。

修法：原生直接回扁平 `{name, mime, base64}`，适配层的 `decodeFile` 变成兼容旧形状的兜底。

### 2.4 `auth.renew` 的取消只停在 JS 侧（小缺口）

页面用 `adapter.invoke("auth.renew", {}, { signal })`（9290），abort 时我们的适配层只是**本地 reject 并从 pending 删除**，没有通知原生（docs/03 §5.3 的 `auth.renew.cancel` 事件没实现）。原生的 `URLSession` 会继续跑完，回执回来时无人接收。

影响：一次被放弃的续期仍会占用网络与 20 s 超时窗口；不会出错，只是浪费。

### 2.5 未实现的可选契约

| 项 | 页面侧 | 壳侧 |
| --- | --- | --- |
| `dsh-mobile:native-back` 事件 | 监听（8 处），用于关抽屉/关面板/关对话框 | ❌ 从不派发（iOS 无返回键，docs/03 §7.1 记录为「本期不做」） |
| `keyboard.state` / `__DSH_MOBILE_KEYBOARD_STATE__` | 读它决定回车是否换行、是否收起键盘（5143、5930） | ❌ 0.9.18 起不再发布（键盘改动已全部撤回，见 [10 §12](10-upstream-issues.md)） |
| `page.background` / `page.scroll` | 可选 | ❌ 未实现 |
| `notification.*` | 有 `includes` 开关 | ❌ 不报，页面自动隐藏（符合预期） |
| `share` | 只有降级实现（`navigator.share`），**无调用点** | ⚠️ 实现并上报，但页面永不调用（[10 §7](10-upstream-issues.md)） |

## 3 建议的修复顺序

1. **2.1 `auth.renew` 失败码**——影响「电脑端撤销后停止重试」的核心语义，改动小（枚举 + 映射 + 测试）；
2. **2.2 活动超时 305 s**——影响选文件，改动小（适配层按 action 取默认值）；
3. **2.3 扁平文件回执**——消除静默失败的可能，改动中等（原生 + 适配层 + 文档）；
4. **2.4 `auth.renew.cancel`**——纯优化，可最后做。

2.5 里除 `keyboard.state` 外都属于「本期不做」的有意选择，不需要动。
