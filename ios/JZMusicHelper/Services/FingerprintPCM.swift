import Foundation

// MARK: - 指纹输入：8k / 单声道 / 16bit → Float32 小端 base64
//
// 网易的 afp 指纹引擎（wasm）要的是 **Float32** 采样，而酷狗要的是 Int16 裸 PCM。
// 采集层统一产出 Int16，所以这里做一次转换（纯函数，CI 可断言）。
//
// 与 Android `NeteaseFingerprint.to8kFloatB64` 同口径：只取**最后 12 秒**
// （更靠后的那段才是用户刚听到的），不足 1 秒直接返回 nil。
enum FingerprintPCM {

    static let sampleRate = 8_000
    static let windowSeconds = 12

    /// Int16LE PCM → Float32LE 的 base64（值域 −1…1）
    static func float32Base64(pcm16: Data,
                              sampleRate: Int = FingerprintPCM.sampleRate,
                              seconds: Int = FingerprintPCM.windowSeconds) -> String? {
        guard sampleRate > 0, seconds > 0 else { return nil }
        guard pcm16.count >= sampleRate * 2 else { return nil }

        let total = pcm16.count / 2
        let need = sampleRate * seconds
        let start = max(0, total - need)

        var out = Data()
        out.reserveCapacity((total - start) * 4)
        var index = pcm16.startIndex + start * 2
        while index + 1 < pcm16.endIndex {
            let low = UInt16(pcm16[index])
            let high = UInt16(pcm16[index + 1])
            let sample = Int16(bitPattern: low | (high << 8))
            var bits = (Float(sample) / 32768).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
            index += 2
        }

        // 至少 1 秒，太短没有识别价值
        guard out.count >= sampleRate * 4 else { return nil }
        return out.base64EncodedString()
    }

    /// 把 base64 解回 Float32 采样（测试与排查用）
    static func floats(fromBase64 base64: String) -> [Float] {
        guard let data = Data(base64Encoded: base64) else { return [] }
        return stride(from: 0, to: data.count - 3, by: 4).map { offset in
            let bits = UInt32(data[data.startIndex + offset])
                | (UInt32(data[data.startIndex + offset + 1]) << 8)
                | (UInt32(data[data.startIndex + offset + 2]) << 16)
                | (UInt32(data[data.startIndex + offset + 3]) << 24)
            return Float(bitPattern: bits)
        }
    }
}
