import XCTest
import GRDB
@testable import MemoryCore

final class NodeTagsTests: XCTestCase {
    func test_node_tags_roundtrip_and_overwrite() throws {
        let store = try MemoryStore(inMemory: true, embeddingDim: 1024)
        try store.setTags(nodeId: "n1", ["trading", "finanzas"])
        XCTAssertEqual(try store.tagsFor(nodeId: "n1"), ["finanzas", "trading"])   // sorted
        XCTAssertEqual(try store.nodesWithTag("trading"), ["n1"])
        try store.setTags(nodeId: "n1", ["salud"])                                 // overwrite replaces
        XCTAssertEqual(try store.tagsFor(nodeId: "n1"), ["salud"])
        XCTAssertEqual(try store.nodesWithTag("trading"), [])
        XCTAssertEqual(try store.distinctTags(), ["salud"])
    }
    func test_clusterKind_and_relation_exist() {
        XCTAssertEqual(NodeKind.cluster.rawValue, "cluster")
        XCTAssertEqual(Relation.belongsToCluster.rawValue, "belongsToCluster")
    }
}
