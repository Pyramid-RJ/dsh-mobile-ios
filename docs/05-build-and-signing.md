# 05 构建、签名与 7 天侧载

## 1 环境要求

| 项 | 要求 | 备注 |
| --- | --- | --- |
| macOS | 当前受支持的正式版 | 构建 `ipa` 必须在 macOS 上（`codesign`/`xcrun` 不可在 Windows 上用） |
| Xcode | 与目标 iOS SDK 对应的正式版 | 不要用 beta 打侧载包 |
| Xcode Command Line Tools | `xcode-select --install` | `xcodebuild`、`codesign`、`security` |
| Apple ID | **免费账号即可** | 不需要 688 元的开发者计划 |
| 真机 | 至少 1 台 iPhone + 1 台 iPad | 免费签名不能装到模拟器之外的非注册设备（设备在你自己的 Apple ID 下会自动注册） |
| 工具（可选） | [AltStore](https://altstore.io/)、[Sideloadly](https://sideloadly.io/) | 用于 7 天自动/手动重签 |

> 本项目在 Windows 上开发时，**只能**做文档、纯逻辑单元测试（`swift test` 需 macOS，实际用 CI）与脚本；任何 `xcodebuild` 步骤都必须转到 macOS。

## 2 工程结构要求

```
ios/
  DSHMobile.xcodeproj           # 不提交 *.xcodeproj 的产物（对齐上游 .gitignore 里 android/**/build 的做法）
  Package.swift                 # 纯逻辑模块用 SPM，便于 CI 无模拟器测试
  App/
    Info.plist
    DSHMobile.entitlements
    Assets.xcassets/
  Sources/...
  Tests/...
  scripts/
    build-unsigned-ipa.sh
    bump-build.sh
    verify-ipa.sh
```

**关键决策：把可测逻辑放进 Swift Package，而不是全塞进 App target。**

理由与上游一致：Android 有 80 个 JVM 单元测试套件（`apps/mobile/android/app/src/test/...`），ios 若把所有逻辑绑死在 UIKit 上，CI 就得开模拟器，速度慢一个数量级。建议切分：

| 模块 | 依赖 | 能否在 macOS 上 `swift test` |
| --- | --- | --- |
| `DSHPairing` | Foundation | ✅ |
| `DSHTrust` | Foundation + Security | ✅ |
| `DSHTransport` | Foundation | ✅ |
| `DSHBridge` | Foundation | ✅ |
| `DSHDeviceStore` | Foundation + Security | ✅（Keychain 用协议注入假实现） |
| `DSHFeatures` | UIKit | ❌（用协议隔离后测逻辑层） |
| `DSHWeb` | WebKit | ❌（真机/模拟器） |

## 3 签名配置

### 3.1 Bundle ID 与唯一性

- Bundle ID 建议：`io.<yourname>.dshmobile.ios`（**必须**与上游 Android 的 `io.github.sayach.dshmobile` 区分，避免误认官方包）。
- 免费签名下，Bundle ID 由 Xcode 的 `Personal Team` 自动生成 `iOS Team Provisioning Profile`，无需在开发者后台创建 App ID。
- 每 7 天重签会**复用同一个 Bundle ID**，所以配对数据不受影响（见 §4）。

### 3.2 Entitlements 清单

免费签名可用的键很有限。**必须保持最小集**：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 仅开发期调试用；Release 构建不要带 -->
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
```

明确**不在** entitlements 里出现的键（出现即构建失败，因为是付费能力）：

| 键 | 需要 | 用它会怎样 |
| --- | --- | --- |
| `aps-environment` | 付费开发者计划 | 签名失败 / 运行时注册失败 |
| `com.apple.developer.networking.multicast` | 需单独申请 | 不能做 UDP 广播发现 |
| `com.apple.developer.associated-domains` | 付费 | 不用于本项目 |
| `com.apple.developer.icloud-*` | 付费 | 不做 iCloud |
| `com.apple.developer.app-groups` | 付费 | 不做扩展 |
| `com.apple.developer.healthkit` 等 | 付费 | 不需要 |

> 注：`get-task-allow` 在免费签名的描述文件中本来就为 true（因为是 development profile），所以它不会导致失败，但**只用于调试**。

### 3.3 Info.plist 关键项

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key><true/>
</dict>
<key>NSLocalNetworkUsageDescription</key>
<string>用于在局域网中发现并连接你电脑上的 DeepSeek Harness。</string>
<key>NSBonjourServices</key>
<array>
    <string>_dsh-mobile._tcp</string>
</array>
<key>NSCameraUsageDescription</key>
<string>用于拍摄照片并作为附件发送到对话。</string>
<key>NSMicrophoneUsageDescription</key>
<string>用于语音输入（由你电脑上的 DeepSeek Harness 处理）。</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>用于从相册选择图片作为附件。</string>
<key>UILaunchScreen</key>
<dict/>
<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

**不要**加 `UIBackgroundModes`（免费签名不可用，加了会被描述文件拒绝）。

**不要**加 `NSAllowsArbitraryLoads` 或 `NSAllowsArbitraryLoadsInWebContent`（见 [04 §2.4](04-security.md#24-wkwebview-的证书决策与-ats)）。

## 4 7 天重签运维

这是免费签名下**最容易被低估**的成本。设计目标：**重签不得导致重新配对**。

### 4.1 为什么能保住配对

配对数据存在两类位置：

| 数据 | 存哪 | 重签（覆盖安装）后 |
| --- | --- | --- |
| deviceToken / CA / Origin | **Keychain** | 保留（Keychain 与 App 签名解耦） |
| 设备元数据（名称、顺序、最近连接） | `UserDefaults`（App 沙箱） | 保留（覆盖安装不清沙箱） |
| Cookie / LocalStorage | `WKWebsiteDataStore.default()` | 保留（同一沙箱） |

关键前提：**Bundle ID 不变 + 用"覆盖安装"而不是"卸载重装"**。只要 Xcode / AltStore 走的是 install-over-update，沙箱与 Keychain 都不动。

### 4.2 重签流程（三种，按易用度排序）

#### A. Xcode 直接 Run（最简单，7 天一次插线）

1. 连接设备，`xcodebuild -scheme DSHMobile -destination 'id=<UDID>' build`（或直接在 Xcode 点 Run）。
2. Xcode 用 `Personal Team` 重新签名并覆盖安装。
3. 首次重签后描述文件变为新的一份，App 数据不动。

优点：零额外工具。缺点：要插线。

#### B. AltStore / SideStore（推荐长期方案）

- 在 iPhone 上装 AltServer（电脑端）→ AltStore（手机端），用 Apple ID 登录后，AltStore 能**每 7 天自动重签**（依赖电脑与手机同网）。
- 需要把本项目的未签名 `.ipa` 交给 AltStore 安装。

#### C. Sideloadly（手动，最通用）

- 拖入 `.ipa` + Apple ID，一键签名并安装，7 天后重来。
- 适合偶尔使用。

### 4.3 版本号策略（重签必须递增）

iOS 覆盖安装要求 `CFBundleVersion` **严格递增**，否则可能出现"装了旧版"或"安装失败"：

```bash
#!/usr/bin/env bash
# scripts/bump-build.sh —— 用时间戳作为 build number，避免人工忘记
set -euo pipefail
BUILD=$(date -u +%Y%m%d%H%M)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" ios/App/Info.plist
```

`CFBundleShortVersionString` 保持语义化（`0.1.0`、`0.2.0`），`CFBundleVersion` 用时间戳。

### 4.4 重签检查清单

每次重签后逐项确认（建议做成 App 内"诊断"页的自动检查）：

- [ ] 打开 App 直接进入设备列表（不是配对页）→ 说明 Keychain 与 `UserDefaults` 都在
- [ ] 点击设备能进入 DSH 页面 → 说明 deviceToken 仍有效（未被 7 天过期影响；deviceToken 有效期默认 90 天，不受签名过期影响）
- [ ] 会话恢复（冷启动后不需要重新登录）
- [ ] 固定 CA 仍有效（局域网）

### 4.5 7 天过期的表现与处理

签名过期后，**App 图标仍在但点开会闪退**（`_CodeSignature` 失效）。此时：

1. 不要删除 App（删了 Keychain 可能残留、`UserDefaults` 一定丢失）；
2. 直接覆盖重签安装；
3. 若已误删：首次启动会走 [02 §6](02-architecture.md#6-状态与持久化) 的"Keychain 残留恢复"流程。

### 4.6 同时最多 3 个自签 App

如果用户已经用免费账号装了 3 个（AltStore 自身也占一个名额），需要腾出位置。文档里要明确列出这一点，避免用户以为是本项目的问题。

## 5 构建命令

### 5.1 本机（macOS）

```bash
# 1) 纯逻辑测试（无需模拟器）
cd ios && swift test

# 2) 归档（未签名）
xcodebuild -project ios/DSHMobile.xcodeproj \
  -scheme DSHMobile \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/DSHMobile.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  archive

# 3) 从 .xcarchive 打出 .ipa（Payload/ 结构）
mkdir -p build/Payload
cp -R build/DSHMobile.xcarchive/Products/Applications/DSHMobile.app build/Payload/
cd build && zip -qry DSHMobile-unsigned.ipa Payload
```

未签名 `.ipa` 交给 AltStore / Sideloadly 时，它们会用你的 Apple ID 重签。

### 5.2 CI（GitHub Actions macOS runner）

> **实现位置**：仓库里已有可直接使用的实现，本节下面的片段只作最小示例——
> `.github/workflows/ios-ci.yml`（PR / 推送校验）、`.github/workflows/ios-release.yml`（`ios-v*` 标签发布）、
> `.github/actions/ios-env/action.yml`（选 Xcode + 缓存）、`ios/scripts/build-unsigned-ipa.sh` /
> `ios/scripts/verify-ipa.sh` / `ios/scripts/bump-build.sh`。
> Runner 与 Xcode 版本选择、缓存、产物校验、排错，见 [08 CI 环境](08-ci-environment.md)。

```yaml
name: iOS Build
on:
  push:
    tags: ['ios-v*']
  pull_request:
    paths: ['ios/**']

jobs:
  test:
    runs-on: macos-15          # 按当前可用版本调整
    steps:
      - uses: actions/checkout@v4
      - name: Swift package tests
        run: cd ios && swift test
      - name: Unsigned archive
        run: |
          xcodebuild -project ios/DSHMobile.xcodeproj \
            -scheme DSHMobile -configuration Release \
            -destination 'generic/platform=iOS' \
            -archivePath build/DSHMobile.xcarchive \
            CODE_SIGNING_ALLOWED=NO archive
      - uses: actions/upload-artifact@v4
        with:
          name: ios-unsigned-archive
          path: build/DSHMobile.xcarchive
```

**CI 不签名**。原因：

1. 免费签名需要 Apple ID 凭据 + 设备 UDID，不适合放进 CI secret；
2. 签名产物与设备绑定，CI 产出的未签名包才是可复用的交付物；
3. 用户在自己机器上签名，攻击面更清晰。

如果未来切换到付费账号，可加一条 `xcodebuild -exportArchive` 用 `ExportOptions.plist`（`method=development` 或 `ad-hoc`）签名，但仍建议保持 CI 只产未签名包。

### 5.3 Windows 上的可做与不可做

| 任务 | Windows | 说明 |
| --- | --- | --- |
| 写文档、协议分析 | ✅ | 本文件即在此完成 |
| 读/改 Swift 源码 | ✅ | 只是文本 |
| `swift test` | ❌ | 需 macOS 或 Linux（Linux 无 WebKit，只能跑纯 Foundation 部分） |
| `xcodebuild` / `codesign` | ❌ | — |
| 触发 CI 并下载产物 | ✅ | 用 `gh run download` |

## 6 交付物清单

一个"可侧载版本"应包含：

| 文件 | 内容 |
| --- | --- |
| `DSHMobile-unsigned.ipa` | 未签名安装包 |
| `DSHMobile-<version>.xcarchive.zip` | 归档（用于重新导出） |
| `dSYM.zip` | 崩溃符号（侧载场景可直接丢弃，但保留便于排查） |
| `release.json` | `{version, build, minIOS, pluginCompatibility}`（对齐上游 `apps/mobile/release.json` 的形状） |
| `SHA256SUMS` | 校验和 |
| `INSTALL.md` | 面向用户的三步安装说明（Xcode / AltStore / Sideloadly） |

## 7 安装说明模板（给最终用户）

> 以下为 `INSTALL.md` 的草案，发布时应与产物一起提供。

**准备**：一台 Mac（或已装 AltServer 的电脑）、你的 Apple ID、Lightning/USB-C 线。

**方式一：Xcode（推荐首次）**
1. 打开 `ios/DSHMobile.xcodeproj`；
2. 在 *Signing & Capabilities* 里选择你的 Personal Team，Bundle Identifier 改成唯一值；
3. 连接 iPhone，选中设备，点 Run；
4. 手机上 *设置 → 通用 → VPN与设备管理* → 信任你的开发者证书；
5. 打开 App。

**方式二：AltStore / Sideloadly**
1. 用工具加载 `DSHMobile-unsigned.ipa`，输入 Apple ID；
2. 等待签名安装完成；
3. 首次运行前信任证书（同上）。

**注意**
- 7 天后 App 会闪退，需重新签名安装（**不要删除 App**，否则配对数据可能丢失）。
- 免费账号同时最多 3 个自签 App。
- 本 App 不支持推送通知与后台提醒；需要推送请继续使用 Safari 添加到主屏幕的方式。
