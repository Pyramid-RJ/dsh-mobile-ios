# ios/ 工程骨架（P0）

这是 [docs/07 路线图](../docs/07-roadmap-and-risks.md) 阶段 P0 的产出：**能在 macOS 上产出未签名 archive 的最小工程**，加上两个可测的纯逻辑模块，以及一个用来做 S-1 实验的真机探针。

## 目录

```
Package.swift               纯逻辑 Swift Package（DSHPairing / DSHTrust）
Sources/DSHPairing/         配对键、Origin、配对链接、导航策略
Sources/DSHTrust/           CA 指纹、固定锚点的 SecTrust 评估、URLSession 委托
Tests/                      macOS 上 swift test 直接跑，不需要模拟器
App/                        SwiftUI 应用（DSHMobile）
App/Spike/                  S-1 探针：WKWebView + 固定私有 CA
project.yml                 XcodeGen 规格；.xcodeproj 由它生成，不提交
scripts/                    构建、校验、版本号脚本（docs/05 §5）
```

## 本机（macOS）

```bash
brew install xcodegen
cd ios
xcodegen generate      # 产出 DSHMobile.xcodeproj
swift test             # 纯逻辑测试
open DSHMobile.xcodeproj
```

命令行出未签名包（CI 走同一条路径）：

```bash
./scripts/build-unsigned-ipa.sh
./scripts/verify-ipa.sh build/DSHMobile-unsigned.ipa
```

## S-1 实验怎么跑

S-1 决定架构是否成立：**WKWebView 能不能用固定私有 CA 接受的决策加载自签 HTTPS 页面**。探针就是为回答这一件事写的。

1. 在电脑上开 DSH 的局域网访问（网关是自签 CA）。
2. 用 Xcode 以 **Debug** 装到真机（局域网权限弹窗要点允许）。
3. App 首页 → **P0 探针 / S-1** → 填 `https://<电脑IP>:3443` → 取 CA 并加载。
4. 看日志与结论：

| 日志 | 含义 |
| --- | --- |
| `challenge #1 NSURLAuthenticationMethodServerTrust` | WebKit 把证书决策交给了我们，这是 S-1 成立的前提 |
| `固定 CA 通过` + `didFinish` | 固定 CA 的决策被接受，页面加载成功 → S-1 通过 |
| 只有 `didFailProvisionalNavigation` 且 **没有** challenge | 证书在 challenge 之前就被拦了（ATS/WebKit）→ S-1 失败，转架构 A |
| `拒绝：trust evaluation failed…` | 决策跑到了，但链/主机名校验没过，按提示文案排查（CA 不对、缺 SAN） |

探针会先用**有界的引导窗口**（只对 `/mobile-access/ca.cer`）取 CA，然后立刻换成固定 CA 的评估器。这条引导例外是 docs/04 §2.3 明确允许的，不要扩散到其它请求。

## 必须改的两处

1. **Bundle ID**：`io.example.dshmobile.ios` 是占位值（docs/07 Q-1）。第一次装真机前改成你自己的；它决定 App 身份与 Keychain 归属。
2. **最低系统版本**：当前 `iOS 17.0`（docs/00 §3）。要下调必须重新验证 WebKit 行为。

## 还没做的（按路线图顺序）

| 项 | 阶段 | 状态 |
| --- | --- | --- |
| S-1：固定私有 CA 的可行性 | P0 | ✅ 2026-11-13 真机通过（iPhone，iOS 27.0.1） |
| native-pair / renew / probe、CA 固定、Cookie 注入 | P1 | 未开始 |
| Keychain 设备表、设备列表、可达性 | P2 | 未开始 |
| 页面桥、返回键、缩放 | P3 | 未开始 |

## 当前已知缺口

- **没有在任何真机或模拟器上跑过**。Swift 代码已在 GitHub Actions 的 macOS runner 上编译并通过测试（见 [docs/08](../docs/08-ci-environment.md) §11），但这不等于真机行为已验证。
- S-1 已通过：架构确定为「原生壳 + 固定私有 CA」；iOS 17.0（最低版本）与 iPad 尚未复核。
- 没有签名配置：CI 产物是未签名包，真机安装要用你自己的 Apple ID 重签。
- 应用图标是程序生成的占位图，文案为中文占位，未做本地化。
