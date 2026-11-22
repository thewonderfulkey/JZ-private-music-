import SwiftUI

// MARK: - 存储自检（2026-11-22 老板："空间从 20 多 G 变 40 多 G，我找不到多余的文件"）
//
// 这一页只回答三个问题：
//   ① 磁盘上到底被什么占了（按目录分开列）；
//   ② 「记录合计」和「磁盘合计」差多少（差出来的就是没被任何记录认领的东西）；
//   ③ 哪些可以安全删（导入暂存 / 写标签的隐藏临时文件 / 没人认领的音频）。
//
// 删除一律要用户点头，且每一类都只动它自己那一类的东西 —— 不做"一键清空容器"这种事。
struct StorageAuditSheet: View {

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var report: StorageAuditReport?
    @State private var running = false
    @State private var notice: String?
    @State private var copied = false
    @State private var confirmOrphans = false
    @State private var confirmTrash = false

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    summarySection(report)
                    trashSection(report)
                    sectionsSection(report)
                    stagingSection(report)
                    tmpSection(report)
                    tempSection(report)
                    orphanSection(report)
                } else {
                    Section {
                        HStack(spacing: Tokens.Spacing.s) {
                            ProgressView().controlSize(.small)
                            Text(running ? "正在量磁盘…" : "点右上角「重新检查」开始")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("存储自检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        copyReport()
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(report == nil)
                    Button {
                        Task { await runAudit() }
                    } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                    .disabled(running)
                }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, Tokens.Spacing.m)
                        .padding(.vertical, Tokens.Spacing.s)
                        .background(Capsule().fill(Tokens.Palette.paperElevated))
                        .padding(.bottom, Tokens.Spacing.l)
                        .transition(.opacity)
                }
            }
            .confirmationDialog("删掉这些没人认领的音频？",
                                isPresented: $confirmOrphans, titleVisibility: .visible) {
                Button("删掉（文件一起删除）", role: .destructive) {
                    guard let report else { return }
                    let freed = StorageAudit.delete(report.orphans)
                    flash("已释放 \(ByteText.human(freed))")
                    Task { await runAudit() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这些文件在「Music」里，但没有任何一条下载记录指向它们 —— 通常是早期导入/改名之后留下的旧副本。删掉不影响列表里的歌。")
            }
            .task { await runAudit() }
        }
    }

    // MARK: 「文件」App 废纸篓（2026-11-22 那 18 GB 的真凶）

    @ViewBuilder
    private func trashSection(_ r: StorageAuditReport) -> some View {
        if r.trashBytes > 0 {
            Section {
                row("废纸篓里还压着", ByteText.human(r.trashBytes), strong: true, warn: true)
                row("文件数", "\(r.trashFiles) 个")
                Button(role: .destructive) {
                    confirmTrash = true
                } label: {
                    Label("清空废纸篓（释放 \(ByteText.human(r.trashBytes))）", systemImage: "trash")
                }
            } header: {
                Text("「文件」App 的废纸篓（.Trash）")
            } footer: {
                Text("这就是上一次空间翻倍的真凶：在「文件」App 里删掉 JZ 音乐目录下的东西时，"
                     + "Files 只是把它**挪进**这个 `.Trash`，并没有真删；而 Files 的浏览页看不到它"
                     + "（点开头的目录），iOS 却照样算进 App 占用。"
                     + "里面全是你已经删过的东西，清空不影响列表里的歌。")
            }
            .confirmationDialog("清空「文件」App 的废纸篓？",
                                isPresented: $confirmTrash, titleVisibility: .visible) {
                Button("清空（释放 \(ByteText.human(r.trashBytes))）", role: .destructive) {
                    let freed = StorageAudit.clearTrash()
                    flash("已清空废纸篓，释放 \(ByteText.human(freed))")
                    Task { await runAudit() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这些是你之前删过、但 Files 只是挪进废纸篓的文件。清掉之后「文件」App 的「最近删除」里也就没有了。")
            }
        }
    }

    // MARK: 汇总

    private func summarySection(_ r: StorageAuditReport) -> some View {
        Section {
            row("磁盘合计（约等于「设置」里那个数）", ByteText.human(r.totalBytes), strong: true)
            row("音频合计（Music 里 \(r.audioFiles) 个文件）", ByteText.human(r.audioBytes))
            row("记录合计（\(r.libraryCount) 首）", ByteText.human(r.libraryBytes))
            row("音频 − 记录", ByteText.human(r.audioWasteBytes),
                warn: r.audioWasteBytes > 50_000_000)
            row("旁车与其它（封面/歌词/配置/日志/缓存/临时）", ByteText.human(r.overheadBytes))
        } footer: {
            Text("只有「音频 − 记录」这一条该警惕（>0 = Music 里有没人认领的歌，下面「孤儿音频」会列出来）。"
                 + "「旁车与其它」是**正常开销**：每首歌的封面图 + 歌词文件、配置 json、诊断日志、"
                 + "系统缓存（Library）。清掉缓存会自己重建，不算垃圾。")
        }
    }

    private func sectionsSection(_ r: StorageAuditReport) -> some View {
        Section("按目录") {
            ForEach(r.sections) { s in
                HStack {
                    Text(s.title).font(FontRole.songSubtitle).lineLimit(2)
                    Spacer(minLength: Tokens.Spacing.xs)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ByteText.human(s.bytes)).font(.footnote.monospacedDigit())
                        Text("\(s.files) 个文件").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: 导入暂存

    @ViewBuilder
    private func stagingSection(_ r: StorageAuditReport) -> some View {
        Section {
            HStack {
                Text("ImportStaging").font(FontRole.songSubtitle)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteText.human(r.stagingBytes)).font(.footnote.monospacedDigit())
                    Text("\(r.stagingFiles) 个文件").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if r.stagingFiles > 0 {
                Button(role: .destructive) {
                    let freed = StorageAudit.clearStaging()
                    flash("已清空导入暂存，释放 \(ByteText.human(freed))")
                    Task { await runAudit() }
                } label: {
                    Label("清空导入暂存（安全）", systemImage: "trash")
                }
            }
        } footer: {
            Text("导入时先把文件抄进这个暂存目录、再挪进 Music。正常流程结束会自己清空；"
                 + "**进程被杀 / 导入中途退出**就会留下副本 —— 这里不为 0 就是白占。")
        }
    }

    // MARK: tmp 里的旧残留

    @ViewBuilder
    private func tmpSection(_ r: StorageAuditReport) -> some View {
        Section {
            ForEach(r.staleTmpFiles.prefix(6)) { f in
                HStack {
                    Text(f.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Tokens.Spacing.xs)
                    Text(ByteText.human(f.bytes)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if r.staleTmpFiles.count > 6 {
                Text("还有 \(r.staleTmpFiles.count - 6) 个…")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !r.staleTmpFiles.isEmpty {
                Button(role: .destructive) {
                    let freed = StorageAudit.delete(r.staleTmpFiles)
                    flash("已清 \(r.staleTmpFiles.count) 个旧临时文件，释放 \(ByteText.human(freed))")
                    Task { await runAudit() }
                } label: {
                    Label("清掉 tmp 里 1 小时前的 \(r.staleTmpFiles.count) 个文件（安全）",
                          systemImage: "trash")
                }
            }
        } footer: {
            Text("从别的 App（Light Player 这类）导入时，系统会先把选中的文件**抄进我们 App 的 tmp**，"
                 + "我们抢完再删自己那份。中途取消 / 预算用完，那批副本就留在 tmp 里 —— "
                 + "「文件」App 里看不到，但 iOS 照样算进 App 占用。只清 1 小时前的，正在下载的不动。")
        }
    }

    // MARK: 写标签的临时文件
    @ViewBuilder
    private func tempSection(_ r: StorageAuditReport) -> some View {
        Section {
            ForEach(r.tempArtifacts.prefix(6)) { f in
                HStack {
                    Text(f.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Tokens.Spacing.xs)
                    Text(ByteText.human(f.bytes)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if r.tempArtifacts.count > 6 {
                Text("还有 \(r.tempArtifacts.count - 6) 个…")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !r.tempArtifacts.isEmpty {
                Button(role: .destructive) {
                    let freed = StorageAudit.delete(r.tempArtifacts)
                    flash("已删 \(r.tempArtifacts.count) 个临时文件，释放 \(ByteText.human(freed))")
                    Task { await runAudit() }
                } label: {
                    Label("删掉这 \(r.tempArtifacts.count) 个临时文件（安全）", systemImage: "trash")
                }
            }
        } footer: {
            Text("写歌名/封面/歌词到音频里时，会先生成一个隐藏临时文件（`.tags-…` / `.embed-…`）再原子替换。"
                 + "正常路径会自己删；进程被杀就会留下 —— 它们以点开头，在「文件」App 里看不见，但确实占空间。")
        }
    }

    // MARK: 孤儿音频

    @ViewBuilder
    private func orphanSection(_ r: StorageAuditReport) -> some View {
        Section {
            if r.orphans.isEmpty {
                Text("没有孤儿音频").font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(r.orphans.prefix(10)) { f in
                    HStack {
                        Text(f.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Text(ByteText.human(f.bytes)).font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if r.orphans.count > 10 {
                    Text("还有 \(r.orphans.count - 10) 个…")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Button(role: .destructive) {
                    confirmOrphans = true
                } label: {
                    Label("删掉这 \(r.orphans.count) 个孤儿音频（\(ByteText.human(r.orphanBytes))）",
                          systemImage: "trash")
                }
            }
        } header: {
            Text("Music 里没人认领的音频")
        } footer: {
            Text("判定只比**文件名**（保守）：只要有一条记录的 localPath 或 fileName 对得上，就不算孤儿。"
                 + "删之前请确认列表里那些歌都还在。")
        }
    }

    // MARK: 小工具

    private func row(_ title: String, _ value: String,
                     strong: Bool = false, warn: Bool = false) -> some View {
        HStack {
            Text(title).font(strong ? .body.weight(.semibold) : .body)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(warn ? Tokens.Palette.vermilion : .primary)
        }
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if notice == text { notice = nil }
        }
    }

    private func runAudit() async {
        running = true
        report = await StorageAudit.run(items: downloads.items)
        running = false
    }

    private func copyReport() {
        guard let r = report else { return }
        var lines: [String] = ["【存储自检】\(Date())"]
        lines.append("磁盘合计 \(ByteText.human(r.totalBytes)) · 音频 \(r.audioFiles) 个 "
                     + "\(ByteText.human(r.audioBytes)) · 记录 \(r.libraryCount) 首 "
                     + "\(ByteText.human(r.libraryBytes))")
        lines.append("音频−记录 \(ByteText.human(r.audioWasteBytes)) · 旁车与其它 "
                     + "\(ByteText.human(r.overheadBytes))")
        lines.append("— 按目录 —")
        for s in r.sections {
            lines.append("\(s.title)：\(ByteText.human(s.bytes))（\(s.files) 个文件）")
        }
        lines.append("— 导入暂存 —")
        lines.append("\(r.stagingPath)：\(ByteText.human(r.stagingBytes))（\(r.stagingFiles) 个文件）")
        lines.append("— 写标签临时文件 —")
        lines.append("\(r.tempArtifacts.count) 个，\(ByteText.human(r.tempBytes))")
        lines.append("— 「文件」App 废纸篓 .Trash —")
        lines.append("\(r.trashFiles) 个，\(ByteText.human(r.trashBytes))")
        lines.append("— tmp 旧残留 —")
        lines.append("\(r.staleTmpFiles.count) 个，"
                     + "\(ByteText.human(r.staleTmpFiles.reduce(0) { $0 + $1.bytes }))")
        lines.append("— 孤儿音频 —")
        lines.append("\(r.orphans.count) 个，\(ByteText.human(r.orphanBytes))")
        for f in r.orphans.prefix(40) {
            lines.append("\(ByteText.human(f.bytes))  \(f.name)")
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        copied = true
        flash("已复制，可以直接发到群里")
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}
