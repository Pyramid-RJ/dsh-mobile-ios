# 09 交接说明（2026-11-14）

给下一个接手的人/会话：**先读这一页**，再决定从哪里继续。下面的"已验证"只有真机证据，"未验证"一律不算通过。

## 1 当前状态一句话

iOS 壳已经能配对、能打开 DSH 页面、页面走原生分支，桥的九项能力全部实现；**附件链路（选文件/拍照/分享）已实现但未在真机验证**。

| 项 | 状态 |
| --- | --- |
| 仓库 | https://github.com/Pyramid-RJ/dsh-mobile-ios（公开） |
| 最新 Release | `ios-v0.8.0`，ipa 238,735 B |
| AltStore 源 | `https://github.com/Pyramid-RJ/dsh-mobile-ios/releases/latest/download/source.json`（0.1.0–0.8.0 全部保留） |
| CI | `iOS CI`（PR/推送）+ `iOS Release`（`ios-v*` 标签），均验证通过 |
| 分支 | `main`，无未推送改动 |

## 2 已验证（真机，iPhone / iOS 27.0.1）

| 能力 | 证据 |
| --- | --- |
| S-1 固定私有 CA | `challenge #1 …ServerTrust` → `固定 CA 通过` → `didFinish` |
| 配对 → 打开页面 | 局域网配对链接 → 进入 DSH 会话页，不再停在「重新配对」 |
| 启动自动恢复（US-4） | 杀进程重开后自动连上 |
| 页面走原生分支 | 桥日志 `frontend=dedicated \| gateway=authenticated \| bridge=object` |
| 页面缩放 | `invoke mobile.display-scale.get` → `reply ok`；重开值不变 |
| 切换电脑 | **长按抽屉开关 500 ms** → 退回设备列表（不是菜单项，见 docs/03 §6.0.1） |

## 3 未验证（不要当成通过）

1. **附件链路**：`files.pick` / `camera.capture` / `share` 已实现；2026-11-14 真机日志显示 `camera.capture` 5 次里 4 次在 1 s 内 `reply failed`，**失败原因尚未定位**（见 §5 第 1 条）；
2. **权限被拒的路径**：`permission_denied` 分支已补（`CameraCapture` 预检 + `PickFailure.bridgeCode`），**真机未验证**；
3. **iOS 17.0**（声明的最低版本）与 **iPad**：全部功能都没在这两个目标上测过；
4. **远程通道**：隧道那条路（Cloudflare origin 是 http）只用探针试过，配对未验证；
5. **7 天重签**：未实测（需要等签名过期）。

## 4 代码地图

```
ios/
  Package.swift              纯逻辑包，macOS 上 swift test 即可
  Sources/DSHPairing/        配对键、Origin、配对链接、导航策略
  Sources/DSHTrust/          CA 指纹、固定锚点评估、URLSession 委托
  Sources/DSHTransport/      三个端点、严格键集合、错误映射、Cookie 计划
  Sources/DSHDeviceStore/    Keychain 设备表（含 CA），损坏检测
  Sources/DSHBridge/         桥协议：限额、回执、能力白名单、缩放公式
  App/Pairing/               配对编排、启动恢复（AppModel）
  App/Web/                   WebView、桥宿主、注入脚本、Cookie 安装、桥日志、
                             共享面板、文件选择、拍照、缩放存储
  App/Spike/                 S-1 探针（保留作回归用）
```

关键不变量（改代码前请确认没有破坏）：

- 只有 `PinnedTrustEvaluator` 能回答 server-trust 挑战；`BootstrapOnlyTrustDelegate` 只允许用于 `/mobile-access/ca.cer`；
- 桥只报**真正实现**的能力（docs/03 §6.2），否则页面出现"点了没反应"的控件；
- Keychain 读取失败必须报错，**不得**静默当作空表（否则会诱发误重配对）；
- 凭据一律走 JSON body（`{deviceToken}`），**不用** Authorization 头——这是对照上游 `NativeAuthClient.kt` 确认的。

## 5 下一步建议顺序

1. **先把 `camera.capture` 的 1 s 失败定位掉**（当前第一优先）：装新包 → 点相机 → 打开「桥日志」，看顶部「设备诊断」里的 `cameraAvailable` / `keyWindow` / `presented`，以及 `reply failed` 下面那行原因。用例与权限重置方法见 [09 相机测试方案](09-camera-test-plan.md)；
2. **真机验证附件链路**：选文件 → 图片进输入框 → 发送；拍照同理（C-1…C-7）；
3. **iOS 17 与 iPad 复核**：至少跑一遍配对 + 打开页面；
4. **远程通道**：用隧道地址走一次完整配对（注意 origin 是 http，不需要私有 CA）；
5. P2 剩余：设备列表的重命名/排序/删除 UI（数据层 `DeviceRecordBook` 已就绪）。

## 6 踩过的坑（省时间用）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| workflow 直接红、0 job | `inputs.xcode-version` 非法；或 `${{ … })` 少花括号 | 用 `inputs['xcode-version']`；表达式以 `}}` 收尾 |
| release 卡 15 分钟后失败 | `The job was not acquired by Runner…`（macOS 排队） | `gh run rerun <id>`，与代码无关 |
| 并发触发互相取消 | `cancel-in-progress: true` | 一次只触发一次 |
| 编译报 `cannot find type X` | 新文件漏了 `import DSHBridge` 之类 | 每个用到包类型的文件都要显式 import |
| 桥日志只有 `bridge.ready` | `capabilities()` 是按需调用，不是启动即调 | 正常；触发「切换电脑」长按才会看到探测 |
| 抽屉里找不到「切换电脑」 | 它是长按手势，不是菜单项 | 长按抽屉开关 500 ms |
| `camera.capture` 1 s 内 `reply failed` | 旧代码在弹相机前就拒绝（`isAvailable == false` 或 `no presenter`），与权限无关 | 新包：桥日志顶部「设备诊断」+ `reply failed` 下方原因行 |
| 改了代码但行为没变 | 装了旧包 / 没重装 | 设备诊断里的 `build` 字段 |

## 7 环境注意

- 本机是 Windows，**没有 Swift/Xcode**：所有编译与测试都在 GitHub Actions 上完成，本地只做结构校验；
- 推送曾因 git 的 schannel 凭据问题失败，当时改用 GitHub Git Data API 推送；现在 `gh` 可用时优先用普通 git + API 兜底；
- macOS 分钟在公开仓库免费，但排队时间不可控，发布偶发需要重跑。
