import Foundation

// Shared by the debounce and request paths: new ink waits while a request runs.
struct AutomaticQuestionState {
    private(set) var pending: UUID?
    private var submitted: [String: Set<Date>] = [:]

    mutating func schedule() -> UUID {
        let token = UUID()
        pending = token
        return token
    }
    mutating func cancel() { pending = nil }
    mutating func consume(_ token: UUID, canStart: Bool = true) -> Bool {
        guard canStart, pending == token else { return false }
        pending = nil
        return true
    }
    func excludedStrokes(for key: String) -> Set<Date> { submitted[key] ?? [] }
    mutating func submitted(_ starts: [Date], for key: String) {
        submitted[key, default: []].formUnion(starts)
    }
}
