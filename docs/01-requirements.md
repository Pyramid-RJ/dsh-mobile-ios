# 01 需求与验收标准

本文件定义「做成什么样算完成」。凡标 **[M]** 为必须项，**[S]** 为应有项，**[C]** 为可选，**[N]** 为本期明确不做。

## 1 产品定位

**给一个人（开发者自己 / 少数自用者）一个可以长按图标、不用先开 Safari、且能用上原生附件与返回键的 iOS 入口，连到自己电脑上的 DSH。**

不是：
- 不是要替代 Android App 的官方客户端；
- 不是上架 App Store 的产品；
- 不是给不特定多数人分发的安装包。

## 2 用户故事

| ID | 故事 | 优先级 |
| --- | --- | --- |
| US-1 | 我在家/办公室，手机和电脑同一 Wi-Fi，我打开 App 就能看到电脑，点一下就进 DSH | [M] |
| US-2 | 我在外面，用远程通道（cloudflared 命名隧道 / Tailscale / FRP）连回电脑 | [M] |
| US-3 | 我第一次安装时，扫描电脑上的配对二维码即可完成配对 | [M] |
| US-4 | 电脑重启、DSH 重启后，App 自动恢复会话，我不需要重新配对 | [M] |
| US-5 | 我在 App 里给对话加一张照片（拍照或相册） | [S] |
| US-6 | 我在 App 里复制代码、粘贴到对话 | [M] |
| US-7 | 我用返回手势关掉面板/回到上一层，而不是直接退出 App | [M] |
| US-8 | 我在设置里调整页面缩放，让字不至于太小 | [S] |
| US-9 | 我配对了两台电脑，可以在 App 里切换 | [S] |
| US-10 | 苹果把我的签名搞过期了，我重签一次，配对数据还在 | [M] |
| US-11 | 我把手机丢了，我在电脑上撤销设备，App 立即无法再进入 | [M] |
| US-12 | 我在锁屏时收到任务完成提醒 | **[N]**（免费签名无 APNs；用上游 Safari PWA 的网页推送代替） |

## 3 关键约束 free provisioning 决定的硬边界

用免费 Apple ID 签名（`Personal Team`）意味着下列条件**在技术上不可突破**，需求必须围绕它们设计，而不是"以后再说"。

