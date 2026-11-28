// r318 迷你自测（2026-11-28）：识曲音源（外部/机内）纯规则
// 本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在歌词解密那节中止；这里只跑本轮新增断言。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

print("— 识曲音源（外部/机内）")
check("默认音源是外部", RecognizeSourceRules.defaultSource == .external)
check("空值回外部", RecognizeSourceRules.source(from: nil) == .external)
check("未知值回外部", RecognizeSourceRules.source(from: "xxx") == .external)
check("机内值能读回", RecognizeSourceRules.source(from: "internal") == .internalAudio)
check("外部短名", RecognizeSource.external.shortTitle == "外部")
check("机内短名", RecognizeSource.internalAudio.shortTitle == "机内")
check("机内提示要外放", RecognizeSource.internalAudio.idleDetail.contains("外放"))
check("扬声器不拦", RecognizeSourceRules.routeWarning(port: "Speaker") == nil)
check("耳机要拦", RecognizeSourceRules.routeWarning(port: "Headphones") != nil)
check("蓝牙要拦", RecognizeSourceRules.routeWarning(port: "BluetoothA2DPOutput") != nil)
check("空端口要拦", RecognizeSourceRules.routeWarning(port: nil) != nil)
check("机内静音门槛更低",
      RecognizeSourceRules.isSilent(peak: 0.007, source: .external)
        && !RecognizeSourceRules.isSilent(peak: 0.007, source: .internalAudio))

print("通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty { exit(1) }
