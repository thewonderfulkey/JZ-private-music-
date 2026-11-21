import AVFoundation
import CoreMedia
import Foundation

// MARK: - 音频标签内嵌（m4a / mp3）
//
// 目标：下载完成后把 标题/歌手/专辑/封面/歌词 **真正写进音频文件本身**，
// 这样文件被拷到别的机器、或者 App 的旁车文件被误删，歌词和封面依然跟着歌走。
//
// 安全原则（老板的要求本质是"离线也能看词看封面"，但绝不能因此把能放的歌写坏）：
//   · 永远**先写临时文件**。AVAssetExportSession 本来就必须有独立输出路径，
//     好处是导出失败时原文件一个字节都没动；mp3 同理，先拼好写临时文件。
//   · 临时文件成功后做**可读性校验**（体积 > 0，且 AVAsset 判定可播放），
//     校验通过才用 `FileManager.replaceItemAt` 原子替换原文件。
//   · 任何一步失败：删掉临时文件、保留原文件、返回 false。调用方仍有旁车兜底，
//     所以"内嵌失败"对用户只是少了一份可携带的副本，不是功能失效。
//
// 为什么要原子替换：直接往原文件写（截断再写）一旦中途失败/被系统杀掉，
// 文件就成了半截音频 —— 那才是真正的灾难。`replaceItemAt` 是同一个卷上的 rename：
// 要么旧文件完整，要么新文件完整，不存在中间态。
//
// 这个文件依赖 AVFoundation，不进 CI 的 swiftc 纯逻辑清单（那边只跑 Foundation 的
// `DownloadCompanion`）。所有 AVFoundation 调用都在静态函数里，无共享可变状态。
enum AudioTagEmbedder {

    // MARK: - m4a（AVFoundation metadata）

