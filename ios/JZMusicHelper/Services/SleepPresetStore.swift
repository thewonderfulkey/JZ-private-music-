import Foundation
import Observation

// MARK: - 用户自存的搭配组合
//
// 老板要的：「可以让用户自定义命名并自动添加在搭配组合」。
// 存 UserDefaults（一条组合就几个 id + 音量，不值得上数据库），
// 顺序按保存时间倒序，新的在前。
@MainActor
@Observable
final class SleepPresetStore {

    static let shared = SleepPresetStore()

    private(set) var custom: [SleepPreset] = []

    private let key = "sleep.customPresets.v1"

    private init() { load() }

    /// 存一条。同名的直接覆盖（避免越存越多）。
    @discardableResult
    func save(name: String, mix: [SleepMixItem]) -> SleepPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mix.isEmpty else { return nil }
        let finalName = trimmed.isEmpty ? "我的组合" : trimmed

        if let idx = custom.firstIndex(where: { $0.name == finalName }) {
            custom.remove(at: idx)
        }
        let preset = SleepPreset.make(id: UUID().uuidString, name: finalName, mix: mix)
        custom.insert(preset, at: 0)
        persist()
        return preset
    }

    func delete(_ id: String) {
        custom.removeAll { $0.id == id }
        persist()
    }

    // MARK: 落盘

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        custom = (try? JSONDecoder().decode([SleepPreset].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
