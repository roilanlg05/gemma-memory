import XCTest
@testable import MemoryCore

final class Task13ProspectiveTests: XCTestCase {
    func test_cancelled_task_is_not_a_due_reminder() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let node = Node(id: "task", kind: NodeKind.task.rawValue, label: "Call", body: "Call", layer: .daily,
                        createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0,
                        confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil,
                        origin: .explicit, serverId: nil, dirty: true, deleted: false,
                        extra: NodeAttributes(status: "cancelled", date: "2026-01-01").toJSON())
        try store.upsert(node)
        XCTAssertTrue(try store.dueReminders(today: "2026-11-11").isEmpty)
    }

    func test_event_retouch_preserves_calendar_metadata() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let id = try store.upsertEvent(title: "Appointment", start: 100, end: 200, allDay: false, location: nil, origin: .explicit)
        var node = try XCTUnwrap(store.node(id: id))
        node.extra = #"{"status":"scheduled","startAt":100,"endAt":200,"allDay":false,"canonicalKey":"appointment|1","appleEventId":"apple","appleOccurrenceAt":100,"source":"apple:work","contentUpdatedAt":42}"#
        // Keep the actual canonical key created by the store.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(node.extra!.utf8)) as? [String: Any])
        json["canonicalKey"] = MemoryText.eventCanonicalKey(title: "Appointment", startAt: 100)
        node.extra = String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)
        try store.dbQueue.write { db in try node.update(db) }
        _ = try store.upsertEvent(title: "Appointment", start: 100, end: 200, allDay: false, location: nil, origin: .explicit)
        let result = try XCTUnwrap(store.node(id: id)?.extra)
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(saved["appleEventId"] as? String, "apple")
        XCTAssertEqual(saved["contentUpdatedAt"] as? Double, 42)
    }
}

extension Task13ProspectiveTests {
    func test_delivery_and_deferral_never_complete_a_task() throws {
        let (store, prospective, _) = try task13Fixture()
        let candidates = try prospective.candidates(scope: .user, revision: BrainStore(store: store, authorization: task13Authorization()).revision())
        XCTAssertEqual(candidates.map(\.id), ["task"])
        try prospective.recordDelivery(id: "task", deliveryID: "delivery", state: .read)
        try prospective.deferFollowUp(id: "task", until: 100)
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "pending")
        XCTAssertTrue(try prospective.candidates(scope: .user, revision: BrainStore(store: store, authorization: task13Authorization()).revision()).isEmpty)
    }

    func test_user_report_closes_task_and_stale_external_observation_conflicts() throws {
        let (store, _, observations) = try task13Fixture()
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .done, evidenceID: "user-proof", operationID: "one")
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "done")
        XCTAssertEqual(try observations.history(id: "task").last?.attribution, .userReported)
        try observations.observeTask(id: "task", sourceID: "external", sourceVersion: 1, observedAt: 5, status: .pending, evidenceID: "external-proof", operationID: "two")
        XCTAssertEqual(try observations.history(id: "task").last?.disposition, .conflict)
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "done")
    }

    func test_resolving_doubt_does_not_complete_related_task() throws {
        let (store, prospective, _) = try task13Fixture()
        var doubt = try XCTUnwrap(store.node(id: "task")); doubt.id = "doubt"; doubt.kind = NodeKind.clarification.rawValue
        try store.upsert(doubt)
        try prospective.resolveCandidate(id: "doubt", evidenceID: "user-proof")
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "pending")
        XCTAssertFalse(try prospective.candidates(scope: .user, revision: BrainStore(store: store, authorization: task13Authorization()).revision()).contains { $0.id == "doubt" })
    }
}

import BrainContract
import GRDB

