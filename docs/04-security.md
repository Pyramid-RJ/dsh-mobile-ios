# 04 安全与信任模型

本文件定义 iOS 客户端**必须守住**的安全边界，以及对上游 `SECURITY.md` 中「配对设备 = 完全可信」这一前提的继承方式。

## 1 威胁模型

| 威胁 | 是否在本项目范围内 | 说明 |
| --- | --- | --- |
| 局域网内有人嗅探/中间人 | ✅ 是 | 靠 TLS + 私有 CA 固定；**这是 iOS 版最大的安全命题** |
| 手机丢失后被他人打开 App | ✅ 部分是 | 原生层不保存可读的 deviceToken 明文；但**解锁状态下**用户可直接进入——与 Android 一致，靠电脑端撤销 |
| 恶意网页/第三方 iframe 调用原生桥 | ✅ 是 | 精确 Origin + 主框架校验 |
| 配对码被截获重放 | 部分 | 服务端一次性 + TTL；客户端不缓存配对码 |
| App 被重签替换（侧载特有） | ⚠️ 承认 | 7 天重签流程下，用户每次都在本机签名，攻击面等价于"用户自己的 Mac"；但仍要防"下载别人的 ipa" |
| DNS 劫持把远程通道指向他人 | ✅ 是 | 系统 CA 校验 + 精确 Origin；`dsh2` 还需固定 CA |
| 电脑端被完全控制 | ❌ 否 | 上游口径：配对设备可操作电脑上的 DSH，视为完全可信 |

**继承上游的一句话**：配对成功即等于"这台手机可以操作电脑上的 DSH"。所有安全设计的目标是**防止未配对或伪造的来源获得这个能力**，而不是在该能力内部再做细粒度限制。

## 2 私有 CA 在 iOS 上的落地方式

这是与 Android 差异最大、也是最容易做错的部分。

### 2.1 Android 的做法（参考）

- 用例配对密钥里带 `instanceId`（＝ CA 的 SHA-256 指纹）。
- 从 `/mobile-access/ca.cer` 取 DER，校验：自签、有效期内、指纹 == instanceId。
- 用这个 CA 构造 `TrustManager`，钉住它。
- WebView 的 `onReceivedSslError` 里再判断叶证书：issuer == CA subject、叶签名由 CA 验过、SAN 含目标 host、EKU 允许 `serverAuth`，才 `proceed()`。

### 2.2 iOS 的对应实现

概念一一对应，但 API 完全不同：

```swift
struct ServerTrustEvaluator {
    let pinnedCA: SecCertificate       // 来自 /mobile-access/ca.cer
    let expectedFingerprint: String    // pairing key 的 instanceId（小写 hex SHA-256）

    func evaluate(_ trust: SecTrust, host: String) -> Bool {
        // 1. 服务器只发叶证书的场景也要能建链
        let anchors = [pinnedCA] as CFArray
        SecTrustSetAnchorCertificates(trust, anchors)
        SecTrustSetAnchorCertificatesOnly(trust, true)   // 关键：只信这一个 CA
        // 2. 策略：SSL + 精确 hostname（不要用 .default，会接受通配与宽松匹配）
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(trust, policy)
        // 3. 评估
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return false }
        // 4. 显式校验叶证书 SAN 含 host（SecTrust 已做，但保留双保险）
        guard let leafChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = leafChain.first else { return false }
        return certificateMatchesHost(leaf, host: host)
    }
}
```

必守的四点：

1. **`SecTrustSetAnchorCertificatesOnly(trust, true)`** —— 不加这行，系统根证书仍被信任，等于没钉住。
2. **`SecPolicyCreateSSL(true, host)`** —— 第二个参数传具体 host，不用 `nil`（`nil` 表示不校验证书名）。
3. **有效期**：`SecTrustEvaluateWithError` 会校验，但若 CA 本身过期，必须给出**专门**的错误（"CA 已过期，请重新配对"），而不是通用 TLS 失败。
4. **指纹**：读取固定 CA 时重新算 SHA-256，与保存的 instanceId 比对；不符即视为凭据损坏，**报错而不是静默丢弃**。

复刻 Android 的叶证书校验语义：

