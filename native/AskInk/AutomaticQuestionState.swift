import Foundation

// Shared by the debounce and request paths: new ink waits while a request runs.
struct AutomaticQuestionState {
    private(set) var pending: UUID?
    private var notes: [String: Set<Date>] = [:]
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
    func scannedStrokes(for key: String) -> Set<Date> { (submitted[key] ?? []).union(notes[key] ?? []) }
    mutating func assessedNote(_ starts: [Date], for key: String) { notes[key, default: []].formUnion(starts) }
    func excludedStrokes(for key: String) -> Set<Date> { submitted[key] ?? [] }
    mutating func submitted(_ starts: [Date], for key: String) {
        submitted[key, default: []].formUnion(starts)
    }
    mutating func withdrawSubmission(_ starts: [Date], for key: String) {
        submitted[key]?.subtract(starts)
        notes[key]?.subtract(starts)
    }

}
