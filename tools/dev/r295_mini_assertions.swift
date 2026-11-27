// r295 迷你自测（2026-11-27）：智能搜索 v1 —— 输入联想
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}
func s(_ p: MusicPlatform, _ name: String, _ singer: String, _ id: String) -> Song {
    Song.make(platform: p, platformID: id, name: name, singer: singer, album: "",
              duration: 200, picURL: nil)
}

print("— 什么时候才联想")
check("中文 1 个字就联想", SearchSuggestRules.shouldSuggest("晴"))
check("英文 1 个字母不联想", !SearchSuggestRules.shouldSuggest("a"))
check("英文 2 个字母才联想", SearchSuggestRules.shouldSuggest("ab"))
check("空格不算输入", !SearchSuggestRules.shouldSuggest("   "))
check("前后空格不影响", SearchSuggestRules.shouldSuggest("  晴天  "))
check("日文假名 1 个字也联想", SearchSuggestRules.shouldSuggest("あ"))

print("— 去重与过滤")
let pool = [s(.kuwo, "晴天", "周杰伦", "k1"), s(.qq, "晴天", "周杰伦", "q1"),
            s(.qq, "晴天 (Live)", "周杰伦", "q2"), s(.netease, "晴天 0.8x", "上传者", "n1"),
            s(.qq, "七里香", "周杰伦", "q3")]
let refined = SearchSuggestRules.refine(pool)
check("跨平台同曲只留一条", refined.filter { $0.name == "晴天" }.count == 1,
      "\(refined.map(\.name))")
check("Live 版保留", refined.contains { $0.name == "晴天 (Live)" })
check("变速垃圾不出现", !refined.contains { $0.name.contains("0.8x") })
check("顺序保持", refined.first?.platform == .kuwo)

let many = (1...20).map { s(.kuwo, "歌\($0)", "x", "m\($0)") }
check("最多 8 条", SearchSuggestRules.refine(many).count == 8)
check("limit 生效", SearchSuggestRules.refine(many, limit: 3).count == 3)
check("空给空", SearchSuggestRules.refine([]).isEmpty)

print("— 副标题")
check("歌名含歌手就不重复",
      SearchSuggestRules.subtitle(for: s(.qq, "华晨宇 (烟火里的尘埃)", "华晨宇", "z1")) == "")
check("正常显示歌手", SearchSuggestRules.subtitle(for: s(.qq, "晴天", "周杰伦", "z2")) == "周杰伦")
check("没有歌手不显示", SearchSuggestRules.subtitle(for: s(.qq, "晴天", "", "z3")) == "")

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}
