# 03 与 Android APK 的协议对齐矩阵

本文件的每一条都来自上游 `main` 分支的实际代码（`src/gateway.ts`、`src/access.ts`、`src/http-security.ts`、`apps/mobile/android/app/src/main/java/io/github/sayach/dshmobile/*.kt`）。**iOS 端必须逐项实现，不允许"大致差不多"**——服务端对键集合、格式、长度都有严格校验。

标注：**[同]** = 与 Android 完全一致；**[异]** = 平台不同但语义要等价；**[无]** = iOS 不做。

## 1 HTTP 端点

| 端点 | 方法 | 认证 | iOS 用途 | 备注 |
| --- | --- | --- | --- | --- |
| `/mobile-access/ca.cer` | GET | 无（引导阶段） | 取私有 CA（DER） | **[重要]** 404 = 无私有 CA；请求此端点时必须用**不受信任也继续**的引导通道 |
| `/mobile-access/discovery` | GET | 无 | 兼容性发现元数据 | 返回 `{deviceName, origin, port, protocol, instanceId}` 恰好 5 键 |
| `/mobile-access/metadata` | GET | 无 | 版本门槛 | `{version, pluginVersion, minimumAndroidAppVersion, discoveryProtocol}` |
| `/mobile-access/health` | GET | 无 | 连通性 | `{ok:true}` |
| `/mobile-access/auth/native-pair` | POST | 配对 token | 换取设备凭据 | 201 |
| `/mobile-access/auth/native-renew` | POST | deviceToken | 续期会话 | 200 |
| `/mobile-access/auth/native-probe` | POST | deviceToken | 可达性 | 200 |
| `/mobile-access/auth/logout` | POST | 会话 | 清除会话 | 本期可不做（删本地记录即可） |
| `/mobile-access/background-events` | GET(SSE) | 会话 | 后台事件流 | **[无]** 免费签名下无后台 |
| `/mobile-access/mobile-boot/<64hex>.js` | GET | 会话 | 页面启动批 | 由页面自动请求，壳不介入 |
| `/mobile-access/compat.js` | GET | 会话 | 兼容层 | 由网关注入，壳**不要**重复注入 |

