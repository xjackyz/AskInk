import SwiftUI

@MainActor
final class AnswerViewportState: ObservableObject {
    @Published private(set) var positions: [UUID: CGPoint] = [:]
    @Published private(set) var thinking: CGPoint?
    @Published private(set) var failure: CGPoint?
    @Published private(set) var occupied: [CGRect] = []
    func update(positions: [UUID: CGPoint], thinking: CGPoint?, failure: CGPoint? = nil, occupied: [CGRect] = []) {
        if self.positions != positions { self.positions = positions }
        if self.thinking != thinking { self.thinking = thinking }
        if self.failure != failure { self.failure = failure }
        if self.occupied != occupied { self.occupied = occupied }
    }
}

struct AnswerOverlay: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var viewport: AnswerViewportState
    @Binding var expanded: UUID?
    @State private var showFailure = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if expanded != nil {
                    Color.black.opacity(0.025).contentShape(Rectangle()).onTapGesture { expanded = nil }
                }
                ForEach(store.overlayReplies) { reply in
                    if expanded == nil || expanded == reply.conversationID,
                       let position = viewport.positions[reply.conversationID],
                       CGRect(origin: .zero, size: geometry.size).insetBy(dx: -16, dy: -16).contains(position) {
                        MarginAnswer(store: store, reply: reply, anchor: position, viewport: geometry.size,
                            occupied: viewport.occupied, expanded: $expanded).id(reply.conversationID)
                    }
                }
                ForEach(store.unanswered) { saved in
                    if expanded == nil, let position = viewport.positions[saved.id] {
                        SavedQuestionMarker(store: store, saved: saved).position(x: max(20, min(geometry.size.width - 20, position.x + 16)), y: position.y + 12)
                    }
                }
                if let position = viewport.thinking, CGRect(origin: .zero, size: geometry.size).contains(position) {
                    let size = CGSize(width: min(280, max(180, geometry.size.width - 24)), height: store.streamingText.isEmpty ? 32 : 110)
                    let center = AnswerPlacement.center(anchor: position, card: size, viewport: geometry.size, occupied: viewport.occupied)
                    if expanded != store.streamingThreadID || store.streamingThreadID == nil {
                        HStack(alignment: .top, spacing: 7) {
                            BreathingSparkle()
                            if !store.streamingText.isEmpty { Text(store.streamingText).font(.system(size: 12)).lineSpacing(3).lineLimit(5) }
                        }.padding(10).frame(width: size.width, height: size.height, alignment: .topLeading)
                            .background {
                                if viewport.occupied.contains(where: { $0.intersects(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)) }) { RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial) }
                            }.position(center).allowsHitTesting(false).accessibilityLabel("正在回答")
                    }
                }
                if let position = viewport.failure, store.failedQuestion != nil, store.unanswered.isEmpty {
                    Button { showFailure = true } label: {
                        Image(systemName: store.questionOffline ? "icloud.slash" : "exclamationmark.circle")
                            .font(.system(size: 16)).foregroundStyle(.secondary).padding(10)
                    }.position(x: min(geometry.size.width - 20, max(20, position.x + 16)), y: min(geometry.size.height - 20, max(20, position.y + 10)))
                        .popover(isPresented: $showFailure) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(store.questionOffline ? "You're offline." : "Couldn't answer.").font(.headline)
                                if ProviderKey.read(provider: AIProvider.selected).isEmpty { Text("可在 Settings → AI → Advanced 配置自己的 AI 连接。问题和笔迹已保留。").font(.caption).foregroundStyle(.secondary) }
                                Button(store.questionOffline ? "Retry when connected" : "Retry") { showFailure = false; Task { await store.retryAutomaticQuestion() } }.disabled(store.busy)
                            }.padding(24).frame(width: 280).presentationCompactAdaptation(.popover)
                        }.accessibilityLabel(store.questionOffline ? "离线问题，点击重试" : "问题未回答，点击重试")
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.onChange(of: store.scrollRevision) { _, _ in expanded = nil }
    }
}

