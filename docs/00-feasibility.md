# 00 可行性与技术选型

## 1 结论

**可行，但不是「把 APK 换个壳编译一遍」。**

Android App 是一个 Kotlin WebView 薄壳，页面本身由电脑端插件提供，所以 iOS 版真正的移植对象是**三层东西**：

| 层 | Android 现状 | iOS 需要做什么 | 难度 |
| --- | --- | --- | --- |
| 页面 | 由网关改写并提供的 dedicated 页面 | **零改动**（同一份页面，同一批 `data-dsh-mobile-*` 契约） | 无 |
| 协议 | 配对密钥格式、`native-pair/renew/probe`、Cookie、CSRF、发现报文 | **逐字节对齐**，不新增服务端字段 | 低 |
| 原生壳 | WebView + WebMessage 桥 + Keystore + NSD + 前台服务 | 全部用 Apple 对应能力重写 | **高**（主要工作量） |

结论按重要性排序：

1. **协议层几乎零成本**：电脑端不需要为 iOS 做任何改动。这是本项目最大的有利条件——上游把「原生 App」设计成了纯客户端。
2. **原生壳是主要成本**：权限、TLS 信任、本地网络发现、文件/相机、Cookie 注入这五件事在 iOS 上各有各的坑。
3. **免费签名是最大约束**：它砍掉了推送与后台，也带来了 7 天运维周期。这不是工程问题，是**产品边界**问题，必须在开工前接受（见 [01 §3](01-requirements.md)）。
4. **有一个必须先验证的技术假设**：WKWebView 能否用「固定私有 CA」的方式加载自签 HTTPS 页面。整个局域网体验都押在这上面（见 §5 S-1）。

## 2 Android 壳的可迁移性与不可迁移性

### 2.1 可直接照抄的部分（协议与语义）

这些是纯粹的线上契约，与平台无关，iOS 端**必须一致**，否则服务端会拒绝或页面会退化：

- 配对密钥 `dsh1|dsh2.<64 hex instanceId>.<43 字符 token>`，`dsh2` 表示必须固定 CA。
- `POST /mobile-access/auth/native-pair`、`native-renew`、`native-probe` 三个端点及其**精确响应键集合**、状态码到失败类型的映射。
- `GET /mobile-access/ca.cer`（404 = 无私有 CA）、`/discovery`、`/metadata`、`/health`。
- Cookie 名：`__Host-dsh_ma_session` / `__Host-dsh_ma_csrf`（TLS 时），否则 `dsh_ma_session` / `dsh_ma_csrf`；CSRF 头 `x-dsh-mobile-csrf`。
- 发现：DNS-SD 服务类型 `_dsh-mobile._tcp.`，TXT 键 `deviceName / origin / instanceId / protocol`；UDP 广播查询串 `DSH_MOBILE_DISCOVER_V1`；公告 JSON **恰好 5 个键**。
- 页面桥：`window.__DSH_MOBILE_NATIVE__ = { capabilities(), invoke(action, input, options?) }`，报文 `{version:1, requestId, action, input}`，回执 `{requestId, ok, value}` / `{requestId, ok:false, code, message}`。
- 宿主事件：`keyboard.subscribe`、`keyboard.state`、`page.background`、`page.scroll`、`auth.renew.cancel`。
- 返回键契约：派发可取消事件 `dsh-mobile:native-back`，`defaultPrevented` 即「页面已处理」。
- 限额：入站 1 MiB、剪贴板 256 KiB、二进制结果 8 MiB、回执 12 MiB、并发 pending 16。

逐条对照见 [03 协议对齐矩阵](03-protocol-alignment.md)。

### 2.2 必须重写的部分（平台能力）

