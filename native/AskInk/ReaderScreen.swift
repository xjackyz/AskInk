import SwiftUI
import UniformTypeIdentifiers

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
        traits.userInterfaceStyle == .dark ? UIColor.systemBackground : UIColor(red: 0.945, green: 0.958, blue: 0.984, alpha: 1)
    })
    static let soft = accent.opacity(0.08)
    static let line = accent.opacity(0.12)
    static let brandGradient = LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ambientGradient = LinearGradient(colors: [accent.opacity(0.07), violet.opacity(0.06), paper.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private struct ReaderBrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        Image("ReaderBrand").resizable().scaledToFit().frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
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
    @State private var importing = false
    @State private var library = false
    @State private var importAfterLibrary = false
    @State private var settings = false
    @State private var jumping = false
    @State private var pageText = ""
    @State private var showAI = true
    @State private var mobileAI = false
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                documentTabs
                if store.document != nil {
                    documentToolbar(wide: geometry.size.width >= 900)
                    WritingToolbar().environmentObject(store)
                }
                Rectangle().fill(ReaderStyle.line).frame(height: 1)
                HStack(spacing: 0) {
                    ZStack {
                        if store.document != nil {
                            PDFReader(store: store)
                        } else {
                            ReaderWelcome { importing = true }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if geometry.size.width >= 900 && showAI {
                        Rectangle().fill(ReaderStyle.line).frame(width: 1)
                        ReplyPane().frame(width: geometry.size.width >= 1200 ? 340 : 300)
                    }
                }
            }.background(ReaderStyle.canvas)
        }.tint(ReaderStyle.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result { case .success(let url): store.importPDF(url); case .failure(let error): store.error = error.localizedDescription }
        }
        .sheet(isPresented: $library, onDismiss: {
            if importAfterLibrary { importAfterLibrary = false; importing = true }
        }) {
            ReaderLibrary(open: { book in store.open(book); library = false }, importPDF: { importAfterLibrary = true; library = false })
        }
        .sheet(isPresented: $settings) { ReaderSettings().tint(ReaderStyle.accent) }
        .sheet(isPresented: $mobileAI) {
            NavigationStack { ReplyPane().toolbar { Button("完成") { mobileAI = false } } }
                .tint(ReaderStyle.accent)
        }
        .alert("跳转页面", isPresented: $jumping) {
            TextField("PDF 页码", text: $pageText).keyboardType(.numberPad)
            Button("跳转") { if let number = Int(pageText) { store.jump(number) } else { store.error = "请输入整数页码。" } }
            Button("取消", role: .cancel) {}
        } message: { Text("输入 PDF 文件的页序号（不是印刷页码）") }
        .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private var documentTabs: some View {
        HStack(spacing: 0) {
            Button { library = true } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).frame(width: 48, height: 44)
            }.accessibilityLabel("返回书库")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        if store.openBookIDs.isEmpty {
                            Text("文档").font(.system(size: 13, weight: .medium)).padding(.horizontal, 18).frame(height: 44)
                        }
                        ForEach(store.openBookIDs, id: \.self) { id in
                            if let book = store.books.first(where: { $0.id == id }) {
                                documentTab(book).id(id)
                            }
                        }
                    }.padding(.horizontal, 4)
                }
                .onChange(of: store.currentBook?.id) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .onAppear { if let id = store.currentBook?.id { proxy.scrollTo(id, anchor: .center) } }
            }
            Button { importing = true } label: {
                Image(systemName: "plus").font(.system(size: 17)).frame(width: 48, height: 44)
            }.accessibilityLabel("导入 PDF 并打开新标签页")
            if store.document == nil {
                Button { settings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("设置")
            }
        }.buttonStyle(.plain).foregroundStyle(ReaderStyle.accent)
            .background(ReaderStyle.accent.opacity(0.12))
    }
    private func documentTab(_ book: Book) -> some View {
        let selected = store.currentBook?.id == book.id
        return HStack(spacing: 0) {
            Button {
                if !selected { store.open(book) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.system(size: 12))
                    Text(book.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle).frame(minWidth: 80, maxWidth: 180, alignment: .leading)
                }.padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
            }.accessibilityAddTraits(selected ? .isSelected : [])
            Button { store.closeTab(book.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 36, height: 44)
            }.accessibilityLabel("关闭标签：\(book.name)")
        }.background(selected ? ReaderStyle.paper : Color.clear, in: UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9))
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? ReaderStyle.accent : Color.clear).frame(height: 2) }
    }
    private func documentToolbar(wide: Bool) -> some View {
        HStack(spacing: 3) {
            Button { store.bridge?.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.accessibilityLabel("撤销")
            Button { store.bridge?.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.accessibilityLabel("重做")
            toolbarDivider
            Button { store.jump(store.page - 1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 44) }.disabled(store.page <= 1).accessibilityLabel("上一页")
            Button("\(store.page) / \(store.document?.pageCount ?? 0)") { pageText = String(store.page); jumping = true }
                .font(.system(size: 12, weight: .medium)).monospacedDigit().frame(minWidth: 65, minHeight: 44).accessibilityLabel("跳转页码")
            Button { store.jump(store.page + 1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 44) }.disabled(store.page >= (store.document?.pageCount ?? 0)).accessibilityLabel("下一页")
            Spacer(minLength: 0)
            if store.busy { ProgressView().controlSize(.small).padding(.horizontal, 8).accessibilityLabel("AI 正在处理") }
            if store.automaticError != nil {
                Button { Task { await store.retryAutomaticQuestion() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.disabled(store.busy).accessibilityLabel("重试 AI 回复")
            }
            Button { store.autoReply.toggle() } label: {
                Image(systemName: store.autoReply ? "sparkles" : "pause.circle").frame(width: 44, height: 44)
                    .background(store.autoReply ? ReaderStyle.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }.accessibilityLabel(store.autoReply ? "暂停停笔自动回复" : "开启停笔自动回复")
            Button { if wide { withAnimation(.easeInOut(duration: 0.2)) { showAI.toggle() } } else { mobileAI = true } } label: {
                Image(systemName: "sidebar.right").frame(width: 44, height: 44)
                    .background(showAI && wide ? ReaderStyle.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }.accessibilityLabel("AI 页边栏")
            Menu {
                Text(store.saveStatus)
                Text(store.status)
                Button { importing = true } label: { Label("导入 PDF", systemImage: "plus") }
                Button { settings = true } label: { Label("阅读与书写设置", systemImage: "gearshape") }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("文档菜单与保存状态")
        }.font(.system(size: 17)).buttonStyle(.plain).foregroundStyle(ReaderStyle.accent)
            .padding(.horizontal, 12).padding(.vertical, 3).background(ReaderStyle.paper)
            .overlay(alignment: .bottom) { Rectangle().fill(ReaderStyle.line).frame(height: 1) }
    }
    private var toolbarDivider: some View {
        Rectangle().fill(ReaderStyle.line).frame(width: 1, height: 22).padding(.horizontal, 6)
    }
}

private struct ReaderWelcome: View {
    let open: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            ReaderBrandMark(size: 96)
            Text("打开文档").font(.system(size: 23, weight: .semibold))
            Text("从书库打开一本书，或导入 PDF 开始书写。")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action: open) { Label("导入 PDF", systemImage: "plus") }.buttonStyle(ReaderActionStyle(prominent: true))
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(ReaderStyle.canvas)
    }
}

private struct InkToolIcon: View {
    var tool: InkTool
    var body: some View {
        if let image = UIImage(systemName: tool.symbol) {
            Image(uiImage: image).renderingMode(.template)
        } else {
            Image(systemName: "pencil")
        }
    }
}

private struct WritingToolbar: View {
    @EnvironmentObject var store: ReaderStore
    @State private var widthSettings = false
    @State private var colorSettings = false
    private let colors: [Color] = [.black, .blue, .red]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(InkTool.allCases) { tool in
                    Button { store.tool = tool } label: {
                        InkToolIcon(tool: tool).font(.system(size: 23, weight: .regular))
                            .frame(width: 44, height: 46)
                            .foregroundStyle(store.tool == tool ? ReaderStyle.accent : Color.secondary)
                            .background(store.tool == tool ? ReaderStyle.soft : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottom) { Capsule().fill(store.tool == tool ? ReaderStyle.accent : Color.clear).frame(width: 18, height: 2).padding(.bottom, 3) }
                    }.accessibilityLabel(tool.title).accessibilityAddTraits(store.tool == tool ? .isSelected : [])
                }
                divider
                ForEach([1.0, 2.5, 4.5], id: \.self) { width in
                    Button { store.width = width } label: {
                        Circle().fill(store.tool == .eraser ? ReaderStyle.accent : store.color)
                            .frame(width: width * 2 + 3, height: width * 2 + 3).frame(width: 34, height: 44)
                            .background(abs(store.width - width) < 0.05 ? ReaderStyle.soft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }.accessibilityLabel("笔触粗细 \(width)").accessibilityAddTraits(abs(store.width - width) < 0.05 ? .isSelected : [])
                }
                Button { widthSettings = true } label: {
                    HStack(spacing: 4) {
                        Text(store.width, format: .number.precision(.fractionLength(1))).font(.system(size: 11)).monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.frame(minWidth: 40, minHeight: 44)
                }.accessibilityLabel("自定义笔触粗细")
                    .popover(isPresented: $widthSettings) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text("笔触粗细").font(.headline); Spacer(); Text(store.width, format: .number.precision(.fractionLength(1))).monospacedDigit() }
                            Slider(value: $store.width, in: 0.8...6).accessibilityLabel("笔触粗细")
                        }.padding(24).frame(width: 280).tint(ReaderStyle.accent).presentationCompactAdaptation(.popover)
                    }
                divider
                ForEach(colors, id: \.self) { color in
                    Button { store.color = color } label: {
                        Circle().fill(color).frame(width: 22, height: 22).padding(5)
                            .overlay(Circle().stroke(store.color == color ? ReaderStyle.accent : Color.clear, lineWidth: 1.5))
                            .frame(width: 36, height: 44)
                    }.accessibilityLabel(colorName(color)).accessibilityAddTraits(store.color == color ? .isSelected : [])
                }
                Button { colorSettings = true } label: {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .frame(width: 22, height: 22).frame(width: 40, height: 44)
                }.accessibilityLabel("更多笔迹颜色")
                    .popover(isPresented: $colorSettings) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("笔迹颜色").font(.headline)
                            HStack(spacing: 8) {
                                ForEach([Color.black, .blue, .red, .yellow, .green, .pink], id: \.self) { color in
                                    Button { store.color = color; colorSettings = false } label: {
                                        Circle().fill(color).frame(width: 26, height: 26).frame(width: 36, height: 44)
                                    }.accessibilityLabel(colorName(color))
                                }
                            }
                            ColorPicker("自定义颜色", selection: $store.color, supportsOpacity: false)
                        }.padding(24).tint(ReaderStyle.accent).presentationCompactAdaptation(.popover)
                    }
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 5)
        }.foregroundStyle(ReaderStyle.accent).background(ReaderStyle.paper)
    }
    private var divider: some View { Rectangle().fill(ReaderStyle.line).frame(width: 1, height: 24).padding(.horizontal, 8) }
    private func colorName(_ color: Color) -> String {
        color == .black ? "黑色" : color == .blue ? "蓝色" : color == .red ? "红色" : color == .yellow ? "黄色" : color == .green ? "绿色" : "粉色"
    }
}

