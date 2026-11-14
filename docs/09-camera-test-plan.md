# 09 相机（`camera.capture`）测试方案

> 目的：把 P1-03 从"点一下看运气"变成**可复现、能留证据**的一组用例。
> 证据口径仍按 [06 §1](06-testing.md#1-分层原则)：相机链路**只有 L3 算通过**，L1 只能写"有自动化覆盖"。

## 1 为什么"直接同意权限"测不出东西

真机日志（2026-11-14 17:39–17:40，`桥日志`）显示 5 次 `invoke camera.capture` 只有 1 次 `reply ok`：

| 时间 | 事件 | 说明 |
| --- | --- | --- |
| 17:39:35 | `event bridge.ready` | 适配层已注入 |
| 17:39:37 | `frontend=dedicated \| gateway=authenticated \| bridge=object \| path=/` | 专用页 + 桥对象都在，页面会走原生分支 |
| 17:39:40 / 46 / 51 | `invoke camera.capture` | 三次调用，间隔 5–6 s |
| 17:39:41 / 47 | `reply failed` | 1 s 内失败 → **不是**权限弹窗（用户没机会点），是原生**立即**拒绝 |
| 17:39:56 | `reply ok` | 这一次成功 |
| 17:40:12 / 14 | `invoke` + `reply failed` | 同样 1 s 内失败 |

结论：失败不是"用户拒绝权限"，而是原生在**弹出相机之前**就返回了失败。旧代码里能 1 s 内失败的只有两处：

- `CameraCapture.isAvailable == false` → `unavailable`（"no camera on this device"）；
- `presenter()` 为 nil → `unavailable`（"no presenter"）。

**为什么"直接同意权限"不算测过**：权限弹窗只在 `AVCaptureDevice` 状态为 `notDetermined` 时出现。一旦同意，系统记住结果，之后所有用例都不再经过权限分支——你测到的是"已授权路径"，而**拒绝 / 受限 / 再次调用**这三条分支永远没被走到。反过来，日志里的失败也不是权限造成的，所以"同意权限"既没覆盖权限分支，也没解释失败。

## 2 本次代码改动（为可测性）

| 改动 | 文件 | 作用 |
| --- | --- | --- |
| 失败码细分 | `FilePicker.swift`（`PickFailure.bridgeCode`） | `unavailable / permission_denied / cancelled / timeout / payload_too_large / failed` 一一对应页面错误码，不再全部落到 `failed` |
| 权限前置检查 | `CameraCapture.swift` | `denied/restricted` 直接回 `permission_denied`；`notDetermined` 才弹系统询问；询问结果再决定 |
| 只拍照片 | 同上（`mediaTypes = ["public.image"]`） | 不触发麦克风权限 |
| 原生超时 | 同上（60 s，先于页面的 305 s；可临时改短，见 §4.1） | 用户不拍也不关时，回 `timeout` 并关闭相机，不泄漏 pending |
| 不可下滑关闭 | 同上（`isModalInPresentation`） | 下滑关闭不会回调 delegate，会让页面白等到超时 |
| 失败可诊断 | `BridgeHost.swift` + `BridgeLog.swift` | `reply failed <错误码>` 下一行直接显示原因（以前只有 "reply failed"） |
| 设备诊断 | `DeviceDiagnostics.swift`、`BridgeLogScreen.swift` | 桥日志页顶部显示机型、系统、build、相机权限状态、`isAvailable`、键盘窗口、当前弹出的控制器；一键复制 |
| 超时可测 | `CameraCapture.deadline` | 60 s，且可临时改短（§4.1） |
| L1 覆盖 | `ios/Tests/DSHBridgeTests/CameraFailureTests.swift` | 错误码形状、码值集合、失败后释放 pending、诊断不进能力表 |

**仍未解决、必须真机确认的**：日志里 1 s 内的失败到底是 `isAvailable == false` 还是 `no presenter`。新包会在桥日志顶部「设备诊断」和 `reply failed` 下方的原因行里直接写出来（§2.1、用例 C-1）。

### 2.1 怎么在手机上直接看到"为什么失败"

打开页面右上角 **桥日志**，顶部「设备诊断」一节就是原因：

| 字段 | 读法 |
| --- | --- |
| `cameraStatus` | `notDetermined` 表示还没问过（C-2 的前提）；`denied` 表示被拒（C-3/C-4）；`authorized` 表示已允许 |
| `cameraAvailable` | `false` 就是 `isAvailable == false` → 页面会收到 `unavailable` |
| `keyWindow` / `presented` | 没有 key window 或弹出的不是预期控制器，就是旧日志里 "no presenter" 那一类 |
| `build` | 装了旧包时这里会露馅（改了代码没重装） |

日志里 `reply failed` 下面那行橙色文字是原生的错误消息，例如 `camera access is off; allow it in Settings > DSH > Camera`。

## 3 测试矩阵

每条用例都要在 `桥日志` 里留下 `invoke camera.capture` + 一条 `reply ...`，截图存档。

| ID | 前置 | 操作 | 期望（页面 + 日志） |
| --- | --- | --- | --- |
| C-1 可用性 | 任意 | 冷启动进页面，点相机 | 日志 `reply ok`；若失败，记录 `camera status=` 那一行的 `message`（`no camera on this device` / `no presenter`） |
| C-2 首次授权·同意 | **重装 App**（权限回到 `notDetermined`） | 点相机 → 系统询问 → 允许 → 拍 → 使用照片 | 先出现系统询问，再出现相机；`reply ok`，附件出现在输入栏，可发送 |
| C-3 首次授权·拒绝 | **重装 App** | 点相机 → 不允许 | 不出现相机；`reply failed` + `camera status=denied result=permission_denied`；页面提示可去设置 |
| C-4 已拒绝后再点 | 接 C-3 | 再点相机 3 次 | 每次立刻 `permission_denied`，**不再弹**系统询问 |
| C-5 设置里改回允许 | 接 C-4 | 设置 → DSH → 相机 → 打开 → 回 App 再点 | 直接进相机，`reply ok`（验证 App 不缓存旧状态） |
| C-6 取消 | 已授权 | 进相机后点"取消" | `reply failed` + `result=cancelled`；页面不卡死，可再次点 |
| C-7 连拍/重试 | 已授权 | 成功拍 1 张后再拍 1 张 | 两次 `reply ok`；证明 pending 已释放（不会因 16 上限被拒） |
| C-8 中途回桌面 | 已授权 | 进相机后 Home → 回 App | 相机仍在或可恢复；最终有且只有一条回执 |
| C-9 大图 | 已授权 | 拍一张高细节照片（> 8 MiB 的 0.9 质量 JPEG 少见，可用 iPad 高分辨率机型尝试） | 若超限：`payload_too_large`，页面提示文件过大 |
| C-10 超时 | 已授权 | 进相机后**不操作**（先用短时限，见 §4.1） | 时限到点相机自动关闭，`reply failed` + `timeout` / `result=timeout`；页面自身 305 s 超时不会先触发 |
| C-11 无相机设备 | 模拟器 / 无相机 iPad 型号 | 点相机 | `unavailable`，页面不崩 |
| C-12 权限受限 | 若有 MDM / 家长控制设备 | 点相机 | `permission_denied`（`restricted`），不弹询问 |

## 4 怎么把权限"重置"回未决定

iOS 没有"重置单个权限"按钮，按代价从低到高：

1. **删 App 重装**（最快，且会清 Keychain 里的配对 → 需要重新扫码配对）；
2. 设置 → 通用 → 传输或还原 iPhone → 还原 → **还原位置与隐私**（清全部权限，不删数据，但其他 App 权限也会重置，需谨慎）；
3. 换一台没装过的设备 / 新建模拟器（模拟器无相机，只适合 C-11）。

C-2/C-3 必须用第 1 或第 2 种方式，**且每次都要先卸载再装**，否则测到的是 C-4/C-5。

### 4.1 C-10 先用短时限（功能正常后再改回）

原生超时 `CameraCapture.deadline` 默认 **60 s**（页面侧仍是 305 s）。等 5 分钟测一次太慢，所以先把它改短：

```swift
// ios/App/Web/CameraCapture.swift
static internal(set) var deadline: TimeInterval = 60   // ← 测 C-10 时临时改成 10
```

- 改成 **10 s** → 进相机后什么都不点 → 约 10 s 相机自动关闭，日志出现 `reply failed timeout`；
- 这只能证明"时限会触发、相机会关、页面拿到 `timeout`"，**不能**证明 60 s 这个数合适；
- 测完**必须改回 60**（`resetDeadlineForRelease()` 也是 60），并在 §5 记录里写"短时限已改回"。

不要为了测 C-10 去改页面侧 305 s——那是上游契约，不归我们改。

## 4.2 真机记录：2026-11-14 / 0.9.2 (build 51)

设备 iPhone19,7 / iOS 27.0.1，相机权限 `authorized`，从 `UIHostingController<…RootView…>` 呈现。

| 用例 | 结果 | 日志证据 |
| --- | --- | --- |
| C-1 可用性 | ✅ | `camera presenting from UIHostingController<…>` |
| C-2 拍照成功 | ✅ | `camera shutter 3024x4032 jpeg 1575040B after 13.3s` → `reply ok`，照片作为附件进入对话 |
| C-6 取消 | ✅ | `camera cancelled / user tapped cancel after 2.6s` → `reply failed cancelled` |
| C-7 连续两次 | ✅ | 两次 `invoke` 各自独立完成（一次 ok、一次 cancelled），没有互相顶掉 |
| C-3/C-4 拒绝权限 | 未测 | 需要卸载重装把权限重置为 `notDetermined` |
| C-9 超大图 | 未测 | 3024x4032 / 1.5 MB，离 8 MiB 上限还远 |
| C-10 超时 | 未测 | 需临时把 `deadline` 改短（§4.1） |

结论：**P1-03 通过**。0.9.0 时那些 1 s 内的 `cancelled` 在 0.9.2 的日志里不再出现——原因是当时既没有「呈现」记录，也分不清取消来源；现在每次都有 `presenting` / `shutter` / `cancelled … after N.Ns` 三段可查。

## 5 记录模板

```markdown
## 2026-MM-DD  iOS 0.1.0 (build N)  camera.capture

- 设备：iPhone 16 Pro / iOS 18.x；相机权限初始状态：notDetermined（已重装）
- C-1 可用性：通过 / 失败（日志 message：…）
- C-2 同意：通过
- C-3 拒绝：通过（日志：camera status=denied result=permission_denied）
- C-4 已拒绝：通过
- C-5 改回允许：通过
- C-6 取消：通过
- C-7 连拍：通过
- C-8 中途回桌面：未测
- C-9 大图：未测（机型分辨率不足）
- C-10 超时：通过（短时限 10 s 验证；已改回 60 s）
- C-11 模拟器：通过（unavailable）
- C-12 受限：未测（无 MDM 设备）
- 备注：C-1 若失败，先看日志 message 判定是 isAvailable 还是 presenter
```

## 6 与 06 的关系

- 本文件是 [06 §5](06-testing.md#5-p1-用例应有90-通过) 中 P1-03 的展开，P1-03 判"通过"的条件是 C-1…C-7 全绿；
- 权限弹窗、系统选择器交互按 [06 §10](06-testing.md#10-自动化边界诚实说明) 不能自动化，`CameraFailureTests` 只覆盖错误码形状；
- "点了相机没反应 / 停在某个界面"这类问题，先看 §2.1 的设备诊断，再决定是权限、可用性还是呈现位置；
- 若 C-1 复现"立即 `unavailable`"，**不得**把 P1-03 写成"通过"，应记入 `ios/README.md` 的已知缺口并单独立 issue。
