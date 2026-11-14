# 08 GitHub Actions macOS Runner 环境

> **状态：配置已落地，尚未在真实仓库跑过。** 本次在 Windows 上完成，只做了 YAML 解析与 Shell 语法校验；首次推送后请按 §5 手动触发一次确认。
>
> 仓库已有 P0 工程骨架（`ios/project.yml` + `App/` + `Package.swift`），工作流检测到 `ios/*.xcodeproj`、`ios/*.xcworkspace` 或 `ios/project.yml` 后就会真正构建。但这套构建**尚未在 macOS 上跑过**，首次触发请按 §5 手动确认。

## 1 落地清单

| 路径 | 作用 |
| --- | --- |
| `.github/workflows/ios-ci.yml` | PR / 推送到 `main`：检测工程 → 工具链自检 → SwiftPM 测试 → 未签名 `.ipa` → CI gate |
| `.github/workflows/ios-release.yml` | 推送 `ios-v*` 标签或手动触发：构建并以 GitHub Release 形式发布产物 |
| `.github/actions/ios-env/action.yml` | 复合 action：选 Xcode、打印工具链、恢复缓存 |
| `ios/scripts/build-unsigned-ipa.sh` | `xcodebuild archive` → 打 `Payload/` → 未签名 `.ipa`，并写 `release.json` |
| `ios/scripts/verify-ipa.sh` | 产物校验（签名状态、付费 entitlement、版本号、arm64、隐私描述） |
| `ios/scripts/bump-build.sh` | 本地改 `CFBundleVersion`（7 天重签运维用） |
| `.gitignore` | 忽略 `build/`、`*.xcarchive`、`*.ipa`、XcodeGen 产物、`.build` |
| `ios/project.yml` + `ios/App/` | XcodeGen 规格与 SwiftUI 空壳（P0 骨架） |
| `ios/Package.swift` + `ios/Sources/DSHPairing` | 纯逻辑包：配对键、Origin、配对链接、导航策略（带测试） |

工作流用到的仓库变量（都可选，不设置就用默认值）：

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `IOS_RUNNER` | `macos-15` | macOS runner 标签 |
| `IOS_XCODE_VERSION` | `16.4` | 固定 Xcode 版本 |
| `IOS_MARKETING_VERSION` | 空（用工程里的值） | 覆盖 `CFBundleShortVersionString` |

## 2 为什么 CI 只产未签名包

