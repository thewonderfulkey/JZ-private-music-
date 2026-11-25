// r251 迷你自测（2026-11-25 v2.4.112）：播放缓存 + 文件索引闸门
//
// 为什么单独编：官方 SelfTest 在本机 WSL 上会因为歌词那节的 zlib 桩中止；
// 这里只编 `PlaybackRules.swift`（纯逻辑、只 import Foundation），本机就能跑。
import Foundation

var pass = 0
var fails: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fails.append(name); print("  ✗ \(name)  ← \(extra)") }
}

// MARK: - 文件自己的索引

func flacHead(sampleRate: Int, totalSamples: UInt64) -> Data {
    var b = [UInt8](repeating: 0, count: 42)
    b[0] = 0x66; b[1] = 0x4C; b[2] = 0x61; b[3] = 0x43   // fLaC
    b[4] = 0x80                                           // last + type 0 (STREAMINFO)
    b[7] = 34
    var acc: UInt64 = (UInt64(sampleRate & 0xFFFFF) << 44)
    acc |= (2 << 41)
    acc |= (24 << 36)
    acc |= (totalSamples & 0x0000_000F_FFFF_FFFF)
    for i in 0..<8 { b[18 + i] = UInt8((acc >> (8 * (7 - i))) & 0xFF) }
    return Data(b)
}

func mp3Head(frames: Int) -> Data {
    var b = [UInt8](repeating: 0, count: 64)
    b[0] = 0xFF; b[1] = 0xFB        // MPEG1, Layer III
    b[2] = 0x90                     // 128k, 44100
    b[3] = 0xC0                     // mono
    b[21] = 0x58; b[22] = 0x69; b[23] = 0x6E; b[24] = 0x67  // Xing
    b[25] = 0; b[26] = 0; b[27] = 0; b[28] = 1              // flags: 有帧数
    b[29] = UInt8((frames >> 24) & 0xFF)
    b[30] = UInt8((frames >> 16) & 0xFF)
    b[31] = UInt8((frames >> 8) & 0xFF)
    b[32] = UInt8(frames & 0xFF)
    return Data(b)
}

func m4aHead(timescale: Int, duration: Int) -> Data {
    func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    var b: [UInt8] = []
    b += be32(32); b += Array("ftyp".utf8); b += [UInt8](repeating: 0, count: 24)
    b += be32(36); b += Array("moov".utf8)
    b += be32(28); b += Array("mvhd".utf8)
    b += [0, 0, 0, 0]               // version 0 + flags
    b += be32(0); b += be32(0)      // creation / modification
    b += be32(timescale); b += be32(duration)
    return Data(b)
}

print("— 文件自己的索引")
let flac = MediaIndexRules.duration(head: flacHead(sampleRate: 48_000, totalSamples: 12_102_400),
                                    container: "flac", totalBytes: 0)
check("flac STREAMINFO → 252.13s", abs((flac ?? 0) - 252.133) < 0.01, "\(flac ?? -1)")

let mp3 = MediaIndexRules.duration(head: mp3Head(frames: 10_000), container: "mp3", totalBytes: 0)
check("mp3 Xing 帧数 → 261.22s", abs((mp3 ?? 0) - 10_000 * 1152 / 44100.0) < 0.01, "\(mp3 ?? -1)")

let m4a = MediaIndexRules.duration(head: m4aHead(timescale: 44_100, duration: 11_900_000),
                                   container: "m4a", totalBytes: 0)
check("m4a mvhd → 269.84s", abs((m4a ?? 0) - 11_900_000 / 44_100.0) < 0.01, "\(m4a ?? -1)")

check("认不出的字节 → nil（不是 0 秒）",
      MediaIndexRules.duration(head: Data(repeating: 0x11, count: 64),
                               container: "mp3", totalBytes: 1_000) == nil)
check("mp3 没有 Xing 头 → nil（这段里没有可信长度）",
      MediaIndexRules.duration(head: Data(repeating: 0, count: 64),
                               container: "mp3", totalBytes: 1_000) == nil)

// MARK: - ±5 秒闸门

print("— 时长闸门（±5 秒）")
check("差 0 秒 → match", PlaybackCacheRules.gate(candidate: 200, expected: 200) == .match(200))
check("差 4.9 秒 → match", {
    if case .match = PlaybackCacheRules.gate(candidate: 204.9, expected: 200) { return true }
    return false
}())
check("差 5.1 秒 → mismatch", {
    if case .mismatch = PlaybackCacheRules.gate(candidate: 205.1, expected: 200) { return true }
    return false
}())
check("解不出索引 → unverified（不是 mismatch）",
      PlaybackCacheRules.gate(candidate: nil, expected: 200) == .unverified)
check("曲目时长未知 → unverified",
      PlaybackCacheRules.gate(candidate: 200, expected: 0) == .unverified)
check("原来是 ±25 秒，现在必拒 10 秒差", {
    if case .mismatch = PlaybackCacheRules.gate(candidate: 210, expected: 200) { return true }
    return false
}())