private struct Task13Authority: TaskObservationAuthority, ProspectiveResolutionAuthority {
    func approves(candidateID: String, evidence: BrainEvidence) -> Bool { candidateID == "doubt" && evidence.id == "user-proof" }
    func approvesReopening(id: String, sourceID: String, status: TaskStatus, evidence: BrainEvidence) -> Bool { id == "task" && evidence.id == "correction" && status == .pending }
    func approves(id: String, sourceID: String, sourceVersion: Int64, observedAt: Double, status: TaskStatus, evidence: BrainEvidence) -> Bool {
        (sourceID == "external" && ["external-proof", "external-new"].contains(evidence.id)) || (sourceID == "user" && ["user-proof", "correction"].contains(evidence.id))
    }
}
private func task13Authorization() -> BrainAuthorization {
    BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread"], sourceSpeakers: [.userMessage: ["self:user"], .imported: ["source"]], mayCommitClaims: true, mayForget: true)
}
private func task13Fixture() throws -> (MemoryStore, ProspectiveMemoryStore, TaskObservationStore) {
    let store = try MemoryStore(inMemory: true, embeddingDim: 8)
    let auth = task13Authorization()
    let brain = BrainStore(store: store, authorization: auth)
    for (id, kind, speaker, time) in [("user-proof", BrainSourceKind.userMessage, "self:user", 10.0), ("external-proof", .imported, "source", 5.0)] {
        _ = try brain.recordEvidence(.init(id: id, sourceKind: kind, speakerID: speaker, threadID: "thread", observedAt: time, recordedAt: time, accessScope: .user, text: "Synthetic task statement"), idempotencyKey: id)
    }
    let node = Node(id: "task", kind: NodeKind.task.rawValue, label: "Call", body: "Call", layer: .daily, createdAt: 1, updatedAt: 1, lastSeenAt: 1, salience: 3, decayRate: 0, confidence: .probable, mentionCount: 1, ttlExpiresAt: nil, sourceRef: nil, origin: .explicit, serverId: nil, dirty: true, deleted: false, extra: NodeAttributes(status: "pending").toJSON())
    try store.upsert(node)
    return (store, ProspectiveMemoryStore(store: store, authorization: auth, resolutionAuthority: Task13Authority(), clock: { 20 }), TaskObservationStore(store: store, authorization: auth, authority: Task13Authority()))
}

extension Task13ProspectiveTests {
    func test_same_external_source_advances_and_withdrawal_does_not_resurrect() throws {
        let (store, prospective, observations) = try task13Fixture()
        let auth = task13Authorization()
        let brain = BrainStore(store: store, authorization: auth)
        _ = try brain.recordEvidence(.init(id: "external-new", sourceKind: .imported, speakerID: "source", threadID: "thread", observedAt: 8, recordedAt: 8, accessScope: .user, text: "Synthetic external update"), idempotencyKey: "new")
        try observations.observeTask(id: "task", sourceID: "external", sourceVersion: 1, observedAt: 5, status: .pending, evidenceID: "external-proof", operationID: "first")
        try observations.observeTask(id: "task", sourceID: "external", sourceVersion: 2, observedAt: 8, status: .done, evidenceID: "external-new", operationID: "second")
        XCTAssertEqual(try observations.history(id: "task").last?.disposition, .applied)
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "done")
        _ = try brain.forget(scope: .init(kind: .evidence, id: "external-new"), expectedRevision: brain.revision(), operationID: "erase")
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "unknown")
        XCTAssertTrue(try prospective.candidates(scope: .user, revision: brain.revision()).isEmpty)
        XCTAssertEqual(try observations.history(id: "task").count, 1)
    }

    func test_receipts_are_monotonic_and_late_read_does_not_change_task() throws {
        let (store, prospective, observations) = try task13Fixture()
        try prospective.recordDelivery(id: "task", deliveryID: "d", state: .sent)
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .done, evidenceID: "user-proof", operationID: "done")
        try prospective.recordDelivery(id: "task", deliveryID: "d", state: .read)
        XCTAssertThrowsError(try prospective.recordDelivery(id: "task", deliveryID: "d", state: .sent))
        XCTAssertThrowsError(try prospective.recordDelivery(id: "task", deliveryID: "new", state: .sent))
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "done")
    }

    func test_calendar_content_change_updates_stamp() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 8)
        let id = try store.upsertEvent(title: "Appointment", start: 100, end: 200, allDay: false, location: nil, origin: .explicit)
        var node = try XCTUnwrap(store.node(id: id))
        var attrs = NodeAttributes.from(node.extra); attrs.contentUpdatedAt = 42; attrs.appleEventId = "apple"
        node.extra = attrs.toJSON(); try store.dbQueue.write { try node.update($0) }
        _ = try store.applyEventEdit(node, location: "Office")
        let updated = NodeAttributes.from(try XCTUnwrap(store.node(id: id)).extra)
        XCTAssertEqual(updated.appleEventId, "apple")
        XCTAssertGreaterThan(try XCTUnwrap(updated.contentUpdatedAt), 42)
    }
}

extension Task13ProspectiveTests {
    func test_snapshot_binding_rejects_changed_candidate() throws {
        let (store, prospective, _) = try task13Fixture()
        let revision = try BrainStore(store: store, authorization: task13Authorization()).revision()
        let candidate = try XCTUnwrap(prospective.candidates(scope: .user, revision: revision).first)
        var node = try XCTUnwrap(store.node(id: "task")); node.label = "Different task"
        try store.upsert(node)
        XCTAssertThrowsError(try prospective.revalidate(candidate, scope: .user, revision: revision))
        XCTAssertThrowsError(try prospective.recordDelivery(candidate: candidate, deliveryID: "d", state: .sent))
    }