struct ReplyPane: View {
    @EnvironmentObject var store: ReaderStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 19)).foregroundStyle(ReaderStyle.accent)
                    .frame(width: 40, height: 40).background(ReaderStyle.ambientGradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) { Text("AI 批注").font(.system(size: 16, weight: .semibold)); Text("AI").font(.system(size: 9, weight: .bold)).foregroundStyle(ReaderStyle.accent).padding(.horizontal, 6).padding(.vertical, 3).background(ReaderStyle.soft, in: Capsule()) }
                    Text(store.autoReply ? "停笔后自动回答" : "自动回复已暂停").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(22)
            Rectangle().fill(ReaderStyle.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if store.replies.isEmpty { welcome }
                    ForEach(store.replies) { reply in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Button { store.jump(reply.page) } label: { Label("第 \(reply.page) 页", systemImage: "arrow.up.right") }; Spacer(); Text("页边对话").foregroundStyle(.tertiary) }.font(.system(size: 10))
                            Text(reply.question).font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(ReaderStyle.soft, in: RoundedRectangle(cornerRadius: 10))
                            if let ink = reply.inkImageDataURL, let comma = ink.firstIndex(of: ","),
                               let data = Data(base64Encoded: String(ink[ink.index(after: comma)...])), let image = UIImage(data: data) {
                                DisclosureGroup("查看原始手写问题") { Image(uiImage: image).resizable().scaledToFit() }
                                    .font(.caption)
                            }
                            Text(reply.answer).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                            DisclosureGroup("查看引用正文") { Text(reply.source.isEmpty ? "此次使用附近正文图像。" : reply.source).font(.caption).lineSpacing(4).padding(.top, 8) }.font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(reply.model).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }.padding(16).background(ReaderStyle.paper, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(ReaderStyle.line))
                    }
                }.padding(22)
            }
            HStack(spacing: 7) { Image(systemName: "lock.shield"); Text("本机识别 · 停笔自动回复") }
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(18).frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Rectangle().fill(ReaderStyle.line).frame(height: 1) }
        }.background(ReaderStyle.paper)
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(ReaderStyle.brandGradient).padding(.top, 28).padding(.bottom, 22)
            Text("本书暂无 AI 批注").font(.system(size: 18, weight: .semibold)).lineSpacing(7).padding(.top, 12)
            Text("在段落旁写下疑问，停笔后自动回复。\n我会结合附近正文，和你一起想。")
                .font(.system(size: 12)).lineSpacing(6).foregroundStyle(.secondary).padding(.top, 16).padding(.bottom, 26)
            example("理解一句话", "这里的自由是什么意思？")
            example("追问一个观点", "为什么会这样？")
            example("带着自己的判断", "我不同意作者这里。")
            Label("把问题写在目标段落旁边，\n让每一次对话都有上下文。", systemImage: "pencil.tip")
                .font(.system(size: 11)).lineSpacing(5).foregroundStyle(.secondary).padding(.top, 22)
        }
    }
    private func example(_ title: String, _ question: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 9)).foregroundStyle(.secondary); Text("「\(question)」").font(.system(size: 12)).foregroundStyle(ReaderStyle.accent) }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(ReaderStyle.soft, in: RoundedRectangle(cornerRadius: 12)).padding(.bottom, 10)
    }
}

