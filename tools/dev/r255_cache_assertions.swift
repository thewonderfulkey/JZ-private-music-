// r255 迷你自测（2026-11-25 v2.4.116）：缓存文件名必须带真容器后缀 + 坏缓存文件的自愈规矩
//
// 为什么单独编：官方 SelfTest 在本机 WSL 上会因为歌词那节的 zlib 桩中止；
// 这里只用到 `PlaybackCacheRules`（纯逻辑、只 import Foundation），本机就能跑。
//
//   wsl -d Ubuntu -- bash -lc "cd /mnt/d/Projects/Private_music && bash tools/dev/run_mini_assertions.sh tools/dev/r255_cache_assertions.swift"
import Foundation

var pass = 0
var fails: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fails.append(name); print("  ✗ \(name)  ← \(extra)") }
}

print("— 缓存文件名：必须是 AVFoundation 认得的容器后缀")
check("主干名只用哈希、不含 / 或 .", !PlaybackCacheRules.fileBase(songID: "netease:1/2").contains("/")
      && !PlaybackCacheRules.fileBase(songID: "netease:1/2").contains("."))
check("同一首歌主干名稳定",
      PlaybackCacheRules.fileBase(songID: "kuwo:88") == PlaybackCacheRules.fileBase(songID: "kuwo:88"))
check("不同歌主干名不同",
      PlaybackCacheRules.fileBase(songID: "a") != PlaybackCacheRules.fileBase(songID: "b"))
check("mp3 → .mp3", PlaybackCacheRules.fileExtension(container: "mp3", format: "mp3") == "mp3")
check("flac → .flac", PlaybackCacheRules.fileExtension(container: "flac", format: "flac") == "flac")
check("m4a → .m4a", PlaybackCacheRules.fileExtension(container: "m4a", format: "m4a") == "m4a")
check("wav → .wav", PlaybackCacheRules.fileExtension(container: "wav", format: "wav") == "wav")
check("ogg → .ogg", PlaybackCacheRules.fileExtension(container: "ogg", format: "ogg") == "ogg")
check("aac 归到 .m4a", PlaybackCacheRules.fileExtension(container: "aac", format: "aac") == "m4a")
check("容器认不出时退回源格式", PlaybackCacheRules.fileExtension(container: "unknown", format: "flac") == "flac")
check("两样都认不出也不许留空/乱写",
      PlaybackCacheRules.fileExtension(container: "unknown", format: "") == "mp3")
check("事故后缀 .audio 必须被判为不可播",
      !PlaybackCacheRules.isPlayableExtension("audio"))
check("正常后缀被判为可播",
      PlaybackCacheRules.isPlayableExtension("mp3") && PlaybackCacheRules.isPlayableExtension("FLAC"))
check("拼出来的文件名一定是可播后缀", {
    for c in ["mp3", "flac", "m4a", "wav", "ogg", "unknown", ""] {
        let name = PlaybackCacheRules.fileBase(songID: "x") + "."
            + PlaybackCacheRules.fileExtension(container: c, format: "mp3")
        if !PlaybackCacheRules.isPlayableExtension((name as NSString).pathExtension) { return false }
    }
    return true
}())

print("— 坏缓存文件的自愈规矩")
check("「播放缓存」必须被认成本地源（时长闸门豁免 + 失败自愈都用它）",
      PlaybackCacheRules.isCacheBackedLocalSource("播放缓存"))
check("网络源不许被误认",
      !PlaybackCacheRules.isCacheBackedLocalSource("酷狗") && !PlaybackCacheRules.isCacheBackedLocalSource(""))
check("回退次数上限是 1（只许回网络重取一次，不许原地打转）",
      PlaybackCacheRules.maxCachedFileFallbacks == 1)

print("")
if fails.isEmpty {
    print("全部通过：\(pass)")
} else {
    print("失败 \(fails.count)：\(fails.joined(separator: " / "))")
    exit(1)
}