    func test_default_denied_resolution_and_mutation() throws {
        let (store, _, _) = try task13Fixture()
        var doubt = try XCTUnwrap(store.node(id: "task")); doubt.id = "doubt"; doubt.kind = NodeKind.clarification.rawValue
        try store.upsert(doubt)
        let noBinding = ProspectiveMemoryStore(store: store, authorization: task13Authorization())
        XCTAssertThrowsError(try noBinding.resolveCandidate(id: "doubt", evidenceID: "user-proof"))
        let readonly = BrainAuthorization(principal: "user", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread"], sourceSpeakers: [.userMessage: ["self:user"]])
        let reader = ProspectiveMemoryStore(store: store, authorization: readonly)
        XCTAssertThrowsError(try reader.deferFollowUp(id: "task", until: 100))
        XCTAssertThrowsError(try reader.recordDelivery(id: "task", deliveryID: "d", state: .sent))
    }

    func test_proposal_not_due_and_curiosity_not_obligation() throws {
        let (store, prospective, _) = try task13Fixture()
        var task = try XCTUnwrap(store.node(id: "task"))
        task.extra = NodeAttributes(status: "proposed", date: "2026-01-01").toJSON(); try store.dbQueue.write { try task.update($0) }
        var topic = task; topic.id = "topic"; topic.kind = NodeKind.topic.rawValue; try store.upsert(topic)
        XCTAssertTrue(try store.dueReminders(today: "2026-11-11").isEmpty)
        let candidates = try prospective.candidates(scope: .user, revision: BrainStore(store: store, authorization: task13Authorization()).revision())
        XCTAssertEqual(candidates.map(\.id), ["task"])
        XCTAssertEqual(candidates.first?.kind, "proposal")
    }
}


extension Task13ProspectiveTests {
    func test_explicitly_authorized_reopening() throws {
        let (store, _, observations) = try task13Fixture()
        let brain = BrainStore(store: store, authorization: task13Authorization())
        _ = try brain.recordEvidence(.init(id: "correction", sourceKind: .userMessage, speakerID: "self:user", threadID: "thread", observedAt: 12, recordedAt: 12, accessScope: .user, text: "Synthetic correction"), idempotencyKey: "correction")
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .done, evidenceID: "user-proof", operationID: "done")
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 2, observedAt: 12, status: .pending, evidenceID: "correction", operationID: "correct")
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "pending")
    }
}

extension Task13ProspectiveTests {
    func test_ordinary_task_writes_cannot_change_authoritative_status() throws {
        let (store, _, observations) = try task13Fixture()
        var stale = try XCTUnwrap(store.node(id: "task"))
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .done, evidenceID: "user-proof", operationID: "done")
        try store.upsert(stale)
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "task")).extra).status, "done")
        stale.id = "other"; try store.upsert(stale)
        stale.extra = NodeAttributes(status: "done").toJSON(); try store.upsert(stale)
        XCTAssertEqual(NodeAttributes.from(try XCTUnwrap(store.node(id: "other")).extra).status, "pending")
    }

    func test_mutations_advance_revision_once_and_retries_are_idempotent() throws {
        let (store, prospective, observations) = try task13Fixture()
        let brain = BrainStore(store: store, authorization: task13Authorization())
        let revision = try brain.revision()
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .pending, evidenceID: "user-proof", operationID: "observe")
        XCTAssertEqual(try brain.revision(), revision + 1)
        XCTAssertThrowsError(try prospective.candidates(scope: .user, revision: revision))
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .pending, evidenceID: "user-proof", operationID: "observe")
        XCTAssertEqual(try brain.revision(), revision + 1)
        try prospective.deferFollowUp(id: "task", until: 100)
        XCTAssertEqual(try brain.revision(), revision + 2)
        try prospective.deferFollowUp(id: "task", until: 100)
        XCTAssertEqual(try brain.revision(), revision + 2)
    }

    func test_legacy_followup_readers_honor_deferral_and_resolution() throws {
        let (store, prospective, _) = try task13Fixture()
        var doubt = try XCTUnwrap(store.node(id: "task")); doubt.id = "doubt"; doubt.kind = NodeKind.clarification.rawValue
        try store.upsert(doubt)
        try prospective.deferFollowUp(id: "task", until: Date().timeIntervalSince1970 + 1000)
        try prospective.resolveCandidate(id: "doubt", evidenceID: "user-proof")
        XCTAssertFalse(try store.pendingFollowUps().contains { $0.id == "task" })
        XCTAssertFalse(try store.pendingClarifications().contains { $0.id == "doubt" })
    }

    func test_user_subject_is_required_for_prospective_mutation() throws {
        let (store, _, _) = try task13Fixture()
        let auth = BrainAuthorization(principal: "user", owner: "user", subjects: [], scopes: [.user], threads: ["thread"], sourceSpeakers: [.userMessage: ["self:user"]], mayCommitClaims: true)
        let prospective = ProspectiveMemoryStore(store: store, authorization: auth, resolutionAuthority: Task13Authority())
        var doubt = try XCTUnwrap(store.node(id: "task")); doubt.id = "doubt"; doubt.kind = NodeKind.clarification.rawValue; try store.upsert(doubt)
        XCTAssertThrowsError(try prospective.deferFollowUp(id: "task", until: 100))
        XCTAssertThrowsError(try prospective.resolveCandidate(id: "doubt", evidenceID: "user-proof"))
        XCTAssertThrowsError(try prospective.recordDelivery(id: "task", deliveryID: "d", state: .sent))
    }
}

