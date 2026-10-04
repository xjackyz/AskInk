import UIKit
import Vision
import PencilKit

struct QuestionSnapshot {
    var page: Int
    var ink: UIImage
    var handwritingImage: UIImage
    var context: String
    var pageImage: UIImage
    var drawing: PKDrawing
    var bookID: UUID
    var revision: UUID
    var scope: InkScope
    var block: Int
    var blockCount: Int
    var inkDataURL: String { "data:image/png;base64," + (ink.pngData()?.base64EncodedString() ?? "") }
    var handwritingDataURL: String { "data:image/png;base64," + (handwritingImage.pngData()?.base64EncodedString() ?? "") }
    var pageDataURL: String { "data:image/jpeg;base64," + (pageImage.jpegData(compressionQuality: 0.85)?.base64EncodedString() ?? "") }
}
struct QuestionDraft: Identifiable {
    var id = UUID()
    var snapshot: QuestionSnapshot
    var text: String
    var candidates: [HandwritingCandidate]
    var source: String
    var milliseconds: Double
    var recognitionNote: String
    var regions: [HandwritingRegion] = []
    var recognitionVersion: Int? = nil
}
// The iPad sends directly to the selected HTTPS provider.
enum ReaderAPI {
    static func call<T: Decodable>(_ path: String, body: [String:Any]) async throws -> T {
        guard path == "answer" else { throw ReaderError.message("识字在本机完成。") }
        let connection = AIConnection.stored(AIProvider.selected)
        let request = try AIRequest.request(connection:connection,key:ProviderKey.read(provider:connection.provider),body:body)
        let (data,response) = try await URLSession.shared.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw ReaderError.message("AI 没有返回有效响应。") }
        let answer = try AIRequest.decode(data:data,status:http.statusCode,connection:connection)
        return try JSONDecoder().decode(T.self,from:JSONEncoder().encode(answer))
    }
}
