# DSH Mobile iOS — 原生 iOS 客户端（规划）

> **状态：文档 + P0 工程骨架。** 这是一个为 [`saya-ch/dsh-mobile`](https://github.com/saya-ch/dsh-mobile) 规划**可侧载 iOS 客户端（`.ipa`）**的技术方案仓库。`ios/` 里已有可构建的 Xcode 工程骨架（XcodeGen + SwiftUI 空壳 + 纯逻辑包 `DSHPairing`）与 GitHub Actions 构建链，但**尚未在任何 macOS 或真机上实测**，功能实现从 P1 开始。
>
> 上游项目明确不提供、也不计划提供原生 iOS App（其官方路径是 Safari + 添加到主屏幕的 PWA）。本项目是**社区衍生的独立方向**，不是上游官方发布，也不包含上游源码的修改。

## 为什么会有这个仓库

上游的 Android App 是一个 WebView 薄壳：页面由电脑端插件提供，原生层只负责配对、TLS、桥接与系统集成。这套结构在技术上可以平移到 iOS——但要平移到 **免费 Apple ID 自签（7 天）** 这个约束下，就必须先接受几条硬边界，并解决一个会决定架构成败的技术假设。

本仓库把这些前提、边界与方案写成可评审的文档，**先定计划，再写代码**。

## 文档

| 文件 | 内容 |
| --- | --- |
| [docs/index.md](docs/index.md) | 索引与一句话结论 |
| [docs/00-feasibility.md](docs/00-feasibility.md) | 可行性、三种架构的取舍、必须实测的 4 个 Spike、工作量估算 |
| [docs/01-requirements.md](docs/01-requirements.md) | 用户故事、功能/非功能需求、免费签名决定的硬边界、验收标准 |
| [docs/02-architecture.md](docs/02-architecture.md) | 分层、启动时序、WKWebView 装配、桥的安全校验、状态与错误模型 |
| [docs/03-protocol-alignment.md](docs/03-protocol-alignment.md) | 与 Android APK 的逐项协议对齐（端点、键集合、错误码、能力映射） |
| [docs/04-security.md](docs/04-security.md) | 威胁模型、私有 CA 在 iOS 的落地、桥的不变量、承认的弱化点 |
| [docs/05-build-and-signing.md](docs/05-build-and-signing.md) | 构建环境、entitlements 清单、7 天重签运维、CI 方案 |
| [docs/08-ci-environment.md](docs/08-ci-environment.md) | GitHub Actions macOS Runner 环境：工作流、Xcode 固定、缓存、产物校验与排错 |
| [docs/06-testing.md](docs/06-testing.md) | 测试分层、契约测试移植、P0/P1/负面用例、真机矩阵、证据记录 |
| [docs/07-roadmap-and-risks.md](docs/07-roadmap-and-risks.md) | 阶段划分、里程碑、9 条风险登记、待决问题、37 人日估算 |

## 三个必须先知道的结论

1. **协议层几乎零成本**：电脑端不需要为 iOS 做任何改动。端点、配对键格式、响应键集合、错误码映射、页面桥契约都可以逐字节对齐。
2. **免费签名砍掉了通知与后台**：没有 APNs entitlement、没有后台模式。iOS 版**不提供任何通知**；需要推送的用户继续用上游的 Safari 主屏幕 PWA（网页推送仍然可用，两者可并存）。
3. **有一个假设会改变全局**：WKWebView 能否加载「固定私有 CA」的自签 HTTPS 页面（Spike S-1）。失败则退化为纯浏览器壳。**开工第一件事就是验证它。**

## 下一步

见 [docs/07-roadmap-and-risks.md §6](docs/07-roadmap-and-risks.md#6-下一动作建议顺序)：

1. macOS 上建空工程，跑通 `xcodebuild archive` + CI（**骨架与 CI 已提交，待一次实测**，见 [ios/README.md](ios/README.md)）；
2. 做 S-1（自签 CA），这是唯一会改变架构的假设；
3. S-1 通过后按 P1 → P7 推进；失败则转架构 A 并重写范围。

## 许可与致谢

本方案引用了 [`saya-ch/dsh-mobile`](https://github.com/saya-ch/dsh-mobile) 的公开协议与文档，该项目以 Apache-2.0 发布。若复用其品牌资产，需保留其 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`。
