import Foundation

/// The manual half of docs/12, in the app.
///
/// The self-check covers what a machine can answer; these items need a person
/// (a photo, a picker, a reinstall). Keeping them here means the acceptance run
/// can be recorded on the phone and copied out as a report instead of being
/// reconstructed from chat logs afterwards.
enum VerificationChecklist {
    enum Status: String, CaseIterable {
        case untested
        case passed
        case failed

        var label: String {
            switch self {
            case .untested: return "未测"
            case .passed: return "通过"
            case .failed: return "失败"
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let steps: [String]
        let criterion: String
    }

    static let items: [Item] = [
        Item(
            id: "B1",
            title: "局域网发现（P1-08）",
            steps: [
                "电脑端开启局域网访问，手机与电脑连同一个 Wi-Fi",
                "打开首页，看「附近的电脑」是否列出这台电脑",
                "点已配对的那台，应该直接进入页面",
            ],
            criterion: "列表出现名称与 https://<IP>:3443；点击后直接进入页面，不要求扫码"
        ),
        Item(
            id: "B2",
            title: "远程通道（P0-03）",
            steps: [
                "电脑端起一条隧道，拿到 https://<域名>",
                "自检 → 地址连通性，粘贴该地址，确认 HTTP 200",
                "用该地址的配对链接配对（不要用带 instance 的 dsh2 链接）",
                "关掉 Wi-Fi，用蜂窝网络重新打开页面",
            ],
            criterion: "配对成功、页面可加载、切换网络后能自动恢复"
        ),
        Item(
            id: "B3",
            title: "手动地址输入（P1-09）",
            steps: [
                "首页输入框粘贴裸 https://<IP>:<端口>，点解析",
                "再粘贴完整配对链接，点配对",
            ],
            criterion: "裸 Origin 只解析不配对；非法输入被拒绝且不崩溃"
        ),
        Item(
            id: "B4",
            title: "相机边界（C-9/C-10/C-11）",
            steps: [
                "拍一张高细节照片，确认是否超过 8 MiB",
                "把 CameraCapture.deadline 临时改成 10 s，进相机后不操作",
                "在模拟器（无相机）里点相机",
            ],
            criterion: "分别回 payload_too_large / timeout / unavailable，且不崩溃"
        ),
        Item(
            id: "B5",
            title: "选文件超时（0.9.20）",
            steps: [
                "点附件 → 选文件",
                "在系统选择器里停留超过 60 秒再选",
            ],
            criterion: "不再出现 JS 侧 timeout，选择照常完成"
        ),
        Item(
            id: "B6",
            title: "续期被拒（0.9.20）",
            steps: [
                "电脑端移除这台设备",
                "在已打开的页面里触发一次续期（切后台再回来）",
            ],
            criterion: "桥日志出现 reply failed device_revoked，页面停止重试"
        ),
        Item(
            id: "B7",
            title: "续期取消（0.9.22）",
            steps: [
                "触发续期后立刻切走，让页面 abort",
            ],
            criterion: "日志出现 auth.renew cancelled 与 reply failed cancelled"
        ),
        Item(
            id: "B8",
            title: "文件回执回归（0.9.22）",
            steps: [
                "拍照或选文件，让附件出现在输入框",
                "发送这条消息",
            ],
            criterion: "附件正常渲染、可以发送"
        ),
        Item(
            id: "B8.5",
            title: "返回键契约（0.9.24）",
            steps: [
                "在页面里打开抽屉或某个面板",
                "点左上角「‹」",
            ],
            criterion: "第一次只关闭面板，再点才退回设备列表"
        ),
        Item(
            id: "B9",
            title: "iOS 17 与 iPad（P7）",
            steps: [
                "在 iOS 17.x 设备上跑一遍配对 → 打开页面 → 拍照 → 选文件",
                "在 iPad 上跑同样流程，并试横竖屏与分屏",
            ],
            criterion: "与主力机一致；布局不破"
        ),
        Item(
            id: "B10",
            title: "7 天重签（P1-11）",
            steps: [
                "等签名过期",
                "重签覆盖安装（不要卸载）",
                "打开 App",
            ],
            criterion: "设备列表与配对保留，无需重新配对"
        ),
    ]

    // MARK: - Storage

    private static let key = "dsh.mobile.verification"

    static func status(for id: String, defaults: UserDefaults = .standard) -> Status {
        let raw = defaults.dictionary(forKey: key)?[id] as? String
        return raw.flatMap(Status.init(rawValue:)) ?? .untested
    }

    static func set(_ status: Status, for id: String, defaults: UserDefaults = .standard) {
        var table = defaults.dictionary(forKey: key) ?? [:]
        table[id] = status.rawValue
        defaults.set(table, forKey: key)
    }

    /// The report the user can paste back, with the date it was produced.
    static func report(defaults: UserDefaults = .standard) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["== 验收清单 " + formatter.string(from: Date()) + " =="]
        for item in items {
            lines.append("[" + status(for: item.id, defaults: defaults).label + "] " + item.id + " " + item.title)
        }
        return lines.joined(separator: "\n")
    }
}
