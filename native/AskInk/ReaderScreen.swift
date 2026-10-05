import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import PencilKit

private enum ReaderStyle {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.62, green: 0.74, blue: 1, alpha: 1) : UIColor(red: 0.20, green: 0.36, blue: 0.68, alpha: 1)
    })
    static let violet = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.76, green: 0.66, blue: 1, alpha: 1) : UIColor(red: 0.43, green: 0.32, blue: 0.76, alpha: 1)
    })
    static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground : UIColor(red: 1, green: 0.992, blue: 0.976, alpha: 1)
    })
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.systemBackground : UIColor(red: 0.9804, green: 0.9725, blue: 0.9529, alpha: 1)
    })
    static let soft = accent.opacity(0.08)
    static let line = accent.opacity(0.12)
    static let brandGradient = LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ambientGradient = LinearGradient(colors: [accent.opacity(0.07), violet.opacity(0.06), paper.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private struct ReaderActionStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 16).frame(minHeight: 44)
            .foregroundStyle(prominent ? Color(uiColor: .systemBackground) : ReaderStyle.accent)
            .background {
                if prominent { RoundedRectangle(cornerRadius: 12).fill(ReaderStyle.brandGradient) }
                else { RoundedRectangle(cornerRadius: 12).fill(ReaderStyle.soft) }
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct ReaderScreen: View {
    @EnvironmentObject var store: ReaderStore
    @AppStorage("welcomeCompleted") private var welcomed = false
    @AppStorage("questionWritingIntroductionShown") private var introduced = false
    @AppStorage("pencilInputIntroductionShown") private var pencilIntroduced = false
    @AppStorage("appearance") private var appearance = "System"
    @State private var reading = true
    @State private var importing = false
    @State private var settings = false
    @State private var drawer = false
    @State private var searching = false
    @State private var query = ""
    @State private var jumping = false
    @State private var exportSheet = false
    @State private var documentInfo = false
    @State private var documentSettings = false
    @State private var settingsCategory = "General"
    @State private var drawerSection = 0
    @State private var expandedThread: UUID?
    @State private var renaming = false
    @State private var remove = false
    @State private var newName = ""
    @State private var shared: ShareFile?
    @State private var pageText = ""
    @State private var scrubber = 1.0
    var body: some View {
        GeometryReader { geometry in
            if !welcomed && store.books.isEmpty {
                WelcomeScreen(open: { importing = true }, sample: { welcomed = true; store.openSample(); reading = true })
            } else if reading, store.document != nil {
                ZStack(alignment: .top) {
                    PDFReader(store: store)
                    AnswerOverlay(store: store, viewport: store.answerViewport, expanded: $expandedThread)
                    if !store.chromeHidden || searching || drawer { toolbar(width: geometry.size.width) }
                    if drawer {
                        HStack(spacing: 0) {
                            PageDrawer(query: query, searching: searching, section: $drawerSection, close: { drawer = false }).frame(width: min(310, geometry.size.width - 48))
                            Color.black.opacity(0.06).contentShape(Rectangle()).onTapGesture { drawer = false }
                        }.padding(.top, 56)
                    }
                    VStack {
                        Spacer()
                        if !introduced {
                            HStack {
                                Text("Write normally with Pencil.\nEnd a question with ? to ask.").font(.system(size: 12)).lineSpacing(4)
                                Button("Got it") { introduced = true }.font(.system(size: 12, weight: .semibold))
                            }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.bottom, 10)
                        }
                        if store.firstPencilContact && !pencilIntroduced {
                            Text("Pencil writes. Finger scrolls and zooms.").font(.system(size: 11)).padding(12)
                                .background(.regularMaterial, in: Capsule()).padding(.bottom, 10)
                                .task { introduced = true; try? await Task.sleep(for: .seconds(4)); pencilIntroduced = true }
                        }
                        if expandedThread == nil { FloatingPenPalette().environmentObject(store) }
                    }.padding(.bottom, 28).frame(maxWidth: .infinity).allowsHitTesting(true)
                    VStack { Spacer(); HStack { Spacer();
                        Button { scrubber = Double(store.page); pageText = String(store.page); jumping = true } label: {
                            Text("\(store.page) / \(store.document?.pageCount ?? 0)").font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(Color.primary.opacity(0.45)).padding(12).background(.ultraThinMaterial, in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel("跳转页码")
                    }}.padding(.bottom, 8).padding(.trailing, 10).allowsHitTesting(true)
                }.background(ReaderStyle.canvas)
            } else {
                LibraryScreen(open: { book in store.open(book); reading = store.document != nil }, importPDF: { importing = true }, settings: { settingsCategory = "General"; settings = true })
            }
        }.tint(ReaderStyle.accent)
            .onChange(of: store.firstPencilContact) { _, contact in if contact { introduced = true } }
            .preferredColorScheme(appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    store.importPDF(url)
                    if store.document != nil { welcomed = true; reading = true }
                case .failure: store.error = "无法打开所选文档。"
                }
            }
            .sheet(isPresented: $settings) { ReaderSettings(initialCategory: settingsCategory) }
            .popover(isPresented: $documentSettings) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Document Settings").font(.headline)
                    Text(store.currentBook?.name ?? "PDF").font(.subheadline).foregroundStyle(.secondary)
                    Button("Rename") { documentSettings = false; newName = store.currentBook?.name ?? ""; renaming = true }
                    Button("Document Info") { documentSettings = false; documentInfo = true }
                    Button("Export") { documentSettings = false; exportSheet = true }
                    Button("Remove from Library", role: .destructive) { documentSettings = false; remove = true }
                }.padding(24).frame(width: 280).presentationCompactAdaptation(.popover)
            }
            .sheet(isPresented: Binding(get: { store.consentQuestion != nil }, set: { if !$0 { store.deferAIPrivacy() } })) { AIPrivacySheet() }
            .sheet(item: $shared) { file in ShareSheet(url: file.url) }
            .sheet(isPresented: $exportSheet) { ExportSheet { kind in if let book = store.currentBook { export(book, kind: kind) } } }
            .popover(isPresented: $documentInfo) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(store.currentBook?.name ?? "文档").font(.headline)
                    Text("\(store.document?.pageCount ?? 0) 页 · PDF")
                    Text("PDF、笔迹与批注保存在此 iPad。")
                }.font(.subheadline).padding(24).frame(width: 300)
            }
            .popover(isPresented: $jumping) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("跳转页码").font(.headline)
                    TextField("页码", text: $pageText).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    if let count = store.document?.pageCount, count > 1 {
                        Slider(value: $scrubber, in: 1...Double(count), step: 1).onChange(of: scrubber) { _, value in pageText = String(Int(value)) }
                    }
                    Button("跳转") { if let page = Int(pageText) { store.jump(page); jumping = false } }.buttonStyle(.borderedProminent)
                }.padding(24).frame(width: 270).presentationCompactAdaptation(.popover)
            }
            .alert("重命名", isPresented: $renaming) {
                TextField("文档名称", text: $newName)
                Button("保存") { if let book = store.currentBook { store.rename(book, to: newName) } }
                Button("取消", role: .cancel) {}
            }
            .alert("从书库移除？", isPresented: $remove) {
                Button("移除", role: .destructive) { if let book = store.currentBook { Task { await store.removeBook(book); reading = false } } }
                Button("取消", role: .cancel) {}
            } message: { Text("此文档的 PDF、手写和批注将从本机删除。") }
            .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("知道了") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
    private func toolbar(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { store.flush(); store.invalidateRecognition(); reading = false; drawer = false; expandedThread = nil } label: { Image(systemName: "chevron.left").frame(width: 44, height: 52) }.accessibilityLabel("返回 Library")
            Button { withAnimation(.easeOut(duration: 0.2)) { drawerSection = 0; drawer.toggle() }; if store.bookIndex == nil { store.buildIndex() } } label: { Image(systemName: "square.grid.2x2").frame(width: 44, height: 52) }.accessibilityLabel("页面、目录和标记")
            if searching {
                TextField("搜索此 PDF…", text: $query).font(.system(size: 14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { searching = false; query = ""; drawer = false } label: { Image(systemName: "xmark").frame(width: 44, height: 52) }.accessibilityLabel("结束搜索")
            } else {
                if width >= 600 {
                    Menu {
                        Button("重命名") { newName = store.currentBook?.name ?? ""; renaming = true }
                        Button("文档信息") { documentInfo = true }
                        Button("导出批注 PDF") { if let book = store.currentBook { export(book, kind: .annotated) } }
                        Button("分享原始 PDF") { if let book = store.currentBook { export(book, kind: .original) } }
                        Button("从 Library 移除", role: .destructive) { remove = true }
                    } label: { Text(store.currentBook?.name ?? "文档").font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity).padding(.horizontal, 12) }
                } else { Spacer(minLength: 0) }
                Button { searching = true; drawer = true; if store.bookIndex == nil { store.buildIndex() } } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 52) }.accessibilityLabel("搜索 PDF")
                if width >= 600 {
                    Button { store.toggleBookmark() } label: { Image(systemName: store.bookmarks.contains(store.page) ? "bookmark.fill" : "bookmark").frame(width: 44, height: 52) }.accessibilityLabel("书签当前页")
                }
                Menu {
                    if store.returnPage != nil { Button("返回刚才的阅读位置") { store.returnToReading() } }
                    Button("跳转页码") { scrubber = Double(store.page); pageText = String(store.page); jumping = true }
                    Button("问题与标记") { drawerSection = 2; drawer = true; if store.bookIndex == nil { store.buildIndex() } }
                    if width < 600 { Button("书签当前页") { store.toggleBookmark() }; Button("重命名") { newName = store.currentBook?.name ?? ""; renaming = true } }
                    Button("阅读外观") { settingsCategory = "Reading"; settings = true }
                    Button("导出") { exportSheet = true }
                    Button("文档设置") { documentSettings = true }
                    Text(store.saveStatus)
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 52) }.accessibilityLabel("更多文档操作")
            }
        }.buttonStyle(.plain).font(.system(size: 17)).padding(.horizontal, 8).frame(height: 56)
            .background(.regularMaterial).overlay(alignment: .bottom) { Rectangle().fill(ReaderStyle.line).frame(height: 0.5) }
    }
    private func export(_ book: Document, kind: ExportKind) {
        Task { do { shared = ShareFile(url: try await store.export(book, kind: kind)) } catch { store.error = "无法准备导出，请稍后再试。" } }
    }
}

