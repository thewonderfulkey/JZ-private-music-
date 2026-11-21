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

    // MARK: - 把歌曲信息写进音频文件（封面 + 歌名/歌手/专辑/时长/歌词）

    /// 写回的结果：换了 / 补了（原来没有标签或封面）/ 本来就是这一套 / 容器不支持 / 失败。
    /// 分开计数是有意义的 —— 老板要能看出"到底补进去几张、跳过几张"。
    enum CoverEmbedOutcome: String, Sendable {
        case replaced
        case added
        case already
        case unsupported
        case failed
    }

    /// 把一首歌的字段写进音频文件本身（**只动我们认识的那几帧**，别的标签原样保留）。
    ///
    /// - mp3：`DownloadCompanion.ID3Tags`（只替换 TIT2/TPE1/TALB/TLEN/APIC/USLT，音频体原样搬）；
    /// - flac：`DownloadCompanion.FlacTags`（Vorbis Comment + PICTURE，音频帧原样搬）；
    /// - m4a/mp4：AVFoundation 读出现有 metadata，换掉同名项后 passthrough 导出；
    /// - 其它容器（wav/ape/ogg…）：`.unsupported`（旁车仍是兜底，见 `DownloadCompanion` 头注释）。
    ///
    /// 任何一步失败都**保留原文件**（先写临时文件、校验通过才原子替换），调用方据此计数。
    static func writeTags(fileURL: URL,
                          fields: DownloadCompanion.ID3Tags.Fields) async -> CoverEmbedOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path), !fields.isEmpty else { return .failed }
        // 第 53 轮：按**文件头**选写入器（扩展名可能骗人：.flac 里装的是 mp3/m4a）
        switch container(of: fileURL) {
        case .mp3:
            return await writeMP3(fileURL: fileURL, fields: fields)
        case .flac:
            return await writeFLAC(fileURL: fileURL, fields: fields)
        case .m4a:
            return await writeM4A(fileURL: fileURL, fields: fields)
        case .ogg, .wav, .ape, .unknown:
            return .unsupported
        }
    }

    /// mp3：只替换那几帧，**音频体走流式拷贝**（第 52 轮：不再把整首读进内存，
    /// 真机峰值从 815MB 降下来）。结构校验：新标签头必须是 ID3v2.3/2.4、体积必须对得上。
    private static func writeMP3(fileURL: URL, fields: DownloadCompanion.ID3Tags.Fields)
        async -> CoverEmbedOutcome {
        guard let head = firstBytes(of: fileURL, count: 10),
              let tagLength = DownloadCompanion.ID3Tags.tagLength(headBytes: head) else { return .failed }
        var tagBytes: [UInt8] = []
        if tagLength > 0 {
            guard let bytes = firstBytes(of: fileURL, count: tagLength),
                  bytes.count == tagLength else { return .failed }
            tagBytes = bytes
        }

        let current = DownloadCompanion.ID3Tags.reading(inFileData: Data(tagBytes))
        if DownloadCompanion.ID3Tags.satisfied(fields, by: current) { return .already }
        let hadCover = !(current.cover?.isEmpty ?? true)

        guard let newTag = DownloadCompanion.ID3Tags.rewriting(tagBytes: Data(tagBytes),
                                                               fields: fields) else { return .failed }
        let newHead = [UInt8](newTag.prefix(4))
        guard newHead.count == 4, newHead[0] == 0x49, newHead[1] == 0x44, newHead[2] == 0x33,
              (newHead[3] == 0x03 || newHead[3] == 0x04) else { return .failed }

        guard await streamRewrite(fileURL: fileURL, header: newTag,
                                  copyFrom: tagLength, suffix: "mp3") else { return .failed }
        return hadCover ? .replaced : .added
    }

    /// flac：重建元数据区（STREAMINFO 保留、VORBIS_COMMENT 重写、front cover PICTURE 换掉），
    /// 音频帧流式拷贝；前置 ID3v2 按设计丢掉。
    private static func writeFLAC(fileURL: URL, fields: DownloadCompanion.ID3Tags.Fields)
        async -> CoverEmbedOutcome {
        guard let prefixBytes = firstBytes(of: fileURL, count: metadataProbeLimit) else { return .failed }
        let prefix = Data(prefixBytes)

        let current = DownloadCompanion.FlacTags.reading(inFileData: prefix)
        if DownloadCompanion.FlacTags.matches(fields, inFileData: prefix) { return .already }
        let hadCover = !(current.cover?.isEmpty ?? true)

        guard let plan = DownloadCompanion.FlacTags.rewritingMetadata(prefix: prefix,
                                                                      fields: fields) else { return .failed }
        let newHead = [UInt8](plan.metadata.prefix(4))
        guard newHead == [0x66, 0x4C, 0x61, 0x43] else { return .failed }

        guard await streamRewrite(fileURL: fileURL, header: plan.metadata,
                                  copyFrom: plan.audioStart, suffix: "flac") else { return .failed }
        return hadCover ? .replaced : .added
    }

    /// 流式写盘：先把 `header`（新标签/新元数据）写到临时文件，再把源文件从 `copyFrom` 起
    /// 1MB 一块拷过去，体积校验通过后原子替换。
    ///
    /// 为什么要流式：662 首里不少是 20–100MB 的 FLAC，以前每首都要"整文件读进内存 + 再拼一份"，
    /// 三首并发就能把峰值顶到 800MB（`诊断/life.log` 实测），既容易被系统杀，也容易写失败。
    private static func streamRewrite(fileURL: URL, header: Data,
                                      copyFrom: Int, suffix: String) async -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64, size > 0,
              Int64(copyFrom) <= size,
              let source = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? source.close() }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tags-\(UUID().uuidString).\(suffix)")
        fm.createFile(atPath: tempURL.path, contents: nil)
        guard let sink = try? FileHandle(forWritingTo: tempURL) else {
            try? fm.removeItem(at: tempURL)
            return false
        }
        do {
            try sink.write(contentsOf: header)
            try source.seek(toOffset: UInt64(copyFrom))
            while true {
                guard let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try sink.write(contentsOf: chunk)
            }
            try sink.synchronize()
            try sink.close()
        } catch {
            try? sink.close()
            try? fm.removeItem(at: tempURL)
            return false
        }

        // 体积必须 = 新头 + 原音频长度（防止拷一半）
        let expected = Int64(header.count) + (size - Int64(copyFrom))
        guard let written = (try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64,
              written == expected else {
            try? fm.removeItem(at: tempURL)
            return false
        }

        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
            return true
        } catch {
            try? fm.removeItem(at: tempURL)
            return false
        }
    }

    /// 真实容器（**看文件头，不看扩展名**）。第 53 轮：老板那份名单里有 13 首"全 missing"，
    /// 最可能是「扩展名 .flac、内容其实是 mp3/m4a」——r120 踩过同一个坑。
    static func container(of fileURL: URL) -> DownloadCompanion.AudioContainer {
        guard let prefix = firstBytes(of: fileURL, count: 4096) else { return .unknown }
        return DownloadCompanion.AudioSniff.container(prefix: prefix)
    }

    /// 这个文件能不能写标签（按**真实容器**判断）
    static func canWriteTags(fileURL: URL) -> Bool {
        container(of: fileURL).canWriteTags
    }

    /// 从文件里**读**出那一套字段（A 方案：文件是真相）。
    /// 第 52 轮起只读文件开头（最多 16MB / 标签区），不再把整个文件读进内存；
    /// 第 53 轮起按**文件头**判断容器（扩展名不再可信）。
    static func readFields(fileURL: URL) async -> DownloadCompanion.ID3Tags.Fields? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        switch container(of: fileURL) {
        case .mp3:
            guard let head = firstBytes(of: fileURL, count: 10),
                  let length = DownloadCompanion.ID3Tags.tagLength(headBytes: head) else { return nil }
            guard length > 0 else { return DownloadCompanion.ID3Tags.Fields() }
            guard let tag = firstBytes(of: fileURL, count: length), tag.count == length else { return nil }
            return DownloadCompanion.ID3Tags.reading(inFileData: Data(tag))
        case .flac:
            guard let prefix = firstBytes(of: fileURL, count: metadataProbeLimit) else { return nil }
            return DownloadCompanion.FlacTags.reading(inFileData: Data(prefix))
        case .m4a:
            return await readM4A(fileURL: fileURL)
        case .ogg, .wav, .ape, .unknown:
            return nil
        }
    }

    /// 读元数据时最多读这么多（封面 + 歌词 + 其它块都在里面；512KB 的封面也就这个量级）
    static let metadataProbeLimit = 16 << 20

    private static func readM4A(fileURL: URL) async -> DownloadCompanion.ID3Tags.Fields? {
        let asset = AVURLAsset(url: fileURL)
        guard let items = try? await asset.load(.metadata) else { return nil }
        var out = DownloadCompanion.ID3Tags.Fields()
        for item in items {
            if isArtworkItem(item) {
                if out.cover == nil, let data = item.dataValue, !data.isEmpty { out.cover = data }
                continue
            }
            let key = item.key as? String
            if item.keySpace == .common, let key {
                switch key {
                case AVMetadataKey.commonKeyTitle.rawValue:
                    if let text = item.stringValue, out.title.isEmpty { out.title = text }
                case AVMetadataKey.commonKeyArtist.rawValue:
                    if let text = item.stringValue, out.artist.isEmpty { out.artist = text }
                case AVMetadataKey.commonKeyAlbumName.rawValue:
                    if let text = item.stringValue, out.album.isEmpty { out.album = text }
                default:
                    break
                }
                continue
            }
            if item.keySpace == .iTunes, key == AVMetadataKey.iTunesMetadataKeyLyrics.rawValue,
               let text = item.stringValue, !text.isEmpty {
                out.lyrics = text
            }
        }
        return out
    }

    /// m4a：读出现有 metadata，换掉同名项（标题/歌手/专辑/封面/歌词），其余项原样保留，
    /// 再 passthrough 导出（不重编码）。这个容器要真的重写一遍，所以保留可播放性闸门。
    private static func writeM4A(fileURL: URL, fields: DownloadCompanion.ID3Tags.Fields)
        async -> CoverEmbedOutcome {
        let fm = FileManager.default
        let asset = AVURLAsset(url: fileURL)
        let existing = (try? await asset.load(.metadata)) ?? []

        let replaced = replacedCommonKeys(fields)
        var hadCover = false
        var items: [AVMetadataItem] = []
        var sameAsWanted = true

        for item in existing {
            if isArtworkItem(item) {
                hadCover = true
                if let data = item.dataValue, let cover = fields.cover, data == cover {
                    // 图一样，继续看文字项
                } else {
                    sameAsWanted = false
                }
                continue
            }
            if let key = item.key as? String, replaced.contains(key), item.keySpace == .common {
                // 这一项我们要重写：顺便看看值是不是已经一样
                if let want = wantedText(for: key, fields: fields),
                   item.stringValue != want {
                    sameAsWanted = false
                }
                continue
            }
            if let copy = mutableCopy(of: item) { items.append(copy) }
        }
        if hadCover == false, fields.cover != nil { sameAsWanted = false }
        if sameAsWanted { return .already }

        // 文字项：空值不写（"缺这一项"比"写一个空字符串"友好）
        func addText(_ key: AVMetadataKey, _ value: String) {
            let text = value.replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = AVMetadataKeySpace.common
            item.key = key.rawValue as NSString
            item.value = text as NSString
            items.append(item)
        }
        addText(.commonKeyTitle, fields.title)
        addText(.commonKeyArtist, fields.artist)
        addText(.commonKeyAlbumName, fields.album)

        if let cover = fields.cover, !cover.isEmpty {
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
        }

        if let lyrics = fields.lyrics,
           !DownloadCompanion.ID3Tags.trim(lyrics).isEmpty {
            let item = AVMutableMetadataItem()
            item.keySpace = AVMetadataKeySpace.iTunes
            item.key = AVMetadataKey.iTunesMetadataKeyLyrics.rawValue as NSString
            item.value = DownloadCompanion.ID3Tags.trim(lyrics) as NSString
            items.append(item)
        }

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".tags-\(UUID().uuidString).m4a")
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
            return hadCover ? .replaced : .added
        } catch {
            return .failed
        }
    }

    /// 这次要重写的 common 键（m4a）
    private static func replacedCommonKeys(_ fields: DownloadCompanion.ID3Tags.Fields) -> Set<String> {
        var keys: Set<String> = []
        if !DownloadCompanion.ID3Tags.trim(fields.title).isEmpty {
            keys.insert(AVMetadataKey.commonKeyTitle.rawValue)
        }
        if !DownloadCompanion.ID3Tags.trim(fields.artist).isEmpty {
            keys.insert(AVMetadataKey.commonKeyArtist.rawValue)
        }
        if !DownloadCompanion.ID3Tags.trim(fields.album).isEmpty {
            keys.insert(AVMetadataKey.commonKeyAlbumName.rawValue)
        }
        return keys
    }

    private static func wantedText(for key: String,
                                   fields: DownloadCompanion.ID3Tags.Fields) -> String? {
        switch key {
        case AVMetadataKey.commonKeyTitle.rawValue:
            return DownloadCompanion.ID3Tags.trim(fields.title)
        case AVMetadataKey.commonKeyArtist.rawValue:
            return DownloadCompanion.ID3Tags.trim(fields.artist)
        case AVMetadataKey.commonKeyAlbumName.rawValue:
            return DownloadCompanion.ID3Tags.trim(fields.album)
        default:
            return nil
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