extension Task13ProspectiveTests {
    func test_task_cannot_be_disguised_or_resurrected_through_ordinary_writes() throws {
        let (store, _, _) = try task13Fixture()
        var stale = try XCTUnwrap(store.node(id: "task"))
        stale.kind = NodeKind.topic.rawValue; try store.upsert(stale)
        XCTAssertEqual(try store.node(id: "task")?.kind, NodeKind.task.rawValue)
        try store.reassignKind(from: NodeKind.task.rawValue, to: NodeKind.topic.rawValue)
        XCTAssertEqual(try store.node(id: "task")?.kind, NodeKind.task.rawValue)
        try store.softDelete(nodeId: "task")
        stale.kind = NodeKind.task.rawValue; try store.upsert(stale)
        XCTAssertTrue(try XCTUnwrap(store.node(id: "task")).deleted)
    }

    func test_ordinary_prospective_node_changes_advance_revision() throws {
        let (store, prospective, _) = try task13Fixture()
        let brain = BrainStore(store: store, authorization: task13Authorization())
        let before = try brain.revision()
        var task = try XCTUnwrap(store.node(id: "task")); task.label = "Changed"
        try store.upsert(task)
        XCTAssertEqual(try brain.revision(), before + 1)
        XCTAssertThrowsError(try prospective.candidates(scope: .user, revision: before))
        let current = try brain.revision(); try store.upsert(try XCTUnwrap(store.node(id: "task")))
        XCTAssertEqual(try brain.revision(), current)
        try store.softDelete(nodeId: "task")
        XCTAssertEqual(try brain.revision(), current + 1)
    }

    func test_delegated_principal_cannot_use_owner_only_prospective_state() throws {
        let (store, _, _) = try task13Fixture()
        let auth = BrainAuthorization(principal: "delegate", owner: "user", subjects: ["self:user"], scopes: [.user], threads: ["thread"], sourceSpeakers: [.userMessage: ["self:user"]], allowDelegated: true, mayCommitClaims: true)
        let prospective = ProspectiveMemoryStore(store: store, authorization: auth, resolutionAuthority: Task13Authority())
        let observations = TaskObservationStore(store: store, authorization: auth, authority: Task13Authority())
        XCTAssertThrowsError(try prospective.candidates(scope: .user, revision: BrainStore(store: store, authorization: task13Authorization()).revision()))
        XCTAssertThrowsError(try prospective.deferFollowUp(id: "task", until: 100))
        XCTAssertThrowsError(try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .done, evidenceID: "user-proof", operationID: "delegate"))
        XCTAssertThrowsError(try observations.history(id: "task"))
    }
}

extension Task13ProspectiveTests {
    func test_candidate_receipt_rejects_newer_same_status_observation() throws {
        let (store, prospective, observations) = try task13Fixture()
        let brain = BrainStore(store: store, authorization: task13Authorization())
        _ = try brain.recordEvidence(.init(id: "correction", sourceKind: .userMessage, speakerID: "self:user", threadID: "thread", observedAt: 12, recordedAt: 12, accessScope: .user, text: "Synthetic second report"), idempotencyKey: "same-status")
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 1, observedAt: 10, status: .pending, evidenceID: "user-proof", operationID: "first-report")
        let candidate = try XCTUnwrap(prospective.candidates(scope: .user, revision: brain.revision()).first)
        try prospective.recordDelivery(candidate: candidate, deliveryID: "issued", state: .sent)
        try observations.observeTask(id: "task", sourceID: "user", sourceVersion: 2, observedAt: 12, status: .pending, evidenceID: "correction", operationID: "second-report")
        XCTAssertThrowsError(try prospective.recordDelivery(candidate: candidate, deliveryID: "stale", state: .sent))
        XCTAssertNoThrow(try prospective.recordDelivery(candidate: candidate, deliveryID: "issued", state: .read))
    }
}