> **引导期 TLS**：Android 的 `bootstrapGet` 在取 CA 时使用一个"接受一切"的 `X509TrustManager`（因为此时还没有 CA 可固定）。iOS 上必须复刻这个**有界**的例外：仅对 `/mobile-access/ca.cer` 与 `/mobile-access/discovery` 两个路径、且仅在**尚未固定 CA** 时使用自定义信任评估，随后立即用指纹校验兜底。见 [04 §2.3](04-security.md#23-引导期信任的分寸)。

## 2 请求头

| 头 | 值 | 适用 |
| --- | --- | --- |
| `Content-Type` | `application/json` | 三个 POST |
| `Origin` | 网关精确 Origin | 三个 POST（网关会校验） |
| `Sec-Fetch-Site` | `same-origin` | 三个 POST |
| `X-DSH-Mobile-Capabilities` | `installation-id` | **[同]** 只有带了它，响应才含 `installationId` |
| `x-dsh-mobile-csrf` | CSRF cookie 值 | 页面发起的写请求（由页面 bootstrap 自动加，壳不管） |

`native-pair` 请求体：`{token: string, label?: string}`；Android 传的 label 是 `"DeepSeek Harness Android"`，iOS 应传 `"DeepSeek Harness iOS"`（会显示在电脑端设备列表）。

### 2.1 三个 POST 的认证载体（2026-11-13 对照上游 `NativeAuthClient.kt` 确认）

```
native-pair  : {"token": "<43>",        "label": "DeepSeek Harness iOS"}
native-renew : {"deviceToken": "<43>"}
native-probe : {"deviceToken": "<43>"}
```

**不使用 `Authorization` 头**——凭据一律走 JSON body。iOS 端实现见 `ios/Sources/DSHTransport/MobileAccessClient.swift`。响应里的 `instanceId` 必须等于配对时预期的实例，否则判 `invalid_response`（上游同样显式校验）。

## 3 响应结构（严格键集合）

### 3.1 `native-pair`（201）

必需键（**集合必须完全相等**，多一个少一个都会判 `invalid_response`）：

```
instanceId, deviceId, deviceToken, deviceExpiresAt,
sessionToken, csrfToken, sessionExpiresAt
```
可选键：`installationId`。

### 3.2 `native-renew`（200）

```
instanceId, deviceId, sessionToken, csrfToken, sessionExpiresAt
```
可选：`installationId`。

### 3.3 `native-probe`（200）

```
instanceId, deviceId, deviceExpiresAt
```
可选：`installationId`。

### 3.4 字段格式（正则必须一致）

| 字段 | 格式 |
| --- | --- |
| `instanceId` / `installationId` | `^[a-f0-9]{64}$` |
| `deviceId` | `^[a-f0-9]{32}$` |
| `deviceToken` / `sessionToken` / `csrfToken` | `^[A-Za-z0-9_-]{43}$` |
| `*ExpiresAt` | 未来时间戳（毫秒 epoch）；`deviceExpiresAt >= sessionExpiresAt` |

其他约束：响应 `Content-Type` 必须 `application/json`（忽略 `;charset`）；响应体 ≤ 32 KiB；`instanceId` 必须等于配对时预期的那个，否则 `invalid_response`。

## 4 错误码映射

| HTTP | JSON `error` | 分类 |
| --- | --- | --- |
| — | `device_revoked` | `deviceRevoked` |
| — | `device_expired` | `deviceExpired` |
| 401 | `authentication_failed` | `deviceRevoked`（电脑端已没有这台设备，语义与撤销相同） |
| 401 / 403 | — | `pairingExpired` |
| 409 | — | `deviceLimit` |
| 429 | — | `rateLimited` |
| 500–599 | — | `serverUnavailable` |
| 其他 | — | `invalidResponse` |

`error` 字段从错误响应体读，长度 1–64 才采用（与 Android `readErrorCode` 一致）。

## 5 页面桥契约

### 5.1 入口对象

```js
window.__DSH_MOBILE_NATIVE__ = {
  capabilities(): Promise<string[]>,
  invoke(action, input = {}, options = {}): Promise<any>,
}
window.dispatchEvent(new Event('dsh-mobile-native-ready'))
```

页面在启动时会读 `window.__DSH_MOBILE_NATIVE__`，并据此决定**是否走原生分支**（例如输入栏 Enter、缩放行、后台提醒行、推送行）。**桥存在但能力不足时，页面只会隐藏对应功能**，不会崩——这给了我们"先上最小桥、逐步加能力"的空间。

### 5.2 报文与回执

| 方向 | 结构 |
| --- | --- |
| 页面 → 原生 | `{version: 1, requestId, action, input}` |
| 页面 → 原生（仅取消） | `{version: 1, event: 'auth.renew.cancel', requestId}` |
| 原生 → 页面（成功） | `{requestId, ok: true, value: {...}}` |
| 原生 → 页面（失败） | `{requestId, ok: false, code, message}` |
| 原生 → 页面（事件） | `{version: 1, event: 'keyboard.state', imeVisible, noHardwareKeyboard}` 等 |

错误 `code` 取值（与 Android 一致）：`bad_message`、`unsupported`、`unavailable`、`cancelled`、`timeout`、`payload_too_large`、`permission_denied`、`failed`。

### 5.3 `auth.renew` 的取消语义

页面在 `AbortSignal` 被 abort 时：
1. 从 pending 表删除该项并 clear 超时；
2. 发 `{event:'auth.renew.cancel', requestId}`；
3. reject 一个 `name: 'AbortError'`、`code: 'cancelled'` 的错误。

因此原生必须：收到 cancel 时取消在途 `URLSession` 任务，并以 `cancelled` 回执（或直接不回执，因为页面已移除 pending——两者都可，建议**回执**，便于诊断）。

### 5.4 超时

| action | 页面侧超时 |
| --- | --- |
| `files.pick` / `camera.capture` | `PAGE_ACTIVITY_TIMEOUT_MS` = 5 min + 5 s = **305 s** |
| 其他 | **60 s** |
| 原生侧 activity 请求截止 | **300 s** |

原生必须自己也有超时（略小于页面侧），避免 pending 泄漏。

## 6 能力映射总表

| action | Android | iOS 本期 | iOS 实现要点 |
| --- | --- | --- | --- |
| `files.pick` | ✅ | **[S]** 建议实现 | 依赖 S-2；`UIDocumentPicker`/`PHPicker`；8 MiB；单文件；MIME 过滤 |
| `camera.capture` | ✅ | **[S]** 视成本 | `UIImagePickerController`；临时文件清理；权限 |
| `share` | ✅ | **[S]** 便宜 | `UIActivityViewController`，`text/plain` |
| `clipboard.read` | ✅ | **[M]** | `UIPasteboard`；iOS 16+ 会弹"允许粘贴"系统提示，**必须**在 UI 里解释，否则用户以为卡死 |
| `clipboard.write` | ✅ | **[M]** | 同上；256 KiB 上限 |
| `auth.renew` | ✅ | **[M]** | `native-renew` + 重写 Cookie |
| `notification.notify` | ✅ | **[无]** | 无 APNs；本地通知缺少事件来源，不必做 |
| `notification.settings` | ✅ | **[无]** | 仅当实现了通知才有意义 |
| `notification.background.get/set` | ✅ | **[无]** | 页面对这两个能力做 `includes` 检查，缺失只隐藏该行 |
| `mobile.switch-computer` | ✅ | **[S]** | 回设备列表 |
| `device.revoked` | ✅ | **[S]** | 页面从事件流得知 `reason: "device_revoked"` 时通知原生：标记该电脑为「已移除」并退回设备列表（页面不检查能力表，直接 `invoke`，忽略回执） |
| `mobile.display-scale.get/set` | ✅ | **[S]** | 改 `meta viewport`，公式见 [03 §6.1](#61-显示缩放公式) |
| iroh 传输 | ✅（完整版） | **[无]** | 见 [02 §8](02-architecture.md#8-与-iroh-的关系) |

### 6.0.1 切换电脑是一个长按手势（2026-11-14 对照上游 `native-mobile.ts` 确认）

页面**不会**在抽屉里放「切换电脑」菜单项。触发方式是：

- 长按抽屉开关（`[data-dsh-mobile-toggle]`，即左上角鲸鱼/☰ 按钮）**500 ms**（`SWITCH_COMPUTER_LONG_PRESS_MS`）；
- 手指移动超过 **14 px**（`SWITCH_COMPUTER_MOVE_TOLERANCE_PX`）即取消，交还给抽屉滑动；
- 首次按下时页面会调一次 `capabilities()` 探测是否支持（`probeSupport`），支持后才允许长按生效；
- 触发后 1200 ms 内抑制合成 click，避免抽屉同时被打开。

因此"抽屉里找不到切换电脑"不是能力缺失。

### 6.1 显示缩放公式

与 Android `NativeDisplayScalePolicy` 完全一致：

```
viewportWidth = round(nativeWidth / density / (percent / 100))
```

范围 80–125 的整数；越界回 `bad_message`（`"display scale must be an integer from 80 to 125"`）。回执必须是 `{percent, minPercent: 80, maxPercent: 125}`，页面会校验这四个数与区间。

### 6.2 capabilities() 的诚实原则

**只返回真正实现的 action**。上游页面全部用 `capabilities().includes(...)` 做开关，谎报会导致：

- 报 `notification.background.*` 但没实现 → 设置页出现一个点了没反应的开关；
- 报 `mobile.display-scale.*` 但 get 返回非法值 → 页面进入 `error` 态并显示"无法调整页面缩放"。

## 7 宿主事件与页面契约

| 事件 | 方向 | iOS 是否需要 |
| --- | --- | --- |
| `keyboard.subscribe` | 页面 → 原生 | 建议实现 |
| `keyboard.state` | 原生 → 页面 | 建议实现（`imeVisible` + `noHardwareKeyboard`） |
| `keyboard.state` 变化时机 | — | 键盘 frame 变化、硬件键盘连接状态变化 |
| `page.background` | 原生 → 页面 | 可选（用于状态栏配色） |
| `page.scroll` | 原生 → 页面 | 可选（`direction: 'up'/'down'`，阈值 ±4 px） |
| `auth.renew.cancel` | 页面 → 原生 | 必须 |
| `dsh-mobile:native-back` | 原生 → 页面（同步取值） | 必须 |

### 7.1 返回键（iOS 用边缘手势/系统返回，但契约要保留）

Android 的实现是：

```js
const event = new Event('dsh-mobile:native-back', { cancelable: true });
window.dispatchEvent(event);
return event.defaultPrevented;   // true = 页面已处理
```

iOS 上系统没有"返回键"，但**页面有多个消费者监听此事件**（设置弹窗、目录选择器、模块管理、布局面板）。因此 iOS 版应：

- 在页面上提供一个**手势或按钮触发点**时调用同一脚本并据返回值决定是否关闭面板/回设备列表；
- 至少在页面内存在可返回层级时，让"Home 手势之外的返回入口"（例如 iPad 上外接键盘的 Esc）走这条路径。

若本期不做返回入口，则**不报任何返回相关能力**，页面照常工作（它本来就有自己的关闭按钮）。

## 8 版本兼容策略

| 检查 | 来源 | iOS 行为 |
| --- | --- | --- |
| 插件版本 | `/metadata.pluginVersion` | 记录并显示在诊断页；不阻塞 |
| 最低移动端版本 | `/metadata.minimumAndroidAppVersion` | 当作"最低移动客户端协议版本"；低于它时提示但不硬拦（因为字段名只覆盖 Android） |
| 发现协议 | `/metadata.discoveryProtocol` 与公告里的 `protocol` | 必须 == 1，否则忽略该公告 |
| 缺失 `/metadata` | 404 | 视为旧网关，允许继续，诊断标注 |

`installationId` 的存在与否要**优雅降级**：旧网关不返回它时，`optionalInstallationId` 为 nil，同电脑两入口（LAN/远程）不会被合并——这与 Android 的行为一致，不需要 iOS 额外处理。

## 9 明确无法对齐的地方（必须在文档中承认）

| 项 | Android | iOS | 处理 |
| --- | --- | --- | --- |
| 证书回调 | `onReceivedSslError` 带 `SslErrorHandler` | `didReceive challenge`（**可能**在 ATS 阶段就被拦） | S-1 验证；失败则降级架构 |
| WebMessage | `JavaScriptReplyProxy` 点对点 | 全局 `evaluateJavaScript` | 页面侧按 requestId 分发（已具备） |
| NSD | `NsdManager` 全量 | `NWBrowser` 仅 Bonjour | 不做 UDP 广播 |
| 前台服务 | ✅ | ❌ | 不做后台提醒 |
| Keystore | 不可导出密钥 | Keychain（可导出数据，但用 `ThisDeviceOnly`） | 安全等级略低，文档标注 |
| SameSite | 服务端 `Strict` | 注入 Cookie 时拿不到该属性 | 已知偏差，记入 [06](06-testing.md) |
| 应用图标切换 | ✅ | ❌ | 不做 |