private struct ReaderLibrary: View {
    @EnvironmentObject var store: ReaderStore
    @Environment(\.dismiss) private var dismiss
    let open: (Book) -> Void
    let importPDF: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本机文档").font(.system(size: 20, weight: .semibold))
                        Text("\(store.books.count) 本书 · 笔记与对话保存在本机").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 12)
                    if store.books.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "books.vertical").font(.system(size: 40, weight: .light)).foregroundStyle(ReaderStyle.accent)
                            Text("书架还空着，放入第一本书吧。").font(.subheadline).foregroundStyle(.secondary)
                            Button(action: importPDF) { Label("导入 PDF", systemImage: "plus") }.buttonStyle(ReaderActionStyle(prominent: true))
                        }.frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                        ForEach(store.books) { book in
                            Button { open(book) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10).fill(ReaderStyle.soft)
                                        Image(systemName: "book.closed").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(ReaderStyle.accent)
                                    }.frame(height: 130)
                                    Text(book.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(2).frame(height: 38, alignment: .top)
                                    HStack { Text("读到第 \(book.lastPage) 页"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 11)).foregroundStyle(ReaderStyle.accent)
                                }.padding(16).background(ReaderStyle.paper, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(ReaderStyle.line))
                            }.buttonStyle(.plain).disabled(store.busy)
                        }
                    }
                }.padding(24)
            }.background(ReaderStyle.canvas).navigationTitle("我的书库").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }; ToolbarItem(placement: .primaryAction) { Button(action: importPDF) { Image(systemName: "plus") }.accessibilityLabel("导入 PDF") } }
        }.tint(ReaderStyle.accent)
    }
}