private struct MarginAnswer: View {
    @ObservedObject var store: ReaderStore
    var reply: ReadingReply
    var anchor: CGPoint
    var viewport: CGSize
    var occupied: [CGRect]
    @Binding var expanded: UUID?
    @State private var compact = false
    @State private var revealRevision = 0
    @State private var followup = ""
    @State private var followupError: String?
    private var isExpanded: Bool { expanded == reply.conversationID }
    private var portrait: Bool { viewport.width < 700 || viewport.height > viewport.width }
    private var cardSize: CGSize {
        if isExpanded { return CGSize(width: portrait ? max(220, viewport.width - 24) : min(500, viewport.width - 32), height: max(180, viewport.height * 0.62)) }
        if compact { return CGSize(width: min(280, max(180, viewport.width - 24)), height: 96) }
        return CGSize(width: 32, height: 32)
    }
    var body: some View {
        let size = cardSize
        let center = isExpanded && portrait ? CGPoint(x: viewport.width / 2, y: viewport.height - size.height / 2 - 8) : AnswerPlacement.center(anchor: anchor, card: size, viewport: viewport, occupied: occupied, preferBelow: portrait)
        ZStack {
            if isExpanded {
                Path { path in path.move(to: anchor); path.addLine(to: CGPoint(x: center.x, y: center.y - size.height / 2)) }
                    .stroke(Color.indigo.opacity(0.14), lineWidth: 1).allowsHitTesting(false)
            }
            Group {
                if isExpanded { thread }
                else if compact {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 4) {
                            Button { expanded = reply.conversationID } label: {
                                Text(reply.answer).font(.system(size: 12)).lineSpacing(3).lineLimit(3).multilineTextAlignment(.leading)
                            }.accessibilityLabel(reply.answer)
                            Button("More ›") {
                                expanded = reply.conversationID
                                if reply.mode != .expanded { ask(reply.question, style: "Detailed") }
                            }.font(.system(size: 10)).foregroundStyle(.secondary).disabled(store.busy)
                        }
                    }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Button { compact = true; revealRevision += 1 } label: { Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(.indigo).frame(width: 32, height: 32) }.accessibilityLabel("显示页边回答")
                }
            }.frame(width: size.width, height: size.height)
                .background {
                    let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
                    if isExpanded || (compact && occupied.contains(where: { $0.intersects(rect) })) { RoundedRectangle(cornerRadius: isExpanded ? 18 : 6).fill(.ultraThinMaterial) }
                }
                .position(center)
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .task(id: reply.id) {
                compact = reply.createdAt.map { Date().timeIntervalSince($0) < 10 } ?? false
                revealRevision += 1
            }
            .task(id: revealRevision) {
                guard compact else { return }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if !isExpanded { withAnimation(.easeOut(duration: 0.2)) { compact = false } }
            }
            .onChange(of: expanded) { previous, current in
                if previous == reply.conversationID && current != previous { compact = false }
            }
            .onChange(of: store.scrollRevision) { _, _ in compact = false }
    }
    private var thread: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.replies.first(where: { $0.conversationID == reply.conversationID })?.question ?? reply.question).lineLimit(2).font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Button("Copy Answer") { UIPasteboard.general.string = reply.answer }
                    Button("Regenerate") { ask(reply.question) }
                    Button("More · Explain Deeply") { ask(reply.question, style: "Detailed") }
                    Button("Delete Thread", role: .destructive) { expanded = nil; store.deleteThread(reply.conversationID) }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }.disabled(store.busy)
                Button { expanded = nil; compact = false } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }.accessibilityLabel("关闭对话")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.replies.filter { $0.conversationID == reply.conversationID }) { message in
                        Text(message.question).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        Text(message.answer).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    }
                    Button("Source · p.\(reply.page)") {
                        expanded = nil; compact = false
                        if let source = reply.sourceReferences?.first(where: { $0.page == reply.page }) { store.jumpToSource(source) }
                        else { store.jump(reply.page) }
                    }.font(.system(size: 11)).foregroundStyle(.indigo)
                    if let sources = reply.sourceReferences, sources.contains(where: { $0.page < reply.page }) {
                        DisclosureGroup("前文候选 · 点击定位") {
                            ReadingSourcesView(store: store, sources: sources.filter { $0.page < reply.page })
                        }.font(.caption)
                    }
                    if store.streamingThreadID == reply.conversationID {
                        Text(store.streamingQuestion).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        HStack(alignment: .top) { BreathingSparkle(); Text(store.streamingText).font(.system(size: 14)).lineSpacing(5) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let followupError { Text(followupError).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack {
                TextField("Ask a follow-up…", text: $followup).font(.system(size: 13)).submitLabel(.send).onSubmit { send() }
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).foregroundStyle(.indigo) }
                    .disabled(store.busy || followup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送追问")
            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }.padding(20)
    }
    private func ask(_ text: String, style: String? = nil) {
        guard !store.busy else { return }
        Task { if !(await store.askFollowup(replyID: reply.id, question: text, style: style)) { followupError = "Couldn't answer. Please try again." } }
    }
    private func send() {
        let text = followup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.busy else { return }
        followupError = nil
        Task {
            if await store.askFollowup(replyID: reply.id, question: text) {
                if followup.trimmingCharacters(in: .whitespacesAndNewlines) == text { followup = "" }
            } else { followupError = "Couldn't answer. Your question is kept here." }
        }
    }
}

private struct SavedQuestionMarker: View {
    @ObservedObject var store: ReaderStore
    var saved: SavedQuestion
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Image(systemName: saved.offline ? "icloud.slash" : "exclamationmark.circle").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 36, height: 36) }
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(!UserDefaults.standard.bool(forKey: "aiPrivacyConsent") ? "Answer this question?" : saved.offline ? "You're offline." : "Couldn't answer.").font(.headline)
                    Text(saved.question).font(.subheadline).lineLimit(3)
                    if ProviderKey.read(provider: AIProvider.selected).isEmpty { Text("可在 Settings → AI → Advanced 配置连接。问题保存在本机。").font(.caption).foregroundStyle(.secondary) }
                    Button(saved.offline ? "Retry when connected" : "Retry") { presented = false; Task { await store.retrySavedQuestion(saved) } }.disabled(store.busy)
                }.padding(24).frame(width: 270).presentationCompactAdaptation(.popover)
            }.accessibilityLabel("尚未回答的问题，点击重试")
    }
}

private struct BreathingSparkle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false
    var body: some View {
        Image(systemName: "sparkle").font(.system(size: 14)).foregroundStyle(.indigo)
            .opacity(reduceMotion ? 0.8 : (bright ? 1 : 0.6))
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { bright = true } } }
            .accessibilityLabel("AI 正在回答")
    }
}