    /// 把 标题/歌手/专辑/封面/歌词 写进 m4a，成功则原子替换原文件。
    ///
    /// 用的是 `AVAssetExportPresetPassthrough` + `.m4a`：音频数据原样搬运，
    /// 只重组 metadata，不重新编码（不损音质，也快）。
    /// 歌词写 iTunes 的歌词键（`AVMetadataKey.iTunesMetadataKeyLyrics`），
    /// Apple Music / 文件 App / 大部分桌面播放器都能读到。
    ///
    /// - Returns: true = 已替换成功；false = 保持原文件不动（调用方按"未内嵌"处理）。
    static func embedM4A(fileURL: URL, title: String, artist: String, album: String,
                         coverData: Data?, lyrics: String) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return false }

        let metadata = makeMetadata(title: title, artist: artist, album: album,
                                    coverData: coverData, lyrics: lyrics)
        // 没有任何可写内容就别重写文件：无意义的 IO，还平白多一次失败面
        guard !metadata.isEmpty else { return false }

        // 临时文件必须和原文件同目录：跨卷 rename 不是原子的，replaceItemAt 会失败。
        // 隐藏文件名（.embed-…）避免在"文件"App 里闪一下临时文件。
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".embed-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: tempURL) }

        let asset = AVURLAsset(url: fileURL)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.m4a) else { return false }
        session.outputURL = tempURL
        session.outputFileType = .m4a
        session.metadata = metadata
        session.shouldOptimizeForNetworkUse = false

        // exportAsynchronously 是 iOS 18 起的弃用 API（替代品 export(to:as:) 要 iOS 18），
        // 但基线是 iOS 17，所以这里用 continuation 包一层旧 API；弃用只是警告，不影响行为。
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            session.exportAsynchronously {
                continuation.resume(returning: session.status == .completed)
            }
        }
        guard finished else { return false }

        // 导出"完成"不等于文件真能放：体积和可播放性都过一遍再替换
        guard await isReadableAudioFile(tempURL) else { return false }

        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - mp3（ID3v2.4）

    /// 把标签前置到 mp3（先剥掉已有 ID3v2 头，避免叠两层），写临时文件后原子替换。
    ///
    /// 只改文件头、不动音频帧：`DownloadCompanion.id3Tag` 产出的字节 + 原文件去掉
    /// 旧 ID3 头后的音频体，两者拼接。音频体一个字节不改，所以"能放"这件事不变。
    ///
    /// - Returns: true = 已替换成功；false = 保持原文件不动。
    static func embedMP3(fileURL: URL, title: String, artist: String, album: String,
                         coverData: Data?, coverMime: String, lyrics: String) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return false }

        // 整读进内存：mp3 一般 3~15MB，比分段改文件简单，也不会出现"改到一半"的中间态
        guard let original = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              !original.isEmpty else { return false }

        let body = stripID3v2(from: original)
        // 只有标签没有音频帧（或头长度损坏）→ 不写，避免造出"看起来有标签、其实不能放"的文件
        guard !body.isEmpty else { return false }

        let tag = DownloadCompanion.id3Tag(title: title, artist: artist, album: album,
                                           coverData: coverData, coverMime: coverMime,
                                           lyrics: lyrics)
        // 只有 10 字节空头 = 没有任何可写内容，不值得重写整个文件
        guard tag.count > 10 else { return false }

        var output = Data(capacity: tag.count + body.count)
        output.append(tag)
        output.append(body)

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".embed-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: tempURL) }

        do {
            try output.write(to: tempURL, options: .atomic)
        } catch {
            return false
        }

        // 校验一：临时文件体积必须和内存里算出来的完全一致（防磁盘写一半）
        // 校验二：头必须是刚写的 ID3v2.4（"ID3" + 0x04）
        guard let size = (try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64,
              size == Int64(output.count),
              let head = firstBytes(of: tempURL, count: 10), head.count == 10,
              head[0] == 0x49, head[1] == 0x44, head[2] == 0x33, head[3] == 0x04 else {
            return false
        }
        // 校验三：AVFoundation 能否识别并播放（mp3 与 ID3v2.4 是标准组合，正常不会失败）
        guard await isReadableAudioFile(tempURL) else { return false }

        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 只换封面（把"前端显示的那张图"写回文件本身）

    /// 封面写回的结果：换了 / 补了 / 本来就是同一张 / 容器不支持 / 失败。
    /// 分开计数是有意义的 —— 老板要能看出"到底补进去几张、跳过几张"。
    enum CoverEmbedOutcome: String, Sendable {
        case replaced
        case added
        case already
        case unsupported
        case failed
    }

    /// 把一张封面写进音频文件（**只动封面**，标题/歌手/专辑/歌词原样保留）。
    ///
    /// - mp3：`DownloadCompanion.ID3Artwork` 只换 APIC 帧，音频体原样搬；
    /// - m4a/mp4：AVFoundation 读出现有 metadata，去掉旧 artwork 换新的，passthrough 导出；
    /// - 其它容器（flac/ogg/wav…）：`.unsupported`（旁车仍是兜底，见 `DownloadCompanion` 头注释）。
    ///
    /// 任何一步失败都**保留原文件**（先写临时文件、校验通过才原子替换），调用方据此计数。
    static func alignArtwork(fileURL: URL, coverData: Data, coverMime: String) async -> CoverEmbedOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path), !coverData.isEmpty else { return .failed }
        switch fileURL.pathExtension.lowercased() {
        case "mp3":
            return await alignMP3(fileURL: fileURL, cover: coverData, mime: coverMime)
        case "m4a", "mp4":
            return await alignM4A(fileURL: fileURL, cover: coverData)
        default:
            return .unsupported
        }
    }

    /// mp3：只替换 APIC 帧。音频体（标签之后的所有字节）一个字节不改，
    /// 所以这里**不需要**再跑一遍 AVAsset 可播放校验（那一步 662 首要多花好几分钟）；
    /// 校验只看"临时文件体积等于算出来的字节数"和"头真的是 ID3v2.3/2.4"。
    private static func alignMP3(fileURL: URL, cover: Data, mime: String)
        async -> CoverEmbedOutcome {
        let fm = FileManager.default
        guard let original = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              !original.isEmpty else { return .failed }

        if let existing = DownloadCompanion.ID3Artwork.image(inFileData: original), existing == cover {
            return .already
        }
        let hadArtwork = DownloadCompanion.ID3Artwork.hasImage(inFileData: original)
        guard let output = DownloadCompanion.ID3Artwork.replacing(inFileData: original,
                                                                  cover: cover, mime: mime) else {
            return .failed
        }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".align-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: tempURL) }
        do {
            try output.write(to: tempURL, options: .atomic)
        } catch {
            return .failed
        }

        guard let size = (try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64,
              size == Int64(output.count),
              let head = firstBytes(of: tempURL, count: 4), head.count == 4,
              head[0] == 0x49, head[1] == 0x44, head[2] == 0x33,
              head[3] == 0x03 || head[3] == 0x04 else {
            return .failed
        }

        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
            return hadArtwork ? .replaced : .added
        } catch {
            return .failed
        }
    }

    /// m4a：读出现有 metadata，剔掉旧 artwork、换成新的，再 passthrough 导出（不重编码）。
    /// 这个容器要真的重写一遍，所以保留原来那条 `isReadableAudioFile` 闸门。
    private static func alignM4A(fileURL: URL, cover: Data) async -> CoverEmbedOutcome {
        let fm = FileManager.default
        let asset = AVURLAsset(url: fileURL)
        let existing = (try? await asset.load(.metadata)) ?? []

        var hadArtwork = false
        var items: [AVMetadataItem] = []
        for item in existing {
            if isArtworkItem(item) {
                hadArtwork = true
                if let data = item.dataValue, data == cover { return .already }
                continue
            }
            if let copy = mutableCopy(of: item) { items.append(copy) }
        }

        let artwork = AVMutableMetadataItem()
        artwork.keySpace = AVMetadataKeySpace.common
        artwork.key = AVMetadataKey.commonKeyArtwork.rawValue as NSString
        artwork.value = cover as NSData
        // 不写 dataType 时部分非 Apple 播放器不认这张封面；按文件头标 JPEG/PNG
        if cover.starts(with: [0xFF, 0xD8, 0xFF]) {
            artwork.dataType = kCMMetadataBaseDataType_JPEG as String
        } else if cover.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            artwork.dataType = kCMMetadataBaseDataType_PNG as String
        }
        items.append(artwork)

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".align-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: tempURL) }

        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough),
              session.supportedFileTypes.contains(.m4a) else { return .failed }
        session.outputURL = tempURL
        session.outputFileType = .m4a
        session.metadata = items
        session.shouldOptimizeForNetworkUse = false

        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            session.exportAsynchronously {
                continuation.resume(returning: session.status == .completed)
            }
        }
        guard finished, await isReadableAudioFile(tempURL) else { return .failed }

        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
            return hadArtwork ? .replaced : .added
        } catch {
            return .failed
        }
    }

    /// 这个 metadata 项是不是封面
    private static func isArtworkItem(_ item: AVMetadataItem) -> Bool {
        item.commonKey == .commonKeyArtwork
            || (item.keySpace == .common
                && (item.key as? String) == AVMetadataKey.commonKeyArtwork.rawValue)
    }

    /// 现有 metadata 项 → 可变副本（导出时直接吃 `AVMetadataItem`，转一份最稳）
    private static func mutableCopy(of item: AVMetadataItem) -> AVMutableMetadataItem? {
        guard let key = item.key, let space = item.keySpace else { return nil }
        let copy = AVMutableMetadataItem()
        copy.keySpace = space
        copy.key = key
        copy.value = item.value
        copy.dataType = item.dataType
        return copy
    }

    // MARK: - metadata 组装

    /// m4a 的 metadata：common 键（标题/歌手/专辑/封面）+ iTunes 歌词键。
    /// 空值不写：宁可没有这一项，也不要写一个空字符串让播放器显示空白。
    private static func makeMetadata(title: String, artist: String, album: String,
                                     coverData: Data?, lyrics: String) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func addCommonText(_ key: AVMetadataKey, _ value: String) {
            let text = value.replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = AVMetadataKeySpace.common
            item.key = key.rawValue as NSString
            item.value = text as NSString
            items.append(item)
        }

        addCommonText(.commonKeyTitle, title)
        addCommonText(.commonKeyArtist, artist)
        addCommonText(.commonKeyAlbumName, album)

        if let coverData, !coverData.isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = AVMetadataKeySpace.common
            item.key = AVMetadataKey.commonKeyArtwork.rawValue as NSString
            item.value = coverData as NSData
            // 不写 dataType 时，部分非 Apple 播放器不认这张封面；按文件头标出 JPEG/PNG
            if coverData.starts(with: [0xFF, 0xD8, 0xFF]) {
                item.dataType = kCMMetadataBaseDataType_JPEG as String
            } else if coverData.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                item.dataType = kCMMetadataBaseDataType_PNG as String
            }
            items.append(item)
        }

        let lyricsText = lyrics.replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !lyricsText.isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = AVMetadataKeySpace.iTunes
            item.key = AVMetadataKey.iTunesMetadataKeyLyrics.rawValue as NSString
            item.value = lyricsText as NSString
            items.append(item)
        }

        return items
    }

    // MARK: - 文件校验 / ID3 头剥离

    /// 文件存在、体积 > 0、且 AVFoundation 判定可播放。
    /// 这是"替换前的最后一道闸"：任何一项不满足都保留原文件。
    private static func isReadableAudioFile(_ url: URL) async -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              size > 0 else { return false }
        do {
            let playable = try await AVURLAsset(url: url).load(.isPlayable)
            return playable
        } catch {
            return false
        }
    }

    /// 剥掉文件开头已有的 ID3v2 标签，返回音频体。
    ///
    /// 为什么必须剥：直接前置新标签会把旧标签留在中间，解码器读到第一个标签就停，
    /// 旧标签之后才是新标签 —— 播放器看到的是**旧**信息；文件也会一次次变大。
    ///
    /// 支持 v2.2（3 字节长度）/v2.3/v2.4（4 字节 syncsafe），v2.4 还可能有 footer。
    /// 头不合法/长度超过文件 → 返回空 Data（调用方据此放弃内嵌，不冒险写）。
    private static func stripID3v2(from data: Data) -> Data {
        guard data.count >= 10 else { return data }
        let header = [UInt8](data.prefix(10))
        // "ID3"
        guard header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return data }

        let version = header[3]
        var tagSize = 0
        if version < 3 {
            // v2.2：长度是 3 个 syncsafe 字节（6..8）
            tagSize = (Int(header[6] & 0x7F) << 14)
                | (Int(header[7] & 0x7F) << 7)
                | Int(header[8] & 0x7F)
        } else {
            tagSize = (Int(header[6] & 0x7F) << 21)
                | (Int(header[7] & 0x7F) << 14)
                | (Int(header[8] & 0x7F) << 7)
                | Int(header[9] & 0x7F)
        }

        var total = 10 + tagSize
        // v2.4 的 footer（标志位 0x10）不算在 size 里，额外占 10 字节
        if version >= 4, header[5] & 0x10 != 0 { total += 10 }
        guard total >= 10, total < data.count else { return Data() }
        return data.subdata(in: total..<data.count)
    }

    /// 只读文件开头 n 个字节（不整读文件）
    private static func firstBytes(of url: URL, count: Int) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return [UInt8](handle.readData(ofLength: count))
    }
}
