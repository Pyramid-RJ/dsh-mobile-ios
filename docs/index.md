# DSH Mobile iOS（IPA）技术与要求文档集

面向 `https://github.com/saya-ch/dsh-mobile` 的 **原生 iOS 客户端** 计划：在已有 Android APK 的基础上，产出一个可侧载的 `.ipa`。

> 状态：**文档 + P0 工程骨架**。`ios/` 里已有 XcodeGen 工程、SwiftUI 空壳、纯逻辑包 `DSHPairing` 与 GitHub Actions 构建链；**尚未在 macOS / 真机实测**，功能实现从 P1 开始。
> 上游项目 **不提供也未计划** 原生 iOS App；本项目是独立的社区衍生方向，必须与上游发布分离，不能声称是上游官方 iOS 版本。

## 先读这一页

| 你想知道 | 直接读 |
| --- | --- |
| 这件事能不能做、代价是什么 | [00 可行性结论](00-feasibility.md) |
| 要做成什么样、怎么算完成 | [01 需求与验收标准](01-requirements.md) |
| 代码怎么分层、桥怎么设计 | [02 架构设计](02-architecture.md) |
| 和 Android APK 怎么逐项对齐 | [03 协议对齐矩阵](03-protocol-alignment.md) |
| 安全边界在哪、什么不做 | [04 安全与信任模型](04-security.md) |
| 怎么编译、怎么签名、7 天怎么续 | [05 构建签名与侧载](05-build-and-signing.md) |
| CI 环境怎么配、怎么触发、产物怎么拿 | [08 GitHub Actions 环境](08-ci-environment.md) |
| 怎么验收、要跑哪些用例 | [06 测试与验收](06-testing.md) |
| 拍照（`camera.capture`）怎么测、权限怎么重置 | [09 相机测试方案](09-camera-test-plan.md) |
| 文本框里的模式词条删不掉（不是壳的问题） | [10 上游问题记录](10-upstream-issues.md) |
| 什么时候做什么、会卡在哪 | [07 路线图与风险](07-roadmap-and-risks.md) |

## 一句话结论

**可行，但必须改变一个前提**：Android 版靠 `dsh1./dsh2.` 配对密钥固定局域网私有 CA，从而在 WebView 里接受自签证书；iOS 上 **同样的做法会踩到 WebKit 的证书决策限制**，因此 iOS 版必须把「局域网 + 私有 CA」这条路径改为 **由原生网络层（URLSession）承担全部受信连接**，WebView 只承载已建立信任的页面内容。详见 [01 §3](01-requirements.md#3-关键约束-free-provisioning-决定的硬边界) 与 [04 §2](04-security.md#2-私有-ca-在-ios-上的落地方式)。

在 **免费 Apple ID 自签（7 天）** 的前提下，另外三条硬边界必须接受：

1. **无远程推送**（APNs entitlement 不可用）。iOS 版不做 `notification.notify` 的原生落地，改为复用上游已有的 **网页推送（Web Push）**，见 [03 §6](03-protocol-alignment.md#6-能力映射总表)。
2. **多数后台模式不可用**（`UIBackgroundModes` 需付费账号）。后台提醒能力 **不移植**。
3. **每 7 天需要重签一次**，且同时最多 3 个自签 App。工程必须为此设计（版本号策略、数据不丢、重签不重配对），见 [05 §4](05-build-and-signing.md#4-7-天重签运维)。

## 范围声明

| 项 | 本期 |
| --- | --- |
| 目标产物 | 可侧载 `.ipa`（未签名工程 + 说明，签名由用户本机完成） |
| 目标系统 | iOS 17.0+（`WKWebView` 与 `URLSession` 行为分界见 [00 §3](00-feasibility.md#3-版本与设备基线)） |
| 分发方式 | 个人自用侧载；不做 App Store、不做 Ad Hoc、不做企业分发 |
| 与上游关系 | 只读复用其 **协议与页面**，不改上游源码，不向上游仓库提交 iOS 工程 |
| 交付形态 | 本文档集 + 后续阶段的 Xcode 工程 |

## 术语

- **Gateway / 移动网关**：上游插件在电脑端起的 HTTPS 服务（默认 3443），移动端唯一入口。
- **Pairing key**：`dsh1.<instanceId>.<token>` / `dsh2.<instanceId>.<token>`，`dsh2` 表示「必须固定 CA」。
- **Dedicated page**：经网关改写、带 `window.__DSH_MOBILE_FRONTEND__="dedicated"` 的专用移动页面。
- **Native bridge**：页面侧的 `window.__DSH_MOBILE_NATIVE__`，Android 由 `dshMobileNative` WebMessage 支撑；iOS 需用 `WKScriptMessageHandler` 重建同一契约。
- **APK / IPA**：Android / iOS 安装包。
