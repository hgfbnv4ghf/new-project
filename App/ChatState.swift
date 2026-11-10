import Foundation
import Observation
import TermCore

struct PendingApproval: Identifiable, Equatable {
    let id = UUID()
    let summary: String
}

/// Everything that belongs to one chat. The terminal and Cowork each have their own, so a run in one
/// carries on while the other is on screen.
@MainActor
@Observable
final class ChatState {
    let kind: SessionKind
    var session = Session()
    var input = ""
    var isRunning = false
    var pendingApproval: PendingApproval?
    var usageLine: String?
    /// Prompt tokens the API counted for the latest request, until the history changes shape.
    var reportedInput: Int?
    /// Bumped when the transcript should jump to the bottom.
    var scrollTick = 0

    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    @ObservationIgnored var alwaysAllow = false
    @ObservationIgnored var assistantItemID: UUID?
    @ObservationIgnored var toolItems: [String: UUID] = [:]
    @ObservationIgnored var promptHistory: [String] = []
    @ObservationIgnored var historyIndex: Int?
    @ObservationIgnored var runStart = Date()
    @ObservationIgnored var listedSessions: [SessionSummary] = []

    init(kind: SessionKind) {
        self.kind = kind
        session = Session(kind: kind)
    }

    // MARK: Transcript

    @discardableResult
    func append(_ kind: TranscriptItem.Kind, _ text: String, title: String? = nil,
                status: TranscriptItem.Status? = nil) -> UUID {
        let item = TranscriptItem(kind: kind, text: text, title: title, status: status)
        session.transcript.append(item)
        return item.id
    }

    func info(_ text: String) { append(.info, text) }
    func fail(_ text: String) { append(.error, text) }

    func mutateItem(_ id: UUID?, _ change: (inout TranscriptItem) -> Void) {
        guard let id, let index = session.transcript.lastIndex(where: { $0.id == id }) else { return }
        change(&session.transcript[index])
    }

    func appendOutput(_ id: UUID?, _ chunk: String) {
        mutateItem(id) { item in
            item.text += chunk
            // Only the tail is shown; keep the stored text bounded for long-running commands.
            if item.text.count > 24_000 { item.text = String(item.text.suffix(16_000)) }
        }
    }

    /// Swaps in another session and forgets what belonged to the old one.
    func show(_ session: Session) {
        self.session = session
        alwaysAllow = false
        usageLine = nil
        reportedInput = nil
    }
}
