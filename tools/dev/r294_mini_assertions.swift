// r294 迷你自测（2026-11-27）：上传者垃圾音频过滤
// 老板："这种第三方的变速版/垃圾音频，定一个规则全部拿掉，不要出现在任何返回结果里。"
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 该被拿掉的")
check("0.8x", JunkAudioRules.isJunk(name: "烟火里的尘埃 0.8x"))
check("1.25x", JunkAudioRules.isJunk(name: "晴天 1.25x"))
check("全角 ×", JunkAudioRules.isJunk(name: "烟火里的尘埃 (0.8×版)"))
check("0.8 倍速", JunkAudioRules.isJunk(name: "烟火里的尘埃 0.8 倍速"))
check("slowed", JunkAudioRules.isJunk(name: "Star Unkind slowed"))
check("Sped Up", JunkAudioRules.isJunk(name: "Star Unkind Sped Up"))
check("nightcore", JunkAudioRules.isJunk(name: "Star Unkind nightcore"))
check("上传者写进歌名", JunkAudioRules.isJunk(name: "你是我的救赎《烟火里的尘埃》 (0.8×版)"))
check("DJ版", JunkAudioRules.isJunk(name: "红色高跟鞋 (DJ版)"))
check("抖音版/剪辑版/变速版",
      JunkAudioRules.isJunk(name: "晴天 抖音版")
        && JunkAudioRules.isJunk(name: "晴天 剪辑版")
        && JunkAudioRules.isJunk(name: "晴天 变速版"))
check("鬼畜", JunkAudioRules.isJunk(name: "晴天 鬼畜版"))
check("专辑名里的 DJ版合集也算",
      JunkAudioRules.isJunk(name: "晴天", album: "抖音热歌 DJ版合集"))

print("— 不许误伤")
check("正常歌名", !JunkAudioRules.isJunk(name: "烟火里的尘埃"))
check("Live 是正式发行", !JunkAudioRules.isJunk(name: "晴天 (Live)"))
check("remix 是正式发行", !JunkAudioRules.isJunk(name: "晴天 (Club Remix)"))
check("24K Magic", !JunkAudioRules.isJunk(name: "24K Magic"))
check("7 rings", !JunkAudioRules.isJunk(name: "7 rings"))
check("X&Y", !JunkAudioRules.isJunk(name: "X&Y"))
check("空名不崩", !JunkAudioRules.isJunk(name: ""))

print("— 批量过滤")
func s(_ n: String, _ id: String) -> Song {
    Song.make(platform: .qq, platformID: id, name: n, singer: "x", album: "", duration: 200, picURL: nil)
}
let pool = [s("晴天", "1"), s("晴天 0.8x", "2"), s("稻香", "3"), s("稻香 slowed", "4")]
check("只留正常歌且保序", JunkAudioRules.filter(pool).map(\.platformID) == ["1", "3"],
      "\(JunkAudioRules.filter(pool).map(\.platformID))")
check("全被过滤返回空", JunkAudioRules.filter([s("晴天 0.8x", "2")]).isEmpty)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}
