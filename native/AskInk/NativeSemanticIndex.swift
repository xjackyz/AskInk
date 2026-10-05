import Foundation
import NaturalLanguage

// System sentence embeddings are genuinely local, but not available for every
// language/device. Missing assets never trigger a download or a cloud fallback.
enum NativeSemanticIndex {
    static func embed(_ text: String) -> ContentEmbedding? {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text),
              let model = NLEmbedding.sentenceEmbedding(for: language),
              let vector = model.vector(for: String(text.prefix(1000))), !vector.isEmpty else { return nil }
        return ContentEmbedding(modelID: "apple-sentence:\(language.rawValue):\(model.revision)", vector: vector)
    }
}
