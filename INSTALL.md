# 安装 DSH Mobile（iOS）

这是一个**未签名**的侧载包：用你自己的 Apple ID 签名后安装，签名 7 天后过期，重新签一次即可，配对数据不会丢。

## 1 准备

| 需要 | 说明 |
| --- | --- |
| iPhone / iPad | iOS 17.0 或更新 |
| Apple ID | 免费账号即可，不需要开发者计划 |
| 一台电脑 | Windows 或 macOS 都行，用来跑签名工具 |
| 数据线或同一 Wi-Fi | 首次安装建议用线 |

## 2 拿到安装包

两种方式任选：

**A. AltStore 源（推荐，之后能自动续签）**

1. 在手机上装 [AltStore](https://altstore.io/) 并登录你的 Apple ID；
2. 添加源：`https://github.com/Pyramid-RJ/dsh-mobile-ios/releases/latest/download/source.json`
3. 在 AltStore 里找到「DSH Mobile」→ 安装。

**B. 直接下载 ipa**

打开 <https://github.com/Pyramid-RJ/dsh-mobile-ios/releases/latest>，下载 `DSHMobile-<版本>-unsigned.ipa`，然后用 Sideloadly（Windows/macOS）或 Xcode（仅 macOS）签名安装。

## 3 安装

### 3.1 Sideloadly（Windows / macOS）

1. 手机连电脑，打开 [Sideloadly](https://sideloadly.io/)；
2. 把 ipa 拖进去，填你的 Apple ID；
3. 点 Start，按提示输入 Apple ID 密码（只用于向 Apple 申请签名）；
4. 装完后在手机上「设置 → 通用 → VPN 与设备管理」里信任你的开发者证书。

### 3.2 Xcode（仅 macOS）

1. 打开 `ios/DSHMobile.xcodeproj`（仓库里没有预生成工程时先跑 `xcodegen`）；
2. 在 Signing & Capabilities 里选你的 Personal Team，Bundle ID 改成唯一的（例如 `io.你的名字.dshmobile.ios`）；
3. 选中你的设备，Run。

### 3.3 AltStore

装好后在 AltStore 的「My Apps」里点 DSH Mobile 即可；保持 AltServer 在同一 Wi-Fi 下会自动续签。

## 4 第一次打开

1. **允许本地网络**：首次启动会弹「允许 DSH 查找并连接本地网络设备」，必须允许，否则连不上电脑；
2. **配对**：
   - 电脑端打开 DSH 的移动访问面板，显示配对二维码；
   - 手机上点首页「扫码」，对准二维码 → 自动解析并配对；
   - 也可以把配对链接粘贴到输入框，点「解析」再点「配对并打开」；
3. 配对成功后点「打开」，就会进入 DSH 页面。

## 5 日常使用

| 想做什么 | 怎么做 |
| --- | --- |
| 切换电脑 | **长按**页面左上角的抽屉按钮 500 ms |
| 调页面缩放 | 页面设置里的缩放行（80–125） |
| 拍照 / 选文件 | 输入框左侧「+」→ 拍照 / 文件 |
| 看桥日志 | 页面右上角「桥日志」，可一键复制 |
| 自检 | 首页 → 诊断 → 自检（凭据、CA、可达性、权限、发现） |
| 验收清单 | 首页 → 诊断 → 验收清单（人工项，可复制报告） |

## 6 7 天到期怎么办

免费签名 7 天后 App 会打不开（图标变灰或提示「无法验证 App」）。

**重新签名即可，不要卸载**：

- AltStore：保持 AltServer 运行，会自动续签；或手动点 Refresh；
- Sideloadly：重新拖 ipa 安装一次，**覆盖安装**；
- Xcode：重新 Run 一次。

覆盖安装不会丢配对数据（凭据在 Keychain 里）。**卸载**会丢 Keychain 之外的本地状态，但凭据本身在 iOS 上通常仍保留，重装后 App 会提示「检测到旧配对记录」，可选择恢复或清除。

## 7 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 打开就闪退 | 签名过期，重新签 |
| 一直停在「连接失败」 | 电脑端 DSH 没开、手机与电脑不在同一网络、或本地网络权限被关 |
| 扫码没反应 | 相机权限被关；或二维码不是配对码（会提示「这不是 DSH 配对码」） |
| 拍照按钮没反应 | 相机权限被关，设置 → DSH → 相机 打开 |
| 页面提示「电脑端已移除」 | 电脑端把这个设备删了，重新配对即可 |
| 字太小 / 太大 | 页面设置里的缩放，或首页自检确认页面走的是 dedicated 分支 |

## 8 隐私

App 不采集、不上报任何数据。凭据只存在本机 Keychain（`ThisDeviceOnly`），日志里不含 token 与配对码。
