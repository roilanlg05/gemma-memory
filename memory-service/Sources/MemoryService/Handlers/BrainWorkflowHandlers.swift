import Foundation
import BrainContract
import Hummingbird
import HTTPTypes
import MemoryCore

extension BrainHandlers {
    static func schema(_ supplied: Int?) throws {
        let version = supplied ?? 1
        guard version == 1 else { throw BrainContractError.unsupportedSchemaVersion(version) }
    }

    @Sendable func propose(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainUpdateProposalRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.turnID) else { throw BrainStoreError.invalid }
            let turns = try services.brain.turnService(turnID: body.turnID)
            let proposals = try await turns.proposeUpdates(turnID: body.turnID)
            let state = try turns.completion(turnID: body.turnID)
            return try Self.response(BrainUpdateProposalResult(turnID: body.turnID, revision: state.revision, updates: proposals))
        } catch { return Self.failure(error) }
    }

    @Sendable func commit(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainStagedCommitRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.turnID), body.expectedRevision >= 0, body.updates.count <= 16 else {
                throw BrainStoreError.invalid
            }
            let turns = try services.brain.turnService(turnID: body.turnID)
            let result = try turns.commitUpdates(body.updates, turnID: body.turnID, expectedRevision: body.expectedRevision)
            if result.disposition == .conflict { throw BrainStoreError.conflict }
            return try Self.response(result)
        } catch { return Self.failure(error) }
    }

    @Sendable func identity(_ request: Request, _: BasicRequestContext) async -> Response {
        let q = request.uri.queryParameters
        let subject = q["subjectID"].map(String.init) ?? BrainIdentity.agentID
        let thread = q["threadID"].map(String.init) ?? "gateway"
        guard Self.validID(thread) else { return Self.failure(BrainStoreError.invalid) }
        let brain = BrainStore(store: services.store, authorization: services.brain.grant(threadID: thread))
        let service = AgentIdentityService(brain: brain)
        do {
            return try Self.response(subject == BrainIdentity.relationshipID ? service.relationship() : service.identity(agentID: subject))
        } catch { return Self.failure(error) }
    }

    @Sendable func revise(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainIdentityRevisionRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.threadID), Self.validID(body.clientOperationID),
                  body.expectedRevision >= 0, body.change.evidenceIDs.count <= 16 else { throw BrainStoreError.invalid }
            let grant = services.brain.grant(threadID: body.threadID, reviseIdentity: true)
            let brain = BrainStore(store: services.store, authorization: grant)
            let result = try AgentIdentityService(brain: brain).reviseIdentity(expectedRevision: body.expectedRevision,
                operationID: body.clientOperationID, change: body.change)
            return try Self.response(result)
        } catch { return Self.failure(error) }
    }

    @Sendable func affect(_ request: Request, _: BasicRequestContext) async -> Response {
        guard let thread = request.uri.queryParameters["threadID"].map(String.init), Self.validID(thread) else {
            return Self.failure(BrainStoreError.invalid)
        }
        do {
            let result = try services.brain.affectService(threadID: thread)
                .context(threadID: thread, now: Date().timeIntervalSince1970)
            return try Self.response(result)
        } catch { return Self.failure(error) }
    }

    private struct AffectCorrectionBody: Decodable {
        let schemaVersion: Int?
        let threadID: String
        let hypothesisID: String
        let clientOperationID: String
        let correction: BrainAffectCorrection
    }

    @Sendable func correctAffect(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(AffectCorrectionBody.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.threadID), Self.validID(body.hypothesisID), Self.validID(body.clientOperationID) else {
                throw BrainStoreError.invalid
            }
            try services.brain.affectService(threadID: body.threadID).correct(hypothesisID: body.hypothesisID,
                operationID: body.clientOperationID, correction: body.correction)
            return try Self.response([String: String]())
        } catch { return Self.failure(error) }
    }

    private struct AffectEndBody: Decodable { let schemaVersion: Int?; let threadID: String }

    @Sendable func endAffect(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(AffectEndBody.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.threadID) else { throw BrainStoreError.invalid }
            try services.brain.affectService(threadID: body.threadID).endSession(threadID: body.threadID)
            return try Self.response([String: String]())
        } catch { return Self.failure(error) }
    }

    @Sendable func forget(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainForgetRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.clientOperationID), body.expectedRevision >= 0,
                  body.scope.id.map(Self.validID) ?? true, body.threadID.map(Self.validID) ?? true else {
                throw BrainStoreError.invalid
            }
            let thread = body.scope.kind == .thread ? body.scope.id : body.threadID
            let grant = services.brain.grant(threadID: thread ?? "", forget: true)
            let brain = BrainStore(store: services.store, authorization: grant)
            let receipt = try brain.ownerErasure().forget(scope: body.scope,
                expectedRevision: body.expectedRevision, operationID: body.clientOperationID)
            return try Self.response(receipt)
        } catch { return Self.failure(error) }
    }

    @Sendable func consolidate(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainConsolidationRequest.self, request)
            try Self.schema(body.schemaVersion)
            let timezone: TimeZone
            if let name = body.timezone {
                guard let parsed = TimeZone(identifier: name) else { throw BrainStoreError.invalid }
                timezone = parsed
            } else { timezone = .current }
            guard let job = await services.scheduler.startBrainJob(kind: body.kind, timeZone: timezone) else {
                throw BrainStoreError.conflict
            }
            return try Self.response(job, status: .accepted)
        } catch { return Self.failure(error) }
    }

    @Sendable func consolidationStatus(_ request: Request, _: BasicRequestContext) async -> Response {
        guard let id = request.uri.queryParameters["jobID"].map(String.init), Self.validID(id) else {
            return Self.failure(BrainStoreError.invalid)
        }
        guard let job = await services.scheduler.brainJob(id: id) else {
            return jsonError(.notFound, "job_not_found", "consolidation job unavailable")
        }
        do { return try Self.response(job) }
        catch { return Self.failure(error) }
    }
}

