import Foundation

// MARK: - 酷我官方歌词
//
// 端点：`https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=<纯数字>&httpsStatus=1`
// 返回 `data.lrclist[{lineLyric, time}]`，`time` 是**秒**（两位小数），只有行级时间、没有逐字。
//
// 只对 KUWO 歌曲生效：平台 ID 就是精确的 musicId，不需要像 LDDC 那样按「歌名+歌手」猜。
// 两个实测坑（Android 侧记的，照抄）：
//   1. musicId 必须纯数字，带 `MUSIC_` 前缀服务端返回"参数错误"
//   2. 该曲无词时返回 `data:{}` 且 code 仍为 200 —— 必须判空，交给 LDDC 兜底
enum KwLyrics {

    private static let timeout: TimeInterval = 8

    static func fetch(platformID: String) async -> [LyricLine]? {
        let rid = platformID.filter { $0.isNumber }
        guard !rid.isEmpty else { return nil }
        let url = "https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=\(rid)&httpsStatus=1"
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: ["Referer": "https://www.kuwo.cn/"], timeout: timeout),
              (json["code"] as? Int) == 200,
              let data = json["data"] as? [String: Any],
              let list = data["lrclist"] as? [[String: Any]] else { return nil }

        var out: [LyricLine] = []
        for item in list {
            let text = LyricsCleaning.cleanLine(item["lineLyric"] as? String ?? "")
            if text.isEmpty { continue }
            guard let timeMs = parseTimeMs(item["time"]) else { continue }
            out.append(LyricLine(timeMs: timeMs, text: text))
        }
        // 行数太少视为残缺词，交给 LDDC
        guard out.count >= 3 else { return nil }
        return out.sorted { $0.timeMs < $1.timeMs }
    }

    /// time 可能是数字 0.12，也可能是字符串 "0.12"；统一换成整首绝对毫秒
    static func parseTimeMs(_ value: Any?) -> Int? {
        let seconds: Double?
        switch value {
        case let d as Double: seconds = d
        case let i as Int: seconds = Double(i)
        case let s as String: seconds = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        case let n as NSNumber: seconds = n.doubleValue
        default: seconds = nil
        }
        guard let seconds, seconds >= 0, seconds.isFinite else { return nil }
        return Int((seconds * 1000).rounded())
    }
}
