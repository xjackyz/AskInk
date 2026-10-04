import UIKit
import PencilKit

struct HandwritingCandidate: Identifiable {
    var id: String { text }
    var text: String
    var score: Float? = nil
}
struct HandwritingRegion: Codable {
    var text: String
    var bounds: CGRect
    var strokeIDs: [UUID]
}
struct HandwritingResult {
    var candidates: [HandwritingCandidate]
    var source: String
    var milliseconds: Double
    var note: String
    var regions: [HandwritingRegion] = []
    var recognitionVersion: Int? = nil
    var text: String { candidates.first?.text ?? "" }
}

// Stroke recognition on iPadOS 27; bundled image OCR is the offline fallback.
actor HandwritingRecognizer {
    static let shared = HandwritingRecognizer()
    private let sessions = ORTSessionManager()
    private var engine: OCREngine?
    private var loading: Task<OCREngine, Error>?
    private func loadedEngine() async throws -> OCREngine {
        if let engine { return engine }
        if let loading { return try await loading.value }
        let task = Task { [sessions] in
            try await sessions.loadModels(tuning: ORTSessionTuningOptions(intraOpThreads: 2))
            return try OCREngine(sessionManager: sessions)
        }
        loading = task
        do { let result = try await task.value; engine = result; loading = nil; return result }
        catch { loading = nil; throw error }
    }
    func recognize(drawing: PKDrawing, image: UIImage) async throws -> HandwritingResult {
        try Task.checkCancellation()
        let start = Date()
        let language = UserDefaults.standard.string(forKey: "handwritingLanguage") ?? "zh-Hans"
        var fallbackReason = "当前系统不支持 Apple 笔画识别。"
        if #available(iOS 27.0, *) {
            if let result = try await recognizeStrokes(drawing, language: language, start: start) { return result }
            fallbackReason = "Apple 不支持所选语言或未返回文字。"
        }
        try Task.checkCancellation()
        do {
            guard let cgImage = image.cgImage else { throw ReaderError.message("笔迹图像无法读取。") }
            let engine = try await loadedEngine()
            try Task.checkCancellation()
            var params = OCRRuntimeParams.noOverrides
            params.textRecScoreThresh = 0 // Keep uncertain text visible for correction.
            params.textRecBatchSize = 4
            let result = try await engine.run(cgImage, params: params)
            try Task.checkCancellation()
            let lines = result.results.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let text = lines.map(\.text).joined(separator: "\n")
            let uncertain = lines.filter { $0.confidence < 0.75 }.map(\.text)
            return HandwritingResult(candidates: text.isEmpty ? [] : [.init(text: text)], source: "PaddleOCR v6 · 本机",
                milliseconds: Date().timeIntervalSince(start) * 1000,
                note: fallbackReason + (text.isEmpty ? "PaddleOCR 也未识别到文字，将保留笔迹图供 AI 判断。" : uncertain.isEmpty ? "请核对文字，尤其是数字、公式和否定词。" : "这些文字可能不准确，请核对：" + uncertain.joined(separator: "、")))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return HandwritingResult(candidates: [], source: "本机识别不可用",
                milliseconds: Date().timeIntervalSince(start) * 1000,
                note: "本机识别失败，转录为空；请结合原始笔迹图判断，不根据正文猜测问题。")
        }
    }
    @available(iOS 27.0, *)
    private func recognizeStrokes(_ drawing: PKDrawing, language: String, start: Date) async throws -> HandwritingResult? {
        let supported = PKStrokeRecognizer.supportedLanguages
        let requested = Locale.Language(identifier: language)
        // Do not silently switch unsupported handwriting to a different language.
        guard supported.contains(where: { $0.isEquivalent(to: requested) }) else { return nil }
        var languages = [requested]
        let english = Locale.Language(identifier: "en")
        if requested != english, supported.contains(where: { $0.isEquivalent(to: english) }) { languages.append(english) }
        // Each snapshot owns a recognizer: concurrent/cancelled snapshots cannot
        // replace the drawing while an older asynchronous result is being read.
        let recognizer = PKStrokeRecognizer(preferredLanguages: languages)
        await recognizer.updateDrawing(drawing)
        try Task.checkCancellation()
        guard let text = await recognizer.recognizedText()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        try Task.checkCancellation()
        var regions: [HandwritingRegion] = []
        for line in text.split(separator: "\n").prefix(24) {
            let matches = await recognizer.search(String(line))
            try Task.checkCancellation()
            regions.append(contentsOf: matches.map {
                HandwritingRegion(text: String(line), bounds: $0.bounds, strokeIDs: Array($0.strokes))
            })
        }
        return HandwritingResult(candidates: [.init(text: text)], source: "Apple 笔画识别 · 本机",
            milliseconds: Date().timeIntervalSince(start) * 1000,
            note: "直接识别笔画；Apple 接口没有提供置信度。数学符号和混写仍需结合原始笔迹判断。",
            regions: regions, recognitionVersion: PKStrokeRecognizer.recognitionVersion)
    }

}
