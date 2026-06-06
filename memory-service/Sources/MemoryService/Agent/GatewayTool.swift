import Foundation

/// Server-side counterpart to the macOS app's `AgentTool` protocol.
/// Each tool receives the JSON-string args and the live `Services` container; returns a plain
/// text result that the agent loop forwards to the model.
public protocol GatewayTool: Sendable {
    static var name: String { get }
    static var description: String { get }
    static var parameters: [GatewayToolParam] { get }
    func run(argsJSON: String, services: Services) async -> String
}

public struct GatewayToolParam: Sendable {
    public enum ParamType: String, Sendable { case string, integer, number, boolean }
    public let name: String
    public let type: ParamType
    public let description: String
    public let required: Bool

    public init(name: String, type: ParamType, description: String, required: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

public extension GatewayTool {
    static var parameters: [GatewayToolParam] { [] }

    /// OpenAI-style JSON Schema for this tool's parameters.
    static var jsonSchema: [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in parameters {
            props[p.name] = ["type": p.type.rawValue, "description": p.description]
            if p.required { required.append(p.name) }
        }
        return ["type": "object", "properties": props, "required": required]
    }

    /// The full function spec for the OpenAI `tools` array.
    static var functionSpec: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": jsonSchema]]
    }

    /// Parse argsJSON into a dictionary (empty on failure).
    static func args(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}