private struct WelcomeScreen: View {
    let open: () -> Void
    let sample: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("ReaderBrand").resizable().scaledToFit().frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 27))
            Text("Read. Write. Ask.").font(.system(size: 30, weight: .semibold, design: .serif))
            Text("Write where you're stuck.\nAskInk answers right there.").font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 22) {
                Text("The gradient points in the\ndirection of greatest increase.").font(.system(size: 17, design: .serif)).lineSpacing(5)
                HStack { Spacer(); Text("why?").italic().font(.system(size: 23, design: .serif)).foregroundStyle(ReaderStyle.accent); Image(systemName: "sparkles").foregroundStyle(ReaderStyle.accent) }
            }.padding(28).frame(maxWidth: 380).background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 18)).padding(.vertical, 18)
            Spacer()
            Button(action: open) { Text("Open a PDF").frame(maxWidth: 330) }.buttonStyle(ReaderActionStyle(prominent: true))
            Button("Try a sample", action: sample).font(.system(size: 14)).padding(10)
            Text("Your PDFs and handwriting stay on your iPad.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 24)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReaderStyle.canvas)
    }
}

private struct FloatingPenPalette: View {
    @EnvironmentObject var store: ReaderStore
    @AppStorage("paletteDock") private var dock = "Bottom"
    @State private var penSettings = false
    @State private var colorSettings = false
    @State private var widthSettings = false
    @State private var eraserSettings = false
    @State private var availableWidth: CGFloat = 768
    @GestureState private var drag = CGSize.zero
    private var penSelected: Bool { ![InkTool.marker, .eraser, .lasso].contains(store.tool) }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: geometry.size.width < 500 ? 1 : 3) {
                if store.paletteCollapsed {
                    Button { store.paletteCollapsed = false; store.chromeHidden = false } label: { Image(systemName: "pencil.tip").font(.system(size: 22)).frame(width: 48, height: 48) }
                } else {
                    Button { if penSelected { penSettings = true } else { store.tool = store.preferredPen } } label: { icon("pencil.tip", selected: penSelected) }.accessibilityLabel("笔；再次点击设置笔触")
                    Button { store.tool = .marker } label: { icon("highlighter", selected: store.tool == .marker) }.accessibilityLabel("高光笔")
                    Button { if store.tool == .eraser { eraserSettings = true } else { store.tool = .eraser } } label: { icon("eraser", selected: store.tool == .eraser) }.accessibilityLabel("橡皮；再次点击设置擦除模式")
                    Button { store.tool = .lasso } label: { icon("lasso", selected: store.tool == .lasso) }.accessibilityLabel("套索选择和移动笔迹")
                    Rectangle().fill(ReaderStyle.line).frame(width: 1, height: 20).padding(.horizontal, 4)
                    Button { colorSettings = true } label: { Circle().fill(store.color).frame(width: 20, height: 20).frame(width: availableWidth < 400 ? 32 : 40, height: 48) }.accessibilityLabel("当前颜色").disabled(store.tool == .eraser || store.tool == .lasso)
                    Button { widthSettings = true } label: { Capsule().fill(store.tool == .eraser ? ReaderStyle.accent : store.color).frame(width: 21, height: min(12, max(2, store.width))).frame(width: availableWidth < 400 ? 32 : 40, height: 48) }.accessibilityLabel("当前粗细").disabled(store.tool == .lasso || (store.tool == .eraser && store.eraserMode == .stroke))
                    Button { store.bridge?.undo() } label: { icon("arrow.uturn.backward") }.accessibilityLabel("撤销")
                    Button { store.bridge?.redo() } label: { icon("arrow.uturn.forward") }.accessibilityLabel("重做")
                }
            }.buttonStyle(.plain).foregroundStyle(ReaderStyle.accent)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: store.paletteCollapsed ? 24 : 16))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                .fixedSize().offset(drag)
                .frame(maxWidth: .infinity, alignment: dock == "Left" ? .leading : dock == "Right" ? .trailing : .center)
                .padding(.horizontal, 20)
                .gesture(LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture()).updating($drag) { value, state, _ in
                    if case .second(true, let gesture?) = value { state = gesture.translation }
                }.onEnded { value in
                    if case .second(true, let gesture?) = value {
                        if gesture.translation.width < -60 { dock = "Left" } else if gesture.translation.width > 60 { dock = "Right" } else { dock = "Bottom" }
                    }
                })
                .contextMenu { Toggle("Keep Open", isOn: $store.palettePinned); Button("收起") { store.paletteCollapsed = true } }
                .popover(isPresented: $penSettings) { PenSettings().environmentObject(store).presentationCompactAdaptation(.popover) }
                .popover(isPresented: $colorSettings) { InkColorSettings().environmentObject(store).presentationCompactAdaptation(.popover) }
                .popover(isPresented: $widthSettings) { InkWidthSettings().environmentObject(store).presentationCompactAdaptation(.popover) }
                .popover(isPresented: $eraserSettings) {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("擦除模式", selection: $store.eraserMode) { ForEach(InkEraserMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        if store.eraserMode == .partial { InkWidthSettings().environmentObject(store) }
                        Text("局部擦除只擦掉经过的区域；整笔擦除删除碰到的笔画。").font(.caption).foregroundStyle(.secondary)
                    }.padding(20).frame(width: 310).presentationCompactAdaptation(.popover)
                }
            .onAppear { availableWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in availableWidth = width }
        }.frame(height: 48)
    }
    private func icon(_ symbol: String, selected: Bool = false) -> some View {
        Image(systemName: symbol).font(.system(size: 20)).frame(width: availableWidth < 400 ? 32 : 40, height: 48)
            .background(selected ? ReaderStyle.soft : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}
private struct InkColorSettings: View {
    @EnvironmentObject var store: ReaderStore
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                ForEach([Color.black, .blue, .red, .yellow, .green], id: \.self) { color in
                    Button { store.color = color } label: {
                        Circle().fill(color).frame(width: 24, height: 24).frame(width: 40, height: 44)
                    }.accessibilityLabel(color.description)
                }
            }.buttonStyle(.plain)
            ColorPicker("自定义颜色", selection: $store.color, supportsOpacity: false)
        }.padding(24).frame(width: 290)
    }
}
private struct InkWidthSettings: View {
    @EnvironmentObject var store: ReaderStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ForEach(store.tool.presetWidths, id: \.self) { width in
                    Button { store.width = width } label: {
                        Circle().fill(store.tool == .eraser ? ReaderStyle.accent : store.color)
                            .frame(width: min(22, 4 + width * 2), height: min(22, 4 + width * 2)).frame(width: 52, height: 44)
                            .background(abs(store.width - width) < 0.1 ? ReaderStyle.soft : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    }.accessibilityLabel("\(width.formatted()) 点")
                }
            }.buttonStyle(.plain)
            Text("\(store.width.formatted(.number.precision(.fractionLength(1)))) 点").font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}