// MARK: - 断流后"同一份文件"判定

print("— 同一份文件")
check("总长+指纹都一样 → 同一份",
      PlaybackCacheRules.sameFile(oldBytes: 100, newBytes: 100, oldHash: "aa", newHash: "aa"))
check("总长不同 → 不是（换了版本）",
      !PlaybackCacheRules.sameFile(oldBytes: 100, newBytes: 101, oldHash: "aa", newHash: "aa"))
check("总长相同但指纹不同 → 不是",
      !PlaybackCacheRules.sameFile(oldBytes: 100, newBytes: 100, oldHash: "aa", newHash: "bb"))
check("只有指纹（总长缺失）也能判",
      PlaybackCacheRules.sameFile(oldBytes: 0, newBytes: 0, oldHash: "aa", newHash: "aa"))
check("两样都没有 → 不算同一份",
      !PlaybackCacheRules.sameFile(oldBytes: 0, newBytes: 0, oldHash: nil, newHash: nil))

// MARK: - 半截 .part 能不能续写（2026-11-25 真机事故：续错文件 → 一直抖）

print("— 半截文件续写身份")
check("指纹一致才能续", PlaybackCacheRules.canResume(partBytes: 1000, partHash: "aa",
                                                    newHash: "aa", newBytes: 5000))
check("指纹不同 → 不许续（换版本）", !PlaybackCacheRules.canResume(partBytes: 1000, partHash: "aa",
                                                             newHash: "bb", newBytes: 5000))
check("没有身份 → 不许续（旧 .part 一律重下）", !PlaybackCacheRules.canResume(partBytes: 1000, partHash: nil,
                                                                newHash: "aa", newBytes: 5000))
check("新源没指纹 → 不许续", !PlaybackCacheRules.canResume(partBytes: 1000, partHash: "aa",
                                                     newHash: nil, newBytes: 5000))
check("旧文件比新源还长 → 不许续", !PlaybackCacheRules.canResume(partBytes: 6000, partHash: "aa",
                                                          newHash: "aa", newBytes: 5000))
check("空 .part → 从头下", !PlaybackCacheRules.canResume(partBytes: 0, partHash: "aa",
                                                     newHash: "aa", newBytes: 5000))

// MARK: - LRU

print("— 淘汰（头进尾出：最早缓存的先走，跳过正在播的）")
let now = Date()
let ordered: [(id: String, cachedAt: Date)] = [
    ("a", now.addingTimeInterval(-300)),
    ("b", now.addingTimeInterval(-200)),
    ("c", now.addingTimeInterval(-100)),
]
check("上限 2 首 → 挤掉最早缓存的 a",
      PlaybackCacheRules.victims(orderedByCachedAt: ordered, limit: 2, keeping: "c") == ["a"])
check("正在播的是 a（最早缓存）也不淘汰它，挤掉 b、c",
      PlaybackCacheRules.victims(orderedByCachedAt: ordered, limit: 1, keeping: "a") == ["b", "c"])
check("没超上限 → 不淘汰",
      PlaybackCacheRules.victims(orderedByCachedAt: ordered, limit: 3, keeping: "a").isEmpty)
let fifoFull: [(id: String, cachedAt: Date)] = [
    ("a", now.addingTimeInterval(-30)), ("b", now.addingTimeInterval(-20)),
    ("c", now.addingTimeInterval(-10)),
]
check("缓存总量恒定：3 首上限 3 不挤，上限 2 只挤 1 首",
      PlaybackCacheRules.victims(orderedByCachedAt: fifoFull, limit: 3, keeping: "").isEmpty
      && PlaybackCacheRules.victims(orderedByCachedAt: fifoFull, limit: 2,
                                    keeping: "").count == 1)

// MARK: - 其它

print("— 杂项")
check("文件名稳定且不含路径分隔符",
      PlaybackCacheRules.fileBase(songID: "netease:123/456") == PlaybackCacheRules.fileBase(songID: "netease:123/456")
      && !PlaybackCacheRules.fileBase(songID: "netease:123/456").contains("/"))
check("不同歌 → 不同文件名",
      PlaybackCacheRules.fileBase(songID: "a") != PlaybackCacheRules.fileBase(songID: "b"))
check("min/max 夹住", PlaybackCacheRules.clampLimit(0) == PlaybackCacheRules.minLimit
      && PlaybackCacheRules.clampLimit(9999) == PlaybackCacheRules.maxLimit)
check("50 首 ≈ 480MB", PlaybackCacheRules.estimatedMB(limit: 50) == 480)
check("mp3 的 UTI 正确", PlaybackCacheRules.contentType(container: "mp3", format: "mp3") == "public.mp3")
check("m4a 的 UTI 正确", PlaybackCacheRules.contentType(container: "m4a", format: "m4a") == "public.mpeg-4-audio")

print("")
if fails.isEmpty {
    print("全部通过：\(pass)")
} else {
    print("失败 \(fails.count)：\(fails)")
    exit(1)
}
