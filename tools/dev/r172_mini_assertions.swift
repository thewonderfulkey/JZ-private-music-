// r172 迷你自测（2026-11-21 v2.4.55）：编辑歌曲信息保存后封面/专辑不显示
//   ① 换封面地址必须 +1 代次（否则行不重新取图 → 一直是音符占位）
//   ② 补料落盘 → `markingCoverLanded` +1 代次、清 stale、**不加锁**
//   ③ 手改专辑要锁住，自动匹配不许再改回去（老板改的就是它）
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func song(_ name: String, _ singer: String, album: String = "", dur: Double = 240,
          id: String = "x1", source: MetaSource = .filenameGuess,
          locked: [MetaField] = [], pic: String? = nil,
          revision: Int = 0, stale: Bool = false,
          platform: MusicPlatform = .local) -> Song {
    Song.make(platform: platform, platformID: id, name: name, singer: singer, album: album,
              duration: dur, picURL: pic)
        .with(meta: MetaProvenance(source: source, locked: locked,
                                   coverStale: stale, coverRevision: revision))
}

let matched = MatchedMetadata(name: "レイラ", singer: "40mP", album: "レイラ",
                              picURL: "https://example.com/leila.jpg", platform: .qq,
                              platformID: "qq_leila", score: 0.93)

print("— 换封面地址 → 代次必须 +1（这是行重新取图的唯一开关）")
let bare = song("レイラ", "40mP", album: "", id: "imp_leila")
let withPic = MetadataMatcher.merge(into: bare, matched: matched)
check("picURL 从 nil → 有值：代次 +1", withPic.coverRevision == bare.coverRevision + 1,
      "\(bare.coverRevision) → \(withPic.coverRevision)")
check("picURL 真的写进去了", withPic.picURL == "https://example.com/leila.jpg", "\(withPic.picURL ?? "nil")")

let again = MetadataMatcher.merge(into: withPic, matched: matched)
check("同一张图再匹配一次：代次**不动**（不许每轮都抖一下）",
      again.coverRevision == withPic.coverRevision, "\(withPic.coverRevision) → \(again.coverRevision)")

print("— 补料把图落盘 → markingCoverLanded")
let staleSong = song("レイラ", "40mP", album: "レイラ", id: "imp_leila", source: .manual,
                     locked: [.name], revision: 7, stale: true)
let landed = MetadataMatcher.markingCoverLanded(staleSong)
check("代次 +1", landed.coverRevision == 8, "\(landed.coverRevision)")
check("stale 清掉（图已确认是这首的）", landed.meta?.coverStale == false)
check("**不加锁**（补料不算用户换封面）",
      landed.meta?.locked.map(\.rawValue) == ["name"],
      "\(landed.meta?.locked.map(\.rawValue) ?? [])")
check("出处不变", landed.meta?.source == .manual, "\(landed.meta?.source.rawValue ?? "-")")
check("歌名/歌手/专辑原样", landed.name == "レイラ" && landed.singer == "40mP" && landed.album == "レイラ")

print("— 手改专辑 → 锁住，自动匹配不许改回去")
let editedAlbum = MetadataMatcher.applyingManualEdit(to: bare, name: bare.name,
                                                     singer: bare.singer,
                                                     album: "我填的专辑", cover: nil)
check("专辑写进去了", editedAlbum.album == "我填的专辑", editedAlbum.album)
check("专辑被锁", editedAlbum.meta?.isLocked(.album) == true,
      "\(editedAlbum.meta?.locked ?? [])")
let afterMatch = MetadataMatcher.merge(into: editedAlbum, matched: matched)
check("匹配回来也不会覆盖手填专辑", afterMatch.album == "我填的专辑", afterMatch.album)
check("歌名没锁 → 可以采用匹配值", afterMatch.name == "レイラ", afterMatch.name)

print("— 只改歌名（不动专辑）→ 专辑仍可自动补")
let onlyName = MetadataMatcher.applyingManualEdit(to: bare, name: "レイラ改",
                                                  singer: bare.singer, album: bare.album,
                                                  cover: nil)
check("专辑没锁", onlyName.meta?.isLocked(.album) == false, "\(onlyName.meta?.locked ?? [])")
let filled = MetadataMatcher.merge(into: onlyName, matched: matched)
check("专辑被自动补上", filled.album == "レイラ", filled.album)
check("手填歌名保留", filled.name == "レイラ改", filled.name)

print("— 恢复自动：解锁后能改回去")
let reset = MetadataMatcher.resettingToAuto(afterMatch)
check("锁清空", reset.meta?.locked.isEmpty == true)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  FAIL: \(f)") }
    exit(1)
}
exit(0)
