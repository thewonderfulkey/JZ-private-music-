import Foundation

// MARK: - 酷我 r.s 的 Python 风格文本解析
//
// 与 Android `KuwoSearchAdapter` 内部的 extractAbsList / splitTopLevel / parseSingleQuotedDict / parseDuration 同口径。
// 单独拆一个文件的原因是：它是纯函数、不碰网络，可以直接被 CI 的 `ios/SelfTest` 编译进来跑断言
// （酷我返回的不是 JSON，是 `{'key':'value',...}` 这种单引号文本，格式一改就会整平台静默 0 条，
//  必须有回归测试盯着——Android 侧曾因此"酷我永远 0 条"）。
enum KuwoParser {

    /// 从整段响应里抽出 abslist 的记录
    static func extractAbsList(from text: String) -> [[String: String]] {
        guard let absRange = text.range(of: "'abslist'") else { return [] }
        let rest = String(text[absRange.lowerBound...])
        guard let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]"),
              open < close else { return [] }
        let listText = String(rest[open...close])
        return splitTopLevel(listText).compactMap { parseSingleQuotedDict($0) }
    }

    /// 按顶层逗号切记录：括号照抄进片段，引号内的字符一律当普通文本（不参与层级与切分）
    static func splitTopLevel(_ s: String) -> [String] {
        var inner = s
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }

        var depth = 0
        var inQuote = false
        var escaped = false
        var current = ""
        var chunks: [String] = []

        for ch in inner {
            if inQuote {
                current.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "'" {
                    inQuote = false
                }
                continue
            }
            switch ch {
            case "'":
                inQuote = true
                current.append(ch)
            case "[", "{":
                depth += 1
                current.append(ch)
            case "]", "}":
                depth -= 1
                current.append(ch)
            case ",":
                if depth == 0 {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chunks.append(current)
                    }
                    current = ""
                } else {
                    current.append(ch)
                }
            default:
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static let dictEntry = NSRegularExpression(
        pattern: "'([^']*)':\\s*'((?:[^'\\\\]|\\\\.)*)'"
    )

    /// 解析单引号键值对，并还原 HTML 实体（不还原的话 "IVORY&nbsp;TOWER" 会漏掉相关性比较）
    static func parseSingleQuotedDict(_ text: String) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        var inner = trimmed
        inner.removeFirst()
        inner.removeLast()

        var out: [String: String] = [:]
        let ns = inner as NSString
        let matches = dictEntry.matches(in: inner, range: NSRange(location: 0, length: ns.length))
        for m in matches where m.numberOfRanges >= 3 {
            let key = ns.substring(with: m.range(at: 1))
            let raw = ns.substring(with: m.range(at: 2))
            out[key] = decodeEntities(raw.replacingOccurrences(of: "\\'", with: "'"))
        }
        return out.isEmpty ? nil : out
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// 时长：v2.1.95 起酷我 r.s 的 DURATION 是**秒数**（262、334…），也兼容 mm:ss / hh:mm:ss
    static func parseDuration(_ raw: String) -> Int {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 0 }
        if let v = Int(t) { return (1...36000).contains(v) ? v : 0 }
        let parts = t.split(separator: ":").map(String.init)
        let nums = parts.compactMap { Int($0) }
        switch parts.count {
        case 2 where nums.count == 2: return nums[0] * 60 + nums[1]
        case 3 where nums.count == 3: return nums[0] * 3600 + nums[1] * 60 + nums[2]
        default: return 0
        }
    }

    /// 酷我变体标记（匿名搜索头部以 DJ/翻唱/现场为主）
    static let variantMarkers: [String] = [
        "伴奏", "ktv", "现场", "dj", "live", "翻唱", "纯音乐", "钢琴",
        "remix", "串烧", "mv版", "合唱", "网友改编", "咚鼓",
    ]

    static func isVariant(_ name: String) -> Bool {
        let s = name.lowercased()
        return variantMarkers.contains { s.contains($0) }
    }

    /// 相关性比较用的宽松归一化：小写 + 多空白压成一个 + 去首尾
    static func loose(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 相关性过滤（**与 Android 不同，这是有意修的缺陷**）
    ///
    /// Android v2.1.95 的口径是把整个查询串当成一个子串去比：
    ///   `loose(name).contains(loose(keyword)) || loose(artist).contains(loose(keyword))`
    /// 于是「晴天 周杰伦」这种两词查询，歌名里没有「晴天 周杰伦」六个字、歌手也没有 → 全被过滤 → **酷我 0 条**。
    /// 2026-11-16 实测：`rn=50` 原始返回 50 条，「晴天 周杰伦」旧口径 0 条 / 全词命中 14 条 / 任词命中 50 条。
    ///
    /// iOS 口径：先要求**每个词**都能在「歌名 + 歌手」里找到；一条都没有时才退回「任一词命中」；
    /// 仍然为空才视为不相关。既修掉 0 条，又保留"把无关 UGC 挡在外面"的初衷。
    static func relevantRecords(_ records: [[String: String]], keyword: String) -> [[String: String]] {
        let tokens = loose(keyword).split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return records }

        func haystack(_ r: [String: String]) -> String {
            let name = r["SONGNAME"] ?? r["NAME"] ?? ""
            let artist = r["ARTIST"] ?? ""
            return loose(name + " " + artist)
        }

        let allTokens = records.filter { r in
            let h = haystack(r)
            return tokens.allSatisfy { h.contains($0) }
        }
        if !allTokens.isEmpty { return allTokens }

        let anyToken = records.filter { r in
            let h = haystack(r)
            return tokens.contains { h.contains($0) }
        }
        return anyToken
    }
}
