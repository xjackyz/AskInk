import SwiftUI

struct ReadingSourcesView: View {
    @ObservedObject var store: ReaderStore
    var sources: [ReadingSource]
    var body: some View {
        ForEach(sources) { source in
            VStack(alignment: .leading, spacing: 5) {
                Button { store.jumpToSource(source) } label: {
                    Label("\(source.page < store.page ? "前文 · " : "")第 \(source.page) 页 · \(source.id)", systemImage: "arrow.up.left")
                }
                Text(source.text).lineLimit(4).foregroundStyle(.secondary)
            }.font(.caption).padding(.vertical, 4)
        }
    }
}

struct ReadingToolsPane: View {
    @EnvironmentObject var store: ReaderStore
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var query = ""
    @State private var previousOnly = true
    @State private var summaryMode: BookSummaryMode = .local
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("阅读工具", selection: $section) {
                    Text("全文索引").tag(0)
                    Text("全文总结").tag(1)
                }.pickerStyle(.segmented).padding()
                Text(store.indexStatus).font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
                if store.indexBuilding { ProgressView().padding(.bottom, 10) }
                if section == 0 { search } else { summary }
            }
            .navigationTitle("\(store.currentBook?.name ?? "文档") · 阅读工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }
    private var search: some View {
        VStack(spacing: 12) {
            TextField("搜索概念、原句或之前的定义", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal)
            Toggle("只检索当前页之前的正文", isOn: $previousOnly).font(.subheadline).padding(.horizontal)
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("输入关键词可查找前文；点结果跳到原文，工具栏可返回阅读位置。").foregroundStyle(.secondary)
                } else if store.searchResults.isEmpty {
                    Text(store.indexBuilding ? "正在建立索引，完成后会自动搜索。" : "没有匹配结果，可缩短关键词或搜索全书。").foregroundStyle(.secondary)
                }
                ForEach(store.searchResults) { source in
                    Button {
                        store.jumpToSource(source); dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第 \(source.page) 页\(source.isOCR ? " · 扫描识别" : "")").font(.caption).foregroundStyle(.secondary)
                            Text(source.text).font(.subheadline).lineLimit(6).foregroundStyle(.primary)
                        }.padding(.vertical, 5)
                    }
                }
                if !store.indexBuilding && store.bookIndex == nil { Button("重新建立索引") { store.buildIndex() } }
            }
        }.task(id: "\(query)|\(previousOnly)|\(store.currentBook?.id.uuidString ?? "")|\(store.bookIndex?.sources.count ?? 0)|\(store.page)") {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await store.searchBook(query, previousOnly: previousOnly)
        }
    }
    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("总结方式", selection: $summaryMode) {
                    ForEach(BookSummaryMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).disabled(store.summaryProgress != nil)
                if summaryMode == .local {
                    Text(BookSummarizer.localAvailability ?? "使用系统本机模型逐块总结，正文不发送到云端。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("首次总结会逐块发送整本可识别正文到已配置的 AI，并产生 API 用量。已完成的块和全文摘要保存在本机；重试会复用缓存。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let index = store.bookIndex, !index.unreadablePages.isEmpty {
                    Text("第 \(index.unreadablePages.map(String.init).joined(separator: "、")) 页没有识别到正文，将不包含在摘要中。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let progress = store.summaryProgress {
                    HStack { ProgressView(); Text(progress).font(.subheadline) }
                    Button("停止总结（保留已完成的缓存）") { store.cancelSummary() }
                } else {
                    Button(summaryMode == .local ? "生成本机全文总结" : "生成云端全文总结") { store.summarizeBook(mode: summaryMode) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.bookIndex == nil || store.indexBuilding || (summaryMode == .local && BookSummarizer.localAvailability != nil))
                }
                if let error = store.summaryError { Text(error).font(.caption).foregroundStyle(.red) }
                if let summary = store.bookSummary {
                    Text(summary.text).font(.body).lineSpacing(6).textSelection(.enabled)
                    Text("\(summary.model) · 覆盖 \(summary.coveredPages.count) 页可识别正文；生成摘要可能遗漏细节，请核对原文。")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 75))], spacing: 10) {
                        ForEach(summary.coveredPages, id: \.self) { page in
                            Button("第 \(page) 页") {
                                if let source = store.bookIndex?.sources.first(where: { $0.page == page }) { store.jumpToSource(source) }
                                else { store.jump(page) }
                                dismiss()
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }.padding(20)
        }
    }
}