private struct OwnerResolutionAuthority: ProspectiveResolutionAuthority {
    let candidateID: String
    let evidenceID: String
    let label: String

    func approves(candidateID: String, evidence: BrainEvidence) -> Bool {
        guard candidateID == self.candidateID, evidence.id == evidenceID, let source = evidence.text else { return false }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let direct = ["resuelve ", "da por resuelta ", "da por resuelto ", "marca como resuelta ",
                      "marca como resuelto ", "resolve ", "dismiss ", "mark as resolved "]
        guard let command = direct.first(where: text.hasPrefix) else { return false }
        let target = text.dropFirst(command.count).trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
        let exact = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [exact, "la " + exact, "el " + exact, "the " + exact].contains(target)
    }
}

extension BrainHandlers {
    @Sendable func deferProspective(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainProspectiveDeferRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.candidateID), body.expectedRevision >= 0, body.until.isFinite,
                  body.until > Date().timeIntervalSince1970 else { throw BrainStoreError.invalid }
            let grant = services.brain.grant(threadID: "", write: true)
            try ProspectiveMemoryStore(store: services.store, authorization: grant)
                .deferFollowUp(id: body.candidateID, until: body.until, expectedRevision: body.expectedRevision)
            return try Self.response([String: String]())
        } catch { return Self.failure(error) }
    }

    @Sendable func resolveProspective(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainProspectiveResolutionRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.candidateID), Self.validID(body.turnID), Self.validID(body.evidenceID),
                  body.expectedRevision >= 0 else { throw BrainStoreError.invalid }
            let turns = try services.brain.turnService(turnID: body.turnID)
            let admitted = try turns.completion(turnID: body.turnID)
            guard admitted.evidenceIDs == [body.evidenceID],
                  let node = try services.store.node(id: body.candidateID) else { throw BrainStoreError.denied }
            let thread = try turns.owningThread(turnID: body.turnID, nativeOnly: true)
            let grant = services.brain.grant(threadID: thread, write: true)
            let authority = OwnerResolutionAuthority(candidateID: body.candidateID, evidenceID: body.evidenceID, label: node.label)
            try ProspectiveMemoryStore(store: services.store, authorization: grant, resolutionAuthority: authority)
                .resolveCandidate(id: body.candidateID, evidenceID: body.evidenceID, expectedRevision: body.expectedRevision)
            return try Self.response([String: String]())
        } catch { return Self.failure(error) }
    }

    @Sendable func acknowledgeProspective(_ request: Request, _: BasicRequestContext) async -> Response {
        do {
            let body = try await Self.read(BrainProspectiveReceiptRequest.self, request)
            try Self.schema(body.schemaVersion)
            guard Self.validID(body.candidateID), Self.validID(body.deliveryID) else { throw BrainStoreError.invalid }
            let grant = services.brain.grant(threadID: "", write: true)
            try ProspectiveMemoryStore(store: services.store, authorization: grant)
                .acknowledgeDelivery(id: body.candidateID, deliveryID: body.deliveryID)
            return try Self.response([String: String]())
        } catch { return Self.failure(error) }
    }
}