struct ReaderSettings: View {
    @EnvironmentObject var store: ReaderStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ProviderKey.read()
    @AppStorage("handwritingLanguage") private var handwritingLanguage = "zh-Hans"
    @State private var model = UserDefaults.standard.string(forKey: "openAIAnswerModel") ?? "gpt-6.1-sol"
    var body: some View {
        NavigationStack {
            Form {
                Section("自动回复") {
                    Toggle("停笔自动识别并回答", isOn: $store.autoReply)
                    Picker("停笔等待", selection: $store.autoReplyDelay) {
                        Text("1 秒").tag(1.0)
                        Text("2 秒").tag(2.0)
                        Text("3 秒").tag(3.0)
                        Text("4 秒").tag(4.0)
                    }
                    Text("默认停笔 2 秒后识别这句话并自动回答，无需点击或确认。继续书写会重新计时；只高光划线或擦除不会提问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("书写手感") {
                    Toggle("书写时锁定页面（防手掌误触）", isOn: $store.lockPageForWriting)
                    Text("Pencil 落笔或悬停时自动防误触。手掌先落下仍会拖动时，可开启页面锁定；开启后用底部按钮翻页，关闭后恢复手指滚动和缩放。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Text("稳定度"); Spacer(); Text("\(Int(store.stabilization * 100))%") }
                    Slider(value: $store.stabilization, in: 0...1)
                    Text("默认 15%。低稳定度适合快速笔记；提高稳定度可减少抖动，也会增加跟随延迟。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Text("压感强度"); Spacer(); Text("\(Int(store.pressureSensitivity * 100))%") }
                    Slider(value: $store.pressureSensitivity, in: 0...1)
                    Text("圆珠笔始终等宽。钢笔温和变化；画笔压感更强，带起收笔变细。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("恢复默认手感") { store.stabilization = 0.15; store.pressureSensitivity = 0.5 }
                }
                Section("OpenAI · iPad 独立连接") {
                    SecureField("OpenAI API Key", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("填写你的 OpenAI 账户可调用的模型 ID；模型需支持图片输入和结构化回答。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("直接从 iPad 连接 AI，无需电脑服务。密钥保存在本机钥匙串；停笔后自动发送识别文字、原始笔迹图和附近正文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("本机识别") {
                    Text("iPadOS 27 优先 Apple 笔画识别；旧系统、语言不支持或无识别文字时，回退内置 PaddleOCR。")
                    TextField("手写主要语言（如 zh-Hans、en）", text: $handwritingLanguage).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("识别文字只是参考；问题的原始笔迹图与附近正文一起发送给支持图片的模型。数学符号看不清时会请求澄清。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.scrollContentBackground(.hidden).background(ReaderStyle.canvas)
                .navigationTitle("阅读偏好").navigationBarTitleDisplayMode(.inline).toolbar { Button("保存") {
                do {
                    let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !selectedModel.isEmpty else { throw ReaderError.message("请填写 OpenAI 模型 ID。") }
                    try ProviderKey.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
                    UserDefaults.standard.set(selectedModel, forKey: "openAIAnswerModel")
                    dismiss()
                }
                catch { store.error = error.localizedDescription }
            } }
        }
    }
}
