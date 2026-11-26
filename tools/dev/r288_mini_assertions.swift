// r288 迷你自测（2026-11-27）：发现页 BANNER 轮播规则
// 老板口径：能滑、能关、只跳站内；0 条不渲染，1 条不自动切。
import Foundation

var pass = 0
var fail: [String] = []
func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 显示 / 自动轮播")
check("0 条不渲染", !BannerRules.shouldShow(count: 0))
check("1 条要渲染但不自动轮播",
      BannerRules.shouldShow(count: 1) && !BannerRules.shouldAutoAdvance(count: 1))
check("多条才自动轮播", BannerRules.shouldAutoAdvance(count: 2))

print("— 循环")
check("最后一张之后回到 0", BannerRules.advanced(from: 2, count: 3) == 0,
      "\(BannerRules.advanced(from: 2, count: 3))")
check("中间正常 +1", BannerRules.advanced(from: 0, count: 3) == 1)
check("负数不越界", BannerRules.nextIndex(current: -1, count: 3) == 2)
check("count 0 不崩", BannerRules.nextIndex(current: 5, count: 0) == 0)

print("— 只跳站内")
let internalBanner = NeteaseBannerItem(image: "http://img/1.jpg", title: "歌单推荐",
                                       playlistID: "18428485896")
let external = NeteaseBannerItem(image: "http://img/2.jpg", title: "演唱会门票", playlistID: nil)
let noImage = NeteaseBannerItem(image: "", title: "空图", playlistID: "123")
check("外链 banner 被过滤", BannerRules.usable([internalBanner, external]).map(\.title) == ["歌单推荐"])
check("空图的也不要", BannerRules.usable([noImage]).isEmpty)

print("— 关闭只关当天")
check("今天关过 → 今天不显示", BannerRules.isHidden(closedDay: 100, today: 100))
check("昨天关过 → 今天照常显示", !BannerRules.isHidden(closedDay: 99, today: 100))
check("从没关过 → 显示", !BannerRules.isHidden(closedDay: nil, today: 100))

print("— 图上文案：类别词不压图")
check("类别词不压图（歌单）", BannerRules.caption("歌单") == nil)
check("类别词不压图（演出）", BannerRules.caption("演出") == nil)
check("空标题不出文案", BannerRules.caption("   ") == nil)
check("真标题照常显示", BannerRules.caption("一周欧美上新") == "一周欧美上新")

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  失败：\(f)") }
    exit(1)
}
