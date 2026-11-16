import CryptoKit
import Foundation

// MARK: - 酷狗指纹识曲（通道 1）
//
// 与 Android `RecognizeAdapter.kt` 同口径，协议是实测出来的（2026-10，8k/单声道/16bit PCM 10s）：
//  · 入口不是 kmr/mobilekmr，而是统一网关 `gateway.kugou.com`
//  · 路径 `/fingerprint.service/v1/music_trackid_mulit`（多结果），POST 体是**裸 PCM**
//  · PCM 必须是 8kHz / 单声道 / 16bit 小端（16k 实测返回空 data）
//  · 签名 = md5(salt + 排序后 k=v 拼接 + **请求体字节** + salt)
//  · 返回 data[] 每项含 songname / singername / album[].albumname / is_original / timelength_*
//
// 这一路只负责"歌名 + 歌手 + 证据"；能不能播仍交给现有的跨平台搜索取流链。
enum KugouRecognizer {

    static let salt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private static let endpoint = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit"
    private static let userAgent = "KuGou/11490 (Android)"
    private static let appid = "3116"
    private static let clientver = "11070"

    enum Failure: LocalizedError {
        case audioTooShort
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .audioTooShort: return "录音太短（至少 1 秒）"
            case .badResponse(let code): return "识曲服务返回 \(code)"
            }
        }
    }

    /// 上传 PCM 识别。返回按通道位次排好的候选（最多 5 条）；空数组 = 没听清。
    static func recognize(pcm: Data, timeout: TimeInterval = 25) async throws -> [RecognizeCandidate] {
        guard pcm.count >= 8_000 * 2 else { throw Failure.audioTooShort }

        let now = Int(Date().timeIntervalSince1970 * 1000)
        let mid = Digest.md5Hex("\(now)")

        // 参数集照抄实测通过的一版（顺序无关，签名前会排序）
        var params: [(String, String)] = [
            ("fpid", "\(now)"),
            ("area_code", "1"),
            ("include_unpublish", "1"),
            ("useid", "0"),
            ("multi_result", "1"),
            ("dfid", "-"),
            ("mid", mid),
            ("uuid", "-"),
            ("appid", appid),
            ("clientver", clientver),
            ("clienttime", "\(now / 1000)"),
        ]
        params.sort { $0.0 < $1.0 }

        let joined = params.map { "\($0.0)=\($0.1)" }.joined()
        let signature = signature(paramsString: joined, body: pcm)
        let query = params.map { "\($0.0)=\(APIClient.encode($0.1))" }.joined(separator: "&")
            + "&signature=\(signature)"

        let text = try await APIClient.shared.postBytes(
            "\(endpoint)?\(query)",
            body: pcm,
            contentType: "application/octet-stream",
            headers: ["User-Agent": userAgent, "mid": mid, "dfid": "-"],
            timeout: timeout)

        return try parse(text)
    }

    /// md5(salt + 参数串 + 请求体 + salt)——body 参与签名，缺了服务端一律判签名错
    static func signature(paramsString: String, body: Data) -> String {
        var combined = Data(salt.utf8)
        combined.append(Data(paramsString.utf8))
        combined.append(body)
        combined.append(Data(salt.utf8))
        return Insecure.MD5.hash(data: combined).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 解析

    static func parse(_ text: String) throws -> [RecognizeCandidate] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse("不是 JSON")
        }
        let code = (root["error_code"] as? Int) ?? -1
        let items = (root["data"] as? [[String: Any]]) ?? []
        if items.isEmpty {
            // error_code=0 + 空 data 是"没识别到"，不是错误；其余码才算失败
            if code != 0 { throw Failure.badResponse("error_code=\(code)") }
            return []
        }

        var out: [RecognizeCandidate] = []
        for item in items {
            let title = (item["songname"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if title.isEmpty { continue }
            let artist = (item["singername"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let albums = item["album"] as? [[String: Any]]
            let album = (albums?.first?["albumname"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            if out.contains(where: { $0.title == title && $0.artist == artist }) { continue }

            // 打分要用的证据：时长优先 320k，is_original：1 原唱 / 2 翻唱 / 4 原唱但非录音室
            let durMs = [item["timelength_320"], item["timelength_128"],
                         item["timelength_high"], item["timelength_other"]]
                .compactMap { $0 as? Int }
                .first { $0 > 0 } ?? 0
            out.append(RecognizeCandidate(
                title: title,
                artist: artist,
                album: album,
                durationSec: durMs > 0 ? durMs / 1000 : 0,
                source: RecognizeScore.sourceKugou,
                rank: out.count,
                isOriginal: (item["is_original"] as? Int) ?? 0))
            if out.count >= 5 { break }
        }
        return out
    }
}
