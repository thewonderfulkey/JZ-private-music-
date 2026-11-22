// v2.4.74（第 58 轮）迷你自测：只跑本轮新增的纯函数口径。
// 本轮：下载页搜索"每输入一个字母就卡"——把"每首歌 × 每个字段 × 每次求值"的归一化，
// 改成"每首歌归一化一次"（LibrarySearch.blob），查询词也只归一化一次。
// 用法：bash tools/dev/run_mini_assertions.sh tools/dev/r190_mini_assertions.swift
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

func song(_ platform: MusicPlatform, _ name: String, _ singer: String,
          album: String = "", dur: Int = 300, id: String) -> Song {
    Song(platform: platform, platformID: id, name: name, singer: singer,
         album: album, duration: Double(dur), picURL: nil)
}

print("— 下载页搜索：预归一化（老板：663 首时每敲一个字母就卡）")

let s1 = song(.qq, "後來", "劉若英", album: "我等你", id: "ls1")
let name = "01 - 劉若英 - 後來.flac"
let blob = LibrarySearch.blob(song: s1, fileName: name)
let q = { (s: String) in LibrarySearch.key(s) }

check("繁简：搜「后来」命中「後來」", LibrarySearch.matches(blob: blob, key: q("后来")))
check("歌手字段能搜", LibrarySearch.matches(blob: blob, key: q("刘若英")))
check("专辑字段能搜", LibrarySearch.matches(blob: blob, key: q("我等你")))
check("文件名能搜（去扩展名）", LibrarySearch.matches(blob: blob, key: q("01")))
check("跨字段不误命中（歌手末尾 + 专辑开头）", !LibrarySearch.matches(blob: blob, key: q("英我等")), blob)
check("空查询不算命中", !LibrarySearch.matches(blob: blob, key: ""))
check("不存在的词不命中", !LibrarySearch.matches(blob: blob, key: q("晴天")))

for word in ["后来", "刘若英", "我等你", "01", "英我等", "晴天", "  "] {
    let old = LibrarySearch.matches(song: s1, fileName: name, query: word)
    let new = LibrarySearch.matches(blob: blob, key: q(word))
    check("与老口径同结论：「\(word)」", old == new, "old=\(old) new=\(new)")
}

print("— 归一化一次 vs 逐次：同一首歌重复取 blob 结果必须稳定")
check("blob 可重复取（调用方缓存的前提）", LibrarySearch.blob(song: s1, fileName: name) == blob)

print("")
print(fail.isEmpty ? "全部通过：\(pass) 条" : "失败 \(fail.count) 条：\(fail.joined(separator: " / "))")
exit(fail.isEmpty ? 0 : 1)
