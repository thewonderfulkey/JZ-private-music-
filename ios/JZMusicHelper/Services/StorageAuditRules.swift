import Foundation

// MARK: - 存储自检的**纯规则**（2026-11-22 老板："空间 20 多 G 变 40 多 G，我找不到多余的文件"）
//
// 为什么单独一个文件：这几条要被 CI 的断言直接喂（`SelfTest` 只编"纯逻辑"那一批文件，
// 不编 `DownloadManager` / `DownloadLocation` 这些要真机环境的东西）。
// 真正去量磁盘的那一半在 `StorageAudit.swift`。
//
// 判定口径（都在这里，别散到 View 里）：
//   · 写标签留下的隐藏临时文件：`AudioTagEmbedder` 生成的是 `.tags-<UUID>.<ext>` / `.embed-<UUID>.m4a`；
//   · 孤儿音频：`Music/` 里**没有任何一条记录指向**的音频（只比文件名，保守，宁可漏删不误删）。
enum StorageAuditRules {

    /// 写标签时留下的隐藏临时文件（`AudioTagEmbedder` 的命名，别改那边不改这里）
    static func isTagTempArtifact(_ name: String) -> Bool {
        name.hasPrefix(".tags-") || name.hasPrefix(".embed-")
    }

    /// 算不算"音频文件"（按扩展名；孤儿清理只动这些，不碰 .lrc / .jpg / 其它）
    static func isAudio(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ImportRules.playableExtensions.contains(ext)
    }

    /// 孤儿判定：`Music/` 里**没有任何一条记录指向**的音频。
    ///
    /// `referenced` 里放的是"记录认得出这个文件"的所有名字：`localPath` 的最后一段 + `fileName`。
    /// 只比名字不比完整路径（保守）：同名的文件在别处也会被当成"有人用"，宁可漏删也不误删。
    /// 点开头的隐藏文件走"临时残留"那一类，不在这里判。
    static func isOrphan(fileName: String, referenced: Set<String>) -> Bool {
        guard !fileName.hasPrefix(".") else { return false }
        guard isAudio(fileName) else { return false }
        return !referenced.contains(fileName)
    }

    /// 记录集合 → "被引用文件名"集合（纯函数，CI 断言）
    static func referencedNames(_ items: [DownloadItem]) -> Set<String> {
        var out = Set<String>()
        for item in items {
            if !item.fileName.isEmpty { out.insert(item.fileName) }
            if let path = item.localPath, !path.isEmpty {
                out.insert((path as NSString).lastPathComponent)
            }
        }
        return out
    }
}