| Android `PinnedTls.acceptsWebViewLeaf` | iOS 对应 |
| --- | --- |
| `ca.basicConstraints >= 0 && leaf.basicConstraints < 0` | `SecCertificateCopyValues` 取 `kSecOIDBasicConstraints`（或用 `SecTrust` 链长判断） |
| `leaf.issuerX500Principal == ca.subjectX500Principal` | `SecCertificateCopyNormalizedIssuerSequence` / `SubjectSequence` 比较 |
| `leaf.verify(ca.publicKey)` | `SecTrustEvaluateWithError` 已覆盖 |
| `extendedKeyUsage` 含 `serverAuth` | `SecCertificateCopyValues` 取 `kSecOIDEKU` |
| SAN 含 host（IP 或 DNS） | `SecPolicyCreateSSL(_, host)` + 显式 SAN 解析 |

### 2.3 引导期信任的分寸

配对前还没有 CA，无法固定。Android 在这段时间用一个"接受一切"的 `X509TrustManager`，**只用于** `/mobile-access/ca.cer` 和 `/mobile-access/discovery` 两个路径。

iOS 必须复刻这个例外，但要收紧：

| 限制 | 做法 |
| --- | --- |
| 路径白名单 | 仅 `ca.cer`、`discovery` 两个**精确路径**，不匹配前缀 |
| 状态白名单 | 仅"当前设备尚未固定 CA"时启用；一旦固定，永久关闭该例外 |
| 来源白名单 | 仅配对流程内（配对表单 → 成功后立即清除） |
| 响应上限 | 16 KiB（CA）/ 8 KiB（discovery），超限即失败 |
| 指纹兜底 | 取回 CA **立刻**校验自签 + 指纹 == instanceId，不符即丢弃 |

**禁止**：把"接受一切"实现成全局 `URLSessionDelegate`，那会让所有远程请求失去证书校验。

### 2.4 WKWebView 的证书决策与 ATS

WKWebView 的 challenge 走 `WKNavigationDelegate`：

```swift
func webView(_ webView: WKWebView,
             didReceive challenge: URLAuthenticationChallenge,
             completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust,
          challenge.protectionSpace.host == origin.host
    else { completionHandler(.cancelAuthenticationChallenge, nil); return }

    if evaluator.evaluate(trust, host: origin.host) {
        completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        onFailure(.tls)
    }
}
```