| Android | iOS 对应 | 备注 |
| --- | --- | --- |
| `androidx.webkit` `addWebMessageListener` | `WKUserContentController.addScriptMessageHandler` | 必须自行校验来源：`message.frameInfo.isMainFrame` + `securityOrigin`，**且 `WKScriptMessageHandler` 不提供来源校验**，只能从 `frameInfo.securityOrigin` 判断 |
| `Keystore` + `EncryptedSharedPreferences` | Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`） | iOS Keychain **在 App 删除后仍保留**，需处理「重装后残留旧凭据」 |
| `NsdManager` | `NWBrowser` / `NetServiceBrowser` + `NSBonjourServices` 声明 | 需 `NSLocalNetworkUsageDescription`，首次弹局域网授权 |
| `WifiManager.MulticastLock` | 无需对应物 | iOS 不做 UDP 广播发现时性能开销可忽略 |
| `onReceivedSslError` + 钉住 CA | `WKNavigationDelegate.didReceive challenge` + `SecTrustSetAnchorCertificates` | **最大不确定项**，见 §5 |
| `ACTION_GET_CONTENT` / Photo Picker | `UIDocumentPickerViewController` / `PHPickerViewController` | `<input type=file>` 在 WKWebView 的支持程度需实测 |
| `MediaStore.ACTION_IMAGE_CAPTURE` | `UIImagePickerController`（相机） | 无系统级等价「拍照→回传 file input」链路 |
| `POST_NOTIFICATIONS` + 前台服务 | **不提供** | 免费签名无 APNs entitlement |
| `activity-alias` 换图标 | 不支持运行时换图标（除 18.x 的 `UIApplication.setAlternateIconName`，但仍受 icon 资源约束） | 本期不做 |
| `BootAssetCache`（设备端载荷缓存） | `WKURLSchemeHandler` 或直接依赖 `URLCache` | 本期不做，属性能优化项 |

### 2.3 一个容易被忽略的上游事实

页面代码里 push 设置行的挂载条件是：

```
view.__DSH_MOBILE_FRONTEND__ === 'dedicated'
  && view.__DSH_MOBILE_NATIVE__ === undefined
  && document.querySelector('meta[name="dsh-mobile-gateway"][content="authenticated"]') !== null
```

也就是说 **一旦 iOS 壳注入了原生桥，页面就不会显示网页推送入口**。这恰好与事实一致：`WKWebView` 里没有 `window.pushManager`，网页推送（Web Push）在原生壳内**根本不存在**，它只对「Safari 添加到主屏幕」这条路径有意义。

因此本期的通知结论是明确的：**iOS 壳不提供任何通知**。需要推送的用户继续使用上游的 Safari PWA 路径，两者可以并存（同一台电脑、各自配对）。

## 3 版本与设备基线

| 项 | 取值 | 理由 |
| --- | --- | --- |
| 最低系统 | **iOS 17.0** | 需要 `NWBrowser` 的现代 API、稳定的 `getUserMedia`；再往下旧 WebKit 对 DSH 前端语法（class static blocks、Iterator helpers）支持不足 |
| 主要验证系统 | iOS 18.x 与最新一个正式版 | 免费签名只能装在自己的设备上，验证覆盖面有限 |
| 设备 | iPhone 与 iPad 各至少一台真机 | iPad 的分屏/多窗口与 iOS 布局差异需要单独验收 |
| Xcode | 与目标 iOS SDK 对应的正式版 | 见 [05 构建签名](05-build-and-signing.md) |
| 架构 | `arm64` 单架构即可 | 免费签名不涉及上架，不需要 `arm64e`/模拟器切片 |

页面侧兼容性依赖电脑端网关自动下发的 `/mobile-access/compat.js`（补齐 `Iterator` helpers、`Promise.withResolvers`、`AbortSignal.any`），**iOS 壳不要自己再注入一份**，否则会与网关补丁冲突。

## 4 三个候选架构与取舍

### A. 纯 Safari 类壳（无原生桥）

WebView 只加载页面，不注入 `__DSH_MOBILE_NATIVE__`。

- 优点：最省事，页面一切按「手机浏览器」分支运行，上游已有完整的浏览器路径（含配对页、重连页）。
- 缺点：**局域网私有 CA 仍然需要解决**；文件选择、剪贴板、返回键、页面缩放全部退化；且没有任何原生能力，产品上等于「带图标的 Safari」。
- 结论：仅作为**降级方案**保留（若 §5 S-1 失败，就退到这里）。

### B. 完整原生壳（对标 Android，推荐）

注入完整的 `__DSH_MOBILE_NATIVE__`，实现 `files.pick / camera.capture / share / clipboard.* / auth.renew / mobile.switch-computer / mobile.display-scale.*`，**不实现** `notification.*`（免费签名下无意义）。

- 优点：与 Android 体验对齐；页面按原生分支运行，输入栏 Enter 换行、返回键、缩放、切换电脑都正确。
- 缺点：工作量最大；需要严格复刻桥的安全约束。
- 结论：**本期目标架构**，见 [02 架构设计](02-architecture.md)。

### C. 本地回环代理壳

App 内起一个 `127.0.0.1` 的 HTTPS→HTTPS 代理，WebView 加载 `https://127.0.0.1:port`，由原生层完成真实网关的 TLS。

