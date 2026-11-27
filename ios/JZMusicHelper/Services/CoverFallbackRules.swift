import Foundation

// MARK: - 封面最后一档：按「原曲歌名」找封面（2026-11-27）
//
// 真机现象（老板截屏）：猜你喜欢里《烟火里的尘埃 0.8x》/ 歌手「你是我的救赎」→ 灰色音符，没有封面。
//
// 为什么现有的四条腿全都拿不到：
//   封面链的身份闸要求「歌名对得上 **并且** 歌手有交集」（`CoverResolver.isStrictMatch`）。
//   而这类型条目是**变速/改编/上传者**版本：
//     · 歌名多一截尾巴（`0.8x`、`1.2x`、`slowed`、`dj版`…），归一化后不再全等；
//     · 歌手是上传者名（「你是我的救赎」），与原曲歌手（华晨宇）永远对不上。
//   于是 QQ / 酷狗 / 网易 / iTunes 四级全灭 → 灰音符。
//   这不是一首歌的问题：「变速 + 上传者」这个组合在整个库里是**一类**。
//
// 兜底口径（只在四级全空之后才走）：
//   把歌名尾巴上的变速/版本标记削掉，用**原曲歌名**再搜一次；
//   候选只要求**歌名键相等**（繁简/全角/标点已折平）且长度 ≥4，**不要求歌手对得上**——
//   因为这一档本来就是"拿原曲的专辑图给改编版用"，歌手必然不同。
//   宁可给一张"同一首歌的官方封面"，也不要给灰音符（老板口径：加载不出来就是问题）。

enum CoverFallbackRules {

    /// 变速/版本尾巴（按出现顺序削，允许重复出现）
    private static let tailMarkers: [String] = [
        // 0.8x / 1.25x / 1.2倍 / 0.8 倍速
        "(?i)\\s*[（(\\[]?\\s*\\d+(?:\\.\\d+)?\\s*(?:x|×|倍速|倍)\\s*[)）\\]]?\\s*$",
        "(?i)\\s*[（(\\[]?\\s*(?:slowed|sped\\s*up|speed\\s*up|reverb|nightcore)\\s*[)）\\]]?\\s*$",
        "\\s*[（(\\[]?\\s*(?:慢速|加速|降速|变调|降调|升调|说唱版|女声版|男声版|童声版)\\s*[)）\\]]?\\s*$",
        "\\s*[（(\\[]?\\s*(?:dj版|dj|remix|伴奏|纯音乐|cover|翻唱)\\s*[)）\\]]?\\s*$",
    ]

    /// 削掉尾巴后的"原曲歌名"（没尾巴就原样返回）
    ///
    /// 只削**结尾**的标记，不动中间：`烟火里的尘埃 0.8x` → `烟火里的尘埃`；
    /// `0.8x`（整名就是一个标记）→ 空串，调用方据此放弃兜底。
    static func baseTitle(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        var rounds = 0
        while changed && rounds < 4 {
            changed = false
            rounds += 1
            for pattern in tailMarkers {
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if let match = re.firstMatch(in: text, range: range),
                   let r = Range(match.range, in: text) {
                    let stripped = String(text[text.index(text.startIndex, offsetBy: 0)..<r.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty {
                        text = stripped
                        changed = true
                    } else {
                        // 整名就是一个标记（比如歌名就叫 "0.8x"）→ 没有原曲可找
                        return ""
                    }
                }
            }
        }
        return text
    }

    /// 这个候选能不能当"原曲封面"用
    ///
    /// 只要求歌名键相等（不要求歌手），并且键长 ≥4 —— 太短的歌名（《众》《晴天》这种两三个字）
    /// 撞名概率高，宁可留灰音符也不贴错图。
    static func acceptsBaseCover(originalName: String, candidateName: String) -> Bool {
        let base = baseTitle(originalName)
        guard !base.isEmpty else { return false }
        let key = NameMatch.identityKey(base)
        guard key.count >= 4 else { return false }
        return NameMatch.identityKey(candidateName) == key
            || (NameMatch.identityKey(candidateName).count >= 4
                && NameMatch.titleEvidence(base, candidateName) != nil)
    }
}
