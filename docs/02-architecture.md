# 02 架构设计

## 1 分层总览

与 Android 壳保持**同样的三层切分**，只替换平台实现，页面与协议层不变。

```
┌──────────────────────────────────────────────────────────────┐
│                     DSH 页面（由电脑端网关提供）               │
│   dedicated 布局 + window.__DSH_MOBILE_NATIVE__ 契约          │
└───────────────────────────┬──────────────────────────────────┘
                            │ WKScriptMessageHandler / evaluateJavaScript
┌───────────────────────────▼──────────────────────────────────┐
│  PageBridge（原生中间层）                                      │
│  · 报文校验（版本/大小/requestId 唯一/并发上限）                │
│  · action 分发 → Service                                    │
│  · 回执编码 {requestId, ok, value|code+message}               │
│  · 宿主事件推送 keyboard.state / page.background / page.scroll │
└───────────────────────────┬──────────────────────────────────┘
        ┌───────────────────┼────────────────────┬──────────────┐
        ▼                   ▼                    ▼              ▼
┌──────────────┐  ┌──────────────────┐  ┌──────────────┐  ┌───────────┐
│ AuthService  │  │ ConnectionService│  │ DeviceStore  │  │  Feature  │
│ pair/renew/  │  │ LAN/remote、TLS  │  │ Keychain 持久│  │ file/cam/ │
│ probe、CA 固定│  │ 发现、可达性探测  │  │ 化与迁移     │  │ clip/share│
└──────┬───────┘  └────────┬─────────┘  └──────┬───────┘  └───────────┘
       └───────────────────┴───────────────────┘
                            ▼
                 URLSession（唯一出网通道）
```

**关键决策**：所有对网关的 HTTP 请求（配对、续期、探测）与所有页面加载的证书决策，都收敛到**一个 `ServerTrustEvaluator`**。不允许任何模块自己写 `completionHandler(.useCredential, ...)`。

## 2 模块划分（建议的 Xcode 目录）

```
ios/
  DSHPairing/          # 纯逻辑，无 UIKit：配对键、Origin、URL 策略、协议模型
  DSHTrust/            # CA 校验、指纹、SecTrust 锚点构造
  DSHTransport/        # URLSession 封装、超时、取消、错误分类
  DSHDeviceStore/      # Keychain + 元数据、迁移、损坏检测
  DSHBridge/           # 报文编解码、限额、pending 表、超时
  DSHFeatures/         # files/camera/clipboard/share/scale/switch
  DSHWeb/              # WKWebView 装配、导航策略、Cookie 注入、脚本注入
  DSHUI/               # 设备列表、配对表单、二维码、诊断
  App/                 # 组合根、生命周期、entitlements
  Tests/               # 单元测试（对应上游 80 个 JVM 套件的思路）
```

`DSHPairing` / `DSHTrust` / `DSHBridge` 必须**不依赖 UIKit**，这样可以在 macOS 上用 `swift test` 直接跑，不必每次开模拟器。

## 3 启动与连接时序

### 3.1 冷启动（已配对，默认「直接进入」）

```
App 启动
 ├─ 读 Keychain 设备表
 │   ├─ 空 → 显示「添加电脑」
 │   └─ 有 → 按启动行为选择目标设备
 ├─ 选定设备后：
 │   1. native-probe（轻量，验证凭据仍有效、网关可达）
 │   2. 读缓存的 CA（若有）；本地 CA 过期 → 直接失败并提示重新配对
 │   3. native-renew → 新 sessionToken / csrfToken / sessionExpiresAt
 │   4. 写 Cookie（__Host-dsh_ma_session, __Host-dsh_ma_csrf）
 │   5. WKWebView.load(origin + "/")
 └─ 失败分类：
     · TLS / CA 指纹不符 → 提示重新配对，不动已有凭据
     · 401 + device_revoked → 标记「电脑端已移除」，停止自动重连
     · 401 其他 → 「配对已过期」
     · 超时/网络 → 「暂不可达」，可手动重试，不切换设备
```

### 3.2 页面内会话过期恢复

对齐 Android 的 `auth.renew` 语义，但触发条件更严格（页面会主动请求）：