- 优点：证书问题被移出 WebView；上游 iroh 通道就是这个思路。
- 致命缺点：**Origin 变了**。网关下发的 Cookie 是 `__Host-` 前缀 + `SameSite=Strict`，`__Host-` 要求 `Secure` + 无 `Domain` + `Path=/`，在 `127.0.0.1` 的 https 下虽可用，但配对/CSRF/Origin 校验全部以「网关真实 Origin」为准（`assertExternalTrust` 校验 `Origin` 头），本地回环会让 Origin 与 Host 不一致，直接 403。
- 结论：**不采用**，除非上游新增「反代模式」支持（成本远高于收益）。

## 5 必须实测的关键假设（Spike 清单）

开工前用 1～2 天做掉这四项，任何一项失败都要触发架构回退：

| ID | 假设 | 验证方法 | 失败后的回退 |
| --- | --- | --- | --- |
| **S-1** | WKWebView 的 `didReceive challenge` 能对自签叶证书做自定义评估并被接受（`URLSession` 层同样需要），且 ATS 不会先一步拦掉握手 | 起一个自签网关，用最小壳加载，观察 `NSURLErrorDomain -1202` 与 challenge 回调顺序 | 退到架构 A（纯浏览器壳 + 引导用户用 Safari）或改用 `NSAllowsLocalNetworking` / 局部 `NSExceptionDomains` |
| **S-2** | `<input type=file>` 在 WKWebView 中能弹出系统选择器并回填文件 | 在 DSH 页面点「文件」附件 | 自行实现 `WKUIDelegate` 选择器 + 注入 `File` 对象 |
| **S-3** | `getUserMedia`（语音输入）在 WKWebView 中可用且能拿到麦克风 | 页面录音入口 | 声明不支持语音，能力表里不出现相关分支 |
| **S-4** | `NWBrowser` 能发现 `_dsh-mobile._tcp.` 并读到 TXT 记录，局域网权限流程正常 | 电脑开局域网访问，iOS 扫描 | 只保留「手输 `https://IP:端口`」与「粘贴配对链接」，不做自动发现 |

S-1 是唯一会改变整体架构的假设，其余只影响功能取舍。

## 6 成本与工作量（估算）

按「一名熟悉 WebKit 的 iOS 工程师」估算，不含真机采购与 Apple ID 准备：

| 阶段 | 内容 | 人日 |
| --- | --- | --- |
| P0 | Spike S-1～S-4、工程骨架、CI 跑通空壳 | 4 |
| P1 | 配对键解析、native-pair/renew/probe、CA 固定、Cookie 注入 | 6 |
| P2 | 设备列表与持久化（Keychain）、启动行为、可达性探测 | 5 |
| P3 | 页面桥（收发、限额、并发、超时）+ 返回键 + 缩放 | 6 |
| P4 | 文件/相机/剪贴板/分享 | 4 |
| P5 | 局域网发现、手动地址、远程入口 | 4 |
| P6 | 7 天重签运维、文档、发布脚本 | 3 |
| P7 | 真机验收（含回归与异常路径） | 5 |
| 合计 | | **≈ 37 人日** |

不确定性主要来自 P4（选择器与相机在 WebView 中的实际行为）与 P1（TLS 细节）。

## 7 与上游的关系

- **不改上游源码**，不向上游提 iOS 工程 PR（上游明确「不分发原生 iOS App」，硬塞会与其发布纪律冲突）。
- **只读复用**其协议文档、契约测试数据（如 `apps/mobile/contract/url-policy-cases.json`）与测试思路。
- 与上游**版本独立**：参考 Android 的做法——插件与 App 各自编号（见上游 `apps/mobile/release.json`）。iOS 版建议从 `0.1.0` 起，不假装等于 `0.7.4`。
- 兼容性以 **插件 metadata 的 `minimumAndroidAppVersion` / `discoveryProtocol`** 为界；iOS 端向 `native-pair` 发 `X-DSH-Mobile-Capabilities: installation-id` 即可获得 `installationId`（与 Android 完全一致的处理）。
- 命名与品牌：仓库名、应用显示名、图标需与上游区分，避免用户误认官方包。
