import Foundation

// MARK: - 下载落盘后的「身份 + 完整性」校验（2026-11-25）
//
// 事故（老板 21:29 录屏，23:0x 确认）：下载了黄霄雲《众》的"无损 FLAC"，
// 播放页红字写着「文件 3:17 · 曲目 3:35（差 18 秒）」——那份 FLAC 根本不是《众》，
// 是黄霄雲的**另一首歌**。它偏偏过了所有闸门：
//   · 字节校验在上游不给 Content-Length 时直接放行（`DownloadGuard.isComplete` 的 `expected > 0` 短路）；
//   · 文件名是我们自己用「歌手 - 歌名」拼的，所以"看起来"完全正确；
//   · 以前**没人拿"文件自己报的长度"和"曲目时长"对过一次**。
//
// 产品口径（老板 23:0x 拍板）：**宁缺勿错**——
// 拿不到可靠文件就标「无可靠源」，不落盘、不标"已下载"，绝不让一个错的音频进曲库。
//
// 这里只放**纯判定**（不读文件、不联网），CI 直接断言；读文件头在调用方做
// （`LocalAudioFacts.facts(url:)`）。
enum DownloadIntegrityRules {

    /// 文件自报长度与曲目时长的容差。
    ///
    /// 为什么是 1.5 秒：官方 FLAC 实测 **215.45s** vs 曲目 215.5s（差 0.05）；
    /// 而错的那份是 **197s**（差 18 秒）。跨平台同一条母带的差异通常 <1.5s，
    /// 所以这条线既不会误杀正常文件，也吃不下"另一首歌"。
    static let durationToleranceSec: Double = 1.5

    /// 落盘文件的自述
    struct Facts: Equatable {
        /// 嗅探出来的容器（mp3/flac/m4a/wav/ogg…；unknown = 认不出）
        let container: String
        /// 文件自己头里写的长度（nil = 解不出，不可信）
        let durationSec: Double?
        let bytes: Int64

        init(container: String, durationSec: Double?, bytes: Int64) {
            self.container = container
            self.durationSec = durationSec
            self.bytes = bytes
        }
    }

    enum Verdict: Equatable {
        /// 通过（带文件自报长度，落库后给播放页/行显示用）
        case ok(Double)
        /// 拒收（人话原因，直接当 `errorMessage`）
        case reject(String)
    }

    /// 已知能播的容器（与 `PlaybackCacheRules.isPlayableExtension` 同口径）
    static func isKnownContainer(_ c: String) -> Bool {
        ["mp3", "m4a", "flac", "wav", "ogg", "aac", "aif", "aiff", "caf"]
            .contains(c.lowercased())
    }

    /// 主判定（顺序即优先级：先看是不是音频，再看长度，再看体积，再看是不是这首）
    ///
    /// - Parameters:
    ///   - facts: 落盘文件的容器 / 自报长度 / 字节数
    ///   - displayedTitle / displayedSinger / displayedDurationSec: 列表上这首歌
    ///   - matchedName / matchedSinger: 这条源实际对应哪条候选（跨源补位时可能不是本歌的 id）
    ///   - expectedBytes: 取流阶段探到的预期体积（0 = 上游没给）
    static func check(facts: Facts,
                      displayedTitle: String, displayedSinger: String,
                      displayedDurationSec: Int,
                      matchedName: String?, matchedSinger: String?,
                      expectedBytes: Int64) -> Verdict {
        // ① 容器：认不出 = 不可信（宁可不要）
        guard isKnownContainer(facts.container) else {
            return .reject("文件头认不出音频容器（\(facts.container)），已删除")
        }
        // ② 文件自己的长度必须解得出来（"流式 FLAC 没写总长"就死在这一步）
        guard let fileSec = facts.durationSec, fileSec > 1 else {
            return .reject("文件里读不出可信长度，无法确认是不是这首，已删除")
        }
        // ③ 体积：上游给了预期就必须够（以前 expected=0 直接放行，等于没校验）
        if expectedBytes > 0,
           !DownloadGuard.isComplete(actual: facts.bytes, expected: expectedBytes) {
            return .reject("文件不完整（\(DownloadGuard.sizeText(facts.bytes)) / "
                           + "预期 \(DownloadGuard.sizeText(expectedBytes))），已删除")
        }
        // ④ 长度：这就是《众》的真正判据（3:17 vs 3:35）
        if displayedDurationSec > 0 {
            let diff = abs(fileSec - Double(displayedDurationSec))
            guard diff <= durationToleranceSec else {
                return .reject("文件只有 \(timeText(fileSec))、曲目 "
                               + "\(timeText(Double(displayedDurationSec)))"
                               + "（差 \(Int(diff.rounded())) 秒）—— 不是这首歌，已删除")
            }
        }
        // ⑤ 身份：来源候选的歌名必须对得上（老流程没记身份时，前面几条已经验过长度，放行）
        if let name = matchedName, !name.isEmpty {
            let displayed = Song.make(platform: .netease, platformID: "displayed",
                                      name: displayedTitle, singer: displayedSinger,
                                      album: "", duration: Double(displayedDurationSec),
                                      picURL: nil)
            let candidate = Song.make(platform: .netease, platformID: "source:\(name)",
                                      name: name, singer: matchedSinger ?? displayedSinger,
                                      album: "", duration: fileSec, picURL: nil)
            guard NameMatch.sameRecording(src: displayed, cand: candidate) else {
                return .reject("这条源其实是《\(name)》，不是《\(displayedTitle)》，已删除")
            }
        }
        return .ok(fileSec)
    }

    /// 秒 → `m:ss`（错误文案用，和播放页同一口径）
    static func timeText(_ sec: Double) -> String {
        let t = max(0, Int(sec.rounded()))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
