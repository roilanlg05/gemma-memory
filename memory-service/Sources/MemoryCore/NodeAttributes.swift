import Foundation

/// Optional structured attributes for a memory node, stored as JSON in `Node.extra`.
/// `task` uses `status` (pending|done); `plan` uses `horizon` (short|long). Extensible:
/// unknown keys are ignored. (Conversation/episode nodes carry their own status key in `extra`;
/// a node is either an episode or a structured fact, so the two never share the same schema.)
public struct NodeAttributes: Codable, Sendable {
    public var status: String?     // task: "pending" | "done"
    public var horizon: String?    // plan: "short" | "long"
    public var date: String?       // task/plan: absolute ISO date (yyyy-MM-dd), resolved from relative refs

    public init(status: String? = nil, horizon: String? = nil, date: String? = nil) {
        self.status = status; self.horizon = horizon; self.date = date
    }

    public func toJSON() -> String? {
        guard status != nil || horizon != nil || date != nil else { return nil }
        return (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func from(_ extra: String?) -> NodeAttributes {
        guard let s = extra, let d = s.data(using: .utf8),
              let a = try? JSONDecoder().decode(NodeAttributes.self, from: d) else { return NodeAttributes() }
        return a
    }
}