| 约束 | 技术原因 | 后果 |
| --- | --- | --- |
| 证书/描述文件 **7 天有效** | 免费签名描述文件有效期上限 7 天 | 必须每 7 天重签；见 [05 §4](05-build-and-signing.md#4-7-天重签运维) |
| 同设备最多 **3 个自签 App** | Apple 对免费账号的签名 App 数量限制 | 用户需为 iOS 壳腾出名额 |
| **无 APNs**（不能申请 Push Notifications capability） | 该 capability 需要付费账号与 App ID 配置 | 不做远程推送；`notification.*` 能力不实现 |
| **多数 `UIBackgroundModes` 不可用** | 后台模式需在 App ID 上开启 | 不做后台事件流（对应 Android 的 `dataSync` 前台服务） |
| **无 `com.apple.developer.networking.multicast`**（需申请） | 该 entitlement 需审核 | 不能做 UDP 广播发现；仅可用 `NWBrowser`（Bonjour）——**此点需在 S-4 中验证** |
| 不能使用 **App Groups / Keychain Sharing** | 需付费账号 | 单 App 单 Keychain，不做扩展共享 |
| 无法上架、无法 Ad Hoc | 需付费账号 | 见 [05](05-build-and-signing.md) |

> 关于「3 个 App」与「7 天」的具体数值以 Apple 当前政策为准，本项目按最严格解释设计。

## 4 功能需求

### 4.1 连接与配对 [M]

| ID | 需求 | 验收 |
| --- | --- | --- |
| F-1.1 | 解析配对链接 `https://<host>[:port]/mobile-access/pair#token=<43字符>` 与裸 Origin | 契约用例全过（见 [06 §3](06-testing.md#3-契约测试移植)） |
| F-1.2 | 解析 `dsh1.` / `dsh2.` 密钥（二维码与粘贴） | 同上 |
| F-1.3 | 局域网模式：从 `/mobile-access/ca.cer` 取 CA，校验自签 + 有效期内 + SHA-256 指纹 == instanceId，然后固定 | 用真机 + 真网关验证；错误 CA 必须拒绝 |
| F-1.4 | 远程模式：`dsh1` 允许系统信任（`ca.cer` 可 404）；`dsh2` 必须拿到并校验 CA | 用 cloudflared 与自搭反代各验证一次 |
| F-1.5 | 调用 `native-pair` 得到 deviceToken / sessionToken / csrfToken，写 Keychain | 与电脑端「设备」列表条目一致 |
| F-1.6 | 启动时用 `native-renew` 续期；401 时能区分 `device_revoked` / `device_expired` | 撤销设备后 App 显示「电脑端已移除」 |
| F-1.7 | `native-probe` 做可达性检查，不消耗会话 | 设备列表状态点正确 |
| F-1.8 | 手动输入 `https://IP:端口` | 非法输入被拒绝且不崩溃 |
| F-1.9 | 局域网自动发现（Bonjour） | **取决于 S-4**；失败则降级为手动 |

### 4.2 会话与页面 [M]

| ID | 需求 | 验收 |
| --- | --- | --- |
| F-2.1 | 加载 dedicated 页面，注入 Cookie（`__Host-dsh_ma_session` 与 `__Host-dsh_ma_csrf`）后才开始导航 | 页面不出现登录/配对表单 |
| F-2.2 | 只允许精确 Origin 的主框架导航；同源保留，外链交系统浏览器 | 点击外链不破坏当前页面 |
| F-2.3 | 子框架只允许同源 | 第三方 iframe 被阻断 |
| F-2.4 | 首屏加载失败给出可操作的处理（重试 / 换地址 / 重新配对） | 拔网线、关网关、错 CA 三种场景都有明确提示 |
| F-2.5 | 撤销通知（在线）立即断开并回设备列表 | 电脑端撤销后 ≤1 次请求内失效 |

### 4.3 原生桥 [M/S]

对齐 Android 的 `window.__DSH_MOBILE_NATIVE__` 契约，见 [03](03-protocol-alignment.md)。

| ID | 能力 | 优先级 |
| --- | --- | --- |
| F-3.1 | `capabilities()` 返回**实际实现**的列表 | [M] |
| F-3.2 | `invoke()` 收发、`requestId`、超时、并发上限 16 | [M] |
| F-3.3 | `auth.renew`（含 `auth.renew.cancel` 与 `AbortSignal`） | [M] |
| F-3.4 | `clipboard.read` / `clipboard.write`（256 KiB 上限） | [M] |
| F-3.5 | `share` | [S] |
| F-3.6 | `files.pick`（8 MiB 上限、MIME 过滤、单文件） | [S] |
| F-3.7 | `camera.capture`（权限、临时文件、全分辨率） | [S] |
| F-3.8 | `mobile.switch-computer` | [S] |
| F-3.9 | `mobile.display-scale.get/set`（80–125，整数） | [S] |
| F-3.10 | `dsh-mobile:native-back` 返回键契约 | [M] |
| F-3.11 | `keyboard.state` 事件（软键盘可见 + 无实体键盘） | [S] |
| F-3.12 | `page.background` / `page.scroll` | [C] |
| F-3.13 | `notification.notify` / `notification.settings` / `notification.background.*` | **[N]** |
| F-3.14 | iroh 传输 | **[N]**（需 Rust 侧车与原生传输，超出本期） |

### 4.4 设备管理 [S]

| ID | 需求 |
| --- | --- |
| F-4.1 | 已配对设备列表：名称、类型、Origin、可达状态、最近连接时间 |
| F-4.2 | 重命名、删除本地记录、上移/置顶 |
| F-4.3 | 启动行为：直接进入 / 显示列表 |
| F-4.4 | 删除记录 = 删除 Keychain 凭据 + 清 Cookie/网站数据；不等于电脑端撤销 |

### 4.5 明确不做 [N]

| 项 | 原因 |
| --- | --- |
| 任何通知（本地/远程） | 免费签名无 APNs；本地通知虽可用但缺少事件来源，价值低 |
| 后台事件流 | 无后台模式 |
| iroh 传输 | 工程量与维护成本过高，且需要 Rust 交叉编译 |
| 运行时切换图标 | iOS 限制 + 免费签名下重签已够繁琐 |
| 设备端页面缓存（对标 `BootAssetCache`） | 纯性能优化，二期 |
| 应用内更新检查 | 侧载场景无灰度意义 |
| 上架 / TestFlight / Ad Hoc | 非本期分发方式 |

## 5 非功能需求

| 类别 | 要求 |
| --- | --- |
| 安全 | 见 [04](04-security.md)。**不得**以 `NSAllowsArbitraryLoads=true` 绕过 ATS；**不得**在 `WKWebView` 中对任意主机的证书无条件 accept |
| 隐私 | 不采集、不上报任何数据；日志不得包含 token、完整 Origin、配对码 |
| 性能 | 冷启动到设备列表 ≤ 1.5 s（不联网）；连接到首屏可交互 ≤ 局域网 5 s / 远程 10 s（正常网络） |
| 稳健 | 任何签名/凭据异常都不得导致"静默清空配对"；读取失败必须报错而不是当作空列表 |
| 可维护 | 原生桥的每个 action 都要有独立的纯函数层 + 单元测试（对标上游 80 个 JVM 测试套件的组织方式） |
| 可构建 | 一条命令产出未签名 `.ipa` 或 `.xcarchive`；CI 可在 macOS runner 上跑 |

## 6 验收标准（Definition of Done）

一个版本可以发布（指"可以拿去侧载"），必须同时满足：

1. [06](06-testing.md) 中 **P0 用例 100% 通过**、P1 用例 ≥ 90%。
2. 至少 **1 台 iPhone + 1 台 iPad** 真机完成：局域网配对 → 使用 → 杀进程重开 → 自动恢复。
3. 至少 **1 条真实远程通道**（建议 cloudflared 命名隧道）完成配对与使用。
4. `codesign -dv --verbose=4` 与 `security cms -D -i` 检查通过，entitlements 中**不含**任何需付费账号的键。
5. 文档集与实现一致（协议矩阵、能力表、限额表）。
6. 明确记录**未验证范围**（不得把"没测"写成"通过"）。

## 7 与上游的兼容性口径

iOS 版声明支持的插件版本必须写成区间，例如 `dsh-mobile >= 0.8.7`，且只对**实际验证过的**版本写"已验证"。上游版本矩阵见其 README 的「兼容性」一节；本项目的兼容表放在 [03 §8](03-protocol-alignment.md#8-版本兼容策略)。

判定依据（与 Android 一致）：

- `GET /mobile-access/metadata` 返回 `pluginVersion` / `minimumAndroidAppVersion` / `discoveryProtocol`。
- iOS 端不因为 `minimumAndroidAppVersion` 是 "Android" 字样就跳过检查；把它当作**移动客户端最低协议版本**对待，并记录实际检查结果。
- 缺失 `/metadata`（旧网关 404）时按兼容旧版处理，但要在诊断里标明。
