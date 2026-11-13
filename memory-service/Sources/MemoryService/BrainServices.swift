import Foundation
import BrainContract
import MemoryCore

/// The single-owner bearer is mapped to server-defined capabilities at the entry point.
/// A request may identify its thread or an issued receipt, but may never supply a grant.
final class BrainServices: @unchecked Sendable {
    let store: MemoryStore
    let transcript: TranscriptStore
    let embedder: any Embedder
    let modelClient: any ModelTextClient
    let gatewayTurns = GatewayTurnCoordinator()
    private let affectLock = NSLock()
    private var affectSessions: [String: AffectiveContextService] = [:]
    private var affectAccess: [String] = []

    init(store: MemoryStore, transcript: TranscriptStore, embedder: any Embedder, modelClient: any ModelTextClient) {
        self.store = store
        self.transcript = transcript
        self.embedder = embedder
        self.modelClient = modelClient
    }

    func grant(threadID: String, write: Bool = false, forget: Bool = false, reviseIdentity: Bool = false) -> BrainAuthorization {
        let owner = ConsolidationEvidenceAdapter.ownerID
        return BrainAuthorization(principal: owner, owner: owner, subjects: BrainIdentity.reservedSubjects,
            scopes: [.user, .thread, .agent, .shared], threads: [threadID], sourceSpeakers: [
                .userMessage: [BrainIdentity.userID], .assistantMessage: [BrainIdentity.agentID], .toolObservation: ["tool:gateway"]
            ], mayCommitClaims: write, mayForget: forget, mayReviseIdentity: reviseIdentity)
    }

    func context(_ request: BrainContextRequest, startup: Bool = false, excluding currentSource: String? = nil,
                 semanticSelection: Bool = true) async throws -> BrainContextBundle {
        let brain = BrainStore(store: store, authorization: grant(threadID: request.threadID))
        let conversation = ConversationStateStore(brain: brain)
        let affect = try affectService(threadID: request.threadID)
        let selector = semanticSelection ? GatewayDetailSelector(model: modelClient, excluding: currentSource) : nil
        for _ in 0..<2 {
            let shared = try brain.ownerSharedRecall(threadID: request.threadID)
            let assembler = BrainContextAssembler(store: conversation, selector: selector, affect: affect,
                recall: AssociativeRetriever(brain: shared, embedder: embedder))
            do {
                return try await assembler.context(request, recallOptions: .init(asOf: Date().timeIntervalSince1970,
                                                                                   includeStartupOrientation: startup))
            } catch BrainStoreError.conflict {
                try Task.checkCancellation()
            }
        }
        // Avoid reusing either discarded semantic result. A fresh, synchronous context snapshot
        // retains the active conversation when unrelated activity keeps changing the revision.
        return try await BrainContextAssembler(store: conversation, affect: affect).context(request)
    }

    func turnService(threadID: String) -> BrainTurnService {
        let grant = grant(threadID: threadID, write: true)
        return BrainTurnService(store: store, authorization: grant,
            extractor: GatewayTurnExtractor(model: modelClient, brain: BrainStore(store: store, authorization: grant)))
    }

    func turnService(turnID: String) throws -> BrainTurnService {
        let thread = try turnService(threadID: "").owningThread(turnID: turnID, nativeOnly: true)
        return turnService(threadID: thread)
    }

    func begin(_ request: BrainTurnRequest, gateway: BrainGatewayAdmission? = nil,
               onAdmission: (() async -> Void)? = nil) async throws -> BrainTurnResult {
        let brain = self
        let grant = grant(threadID: request.threadID, write: true)
        let affect = try affectService(threadID: request.threadID)
        let service = BrainTurnService(store: store, authorization: grant,
            extractor: GatewayTurnExtractor(model: modelClient, brain: BrainStore(store: store, authorization: grant)),
            retrieval: { request, source in
                let context = try BrainContextRequest(clientOperationID: request.clientOperationID, threadID: request.threadID,
                                                      query: request.message.text, budget: request.budget)
                let first = try brain.transcript.range(threadId: request.threadID, from: 1, to: 2).count == 1
                do {
                    return try await brain.context(context, startup: first, excluding: source.id)
                } catch BrainContextAssemblyError.insufficientBudget where gateway == nil {
                    // The native caller still needs its receipt to complete the admitted turn.
                    // Its local recent window can supply context within the provider's budget.
                    return nil
                }
            }, afterLearning: { turnID, _ in
                _ = try? await affect.observe(turnID: turnID, now: Date().timeIntervalSince1970)
            })
        return try await service.begin(request, useServerTimestamp: true, gateway: gateway, onAdmission: onAdmission)
    }
    func affectService(threadID: String) throws -> AffectiveContextService {
        try affectLock.withLock {
            affectAccess.removeAll { $0 == threadID }
            let service: AffectiveContextService
            if let existing = affectSessions[threadID] { service = existing }
            else {
                let brain = BrainStore(store: store, authorization: grant(threadID: threadID))
                service = try AffectiveContextService(brain: brain, extractor: GatewayAffectExtractor(model: modelClient))
                affectSessions[threadID] = service
            }
            affectAccess.append(threadID)
            if affectAccess.count > 32 { affectSessions[affectAccess.removeFirst()] = nil }
            return service
        }
    }
}

/// Coalesce simultaneous retries before invoking the provider or executing tools. The durable
/// brain journal remains the authority for request conflicts and completed reply replays.
actor GatewayTurnCoordinator {
    private struct Pending {
        let threadID: String
        let text: String
        let admission: BrainGatewayAdmission
        let task: Task<String, Error>
    }
    private var pending: [String: Pending] = [:]

    func run(_ request: BrainTurnRequest, admission: BrainGatewayAdmission,
             operation: @escaping @Sendable () async throws -> String) async throws -> String {
        if let existing = pending[request.clientOperationID] {
            guard existing.threadID == request.threadID, existing.text == request.message.text,
                  existing.admission == admission else { throw BrainStoreError.conflict }
            return try await existing.task.value
        }
        let task = Task { try await operation() }
        pending[request.clientOperationID] = .init(threadID: request.threadID, text: request.message.text,
                                                   admission: admission, task: task)
        defer { pending[request.clientOperationID] = nil }
        return try await task.value
    }
}
