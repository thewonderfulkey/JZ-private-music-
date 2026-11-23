// FLAC 头里的 total_samples 迷你自测（2026-11-23）
//   老板：拖动进度条要**准**、672 首全要真实时长、量准之后能不能修文件头。
//   FLAC 的时长就在 STREAMINFO 的 36 bit total_samples 里 —— 改它不碰音频帧、不碰块头
//   （块头 CRC-8 只覆盖那 4 个字节），所以这是"修头"最安全的落点。
// 为什么单独编：本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在"歌词解密"那节中止。
import Foundation

var pass = 0
var fail: [String] = []

func check(_ name: String, _ ok: Bool, _ extra: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail.append("\(name) \(extra)"); print("  ✗ \(name)  ← \(extra)") }
}

// 造一个最小 FLAC 头
var body = [UInt8](repeating: 0, count: 34)
body[0] = 0x10; body[1] = 0x00
body[2] = 0x10; body[3] = 0x00
body[10] = 0x0A            // 采样率 44100（20 bit）高 8 位
body[11] = 0xC4            // 中 8 位
body[12] = 0x43            // 低 4 位 + 声道/位深
body[13] = 0x50            // 位深那半字节 + total_samples 最高 4 位
let samples: UInt64 = 319 * 44_100
body[13] = (body[13] & 0xF0) | UInt8((samples >> 32) & 0x0F)
body[14] = UInt8((samples >> 24) & 0xFF)
body[15] = UInt8((samples >> 16) & 0xFF)
body[16] = UInt8((samples >> 8) & 0xFF)
body[17] = UInt8(samples & 0xFF)

var file: [UInt8] = Array("fLaC".utf8)
file += [0x80, 0x00, 0x00, 34]
file += body

print("\n— 解析 site(inFileData:)")
let site = FlacDurationHeader.site(inFileData: Data(file))
check("能解析出 STREAMINFO", site != nil)
check("offset = 4 + 4 + 13", site?.totalSamplesOffset == 21, "\(site?.totalSamplesOffset ?? -1)")
check("采样率读对", site?.sampleRate == 44_100, "\(site?.sampleRate ?? 0)")
check("total_samples 读对", site?.totalSamples == samples, "\(site?.totalSamples ?? 0)")
check("备份块体 34 字节", site?.streamInfoBody.count == 34)
check("总样本数 → 319 秒", Double(site?.totalSamples ?? 0) / 44_100 == 319)

print("\n— 改值 patched(_:totalSamples:)")
let five = Array(body[13..<18])
let bigger = FlacDurationHeader.totalSamples(seconds: 332, sampleRate: 44_100)!
let patched = FlacDurationHeader.patched(five, totalSamples: bigger)!
check("读回同一个值", FlacDurationHeader.totalSamples(patched) == bigger)
check("高 4 位原样保留", patched[0] & 0xF0 == five[0] & 0xF0)
check("低 4 位 = 总样本数的最高 4 位", (patched[0] & 0x0F) == UInt8((bigger >> 32) & 0x0F))
var file2 = file
for (i, b) in patched.enumerated() { file2[21 + i] = b }
let site2 = FlacDurationHeader.site(inFileData: Data(file2))
check("改完仍可解析、采样率不变", site2?.sampleRate == 44_100)
check("改完读回 332 秒", (site2?.totalSamples ?? 0) / 44_100 == 332)

print("\n— 边界")
check("不是 FLAC → nil", FlacDurationHeader.site(inFileData: Data("ID3xxxxxxx".utf8)) == nil)
check("空数据 → nil", FlacDurationHeader.site(inFileData: Data()) == nil)
check("超过 36 bit 拒绝", FlacDurationHeader.patched(five, totalSamples: 1 << 37) == nil)
check("0 拒绝", FlacDurationHeader.patched(five, totalSamples: 0) == nil)
check("秒→样本数", FlacDurationHeader.totalSamples(seconds: 332, sampleRate: 44_100) == 332 * 44_100)

print("\n— 判定与文案")
check("差 0.5 秒不修", !DurationRepairRules.needsRepair(declaredSec: 319, trueSec: 319.5))
check("差 13 秒要修", DurationRepairRules.needsRepair(declaredSec: 319, trueSec: 332))
check("文案 5:19 → 5:32（+13 秒）已修文件头",
      DurationRepairRules.summaryText(name: "半岛铁盒", declaredSec: 319, trueSec: 332,
                                     repaired: true).contains("5:19 → 5:32（+13 秒）已修文件头"))

print("\n结果：通过 \(pass) / 失败 \(fail.count)")
if !fail.isEmpty {
    for f in fail { print("  ✗ \(f)") }
    exit(1)
}
print("全部通过")
exit(0)