三条理由写在 [05 §5.2](05-build-and-signing.md#52-cigithub-actions-macos-runner)，这里只重复结论：

1. 免费签名需要 Apple ID 凭据与设备 UDID，不该进 CI secret；
2. 签名产物与设备绑定，未签名包才是可复用、可长期收存的交付物；
3. 用户在自己机器上签名，攻击面更清晰。

所以 CI 的职责止于「拿得到、验得过、下得了」的未签名 `.ipa` + `.xcarchive` + `dSYM` + 校验和。真机安装永远发生在你自己的 Mac / AltStore / Sideloadly 上。

## 3 Runner 与 Xcode 版本

镜像现状（取自 `actions/runner-images` 的 macOS 镜像说明，2026-08 快照；**镜像每月滚动，旧版本会被移除**）：

| 标签 | 系统 | 默认 Xcode | 备注 |
| --- | --- | --- | --- |
| `macos-15` | macOS 15.7 | **16.4** | 另有 16.0–16.3、26.0.1–26.3；iOS 18.x / 26.x SDK |
| `macos-26` | macOS 26.6 | **26.6** | 另有 26.0.1–26.5；iOS 26.x SDK |

默认组合：`runs-on: macos-15` + Xcode 16.4。理由与 [05 §1](05-build-and-signing.md#1-环境要求) 一致——不用 beta 打侧载包，且 Xcode 16.4 产出的包覆盖更低的 iOS 版本。

切换方式（优先级从上到下）：

1. 手动触发时填 `xcode-version` 输入；
2. 仓库变量 `IOS_XCODE_VERSION` / `IOS_RUNNER`；
3. 直接改 workflow 里的默认值。

```bash
gh variable set IOS_RUNNER --body "macos-26"
gh variable set IOS_XCODE_VERSION --body "26.6"
```

约束：**固定的 Xcode 必须存在于所跑镜像上**。复合 action 第一步就检查，找不到会打印该镜像上所有 `/Applications/Xcode*.app` 并失败，不会拖到编译阶段才报错。

费用：macOS 分钟按 **10 倍** 计（公开仓库的 GitHub 托管 runner 免费；私有仓库吃 2000 分钟/月配额，约 200 个 macOS 分钟）。所以 `detect` / `gate` / `publish` 这些不需要 macOS 的 job 都放在 `ubuntu-latest`。

## 4 触发方式与产物

| 触发 | 条件 | 结果 |
| --- | --- | --- |
| push / PR | 改动落在 `ios/**`、`.github/workflows/ios-ci.yml`、`.github/actions/**` | 跑 CI，产出未签名 `.ipa` 与 `.xcarchive` |
| 手动 | Actions → iOS CI → Run workflow（输入 `xcode-version`、`device-build`） | 同上，可临时换 Xcode 或只跑工具链 |
| 标签 | 推送 `ios-v*` | 跑 Release，构建并发布 GitHub Release |

产物：

| 产物名 | 内容 | 保留 |
| --- | --- | --- |
| `ios-unsigned-ipa` | `DSHMobile-unsigned.ipa` + `SHA256SUMS` + `release.json` | 14 天 |
| `ios-unsigned-archive` | `DSHMobile.xcarchive.zip` + `DSHMobile.dSYM.zip` | 14 天 |
| `xcodebuild-log` | `build/xcodebuild.log`（失败时也保留） | 7 天 |

归档用 `ditto` 打包成 zip 再上传：`actions/upload-artifact` 不保留 `.xcarchive` 里的符号链接，直接传目录会得到一个导不回去的归档。
| `ios-release-<version>` | 版本化命名后的包，发布用 | 30 天 |

### 4.1 CI 包的版本号从 tag 推导（2026-11-14）

以前 CI 产物永远显示 `0.1.0`：`MARKETING_VERSION` 取自仓库变量 `IOS_MARKETING_VERSION`，变量没设就回落到 `project.yml` 的默认值。现在 build job 多了一步「Derive the marketing version from the newest ios-v* tag」：

| 情况 | 版本 | 例子 |
| --- | --- | --- |
| HEAD 正好在 tag 上 | 该 tag 的版本 | `ios-v0.9.0` → `0.9.0` |
| HEAD 在 tag 之后 | patch +1（未发布的下一版，排序在发布版之上） | `0.9.0` + 3 个提交 → `0.9.1` |
| 设了 `IOS_MARKETING_VERSION` | 该变量（显式覆盖） | — |
| 没有可达的 `ios-v*` tag | 保持 `project.yml` 的值，并打 warning | — |

两个前提：

- checkout 必须 `fetch-depth: 0`（build job 已如此），否则浅克隆里没有 tag，会静默回落到 `project.yml`；
- 版本号保持点分数字（`X.Y.Z`），`CFBundleVersion` 仍用 `run_number`，AltStore 与安装器都按这个规则比较。

验证（run 43592931901，HEAD 距 `ios-v0.9.0` 3 个提交）：`release.json` 里 `version=0.9.1 build=54`，ipa 的 `Info.plist` 同为 `0.9.1 / 54`。


```bash
gh run list --workflow "iOS CI"
gh run watch
gh run download <run-id> -n ios-unsigned-ipa
```

## 5 环境自检：现在就验证一次

不需要工程也能验证环境是否配好：

```bash
gh workflow run "iOS CI"
gh run watch
```

`toolchain` job 会打印并写进 job summary：`xcodebuild -version`、`swift --version`、`xcode-select -p`、`xcodebuild -showsdks`、模拟器运行时、磁盘余量。看到「Xcode 版本符合预期 + iOS SDK 在位」即说明 runner 环境可用。

没有工程时 `build` / `spm-tests` 会被跳过，`detect` 输出一条 notice 说明原因——这是预期行为，不是失败。

## 6 缓存

| 路径 | 内容 |
| --- | --- |
| `ios/.build` | SwiftPM 构建产物 |
| `~/Library/Caches/org.swift.swiftpm` | SwiftPM 依赖缓存 |
| `~/.swiftpm` | SwiftPM 配置与 registry 缓存 |

key 由「前缀 + runner.os + Xcode 版本 + `hashFiles(...)`」组成，`restore-keys` 按前缀兜底，所以换 Xcode 版本会自然重建缓存。

**故意不缓存 DerivedData**：一次完整 archive 的 DerivedData 有几个 GB，命中率却不高（工程、签名、构建设置一变就失效），容易吃掉 10 GB 的仓库缓存配额。干净的 archive 换来的确定性更值。

缓存是尽力而为的优化：未命中只会慢，不会失败。

## 7 产物校验规则（`verify-ipa.sh`）

CI 在打包后、上传前跑一次校验，任何一项失败都会让 job 变红：

| 检查 | 期望 | 失败通常意味着 |
| --- | --- | --- |
| `Payload/` 下恰好一个 `.app` | 1 个 | 打包步骤路径写错 |
| `CFBundleIdentifier` / `CFBundleShortVersionString` / `CFBundleVersion` | 非空 | Info.plist 缺键 |
| `CFBundleVersion` | 纯数字（可带点） | 版本号非法，覆盖安装会失败 |
| 可执行文件存在且含 `arm64` | 是 | 误打成模拟器架构 |
| `_CodeSignature`、`embedded.mobileprovision` | **不存在** | 包被签过名，与"未签名交付"约定不符 |
| `UIBackgroundModes` | 不存在 | 免费签名装不上（见 [01 §3](01-requirements.md)） |
| `NSAllowsArbitraryLoads` / `...InWebContent` | 不存在 | 用 ATS 全局放开绕过证书问题（[04](04-security.md) 禁止） |
| 相机 / 麦克风 / 相册 / 局域网描述 | 仅警告 | 对应功能还没做 |

需要校验签名包时用 `SIGNED=1 ./ios/scripts/verify-ipa.sh <ipa>`。

## 8 GitHub 仓库一次性设置

1. **Actions 权限**：Settings → Actions → General → Workflow permissions 选 *Read repository contents*（默认）。Release job 需要写权限，已在 workflow 里用 `permissions: contents: write` 显式声明；不要给仓库全局写权限。
2. **变量**（可选）：见 §1 的表，Settings → Secrets and variables → Actions → Variables。
3. **分支保护**：把 `CI gate` 设为必需检查。它把 `detect` / `toolchain` / `spm-tests` / `build` 的结果汇总成一个稳定的检查名，以后加 job 不用反复改分支保护。
4. **标签规则**：约定 `ios-v<semver>`（如 `ios-v0.1.0`），Release job 从标签取版本号；手动触发时用 `version` 输入。
5. **首次验证**：按 §5 手动跑一次。

```bash
git tag ios-v0.1.0
git push origin ios-v0.1.0
```

## 9 常见失败与排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Xcode X is not installed on this runner image` | 镜像已滚动掉该版本 | 按提示里的列表改 `IOS_XCODE_VERSION` |
| `Scheme 'DSHMobile' was not found` | scheme 名与工程不符 | 改 `SCHEME`，本地 `xcodebuild -list` 确认 |
| build 被跳过，只有一条 notice | 没有检测到工程或规格文件 | 加入 `ios/project.yml` 或 `.xcodeproj` 后自动启用 |
| `xcodegen: command not found` | 本地没装 | `brew install xcodegen`；CI 已自动安装 |
| `Could not resolve packages` / 网络超时 | 依赖解析失败 | 重跑；缓存 `restore-keys` 兜底 |
| archive 成功但 `Payload` 是空的 | `ApplicationProperties` 与产物路径不一致 | 看 `build/xcodebuild.log` 末尾 80 行（失败时脚本自动打印） |
| 上传报 `if-no-files-found` | 产物名与 `ARCHIVE_NAME` / `IPA_NAME` 不一致 | 统一命名或改 upload 路径 |
| Release 403 | token 缺写权限 | 确认 job 里有 `contents: write` |
| 私有仓库 minutes 用尽 | macOS 分钟 ×10 | 减少 macOS job，或把仓库转公开 |
| 校验报 `no arm64 slice` | 打成了模拟器架构 | 确认 `-destination generic/platform=iOS` |

## 10 与现有文档、路线图的关系

- [05 §5.1](05-build-and-signing.md#51-本机macos) 的本机命令 = `ios/scripts/build-unsigned-ipa.sh` 做的事（archive → `Payload/` → zip）。
- [05 §4.3](05-build-and-signing.md#43-版本号策略重签必须递增) 的版本号策略：CI 用 `CURRENT_PROJECT_VERSION=${{ github.run_number }}` 注入，**不改仓库里的 Info.plist**；本地重签用 `bump-build.sh` 写时间戳。
- [07 §6](07-roadmap-and-risks.md) 阶段 0「macOS 上建空工程，跑通 `xcodebuild archive` + CI」——CI 这一半已就绪，剩下的是建工程。
- 将来换付费账号（TestFlight / Ad Hoc）：在 Release workflow 里加一个 `xcodebuild -exportArchive` job + `ExportOptions.plist`，未签名构建链路不用动。

## 11 验证状态（如实记录）

**已在真实仓库跑通**（2026-11-12，`Pyramid-RJ/dsh-mobile-ios`，提交 `a008e14`）：

| 项 | 结果 |
| --- | --- |
| 触发 | 推送到 `main` 与手动 dispatch 均能触发 |
| Job | `detect` / `toolchain` / `spm-tests` / `build` / `gate` 全部 success |
| Swift | `swift test` 编译 DSHPairing、DSHTrust 并跑完全部测试（`Build complete!`） |
| 产物 | `DSHMobile-unsigned.ipa` 110,155 B（build 27）、`DSHMobile.xcarchive.zip` 1,616,813 B、dSYM、日志 |
| 校验 | `verify-ipa.sh` 全过：arm64、无 `_CodeSignature`、无 entitlements、无 `UIBackgroundModes`、无 ATS 放开、四条隐私描述齐全 |
| 签名 | 无（符合设计） |

实测环境：`macos-15` 镜像 + **Xcode 16.4**，`xcodegen` 由 brew 安装，`xcodebuild archive` 约 100 秒。

踩过并已修复的坑（留作记录）：

1. 表达式里带连字符的输入必须写 `inputs['xcode-version']`；`inputs.xcode-version` 会被判为非法表达式，整个 workflow 直接失效。
2. 表达式必须以 `}}` 收尾：`${{ ... })` 少一个花括号同样让 workflow 变红。
3. macOS runner 上 `xcodebuild -version` 偶发崩溃（exit 134），复合 action 现在带 3 次重试。
4. 同一分支并发触发会互相取消（`cancel-in-progress: true`），验证时只保留一次触发。

**追加验证（2026-11-13）**：

- **S-1 通过**：真机 iPhone（iOS 27.0.1）上 `challenge #1 NSURLAuthenticationMethodServerTrust` → 固定 CA 的 `useCredential` → `didFinish` 全链路成立，CA 指纹与配对链接的 `instance` 一致。
- **发布链路通过**：推 `ios-v0.1.0` 标签后 `meta` / `build` / `publish` 三个 job 全绿；Release 附带 ipa、dSYM、`SHA256SUMS`、`release.json`、`source.json`；AltStore 源 `releases/latest/download/source.json` 可下载，`downloadURL` HEAD 200。
- **P1 配对闭环通过**：`0.3.0` 在真机（iPhone，iOS 27.0.1）上完成配对并打开 DSH 页面，杀进程重开后自动恢复；`0.1.0` → `0.2.0` → `0.3.0` 三次发布都被 AltStore 源正确累积（`versions` 最新在前）。
- **已知的平台抖动**：release 的 macOS job 出现过三次 `The job was not acquired by Runner of type hosted even after multiple attempts`（排队 15 分钟无机器，任务被回收）；重跑即成功，与构建内容无关。

**仍未验证**：

- iOS 17.0（文档声明的最低版本）与 iPad 上的 S-1 行为；
- 真机安装与 7 天重签（需要 Apple ID 与设备）；
- `iroh` 与局域网发现（S-4），属于 P5 范围。

