import SwiftUI
import PhotosUI
import UIKit

// MARK: - 编辑歌曲信息（第 44 轮，2026-11-21 老板需求）
//
// 老板原话："给下载 tab 中加一个可以自己修改歌曲信息的功能（可修改封面、歌手、歌曲名称），
//          人工修改后用修改后的信息去获取封面然后内置形成快照，是否可行？"
//
// 设计口径（已拍板）：
//   · 改过的字段**锁住**（`meta.locked`），自动匹配永不覆盖；点「恢复自动」才解锁；
//   · 只改歌手 → 歌名/专辑/封面保留，封面标 `coverStale`（旧图可能不对）但不删；
//   · 不选新图 → 用改后的「歌名+歌手」重新联网匹配封面（走 B4 同一条兜底链）；
//   · 选新图 → 居中方形裁剪 → 600px JPEG → 覆盖 `Cover/<基名>.jpg` → 代次 +1（三处缓存失效）；
//   · **绝不改音频文件名/基名**（旁车 LRC/JPG 靠基名关联，改名会让已落的词图全串）。
//
// 所有写回都走 `MetadataWriter`（四处快照 + 三处缓存），这里不自己赋值。

struct SongMetadataEditor: View {

    let item: DownloadItem
    /// 保存结果的一句话（页面已经关了，靠列表页的轻提示告诉老板成不成）
    var onSaved: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var singer = ""
    @State private var album = ""
    @State private var photo: PhotosPickerItem?
    /// 已经裁成方形、压到 600px 的 JPEG（用户选了新封面才非空）
    @State private var pickedCover: Data?
    @State private var busy = false
    @State private var message: String?
    @State private var suggestion: Song?
    /// 第 51 轮 A 方案：从**音频文件里读出来**的那一套（文件是真相，列表只是显示）
    @State private var fileFields: DownloadCompanion.ID3Tags.Fields?
    /// 文件读不出来（容器不支持 / 读失败）时置 true，界面上直说"读不了"
    @State private var fileUnreadable = false

