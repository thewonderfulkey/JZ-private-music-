// 开屏时间轴 v2.4.82 的本地自测（WSL 上只编 SplashTimeline.swift，不碰 SwiftUI）
// 跑法：
//   wsl -d Ubuntu -- bash -lc "cd /mnt/d/Projects/Private_music && /home/zhou/swift/usr/bin/swiftc \
//     -Onone -swift-version 5 -o /tmp/splashmini \
//     ios/JZMusicHelper/Services/SplashTimeline.swift tools/dev/r252_splash_mini.swift && /tmp/splashmini"

import Foundation

var failed = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  ok   \(name)")
    } else {
        failed += 1
        print("  FAIL \(name)  \(detail)")
    }
}

@main
struct SplashMini {
    static func main() {
        let T = SplashTimeline.self

        check("头梁先落笔，耳罩才开始戴", T.bandDraw.start < T.cupLeft.start)
        check("两只耳罩错开 0.06s", abs(T.cupRight.start - T.cupLeft.start - 0.06) < 0.001)
        check("耳罩都在声波之前开始", T.cupLeft.start < T.sound.start && T.cupRight.start < T.sound.start)
        check("声波开始时头梁已经画完", T.bandDraw.end <= T.sound.start)
        check("轻顶落在声波窗口内", T.thump.start >= T.sound.start && T.thump.end <= T.sound.end)
        check("耳罩彻底落位之后才退场", T.cupLeft.end <= T.exit.start && T.cupRight.end <= T.exit.start)
        check("图标比纸底先走", T.markFade.end <= T.exit.end)
        check("首页与退场交叉淡入",
              T.contentIn.start < T.exit.end && T.contentIn.end >= T.exit.end - 0.0001)
        check("全片时长 = 退场结束，且 < 1.9s", abs(T.total - T.exit.end) < 0.0001 && T.total < 1.9,
              "total=\(T.total)")
        check("每一拍落在 0…total 之间",
              [T.bandDraw, T.cupLeft, T.cupRight, T.sound, T.soundSecond, T.thump,
               T.exit, T.markFade, T.contentIn]
                .allSatisfy { $0.start >= 0 && $0.end <= T.total + 0.0001 })

        check("第二道声波撑到退场开始", T.soundSecond.end >= T.exit.start,
              "wave2.end=\(T.soundSecond.end) exit.start=\(T.exit.start)")
        check("声波透明度整拍匀速淡出",
              T.waveOpacity(progress: 0.2) > T.waveOpacity(progress: 0.6)
                && T.waveOpacity(progress: 0.6) > T.waveOpacity(progress: 0.95)
                && T.waveOpacity(progress: 0.6) > 0.15,
              "op(0.6)=\(T.waveOpacity(progress: 0.6))")

        let still = T.longestStillWindow()
        check("开屏全程不许停：最长静止窗 < 150ms", still < 0.15, "still=\(still)s")

        check("减弱动效总时长不到一半", T.reduceMotionTotal < T.total / 2, "reduce=\(T.reduceMotionTotal)")
        check("图标开场不透明、结束为 0",
              T.markOpacity(at: 0, reduceMotion: false) == 1
                && T.markOpacity(at: T.total, reduceMotion: false) == 0)
        check("结束判定", !T.isFinished(at: T.total - 0.01, reduceMotion: false)
                && T.isFinished(at: T.total, reduceMotion: false))

        print("")
        print("total=\(T.total)s  still=\(still * 1000)ms")
        print(failed == 0 ? "ALL OK" : "FAILED: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
