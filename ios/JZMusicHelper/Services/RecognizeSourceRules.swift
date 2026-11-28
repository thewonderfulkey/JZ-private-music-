import Foundation

// MARK: - 识曲音源（2026-11-28）
//
// 老板要「外部音源 / 机内音源」两个模式，不要混为一谈。这里只放**纯规则**：
// 文案、默认值、耳机/蓝牙的拦截、静音阈值。真正改音频会话在 `AudioCapture`。
//
// 便宜版的口径（这一轮）：
//   · 外部音源：麦克风听环境（原来的行为），机内 App 的播放会被 `.record` 掐掉。
//   · 机内音源：把会话改成 `.playAndRecord + .mixWithOthers`，让另一个 App 继续用
//     手机扬声器放；麦克风听手机自己的扬声器。**不是真内录**——戴耳机/蓝牙时听不到。
//   · 最终识别仍是酷狗 + 网易两家融合，因为 JZ 在前台，网易的 WKWebView 照常跑。
//
// 为什么不把机内做成自动检测：iOS 没有公开 API 能知道"别的 App 在放什么"；
// 而且两个模式的失败文案/权限/音频会话完全不一样，自动猜会把用户带沟里。
enum RecognizeSource: String, CaseIterable, Identifiable, Hashable {
    case external = "external"
    case internalAudio = "internal"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .external: return "外部音源"
        case .internalAudio: return "机内音源"
        }
    }

    /// 结果卡上那行「音源：…」
    var shortTitle: String {
        switch self {
        case .external: return "外部"
        case .internalAudio: return "机内"
        }
    }

    /// 识曲页 idle 状态下的第二行提示
    var idleDetail: String {
        switch self {
        case .external:
            return "把手机靠近正在外放的音箱"
        case .internalAudio:
            return "先在别的 App 里放歌，再回来点开始；手机外放，别戴耳机"
        }
    }

    /// 没识出来时的建议（noMatch 状态）
    var noSoundDetail: String {
        switch self {
        case .external:
            return "靠近一点、音量别太小，或者换个安静点的地方再试"
        case .internalAudio:
            return "确认另一个 App 还在放、手机是外放（没戴耳机）、音量别太小"
        }
    }

    /// 机内模式正在听的时候，第二行提示补一句
    var listeningHint: String? {
        switch self {
        case .external: return nil
        case .internalAudio: return "手机外放，别锁屏、别切走"
        }
    }
}

enum RecognizeSourceRules {

    /// 新装/没存过时默认外部（老板的硬要求）
    static let defaultSource: RecognizeSource = .external

    /// 从 UserDefaults 的裸字符串读；非法/空值一律回外部
    static func source(from raw: String?) -> RecognizeSource {
        guard let raw, let source = RecognizeSource(rawValue: raw) else { return defaultSource }
        return source
    }

    /// 机内模式要求当前输出是**手机扬声器**。耳机/蓝牙/AirPlay 时麦克风听不到手机自己的声音，
    /// 与其录一段静音再报"没听到"，不如点开始前就拦住。
    ///
    /// `port` 传 `AVAudioSession.Port.rawValue`（如 "Speaker" / "Headphones"）。
    /// 返回 nil = 可以用；非 nil = 给用户看的一句话。
    static func routeWarning(port: String?) -> String? {
        guard let port, !port.isEmpty else {
            return "拿不到当前出声设备。机内音源需要手机外放，先拔掉耳机、断开蓝牙再试。"
        }
        if port == "Speaker" { return nil }

        let name: String
        switch port {
        case "Headphones":
            name = "耳机"
        case "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE":
            name = "蓝牙耳机/音箱"
        case "AirPlay":
            name = "AirPlay"
        case "Receiver":
            name = "听筒"
        case "USBAudio":
            name = "USB 声卡"
        case "CarAudio":
            name = "车载"
        default:
            name = "非扬声器设备"
        }
        return "机内音源要外放；现在接着\(name)，麦克风听不到手机扬声器的声音。拔掉/断开它，或切回外部音源。"
    }

    /// 静音判定。机内是手机扬声器贴着麦克风，正常音量通常比"对着外放音箱"更响，
    /// 所以门槛略低；但低到 0.006 以下基本就是没声音/耳机。
    static func isSilent(peak: Float, source: RecognizeSource) -> Bool {
        switch source {
        case .external: return peak < 0.008
        case .internalAudio: return peak < 0.006
        }
    }

    /// 没采到声音时给用户的一句完整话
    static func noSoundMessage(_ source: RecognizeSource) -> String {
        switch source {
        case .external:
            return "几乎没听到声音。把手机靠近音箱、音量开大一点再试。"
        case .internalAudio:
            return "几乎没听到声音。确认另一个 App 还在放、手机是外放（没戴耳机）、音量别太小。"
        }
    }
}
