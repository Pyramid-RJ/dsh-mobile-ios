# 06 测试与验收

## 1 分层原则

对齐上游 Android 的做法（80 个 JVM 单元测试套件 + 少量真机证据），把证据分成三档，**不得混用**：

| 档 | 手段 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| L1 纯逻辑 | `swift test`（macOS，无模拟器） | 协议解析、URL 策略、错误映射、报文编解码、限额 | 任何平台行为 |
| L2 模拟器 | XCTest + 假网关 | WebView 装配、导航策略、注入时机 | 真实 TLS、真机权限、真机键盘 |
| L3 真机 | 手动脚本 + 真网关 | 真实可用性 | 不代表"所有设备/网络" |

**发布口径**：只有 L3 通过的功能才能写"已验证"；L1/L2 只能写"有自动化覆盖"。

## 2 测试金字塔（建议套件划分）

与 [02 §2](02-architecture.md#2-模块划分建议的-xcode-目录) 的模块一一对应：

| 套件 | 覆盖 | 对应 Android 套件（参考） |
| --- | --- | --- |
| `PairingKeyTests` | `dsh1./dsh2.` 解析、instanceId/token 正则、`requiresCa` | `GatewayUrlPolicyContractTest` |
| `GatewayUrlPolicyTests` | Origin 规范化、拒绝明文/凭据/路径/query/fragment、IPv6、端口边界 | `GatewayUrlPolicyContractTest` |
| `PairingTrustTests` | 自签校验、指纹匹配、过期、非 CA | `NativeAuthClientTest` 部分 |
| `NativeAuthClientTests` | 三个端点响应解析、键集合严格相等、字段正则、时间戳未来性、错误映射 | `NativeAuthClientTest` |
| `NativeAuthFailureTests` | 状态码/error → 分类 | 同上 |
| `BridgeProtocolTests` | 报文校验、requestId 去重、并发 16、1 MiB / 12 MiB 限额 | `NativeBridgePolicyTest` |
| `BridgeReplyTests` | `successJson`/`errorJson` 形状、超限降级 | 同上 |
| `DisplayScaleTests` | 80–125、整数、viewport 宽度公式、越界错误码 | `NativeDisplayScaleTest` |
| `DeviceStoreTests` | Keychain 读写（假实现）、损坏检测、残留恢复决策 | `DeviceCredentialStoreTest`、`PairedDeviceStore*` |
| `ConnectionRestoreTests` | 启动选择、失败分类、不自动切换设备 | `ConnectionRestorePolicyTest` |
| `RemoteHostPolicyTests` | 隧道后缀、公网 IPv4 判定、私有网段排除 | `RemoteHostPolicy`（Android 内联） |
| `DiscoveryTests` | 公告 JSON 5 键、protocol==1、instanceId 正则、origin.host == 来源 | `LanDiscoveryTest` |
| `DownloadAndNavigationTests` | 同源判定、外链、子框架阻断、wss 视为同源 | `GatewayUrlPolicyWebSocketTest`、`DownloadPolicyTest` |

**契约用例直接复用上游的 JSON**：`apps/mobile/contract/url-policy-cases.json` 有完整用例表（规范化 21 条 + connections 若干），iOS 端应写一个读取该 JSON 的测试，保证两边判定一致。这是最高性价比的一致性保障。

## 3 契约测试移植

```swift
struct UrlPolicyContractTests: XCTestCase {
    func testNormalizationCases() throws {
        let fixture = try load("apps/mobile/contract/url-policy-cases.json")
        for c in fixture.normalization {
            XCTAssertEqual(GatewayOrigin.normalize(c.input), c.expected, c.name)
        }
    }
}
```

注意：

- 该文件在上游仓库里，iOS 工程应把它**复制**到 `Tests/Fixtures/`（不要跨仓引用，避免上游改动打破构建）；
- 复制时记录来源 commit，并在 [03 §8](03-protocol-alignment.md#8-版本兼容策略) 的兼容表里写清；
- 若上游修改了用例，升级时用 diff 对齐，**不允许**为了让测试通过而修改期望值。

## 4 P0 用例（发布门槛，必须 100% 通过）

### 4.1 配对

| ID | 步骤 | 期望 |
| --- | --- | --- |
| P0-01 | 扫 `dsh2.` 二维码，局域网 | 取 CA → 校验 → 配对成功 → 设备出现在列表 |
| P0-02 | 同上但 CA 指纹不符 | 拒绝，提示"证书与配对信息不一致"，**不写入**凭据 |
| P0-03 | `dsh1.` + 公网隧道（cloudflared 命名隧道） | 系统 CA 通过，配对成功 |
| P0-04 | `dsh2.` + 自签 FRP 入口 | 固定 CA 后配对成功 |
| P0-05 | 同一个一次性配对码用第二次 | 失败，提示重新生成 |

### 4.2 连接与恢复

| ID | 步骤 | 期望 |
| --- | --- | --- |
| P0-06 | 冷启动（已配对，默认直接进入） | ≤5 s 进入页面，不出现配对/登录表单 |
| P0-07 | 杀进程重开 | 自动恢复，无需重配 |
| P0-08 | 电脑端重启 DSH | App 自动 `native-renew` 恢复；不提示重新配对 |
| P0-09 | 电脑端撤销设备 | App 显示"电脑端已移除"，停止自动重连 |
| P0-10 | 断网后恢复 | 不切换设备、不闪退；给出重试入口 |

### 4.3 TLS

| ID | 步骤 | 期望 |
| --- | --- | --- |
| P0-11 | 局域网自签 CA | 页面正常加载（**S-1 的核心验收**） |
| P0-12 | 换成另一台电脑的 CA | 拒绝加载并报 TLS 错误 |
| P0-13 | CA 过期 | 专门提示"CA 已过期，请重新配对" |
| P0-14 | 远程公开证书 | 正常；若报 TLS 错误则提示检查通道 |

### 4.4 桥

| ID | 步骤 | 期望 |
| --- | --- | --- |
| P0-15 | 页面调用 `capabilities()` | 返回实际实现集合，不含未实现项 |
| P0-16 | 从第三方 iframe 发消息 | 被丢弃（Origin/主框架校验） |
| P0-17 | 发 2 MiB 报文 | 丢弃并回 `bad_message` |
| P0-18 | 页面 abort `auth.renew` | 原生取消在途请求，回 `cancelled` |

### 4.5 页面与导航

| ID | 步骤 | 期望 |
| --- | --- | --- |
| P0-19 | 点对话里的外链 | 交系统浏览器，当前页面不跳走 |
| P0-20 | 页面内嵌第三方 iframe | 被阻断 |
| P0-21 | 在对话里发一条消息 | 正常发送（CSRF 生效） |

## 5 P1 用例（应有，≥90% 通过）

| ID | 步骤 | 期望 |
| --- | --- | --- |
| P1-01 | `clipboard.write` / `read` | 正常，超 256 KiB 报错 |
| P1-02 | `files.pick` 选一张图 | 页面收到文件，可发送 |
| P1-03 | `camera.capture` | 拍照后回传（展开用例、权限重置方法见 [09](09-camera-test-plan.md)） |
| P1-04 | `share` | 系统分享面板 |
| P1-05 | `mobile.display-scale.set(80/125/126)` | 前者生效，126 报 `bad_message` |
| P1-06 | `mobile.switch-computer` | 回到设备列表 |
| P1-07 | 键盘弹出时输入框 Enter | 换行（而非发送） |
| P1-08 | 局域网自动发现（若 S-4 通过） | 列出电脑 |
| P1-09 | 手动输入 `https://IP:端口` | 正常配对 |
| P1-10 | 删除本地记录 | Keychain 与 Cookie 清理；电脑端条目仍在 |
| P1-11 | 重签覆盖安装 | 设备列表与配对保留（[05 §4](05-build-and-signing.md#4-7-天重签运维)） |
| P1-12 | 卸载重装 | 提示"检测到旧凭据"，并可恢复或清除 |

## 6 异常与负面用例（必须有）

这类用例最容易被跳过，但恰恰是上游最看重的部分（见其 CHANGELOG 里大量"拒绝迟到回调""不静默丢弃"的条目）：

| ID | 场景 | 期望 |
| --- | --- | --- |
| N-01 | 响应多一个键 | `invalid_response` |
| N-02 | 响应少一个键 | `invalid_response` |
| N-03 | `instanceId` 与服务端不符 | `invalid_response` |
| N-04 | `deviceExpiresAt < sessionExpiresAt` | `invalid_response` |
| N-05 | 响应 > 32 KiB | `invalid_response` |
| N-06 | `Content-Type` 非 JSON | `invalid_response` |
| N-07 | Keychain 读取返回 `errSecInteractionNotAllowed` | **报错**，不当作空表 |
| N-08 | 元数据损坏 | 报错并给恢复入口 |
| N-09 | 迟到的回执（requestId 已移除） | 丢弃，不崩溃 |
| N-10 | 页面导航后旧 pending 的 Promise | 不悬挂（复用 state map） |
| N-11 | 桥并发超 16 | 新请求被拒 `bad_message` |
| N-12 | 配对过程中断网 | 明确失败，不写入半成品凭据 |

## 7 真机验收矩阵

| 设备 | 系统 | 场景 |
| --- | --- | --- |
| iPhone（主力） | 最新正式版 | 全量 P0 + P1 |
| iPad | 最新正式版 | 布局、分屏、横竖屏、P0 关键项 |
| iPhone（旧机型，若可得） | iOS 17.x | P0 关键项（验证最低版本假设） |

每台设备记录：

- 设备型号、iOS 版本、App build（`CFBundleVersion`）
- 电脑端：DSH 版本、插件版本（`/metadata` 的 `pluginVersion`）
- 连接方式：局域网 / 哪个隧道
- 结果：通过项 / 失败项 / 未测项（**必须区分**）

## 8 证据与记录

对齐上游的"证据分层"作风：

```markdown
## 2026-MM-DD  iOS 0.1.0 (build 202611121530)

- 构建：GitHub Actions run #N（macos-15, Xcode 16.x）
- 插件：dsh-mobile 0.8.7 / DSH 0.2.2-rc.1
- 设备：iPhone 16 Pro / iOS 18.4；iPad Air / iOS 18.4
- 通过：P0-01…P0-21，P1-01…P1-09
- 失败：P1-10（删除记录后 Cookie 清理不完整，见 issue）
- 未测：P0-03（本机无域名，未搭命名隧道）、iroh（不支持）
- 已知偏差：SameSite=Strict 在注入 Cookie 时降级为 Lax
```

**禁止**把"未测"写成"通过"，或把"L1 自动化覆盖"写成"已验证"。

## 9 回归策略

每次改动下列文件，必须重跑对应套件：

| 改动 | 必跑 |
| --- | --- |
| `DSHPairing/*` | `PairingKeyTests` + `GatewayUrlPolicyTests` + 契约用例 |
| `DSHTrust/*` | `PairingTrustTests` + 真机 P0-11…P0-14 |
| `DSHBridge/*` | `Bridge*Tests` + P0-15…P0-18 |
| `DSHWeb/*` | L2 模拟器 + 真机 P0-06、P0-19、P0-20 |
| `Info.plist` / `entitlements` | 全量 P0（ATS/权限改动影响面最大） |
| 上游插件版本变更 | 契约用例 diff + P0 全量 |

## 10 自动化边界（诚实说明）

能在 CI 自动化的只有 L1（`swift test`）与 `xcodebuild` 构建。以下**不能**自动化，必须人工：

- 真实自签 CA 的 WKWebView 加载（P0-11）——取决于 S-1，未知数最大；
- 权限弹窗（局域网、相机、麦克风、剪贴板粘贴）；
- 系统选择器交互；
- 7 天重签后的数据保留（P1-11）；
- iOS 版本升级后的行为漂移。

因此本项目**不应**宣称"CI 全绿 = 可用"，这与上游对 iOS/真机证据的克制表述一致。