private struct PenSettings: View {
    @EnvironmentObject var store: ReaderStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pen").font(.headline)
            ForEach(InkTool.penStyles) { tool in
                Button { store.tool = tool } label: { HStack { Text(tool.title); Spacer(); if store.tool == tool { Image(systemName: "checkmark") } } }.frame(minHeight: 35)
            }
            Text("Thickness").font(.caption).foregroundStyle(.secondary)
            InkWidthSettings().environmentObject(store)
            Text("Color").font(.caption).foregroundStyle(.secondary)
            HStack { ForEach([Color.black, .blue, .red, .yellow, .green], id: \.self) { color in Button { store.color = color } label: { Circle().fill(color).frame(width: 24, height: 24).frame(width: 40, height: 38) }.accessibilityLabel(color.description) } }
        }.padding(24).frame(width: 270).tint(ReaderStyle.accent)
    }
}
private struct AIPrivacySheet: View {
    @EnvironmentObject var store: ReaderStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("AskInk AI", systemImage: "sparkles").font(.title2.weight(.semibold))
            Text("为回答这个问题，AskInk 会发送：\n\n• 你的手写问题\n• 附近正文\n• 必要时，相关区域的小幅图像\n\n不会上传整本 PDF。").font(.body).lineSpacing(5)
            if ProviderKey.read(provider: AIProvider.selected).isEmpty {
                Text("此版本使用你自己的 AI 连接。可在 Settings → AI → Advanced 配置；PDF 阅读和书写始终可离线使用。").font(.caption).foregroundStyle(.secondary)
            }
            Button("Continue") { Task { await store.acceptAIPrivacy() } }.buttonStyle(ReaderActionStyle(prominent: true))
            Button("Not Now") { store.deferAIPrivacy() }.font(.subheadline)
        }.padding(30).presentationDetents([.medium, .large]).interactiveDismissDisabled()
    }
}
private struct ExportSheet: View {
    let export: (ExportKind) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { List(ExportKind.allCases) { kind in
            Button { dismiss(); export(kind) } label: { VStack(alignment: .leading, spacing: 6) {
                Text(kind.rawValue)
                Text(kind == .original ? "原始文档" : kind == .annotated ? "包含手写与高光，批注合并到 PDF" : "PDF、可编辑笔迹、书签与 AI 对话").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 10) }
        }.navigationTitle("Export").toolbar { Button("完成") { dismiss() } } }.presentationDetents([.medium])
    }
}
private struct LibraryScreen: View {
    @EnvironmentObject var store: ReaderStore
    let open: (Document) -> Void
    let importPDF: () -> Void
    let settings: () -> Void
    @State private var searching = false
    @State private var query = ""
    @State private var renamed: Document?
    @State private var newName = ""
    @State private var removing: Document?
    @State private var shared: ShareFile?
    private var filtered: [Document] { store.books.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    private var recent: [Document] { Array(filtered.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }.prefix(3)) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if searching { TextField("Search Library…", text: $query).textFieldStyle(.roundedBorder).autocorrectionDisabled() }
                    if store.books.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "books.vertical").font(.system(size: 40, weight: .light)).foregroundStyle(ReaderStyle.accent)
                            Text("Your library is empty").font(.headline)
                            Button(action: importPDF) { Label("Open a PDF", systemImage: "plus") }.buttonStyle(ReaderActionStyle(prominent: true))
                        }.frame(maxWidth: .infinity).padding(.vertical, 100)
                    } else {
                        if query.isEmpty {
                            Text("Continue Reading").font(.system(size: 20, weight: .semibold))
                            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 18) { ForEach(recent) { book in bookCard(book).frame(width: 175) } } }
                        }
                        Text("Library").font(.system(size: 20, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 22)], spacing: 24) { ForEach(filtered) { book in bookCard(book) } }
                    }
                }.padding(26)
            }.background(ReaderStyle.canvas).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { HStack(spacing: 10) { Image("ReaderBrand").resizable().scaledToFit().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 7)); Text("My Library").font(.headline) } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { searching.toggle() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索书库")
                        Menu { Button("Import PDF", action: importPDF); Button("Open from Files", action: importPDF) } label: { Image(systemName: "plus") }.accessibilityLabel("导入文档")
                        Menu { Button("Settings", action: settings); Button("Help") { store.error = "Pencil 写字，手指滚动和缩放。以 ? 或 ？ 结束新手写来提问；点击答案旁的 ✦ 展开或追问。" }; Button("About AskInk") { store.error = "AskInk · Read. Write. Ask.\nPDF 与手写保存在你的 iPad。" } } label: { Image(systemName: "ellipsis") }.accessibilityLabel("书库菜单")
                    }
                }
        }.sheet(item: $shared) { file in ShareSheet(url: file.url) }
            .alert("Rename", isPresented: Binding(get: { renamed != nil }, set: { if !$0 { renamed = nil } })) {
                TextField("Document name", text: $newName)
                Button("Save") { if let book = renamed { store.rename(book, to: newName) }; renamed = nil }
                Button("Cancel", role: .cancel) { renamed = nil }
            }
            .alert("Remove from Library?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Remove", role: .destructive) { if let book = removing { Task { await store.removeBook(book) } }; removing = nil }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: { Text("The PDF, handwriting and threads will be removed from this iPad.") }
    }
    private func bookCard(_ book: Document) -> some View {
        Button { open(book) } label: {
            VStack(alignment: .leading, spacing: 9) {
                BookCover(url: store.folder(book.id).appendingPathComponent("document.pdf")).frame(height: 175)
                    .frame(maxWidth: .infinity).background(ReaderStyle.paper, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8)).shadow(color: .black.opacity(0.05), radius: 6, y: 3)
                HStack { Text(book.name).font(.system(size: 13, weight: .medium)).lineLimit(2); if book.favorite == true { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) } }
                Text("\(book.lastPage) / \(book.pageCount.map(String.init) ?? "—")").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(book.lastOpenedAt ?? book.addedAt, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary)
            }.foregroundStyle(.primary)
        }.buttonStyle(.plain).contextMenu {
            Button("Open") { open(book) }
            Button("Rename") { newName = book.name; renamed = book }
            Button(book.favorite == true ? "Unfavorite" : "Favorite") { store.toggleFavorite(book) }
            Button("Export Annotated PDF") { export(book, kind: .annotated) }
            Button("Share") { export(book, kind: .original) }
            Button("Remove from Library", role: .destructive) { removing = book }
        }
    }
    private func export(_ book: Document, kind: ExportKind) {
        Task { do { shared = ShareFile(url: try await store.export(book, kind: kind)) } catch { store.error = "Unable to prepare export." } }
    }
}
private struct BookCover: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Image(systemName: "doc.text").font(.system(size: 36, weight: .light)).foregroundStyle(ReaderStyle.accent) } }
            .task(id: url) {
                let path = url
                image = await Task.detached(priority: .utility) { PDFDocument(url: path)?.page(at: 0)?.thumbnail(of: CGSize(width: 300, height: 390), for: .cropBox) }.value
            }
    }
}
private struct PageDrawer: View {
    @EnvironmentObject var store: ReaderStore
    let query: String
    let searching: Bool
    @Binding var section: Int
    let close: () -> Void
    @State private var highlighted: [Int] = []
    var body: some View {
        VStack(spacing: 0) {
            if searching {
                Text("Search Results").font(.headline).padding(18)
                if store.indexBuilding { Text("正在本机建立索引…").font(.caption).foregroundStyle(.secondary) }
                List(store.searchResults) { source in Button { store.jumpToSource(source); close() } label: { VStack(alignment: .leading, spacing: 6) { Text("p.\(source.page)").font(.caption).foregroundStyle(.secondary); Text(source.text).font(.system(size: 12)).lineLimit(4) } } }
                    .task(id: "\(query)|\(store.bookIndex?.sources.count ?? 0)") { try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { await store.searchBook(query, previousOnly: false) } }
            } else {
                Picker("Navigation", selection: $section) { Text("Pages").tag(0); Text("Outline").tag(1); Text("Marks").tag(2) }.pickerStyle(.segmented).padding(12)
                if section == 0 {
                    ScrollView { LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(1...max(1, store.document?.pageCount ?? 1), id: \.self) { number in
                            Button { store.jump(number); close() } label: { VStack(spacing: 7) {
                                PageThumbnail(number: number).frame(height: 145).overlay(RoundedRectangle(cornerRadius: 5).stroke(store.page == number ? ReaderStyle.accent : Color.clear, lineWidth: 2))
                                Text("\(number)").font(.caption)
                            }}.buttonStyle(.plain)
                        }
                    }.padding(14) }
                } else if section == 1 {
                    List { if let outline = store.document?.outlineRoot { OutlineRows(outline: outline, close: close) } else { Text("This PDF has no outline.").foregroundStyle(.secondary) } }
                } else {
                    List {
                        Section("Bookmarks") { ForEach(store.bookmarks.sorted(), id: \.self) { number in Button("p.\(number)") { store.jump(number); close() } } }
                        Section("Highlights") { ForEach(highlighted, id: \.self) { number in Button("p.\(number)") { store.jump(number); close() } } }
                        Section("Questions") { ForEach(store.overlayReplies) { reply in Button("p.\(reply.page) · \(reply.question)") { store.jump(reply.page); close() }.lineLimit(2) } }
                    }
                }
            }
        }.background(ReaderStyle.paper).task(id: store.currentBook?.id) {
            guard let book = store.currentBook else { return }
            let directory = store.folder(book.id)
            highlighted = await Task.detached(priority: .utility) {
                (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.compactMap { file -> Int? in
                    guard file.pathExtension == "drawing", let number = Int(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "page-", with: "")),
                          let data = try? Data(contentsOf: file), let drawing = try? PKDrawing(data: data), drawing.strokes.contains(where: { $0.ink.inkType == .marker }) else { return nil }
                    return number
                }.sorted() ?? []
            }.value
        }
    }
}
private struct PageThumbnail: View {
    @EnvironmentObject var store: ReaderStore
    let number: Int
    @State private var image: UIImage?
    var body: some View { Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Rectangle().fill(ReaderStyle.soft) } }
        .task(id: "\(store.currentBook?.id.uuidString ?? "")/\(number)") {
            guard let book = store.currentBook else { return }; let url = store.folder(book.id).appendingPathComponent("document.pdf")
            image = await Task.detached(priority: .utility) { PDFDocument(url: url)?.page(at: number - 1)?.thumbnail(of: CGSize(width: 180, height: 250), for: .cropBox) }.value
        }
    }
}
private struct OutlineRows: View {
    @EnvironmentObject var store: ReaderStore
    let outline: PDFOutline
    let close: () -> Void
    var body: some View {
        ForEach(0..<outline.numberOfChildren, id: \.self) { index in
            if let child = outline.child(at: index) {
                if child.numberOfChildren > 0 {
                    DisclosureGroup(child.label ?? "Chapter") { OutlineRows(outline: child, close: close) }
                } else {
                    Button(child.label ?? "Chapter") {
                        if let page = child.destination?.page, let document = store.document { store.jump(document.index(for: page) + 1); close() }
                    }
                }
            }
        }
    }
}

