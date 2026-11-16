import Foundation

// MARK: - App Intents 的"信箱"
//
// 为什么要有它：AppIntent 的 `perform()` 可能在非主线程被调用，而真正的动作
// （切 Tab、起播、开始识曲）都发生在视图层。Intent 只往这个线程安全的信箱里放一条"请求"，
// 视图层在 App 回到前台时取走执行——这样 Intent 不需要持有任何 UI 对象，
// 也不用把 PlayerEngine 变成全局单例。
//
// 没有用 Actor：这里只是"放一条、取一条"，NSLock 足够，而且能被 CI 的纯逻辑断言直接测。
final class IntentInbox: @unchecked Sendable {

    enum Request: Equatable {
        /// 从收藏里随机起播
        case playFavorites
        /// 打开识曲页并开始听
        case startRecognition
        /// 打开搜索页并搜这个词
        case search(String)
    }

    static let shared = IntentInbox()

    private let lock = NSLock()
    private var requests: [Request] = []

    init() {}

    func post(_ request: Request) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    /// 取走全部并清空（视图层每次回到前台调一次）
    func takeAll() -> [Request] {
        lock.lock()
        defer { lock.unlock() }
        let out = requests
        requests.removeAll()
        return out
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

// MARK: - 分享文案
//
// 只拼"事实"：歌名、歌手、来源平台。不带链接（我们的音源是各平台直链，几分钟就失效，
// 分享出去必然是死链，反而不如让对方自己去搜）。
enum SongShare {

    static func text(song: Song) -> String {
        var lines: [String] = []
        let title = song.name.trimmingCharacters(in: .whitespaces)
        let singer = song.singer.trimmingCharacters(in: .whitespaces)
        lines.append(singer.isEmpty ? title : "\(title) - \(singer)")
        if !song.album.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("专辑：\(song.album)")
        }
        lines.append("来源：\(song.platform.displayName)")
        lines.append("— 来自 JZ 音乐")
        return lines.joined(separator: "\n")
    }

    static func text(song: Song?, source: StreamSource?) -> String {
        guard let song else { return "— 来自 JZ 音乐" }
        var text = text(song: song)
        if let source, !source.backendName.isEmpty, source.backendName != "本地文件" {
            text += "\n音源：\(source.backendName) · \(source.format.uppercased()) · \(source.kbps) kbps"
        }
        return text
    }
}