1. 页面调用 `invoke('auth.renew', {}, { signal })`。
2. 原生执行 `native-renew`，成功则重写 Cookie 并返回 `{ renewed: true }`。
3. 若 `signal` 被 abort，原生必须取消在途请求，并回 `code: 'cancelled'`。
4. 页面同时监听 `auth.renew.cancel` 事件（页面 → 原生），语义见 [03 §5.3](03-protocol-alignment.md#53-authrenew-的取消语义)。

只允许**一次**连续断连内的单次续期（与上游 `client-recovery.ts` 的策略一致），原生不自行重试。

## 4 WKWebView 装配

### 4.1 配置基线

| 配置项 | 取值 | 理由 |
| --- | --- | --- |
| `WKWebViewConfiguration.websiteDataStore` | `.default()` | 与 Safari PWA 互相独立，避免污染；**不要**用 `.nonPersistent()`，否则每次冷启动都掉登录 |
| `preferences.isJavaScriptEnabled` | true（默认） | — |
| `allowsInlineMediaPlayback` | true | 语音/媒体 |
| `mediaTypesRequiringUserActionForPlayback` | 空集 | 语音播报 |
| `WKUserContentController` | 只加**一个**脚本消息处理器 | 名字固定，便于调试；见 §4.3 |
| 自定义 UA | **不修改** | 页面不依赖 UA 分支（上游全代码库无 UA 嗅探），改 UA 只会让诊断变复杂 |
| 注入脚本 | **只注入桥适配层**（见 §4.2） | 兼容层由网关 `/mobile-access/compat.js` 负责，禁止重复注入 |

### 4.2 注入时机与内容（`WKUserScript` + `.atDocumentStart`, `forMainFrameOnly: true`）

必须**在文档开始**注入，因为页面在启动早期就会检测 `window.__DSH_MOBILE_NATIVE__`。注入内容需要复刻 Android 的适配层语义：

```js
// 目标：构造与 Android 完全一致的 window.__DSH_MOBILE_NATIVE__
(() => {
  const handler = window.webkit?.messageHandlers?.dshMobileNative;
  if (!handler) return;
  const pending = new Map();      // 复用旧 state，避免导航后 promise 悬挂
  window.__DSH_MOBILE_NATIVE_STATE__ = { pending };
  window.__DSH_MOBILE_KEYBOARD_STATE__ = null;

  // 原生 → 页面
  window.__DSH_MOBILE_NATIVE_DELIVER__ = (raw) => { /* 解析回执或事件 */ };

  window.__DSH_MOBILE_NATIVE__ = {
    capabilities: () => Promise.resolve([/* 实际实现列表 */]),
    invoke: (action, input = {}, options = {}) => new Promise((resolve, reject) => {
      /* 生成 requestId、序列化、限额检查、超时、AbortSignal 支持 */
      /* handler.postMessage(raw) */
    }),
  };
  window.dispatchEvent(new Event('dsh-mobile-native-ready'));
  /* postEvent({event:'keyboard.subscribe'}) 等宿主事件订阅 */
})();
```

原生的回执路径：`webView.evaluateJavaScript("__DSH_MOBILE_NATIVE_DELIVER__(...)")`。**不要**用 `callAsyncJavaScript` 传对象（序列化语义差异会引入新 bug），统一传**字符串**，让页面侧 `JSON.parse`。

> 与 Android 的差异：Android 用 `JavaScriptReplyProxy.postMessage` 做点对点回执；WebKit 没有等价物。因此必须用 `evaluateJavaScript` 全局派发，且**页面侧必须按 `requestId` 分发**（这正是 Android 适配层已有的逻辑，可以照搬）。

### 4.3 消息进出的安全校验（WebKit 侧必须自己补上）

`WKScriptMessageHandler` 的 `message` **只给 `frameInfo` 和 `body`**，没有内建来源校验。必须：

```swift
func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    // 1. 必须是主框架
    guard message.frameInfo.isMainFrame else { return }
    // 2. securityOrigin 必须精确等于当前已配对 Origin（scheme+host+port 全等）
    guard let o = message.frameInfo.securityOrigin as? WKSecurityOrigin,
          o.protocol == "https",
          o.host == origin.host,
          o.port == origin.port else { return }
    // 3. 大小上限（1 MiB UTF-8，与 NativeBridgePolicy.MAX_MESSAGE_BYTES 一致）
    guard let text = message.body as? String,
          NativeBridgePolicy.isMessageWithinLimit(text) else { return }
    // 4. 之后才解析
}
```

补充约束（对齐 Android 的 `NativeBridge`）：

- 报文 `version` 必须为 `1`；`requestId` 长度 ≤ 128 且唯一；pending ≥ 16 拒绝（`bad_message`）。
- 未知 action → `bad_message`。
- 所有回执走同一条编码函数，超限（12 MiB）降级为 `payload_too_large`。

### 4.4 Cookie 注入

在 `WKWebsiteDataStore.httpCookieStore` 上设置，**必须在 `load` 之前**完成，且要等回调：

```swift
let session = HTTPCookie(properties: [
  .name: "__Host-dsh_ma_session", .value: token,
  .domain: origin.host, .path: "/",
  .secure: "TRUE", .discard: "FALSE",
  .expires: sessionExpiresAt,
])!
// CSRF 是 httpOnly=false 的同名对
cookieStore.setCookie(csrf) { cookieStore.setCookie(session) { /* 再 load */ } }
```

要点：

- `__Host-` 前缀要求 **`Secure` + 无 `Domain` + `Path=/`**。iOS 的 `HTTPCookie` 必须显式给 `.domain`，否则拒绝；给 host 而不是 `.host` 前缀即可满足"无 Domain"语义（注意：设置 `.domain = host` 在 WebKit 中会被视为 host-only cookie）。
- `SameSite=Strict` 在 `HTTPCookie` 里没有属性键，WebKit 默认为 `Lax`。**必须实测**：网关的 `SameSite=Strict` 主要防止跨站写入；由于我们所有请求都是同源同文档，`Lax` 在本场景下不构成安全回退，但要在 [06](06-testing.md) 里列为已知偏差。
- 页面也可能自己通过 `Set-Cookie` 更新（例如 `/auth/login` 路径），原生不要覆盖已存在的新鲜 Cookie；只在 `native-renew` 成功后覆盖。

## 5 导航与信任

### 5.1 导航策略

| 情形 | 处理 |
| --- | --- |
| 主框架，精确 Origin | 允许 |
| 主框架，其他 `https` | 交 `UIApplication.open`（与 Android `isExternalHttps` 一致） |
| 主框架，非 https | 拒绝 |
| 子框架，非精确 Origin | 拒绝（`shouldBlockSubframeNavigation`） |
| `target=_blank` | `WKUIDelegate.createWebViewWith` 返回 `nil` 并转交系统浏览器 |
| 下载 | 本期不做（可用"在浏览器打开"兜底），列为 [N] |

### 5.2 证书决策

见 [04 §2](04-security.md#2-私有-ca-在-ios-上的落地方式)。概要：

- `URLSession` 侧用 `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`，对 `serverTrust` 做：锚点 ← 已固定 CA，`SecTrustEvaluateWithError`，并**额外**校验叶证书 SAN 含目标 host。
- `WKWebView` 侧用 `WKNavigationDelegate.didReceive challenge`，对 `NSURLAuthenticationMethodServerTrust` 复用**同一** `ServerTrustEvaluator`。
- 任何一步失败：`cancelAuthenticationChallenge`，并向上报 `LoadFailure.tls`，**不得**回落到系统默认处理。

### 5.3 ATS 配置（这是 iOS 版最容易踩的坑）

自签局域网 CA 在 iOS 上会被 ATS 检查。可选配置：

| 方案 | 写法 | 评价 |
| --- | --- | --- |
| `NSAllowsLocalNetworking` | `NSAppTransportSecurity: { NSAllowsLocalNetworking: true }` | 只放宽本地网络（`.local`、私有 IP、无点主机名），**推荐**；对公网隧道无影响 |
| `NSExceptionDomains` 逐域 | 为每个用户可达域名列一条 | 用户域名不可预知，无法枚举 |
| `NSAllowsArbitraryLoads` | 全局关闭 ATS | **禁止**：等于对所有主机放弃传输安全，且与上游安全表述冲突 |

注意：即使设置了 `NSAllowsLocalNetworking`，**`WKWebView` 仍会对未知 CA 触发 trust 失败**，所以仍然需要 §5.2 的 delegate 逻辑。ATS 是"是否允许明文/弱 TLS"，不等于"信任哪个 CA"。

## 6 状态与持久化

| 数据 | 位置 | 保护 |
| --- | --- | --- |
| deviceToken | Keychain（`WhenUnlockedThisDeviceOnly`） | 不随 iCloud 同步，不进备份 |
| 固定 CA（DER） | Keychain（同上） | 与 instanceId 绑定，读取时重新校验指纹 |
| 设备元数据（名称/Origin/类型/顺序/最近连接） | `UserDefaults` 或受保护文件 | 损坏时**报错**，不当作空表 |
| 页面缩放 | `UserDefaults` | 80–125 整数 |
| 启动行为、发现的设备缓存 | `UserDefaults` | — |
| 页面数据（Cookie、LocalStorage） | `WKWebsiteDataStore.default()` | 删除设备记录时一并清理**该 Origin** |

**重装陷阱**：iOS 删除 App 会清 `UserDefaults` **但 Keychain 默认保留**。必须在首次运行时检测「Keychain 有凭据但元数据为空」的情况，明确提示用户「检测到旧凭据，是否恢复或清除」，**不得**直接复用或直接删除。

## 7 错误模型

统一成一个枚举，映射自 `NativeAuthFailureKind` 与加载失败：

```swift
enum MobileFailure {
  case pairingExpired          // 401 且非 revoked
  case deviceRevoked           // error == device_revoked
  case deviceExpired           // error == device_expired
  case deviceLimit             // 409
  case rateLimited             // 429
  case timeout                 // SocketTimeout 类
  case tls                   // 证书/信任失败
  case network                 // 其他 IO
  case serverUnavailable       // 5xx
  case invalidResponse         // 结构不符 / 内容类型不符 / 超长
}
```

映射规则逐条对齐 Android 的 `nativeAuthFailureForStatus`，见 [03 §4](03-protocol-alignment.md#4-错误码映射)。

**禁止**把 `tls` 与其他错误混为一谈：`tls` 必须保留"不要重新配对、先检查 CA"的诊断语气，否则用户会误删配对。

## 8 与 iroh 的关系

本期不支持。原因：iroh 需要 Rust 侧车在**电脑按**运行（已有），且移动端需要原生传输库（Android 有 `.so`，iOS 需交叉编译 + 自定义 TLS 校验）；在免费签名 + 7 天重签的前提下，这部分投入产出比不合理。

架构上预留：`ConnectionService` 的传输层用协议抽象（`TransportEndpoint`），未来可加 `IrohTransport` 而不改上层——这与上游 `TransportEndpoint` 的命名保持一致。