**注意**：这是"自定义评估自签 CA"的正规路径。风险是 Apple 在部分系统版本上对 `WKWebView` 的 trust 处理有额外限制（这正是 S-1 要验证的）。若 S-1 失败，回退方案见 [00 §5](00-feasibility.md#5-必须实测的关键假设spike-清单)。

ATS 配置的正确姿态：

| 键 | 值 | 说明 |
| --- | --- | --- |
| `NSAllowsArbitraryLoads` | **不设置 / false** | 绝不全局关闭 |
| `NSAllowsLocalNetworking` | `true` | 只放宽本地网络（私有 IP、`.local`、无点主机） |
| `NSExceptionDomains` | 空 | 用户远程域名不可预知，不枚举 |
| `NSAllowsArbitraryLoadsInWebContent` | **不设置** | 该键等同"WebView 内关闭 ATS"，等于给任意页面开口子 |

如果 S-1 的失败原因确认为"ATS 拦在 challenge 之前"，正确的补救是 `NSAllowsLocalNetworking` 而非 `NSAllowsArbitraryLoadsInWebContent`；后者会把整个 WebView 变成不校验 TLS 的容器，与上游「不建议绕过证书警告」的立场直接冲突。

## 3 页面桥的安全边界

对齐 Android `NativeBridge` 的六个不变量：

| # | 不变量 | iOS 实现要点 |
| --- | --- | --- |
| 1 | 只接受**主框架**消息 | `message.frameInfo.isMainFrame` |
| 2 | 只接受**精确 Origin** | `message.frameInfo.securityOrigin` 的 scheme/host/port 三项全等 |
| 3 | 报文**大小上限** 1 MiB | 对原始字符串算 UTF-8 字节，超限直接丢（并回 `bad_message`） |
| 4 | `requestId` 唯一、并发 ≤ 16 | 字典 + 上限；重复或超限回 `bad_message` |
| 5 | 回执**大小上限** 12 MiB | 序列化后检查，超限降级 `payload_too_large` |
| 6 | 不暴露任意平台 API | 只有枚举好的 action，未知 action → `bad_message` |

**不要**用 `WKUserContentController.add(_:name:)` 注册多个 handler 来"分类"——Android 只有一个 `dshMobileNative`，页面侧只认那一个名字；多注册只会扩大攻击面。

### 3.1 剪贴板

iOS 上 `UIPasteboard.general.string` 会触发系统"粘贴"提示（iOS 16+）。这不是安全问题，但：

- **读**要显式解释（页面调用 `clipboard.read` 时应有用户可见动作，例如点了"粘贴"按钮）；
- **写**不弹提示，可自由；
- 256 KiB 上限沿用 Android 的值（`MAX_CLIPBOARD_BYTES`）。

### 3.2 文件与相机

- `files.pick` 只有读权限，且用 `asCopy: true` 拷贝到 App 沙箱，避免 Excel/Pages 之类的 security-scoped URL 生命周期问题；
- 8 MiB 上限（`MAX_BINARY_BYTES`）在**读取阶段**就要中断，不要读完再判断；
- 相机临时文件放在 `NSTemporaryDirectory()`，命名带前缀，24 小时后清理（对齐 `CameraCleanupOwnership` 的孤儿清理语义）。

## 4 凭据存储

| 项 | 要求 |
| --- | --- |
| 存储介质 | Keychain，`kSecClassGenericPassword` + `kSecAttrService = "io.<vendor>.dshmobile"` + `kSecAttrAccount = deviceUUID` |
| 可访问性 | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（不进 iCloud、不进备份、不迁移到新设备） |
| 读取失败 | 必须区分 `errSecItemNotFound`（真空）与 `errSecInteractionNotAllowed`（锁屏等）——后者**不能**当作空表 |
| 删除 | 只在用户明确"删除本地记录"或"撤销确认"时删除；任何错误路径都不得删除 |
| 备份 | `UserDefaults` 中的元数据也随 App 沙箱，且 `isExcludedFromBackup` |

**重装恢复**：iOS 卸载 App 不清 Keychain。首次启动若发现 Keychain 有凭据而元数据为空，必须：

1. 尝试用该 deviceToken 调 `native-probe`；
2. 成功 → 视为"同一台电脑"，恢复设备记录（需 Origin 也一并存进 Keychain）；
3. 失败 → 提示用户"检测到旧凭据但已失效"，提供清除按钮。

**绝不**在检测到残留时自动删除（用户可能在换机恢复场景下还需要它）。

## 5 日志与诊断

| 允许 | 禁止 |
| --- | --- |
| 状态迁移（connecting → connected） | deviceToken / sessionToken / csrfToken |
| 失败分类枚举名 | 完整配对码、完整配对链接 |
| Origin 的 host（且仅当用户主动查看诊断） | 完整 URL（可能含 query） |
| 请求耗时、状态码 | 请求/响应体 |

上游的脱敏口径（`docs/SECURITY.md` 与诊断页）与此一致：诊断报告是"脱敏的"，不是"完整的"。

## 6 与上游安全文档的一致性检查表

发布前逐项确认：

- [ ] 没有 `NSAllowsArbitraryLoads`
- [ ] 没有 `NSAllowsArbitraryLoadsInWebContent`
- [ ] 只有一个 `WKScriptMessageHandler`，且做了 Origin + 主框架校验
- [ ] `SecTrustSetAnchorCertificatesOnly(trust, true)` 存在
- [ ] 引导期"接受一切"的信任评估被限制在 2 个精确路径 + 未固定 CA 状态
- [ ] 清空凭据只发生在用户显式操作
- [ ] 日志不含任何 token 或完整 URL
- [ ] entitlements 中只有免费签名可用的键（见 [05 §3.2](05-build-and-signing.md#32-entitlements-清单)）

## 7 承认的弱化点

诚实记录，不得在文档里含糊：

| 项 | Android | iOS（本项目） |
| --- | --- | --- |
| 密钥保护 | Keystore 硬件级、密钥不可导出 | Keychain 软件保护（Secure Enclave 不用于此类通用凭据） |
| 应用完整性 | 正式签名 + 安装来源检查 | 侧载 7 天重签，用户自签；**无法**验证"是不是官方包" |
| 后台攻击面 | 前台服务持续持有凭据 | 无后台进程 → 攻击面反而更小 |
| Cookie `SameSite` | 服务端下发 `Strict` | 注入时无法设置，实际为 `Lax`（同源同文档场景下无实际回退） |
