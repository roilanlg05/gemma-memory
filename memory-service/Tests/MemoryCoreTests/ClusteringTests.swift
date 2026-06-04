import XCTest
@testable import MemoryCore

final class ClusteringTests: XCTestCase {
    func test_knnGraph_links_close_not_far() {
        let embs: [(id: String, vec: [Float])] = [
            ("a", [1, 0, 0, 0]), ("b", [0.99, 0.01, 0, 0]),
            ("x", [0, 0, 1, 0]), ("y", [0, 0, 0.99, 0.01]),
        ]
        let adj = Clustering.knnGraph(embs, k: 8, maxDistance: 0.25)
        XCTAssertTrue(adj["a"]!.contains("b")); XCTAssertTrue(adj["b"]!.contains("a"))
        XCTAssertTrue(adj["x"]!.contains("y"))
        XCTAssertFalse(adj["a"]!.contains("x"))   // far → no edge
    }
    func test_knnGraph_caps_outgoing_nominations_at_k() {
        // 4 vectors all moderately close; k=1 → each nominates only its single nearest.
        let embs: [(id: String, vec: [Float])] = [
            ("a", [1, 0, 0, 0]), ("b", [0.99, 0.14, 0, 0]),
            ("c", [0.96, 0.28, 0, 0]), ("d", [0.91, 0.42, 0, 0]),
        ]
        let adj = Clustering.knnGraph(embs, k: 1, maxDistance: 0.5)
        // a's single nomination is b (its nearest); a must NOT also nominate c or d.
        XCTAssertEqual(adj["a"], ["b"])
    }
    func test_empty_input_returns_empty() {
        XCTAssertTrue(Clustering.knnGraph([], k: 8, maxDistance: 0.25).isEmpty)
        XCTAssertTrue(Clustering.labelPropagation([:], minSize: 2).isEmpty)
    }
    func test_labelPropagation_two_communities_and_drops_singleton() {
        let adj: [String: Set<String>] = [
            "a": ["b", "c"], "b": ["a", "c"], "c": ["a", "b"],
            "x": ["y", "z"], "y": ["x", "z"], "z": ["x", "y"],
            "lonely": [],
        ]
        let groups = Clustering.labelPropagation(adj, minSize: 2)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { Set($0) == ["a", "b", "c"] })
        XCTAssertTrue(groups.contains { Set($0) == ["x", "y", "z"] })
        XCTAssertFalse(groups.contains { $0.contains("lonely") })   // singleton dropped
    }
}
