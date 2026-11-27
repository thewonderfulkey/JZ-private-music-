import Foundation

// MARK: - 垃圾上传音频过滤（2026-11-27，老板口径）
//
// 老板原话：「以后这种上传者的歌曲什么变速版都给我筛掉，不要出现在我们音乐软件返回的结果的
// 任意一处地方，我不希望再见到这种第三方上传者上传的垃圾音频，这类型的定一个规则全部拿掉。」
//
// 来由：遮住一批"用户上传"的变速/剪辑条目（《烟火里的尘埃 0.8x》/「你是我的救赎」、
// `Star Unkind 0.8x`、`红色高跟鞋 (DJ版)`…）。它们的共同特征不是"歌不好"，而是**不是原版发行**：
//   · 标题带变速标记（`0.8x` / `1.2x` / `倍速` / `slowed` / `sped up` / `nightcore`）；
//   · 标题带二次剪辑标记（`DJ版` / `抖音版` / `剪辑版` / `片段` / `鬼畜` / `变速版`…）；
//   · 很多还把上传者名字写进歌名（「你是我的救赎《烟火里的尘埃》」）。
//
// 这条规则只用于**"平台返回给我们的列表"**（搜索结果、榜单、歌单、歌手页、发现页各模块）。
// 不动用户自己导入/收藏/下载的东西——那是他的文件，不是平台的返回结果。

enum JunkAudioRules {

    /// 变速标记：`0.8x` / `1.25X` / `0.8×` / `0.8 倍速` / `1.2倍`
    private static let speedMarkers: [NSRegularExpression] = [
        // 数字 + x/×（允许中间空格、允许后面还有 "版"）
        try! NSRegularExpression(pattern: "(?i)(?:^|[^a-z0-9])\\d+(?:\\.\\d+)?\\s*[x×](?:版)?(?=$|[^a-z0-9])"),
        // 倍速 / 变速 这类中文说法
        try! NSRegularExpression(pattern: "\\d+(?:\\.\\d+)?\\s*倍(?:速)?"),
        try! NSRegularExpression(pattern: "(?i)\\b(?:slowed|sped\\s*up|speed\\s*up|nightcore)\\b"),
    ]

    /// 二次剪辑/搬运标记（**不含 remix**：官方 remix 是正式发行；DJ版/抖音版/剪辑版才是一类垃圾）
    private static let editMarkers: [String] = [
        "dj版", "抖音版", "剪辑版", "变速版", "加速版", "降速版", "慢速版", "鬼畜",
        "片段版", "完整版剪辑", "ai翻唱", "ai版",
    ]

    /// 这条是不是"上传者搬运的垃圾音频"
    ///
    /// 只看标题（歌名/专辑），不看歌手——因为上传者名字是无限集，而"标记"是有限集，
    /// 用有限集判定才不会被新上传者名字绕过。
    static func isJunk(name: String, album: String = "") -> Bool {
        let text = (name + " " + album).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let range = NSRange(text.startIndex..., in: text)
        for regex in speedMarkers where regex.firstMatch(in: text, range: range) != nil {
            return true
        }
        let low = text.lowercased()
        for marker in editMarkers where low.contains(marker) {
            return true
        }
        return false
    }

    /// 给一批歌做过滤（保持原顺序）
    static func filter(_ songs: [Song]) -> [Song] {
        songs.filter { !isJunk(name: $0.name, album: $0.album) }
    }

    /// 给一批「歌单条目」做过滤
    static func filterReleases(_ releases: [KuwoPlaylist.Release]) -> [KuwoPlaylist.Release] {
        releases.filter { !isJunk(name: $0.song.name, album: $0.song.album) }
    }
}