struct ReaderSettings: View {
    @EnvironmentObject var store: ReaderStore
    @Environment(\.dismiss) private var dismiss
    @State private var category: String?
    init(initialCategory: String = "General") { _category = State(initialValue: initialCategory) }
    @State private var deletingHistory = false
    @State private var deletingData = false
    @State private var restoringArchive = false
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("readingBackground") private var readingBackground = "Warm"
    @AppStorage("toolbarAutoHide") private var autoHide = true
    @AppStorage("rememberBookZoom") private var rememberZoom = true
    @AppStorage("continuousScroll") private var continuous = true
    @AppStorage("paletteDock") private var dock = "Bottom"
    @AppStorage("allowSpoilers") private var allowSpoilers = false
    @AppStorage("useContextImages") private var images = true
    var body: some View {
        NavigationSplitView {
            List(["General", "Reading", "Pencil", "AI", "Data & Privacy", "About"], id: \.self,
                 selection: Binding<String?>(get: { category }, set: { if let value = $0 { category = value } })) { Text($0) }
                .navigationTitle("Settings").toolbar { Button("Done") { dismiss() } }
        } detail: {
            Form {
                switch category ?? "General" {
                case "General":
                    Picker("Appearance", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                    LabeledContent("App Language", value: "Automatic")
                case "Reading":
                    Picker("Reading Background", selection: $readingBackground) { ForEach(["White", "Warm", "Dark"], id: \.self) { Text($0) } }
                    Toggle("Toolbar Auto-Hide", isOn: $autoHide)
                    Toggle("Remember Zoom Per Document", isOn: $rememberZoom)
                    Toggle("Continuous Scroll", isOn: $continuous)
                case "Pencil":
                    Picker("Default Tool", selection: $store.tool) { ForEach(InkTool.available) { tool in Text(tool.title).tag(tool) } }
                    ColorPicker("Default Color", selection: $store.color, supportsOpacity: false)
                    InkWidthSettings().environmentObject(store)
                    LabeledContent("Double Tap Action", value: "Switch to Eraser")
                    Picker("Floating Palette", selection: $dock) { ForEach(["Bottom", "Left", "Right"], id: \.self) { Text($0) } }
                    NavigationLink("Advanced") { PencilAdvancedSettings() }
                case "AI":
                    Toggle("AI Mode · Auto", isOn: $store.autoReply)
                    Text("先给 2–4 句页边短答；点击 More 才生成深入解释。").font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow content after my reading position", isOn: $allowSpoilers)
                    Toggle("Use Images When Needed", isOn: $images)
                    NavigationLink("Advanced · Bring Your Own API Key") { AIConnectionSettings() }
                case "Data & Privacy":
                    LabeledContent("Your PDFs", value: "On this iPad")
                    LabeledContent("Your handwriting", value: "On this iPad")
                    Text("Only your question and relevant nearby context are sent when you ask a question. The full PDF is not uploaded.").font(.caption).foregroundStyle(.secondary)
                    Button("Restore AskInk Archive") { restoringArchive = true }
                    Button("Delete AI History", role: .destructive) { deletingHistory = true }.disabled(store.busy)
                    Button("Delete All Local Data", role: .destructive) { deletingData = true }.disabled(store.busy)
                default:
                    Text("AskInk").font(.title2)
                    Text("Read. Write. Ask.")
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                    LabeledContent("Writing Engine", value: "PencilKit")
                    Text("Personal edition · no subscription is enabled.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle(category ?? "General").scrollContentBackground(.hidden).background(ReaderStyle.canvas)
        }.tint(ReaderStyle.accent)
            .fileImporter(isPresented: $restoringArchive, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): store.importArchive(url)
                case .failure: store.error = "Unable to open this archive."
                }
            }
            .alert("Delete AI History?", isPresented: $deletingHistory) { Button("Delete", role: .destructive) { store.deleteAIHistory() }; Button("Cancel", role: .cancel) {} }
            .alert("Delete All Local Data?", isPresented: $deletingData) {
                Button("Delete", role: .destructive) { Task { for book in store.books { await store.removeBook(book) }; dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes local PDFs, handwriting and AI threads.") }
    }
}
private struct PencilAdvancedSettings: View {
    @EnvironmentObject var store: ReaderStore
    var body: some View {
        Form {
            Section("PencilKit") {
                Text("压力、倾角、笔迹稳定与预测由系统引擎处理。公开接口不提供自定义压感曲线或稳定度数值，因此这里不显示无效滑块。")
            }
            Section("Palm behavior") { Toggle("Lock page while writing", isOn: $store.lockPageForWriting) }
        }.navigationTitle("Pencil · Advanced")
    }
}
struct AIConnectionSettings: View {
    @EnvironmentObject var store: ReaderStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider = AIProvider.selected
    @State private var connection = AIConnection.stored(AIProvider.selected)
    @State private var token = ProviderKey.read(provider: AIProvider.selected)
    @AppStorage("aiModel.openAI.expanded") private var expandedModel = "gpt-6.1-sol"
    @State private var connectionDrafts: [AIProvider: AIConnection] = [:]
    @State private var keyDrafts: [AIProvider: String] = [:]
    @AppStorage("handwritingLanguage") private var handwritingLanguage = "zh-Hans"
    var body: some View {
        NavigationStack {
            Form {
                Section("AI · iPad 独立连接") {
                    Picker("服务", selection: $provider) {
                        ForEach(AIProvider.allCases) { value in Text(value.title).tag(value) }
                    }.onChange(of: provider) { old, new in
                        connectionDrafts[old] = connection; keyDrafts[old] = token
                        connection = connectionDrafts[new] ?? AIConnection.stored(new)
                        token = keyDrafts[new] ?? ProviderKey.read(provider: new)
                    }
                    SecureField("API Key", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(provider == .openAI ? "短答模型 ID" : "模型 ID", text: $connection.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if provider == .openAI { TextField("深入解释模型 ID", text: $expandedModel).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    if provider == .compatible {
                        TextField("完整 HTTPS API 地址", text: $connection.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("发送图片（需要视觉模型）", isOn: $connection.includeImage)
                    }
                    Text("填写该服务账户可调用的模型 ID；手写问答需要支持图片输入。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("直接从 iPad 连接 AI，无需电脑服务。密钥保存在本机钥匙串；以问号结束的问题才自动发送识别文字、原始笔迹图和附近正文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("本机识别") {
                    Text("iPadOS 27 优先 Apple 笔画识别；旧系统、语言不支持或无识别文字时，回退内置 PaddleOCR。")
                    TextField("手写主要语言（如 zh-Hans、en）", text: $handwritingLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("识别文字只是参考；问题的原始笔迹图与附近正文一起发送给支持图片的模型。数学符号看不清时会请求澄清。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background(ReaderStyle.canvas)
                .navigationTitle("自带 API Key").navigationBarTitleDisplayMode(.inline).toolbar { Button("保存") {
                do {
                    connection.model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    connection.endpoint = connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = try connection.validatedURL()
                    try ProviderKey.save(token.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
                    connection.save()
                    dismiss()
                }
                catch { store.error = error.localizedDescription }
            } }
        }
    }
}
