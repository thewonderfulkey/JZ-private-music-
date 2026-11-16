import Foundation

// MARK: - 网易云识曲（通道 2）
//
// 协议（2026-11 桌面实测，见 Android `NeteaseRecognizer.kt`）：
//  · POST https://interface.music.163.com/api/music/audio/match，form-urlencoded
//  · sessionId 用官方浏览器扩展的固定值；algorithmCode=shazam_v2（网易对自家指纹的算法名）
//  · rawdata = 端上 afp 指纹（NeteaseFingerprint 生成），duration=12
//  · code=200 且 data.noMatchReason=0 才是命中，>0 一律当"没识别到"（不报错）
//
// 这一路只给元数据，没有可播直链——播放仍走现有跨平台搜索，与酷狗命中完全同一套。
enum NeteaseRecognizer {

    static let endpoint = "https://interface.music.163.com/api/music/audio/match"
    static let sessionID = "441df692-afea-4a54-8aff-f5f20fd34f12"
    static let chromeUA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36"
    static let origin = "chrome-extension://pgphbbekcgpfaekhcbjamjjkegcclhhd"

    static func recognize(fingerprint: String,
                          seconds: Int = FingerprintPCM.windowSeconds,
                          timeout: TimeInterval = 20) async throws -> [RecognizeCandidate] {
        guard !fingerprint.isEmpty else { return [] }
        let text = try await APIClient.shared.postString(
            endpoint,
            body: formBody(fingerprint: fingerprint, seconds: seconds),
            contentType: "application/x-www-form-urlencoded; charset=UTF-8",
            headers: ["User-Agent": chromeUA,
                      "Accept": "application/json",
                      "Origin": origin],
            timeout: timeout)
        return parse(text)
    }

    /// 表单体：键序固定（服务端不校验顺序，但固定下来便于对照抓包）
    static func formBody(fingerprint: String, seconds: Int) -> String {
        let pairs: [(String, String)] = [
            ("sessionId", sessionID),
            ("algorithmCode", "shazam_v2"),
            ("duration", "\(seconds)"),
            ("rawdata", fingerprint),
            ("times", "2"),
            ("decrypt", "1"),
        ]
        return pairs.map { "\($0.0)=\(APIClient.encode($0.1))" }.joined(separator: "&")
    }

    // MARK: 解析（纯函数，CI 可断言）

    static func parse(_ text: String) -> [RecognizeCandidate] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard (root["code"] as? Int) == 200 else { return [] }
        guard let payload = root["data"] as? [String: Any] else { return [] }

        // noMatchReason 可能是字符串或数字，统一按字符串比 "0"
        let reason = (payload["noMatchReason"]).map { "\($0)" } ?? ""
        if !reason.isEmpty, reason != "0" { return [] }

        guard let results = payload["result"] as? [[String: Any]] else { return [] }

        var out: [RecognizeCandidate] = []
        for item in results {
            guard let song = item["song"] as? [String: Any] else { continue }
            let title = (song["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if title.isEmpty { continue }

            let artists = (song["artists"] as? [[String: Any]] ?? [])
                .compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let artist = artists.joined(separator: "、")
            let album = ((song["album"] as? [String: Any])?["name"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)

            if out.contains(where: { $0.title == title && $0.artist == artist }) { continue }

            // 网易给的是毫秒，带出去参与"同一版录音"的互证
            let durMs = (song["duration"] as? Int) ?? 0
            out.append(RecognizeCandidate(
                title: title,
                artist: artist,
                album: album,
                durationSec: durMs > 0 ? durMs / 1000 : 0,
                source: RecognizeScore.sourceNetease,
                rank: out.count,
                isOriginal: -1))
            if out.count >= 5 { break }
        }
        return out
    }
}
