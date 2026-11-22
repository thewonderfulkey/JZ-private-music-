// r209 迷你自测（2026-11-23 v2.4.86）：收藏爱心"数据变了、图标不动"
//   ① 旧写法（命中缓存直接 return）→ 视图收不到通知（就是老板看到的那个 bug）
//   ② 新写法（`FavoriteObservation.cached(_, favoritesCount: favorites.count)`）→ 收得到
//   ③ 判定器本身的语义（空收藏不采信缓存 / 有缓存就采用 / 没缓存就现算）
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止，
// 而这段断言在文件末尾，永远跑不到。
import Foundation
import Observation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

@Observable
final class HeartProbe {
    var favorites: [String] = []
    @ObservationIgnored var cache: [String: Bool] = [:]

    func isFavoriteLegacy(_ id: String) -> Bool {
        if let hit = cache[id] { return hit }
        let hit = favorites.contains(id)
        cache[id] = hit
        return hit
    }

    func isFavoriteFixed(_ id: String) -> Bool {
        if let hit = FavoriteObservation.cached(cache[id], favoritesCount: favorites.count) {
            return hit
        }
        let hit = favorites.contains(id)
        cache[id] = hit
        return hit
    }

    func add(_ id: String) {
        favorites.append(id)
        cache.removeAll()
    }
}

final class Flag { var fired = 0 }

func probe(_ body: @escaping () -> Void, mutate: () -> Void) -> Int {
    let flag = Flag()
    withObservationTracking(body, onChange: { flag.fired += 1 })
    mutate()
    return flag.fired
}

print("— 旧写法：缓存命中后视图丢订阅（bug 本体）")
let legacy = HeartProbe()
_ = legacy.isFavoriteLegacy("a")
_ = legacy.isFavoriteLegacy("a")
let legacyFired = probe({ _ = legacy.isFavoriteLegacy("a") }, mutate: { legacy.add("a") })
check("旧写法命中缓存 → 收藏变化通知不到视图（notified == 0）", legacyFired == 0, "notified=\(legacyFired)")
check("而且数据确实变了（收藏其实成功了）", legacy.favorites.contains("a"))

print("— 新写法：命中缓存也订阅得到")
let fixed = HeartProbe()
_ = fixed.isFavoriteFixed("a")
_ = fixed.isFavoriteFixed("a")
let fixedFired = probe({ _ = fixed.isFavoriteFixed("a") }, mutate: { fixed.add("a") })
check("新写法命中缓存 → 收藏变化通知到视图（notified > 0）", fixedFired > 0, "notified=\(fixedFired)")

print("— 冷缓存本来就没问题（对照）")
let cold = HeartProbe()
let coldFired = probe({ _ = cold.isFavoriteLegacy("a") }, mutate: { cold.add("a") })
check("缓存冷时旧写法也能通知（所以这个 bug 只在“先渲染过”的行上）", coldFired > 0,
      "notified=\(coldFired)")

print("— 判定器语义（FavoriteObservation.cached）")
check("收藏为空 → 不采信缓存", FavoriteObservation.cached(true, favoritesCount: 0) == nil)
check("有收藏 + 命中 → 采用缓存", FavoriteObservation.cached(true, favoritesCount: 3) == true)
check("有收藏 + 命中（false）→ 采用缓存", FavoriteObservation.cached(false, favoritesCount: 3) == false)
check("有收藏 + 没命中 → 现算", FavoriteObservation.cached(nil, favoritesCount: 3) == nil)

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  FAIL: \(f)") }
    exit(1)
}
exit(0)