    var body: some View {
        NavigationStack {
            Form {
                // 第 45 轮（老板 2026-11-21）：**把原文件名露出来**。
                // 导入的歌常是 `Converted… [SUNO V5]…` 这种，改信息时看不到原名就只能靠猜；
                // 只读展示（不许改），因为歌词/封面旁车是按这个基名关联的。
                Section {
                    LabeledContent("原文件名") {
                        Text(fileName)
                            .font(.footnote.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("文件")
                }

                Section {
                    TextField("歌名（必填）", text: $name)
                    TextField("歌手", text: $singer)
                    TextField("专辑", text: $album)
                } header: {
                    Text("歌曲信息")
                } footer: {
                    Text("改过的字段会被锁住，以后自动匹配不会覆盖它。只改信息，**不会改音频文件名**。")
                }

                Section {
                    HStack(spacing: Tokens.Spacing.m) {
                        coverPreview
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            PhotosPicker(selection: $photo, matching: .images,
                                         photoLibrary: .shared()) {
                                Label("从相册选封面", systemImage: "photo")
                            }
                            if pickedCover != nil {
                                Button("取消这张图") { pickedCover = nil; photo = nil }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text("不选图就用改后的歌名+歌手重新联网找封面")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("封面")
                }

                if let suggestion {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("匹配到可能的版本（\(String(format: "%.2f", suggestion.meta?.score ?? 0)) 分）")
                                .font(.footnote)
                            Text("\(suggestion.name) · \(suggestion.singer)"
                                 + (suggestion.album.isEmpty ? "" : " · \(suggestion.album)"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("采用这个") {
                                MetadataWriter.acceptSuggestion(suggestion, for: item.song)
                                self.suggestion = nil
                                dismiss()
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    } header: {
                        Text("待确认")
                    }
                }

                // 第 51 轮 A 方案：把"文件里现在到底是什么"摊出来。
                // 以前这里只有一个输入框，改了以后要猜"文件里有没有跟着变" —— 现在直接对照着看。
                fileTruthSection

                Section {
                    Button {
                        Task { await runRematch(force: true) }
                    } label: {
                        Label("用现在的名字重新联网匹配", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) {
                        Task { await runReset() }
                    } label: {
                        Label("恢复自动（解锁全部字段）", systemImage: "arrow.uturn.backward")
                    }
                } footer: {
                    Text("「重新匹配」只填没锁的字段；「恢复自动」会清掉手填值与封面，回到自动匹配。")
                }

                if let meta = item.song.meta {
                    Section {
                        LabeledContent("当前来源", value: meta.source.label)
                        if !meta.locked.isEmpty {
                            LabeledContent("手填锁定",
                                           value: meta.locked.map(\.label).joined(separator: "、"))
                        }
                        if meta.coverStale {
                            Text("封面可能已不匹配（改过歌名/歌手）")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("来源")
                    }
                }

                if let message {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑歌曲信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .task(id: photo?.itemIdentifier) { await loadPickedPhoto() }
            .task { await loadFileTruth() }
            .onAppear {
                name = item.song.name
                singer = item.song.singer
                album = item.song.album
                suggestion = item.matchSuggest
            }
        }
    }

    @ViewBuilder
    private var coverPreview: some View {
        Group {
            if let pickedCover, let image = UIImage(data: pickedCover) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                SongArtwork(song: item.song, size: 72, radius: Tokens.Radius.artworkSmall)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.artworkSmall, style: .continuous))
    }

    // MARK: 文件

    /// 磁盘上的原始文件名（含扩展名）。找不到本地文件就说明还没落盘。
    private var fileName: String {
        guard let path = item.localPath, !path.isEmpty else { return "（还没有本地文件）" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: 文件里现在是（第 51 轮 A 方案）

    /// 只读展示**音频文件里**现有的标签，并提供「以文件为准」。
    /// 为什么要有这一块：以前这里只有输入框，改完保存只能靠"相信"写回成功；
    /// 现在文件里的值和列表上的值并排放着，不一致一眼就能看见。
    @ViewBuilder
    private var fileTruthSection: some View {
        Section {
            if fileUnreadable {
                Text("这个容器读不出标签（wav / ape / ogg 之类），文件里写了什么只能靠 Cover / Lyrics 旁车。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let f = fileFields {
                LabeledContent("歌名", value: f.title.isEmpty ? "（空）" : f.title)
                LabeledContent("歌手", value: f.artist.isEmpty ? "（空）" : f.artist)
                LabeledContent("专辑", value: f.album.isEmpty ? "（空）" : f.album)
                LabeledContent("封面", value: (f.cover?.isEmpty == false) ? "已内嵌" : "没有")
                LabeledContent("歌词", value: (f.lyrics?.isEmpty == false) ? "已内嵌" : "没有")
                Button("以文件为准（覆盖列表）") { adoptFileTruth(f) }
            } else {
                HStack(spacing: Tokens.Spacing.xs) {
                    ProgressView().scaleEffect(0.8)
                    Text("正在读文件里的标签…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("文件里现在是")
        } footer: {
            Text("A 方案：音频文件里的标签是真相，列表只是显示。「以文件为准」会用上面的值覆盖列表，"
                 + "并把文件里的封面/歌词同步成 Cover / Lyrics 旁车（旁车只是缓存）。空着的项不会清空列表。")
        }
    }

    @MainActor
    private func loadFileTruth() async {
        guard let path = item.localPath, !path.isEmpty else {
            fileUnreadable = true
            return
        }
        if let fields = await AudioTagEmbedder.readFields(fileURL: URL(fileURLWithPath: path)) {
            fileFields = fields
        } else {
            fileUnreadable = true
        }
    }

    /// 用文件里的值覆盖列表（A 方案："以文件为准"这条路必须真的存在，不能只是口号）
    @MainActor
    private func adoptFileTruth(_ f: DownloadCompanion.ID3Tags.Fields) {
        var edited = MetadataMatcher.applyingManualEdit(
            to: item.song,
            name: f.title.isEmpty ? item.song.name : f.title,
            singer: f.artist.isEmpty ? item.song.singer : f.artist,
            album: f.album.isEmpty ? item.song.album : f.album,
            cover: nil)
        var coverSynced = false
        if let path = item.localPath, !path.isEmpty {
            let audio = URL(fileURLWithPath: path)
            let sidecars = DownloadCompanion.writeSidecars(
                audio: audio,
                lyricsText: (f.lyrics?.isEmpty == false) ? f.lyrics : nil,
                coverData: (f.cover?.isEmpty == false) ? f.cover : nil,
                lyricsDirectory: DownloadManager.shared.lyricsDirectory,
                coverDirectory: DownloadManager.shared.coverDirectory)
            coverSynced = sidecars.coverURL != nil
        }
        if coverSynced {
            edited = MetadataWriter.coverChanged(edited, picURL: nil)
        } else {
            MetadataWriter.apply(edited)
        }
        onSaved("已按文件里的信息更新列表")
        dismiss()
    }

    // MARK: 相册

    @MainActor
    private func loadPickedPhoto() async {
        guard let photo else { return }
        guard let data = try? await photo.loadTransferable(type: Data.self) else {
            message = "这张图读不出来，换一张试试。"
            return
        }
        guard let square = MetadataCoverImage.squareJPEG(data, side: 600) else {
            message = "这张图解码失败，换一张试试。"
            return
        }
        pickedCover = square
        message = nil
    }

    // MARK: 保存

    /// 保存：**先把字段写进列表，再立刻关页面**，联网补全全部转后台。
    ///
    /// 老板 2026-11-21 录屏原话："点击保存后还停留在当前页面属实是用户体验不好"。
    /// 以前这里是 `await rematch(...)` 跑完仍不 `dismiss()`，只在表单底部写一句
    /// "已保存，并按新名字补全了专辑/封面/歌词。"——而补料其实只是**入队**，图还没落盘，
    /// 页面又不关，老板看到的就是"一切都停在原地"。现在：写字段 → 关页面 → 后台补图补词。
    @MainActor
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "歌名不能为空。"; return }

        var edited = MetadataMatcher.applyingManualEdit(to: item.song, name: trimmed,
                                                        singer: singer, album: album,
                                                        cover: pickedCover != nil ? .cover : nil)
        var coverWriteFailed = false
        if let data = pickedCover {
            // 自选封面：先落盘（基名不变），代次 +1 让列表/锁屏/内存缓存一起换图
            if let path = item.localPath,
               let url = MetadataCoverImage.writeSidecar(data, audioPath: path) {
                CoverImageCache.shared.invalidate(url: url)
                edited = MetadataWriter.coverChanged(edited, picURL: nil)
                // 第 48/49 轮（老板：前台换了封面/信息，文件里还是旧的 → 要对齐）：
                // 保存完立刻把**这一套**（歌名/歌手/专辑/封面/歌词）写回音频文件本身（后台跑，不挡关页面）。
                DownloadManager.shared.writeSongInfo(for: edited)
            } else {
                coverWriteFailed = true
                MetadataWriter.apply(edited)
            }
        } else {
            MetadataWriter.apply(edited)
        }

        // 关页面（不等网络）。列表这一行立刻能看到新的歌名/歌手/专辑。
        dismiss()
        if coverWriteFailed { onSaved("封面写盘失败，歌曲信息已保存") }

        Task { @MainActor in
            let outcome = await MetadataWriter.rematch(edited, force: false)
            switch outcome.verdict {
            case .auto: onSaved("已保存，正在补全专辑/封面/歌词")
            case .confirm: onSaved("已保存，匹配到一个版本，可再点开确认")
            case .reject: onSaved("已保存（词源里没匹配到这一版）")
            }
        }
    }

    @MainActor
    private func runRematch(force: Bool) async {
        busy = true
        defer { busy = false }
        let outcome = await MetadataWriter.rematch(item.song, force: force)
        switch outcome.verdict {
        case .auto: message = "已匹配并写回。"
        case .confirm: message = "匹配到可能的版本，看看上面的「待确认」。"
        case .reject: message = "没匹配到（词源里没有这一版），可手动改。"
        }
    }

    @MainActor
    private func runReset() async {
        busy = true
        defer { busy = false }
        _ = await MetadataWriter.resetToAuto(item.song)
        message = "已恢复自动，正在重新匹配…"
    }
}

// MARK: - 批量编辑（只改歌手/专辑）

struct BatchMetadataEditor: View {

    let items: [DownloadItem]

    @Environment(\.dismiss) private var dismiss
    @State private var singer = ""
    @State private var album = ""
    @State private var applySinger = true
    @State private var applyAlbum = true
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("改歌手", isOn: $applySinger)
                    TextField("歌手", text: $singer).disabled(!applySinger)
                    Toggle("改专辑", isOn: $applyAlbum)
                    TextField("专辑", text: $album).disabled(!applyAlbum)
                } footer: {
                    Text("将改 \(items.count) 首。只改这里填的字段并锁住它们；歌名与封面不动。")
                }
            }
            .navigationTitle("批量编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                        .disabled(items.isEmpty || (!applySinger && !applyAlbum))
                }
            }
        }
    }

    @MainActor
    private func apply() {
        for item in items {
            let nextSinger = applySinger ? singer : item.song.singer
            let nextAlbum = applyAlbum ? album : item.song.album
            let edited = MetadataMatcher.applyingManualEdit(to: item.song, name: item.song.name,
                                                             singer: nextSinger, album: nextAlbum,
                                                             cover: nil)
            MetadataWriter.apply(edited)
            // 交给补料队列（并发 ≤4）去按新信息取词取图 —— 这里绝不起 N 个并发搜索
            DownloadManager.shared.enqueueCompanionFill(itemID: item.id)
        }
        dismiss()
    }
}

// MARK: - 封面图处理（方形裁剪 + 压 600 + 写旁车）

enum MetadataCoverImage {

    /// 居中方形裁剪 → 600×600 JPEG（复用 App 现有的"压 600"口径，别再造一套尺寸）
    static func squareJPEG(_ data: Data, side: Int = 600) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let target = CGFloat(max(64, side))
        let scale = max(target / w, target / h)
        let draw = CGRect(x: (target - w * scale) / 2, y: (target - h * scale) / 2,
                          width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target))
        let out = renderer.image { _ in image.draw(in: draw) }
        return out.jpegData(compressionQuality: 0.85)
    }

    /// 写 `Cover/<基名>.jpg`（基名来自音频文件名 —— **绝不改名**）。
    /// - Returns: 写成功的文件 URL（调用方拿去 `CoverImageCache.invalidate`）
    @discardableResult
    static func writeSidecar(_ data: Data, audioPath: String) -> URL? {
        let audio = URL(fileURLWithPath: audioPath)
        let base = DownloadCompanion.baseName(for: audio)
        let url = DownloadCompanion.coverURL(in: DownloadManager.shared.coverDirectory,
                                             baseName: base)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
