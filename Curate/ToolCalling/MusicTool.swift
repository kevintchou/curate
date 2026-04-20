//
//  MusicTool.swift
//  Curate
//
//  Core protocol and types for the LLM tool-calling system.
//  Tools are MusicKit API calls or custom logic that the LLM can invoke.
//

import Foundation

// MARK: - Tool Protocol

/// A tool the LLM can call to interact with MusicKit or run custom logic.
/// Both low-level MusicKit tools (flat) and high-level approach tools (layered)
/// conform to this same protocol, making the system extensible.
protocol MusicTool {
    /// Unique name the LLM uses to call this tool (e.g., "search_catalog")
    var name: String { get }

    /// Human-readable description sent to the LLM so it knows when to use this tool
    var description: String { get }

    /// JSON Schema describing the tool's parameters
    var parameters: ToolParameterSchema { get }

    /// Execute the tool with JSON-encoded arguments, return JSON-encoded result.
    /// Arguments come from the LLM's tool call; result goes back in the conversation.
    func execute(arguments: Data) async throws -> ToolResult
}

extension MusicTool {
    /// Build the definition object sent to the LLM
    var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }
}

// MARK: - Tool Definition (sent to LLM)

struct ToolDefinition: Codable {
    let name: String
    let description: String
    let parameters: ToolParameterSchema
}

// MARK: - Parameter Schema (JSON Schema subset)

struct ToolParameterSchema: Codable {
    let type: String
    let properties: [String: ToolPropertyDef]
    let required: [String]

    init(properties: [String: ToolPropertyDef], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct ToolPropertyDef: Codable {
    let type: String
    let description: String
    let items: ToolItemsDef?
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description, items
        case enumValues = "enum"
    }

    /// String property
    static func string(_ description: String) -> ToolPropertyDef {
        ToolPropertyDef(type: "string", description: description, items: nil, enumValues: nil)
    }

    /// Integer property
    static func integer(_ description: String) -> ToolPropertyDef {
        ToolPropertyDef(type: "integer", description: description, items: nil, enumValues: nil)
    }

    /// Number (float/double) property
    static func number(_ description: String) -> ToolPropertyDef {
        ToolPropertyDef(type: "number", description: description, items: nil, enumValues: nil)
    }

    /// Boolean property
    static func boolean(_ description: String) -> ToolPropertyDef {
        ToolPropertyDef(type: "boolean", description: description, items: nil, enumValues: nil)
    }

    /// String enum property
    static func stringEnum(_ description: String, values: [String]) -> ToolPropertyDef {
        ToolPropertyDef(type: "string", description: description, items: nil, enumValues: values)
    }

    /// Array of strings property
    static func stringArray(_ description: String) -> ToolPropertyDef {
        ToolPropertyDef(type: "array", description: description, items: ToolItemsDef(type: "string"), enumValues: nil)
    }
}

struct ToolItemsDef: Codable {
    let type: String
}

// MARK: - Tool Result

enum ToolResult {
    case success(Data)
    case error(String)

    /// Create a success result from any Encodable value
    static func encode<T: Encodable>(_ value: T) -> ToolResult {
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(value)
            return .success(data)
        } catch {
            return .error("Failed to encode result: \(error.localizedDescription)")
        }
    }

    /// The JSON string representation for sending back to the LLM
    var contentString: String {
        switch self {
        case .success(let data):
            return String(data: data, encoding: .utf8) ?? "{}"
        case .error(let message):
            return "{\"error\": \"\(message)\"}"
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - Tool Errors

enum ToolError: LocalizedError {
    case invalidArguments(String)
    case missingRequiredArgument(String)
    case executionFailed(String)
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .missingRequiredArgument(let name): return "Missing required argument: \(name)"
        case .executionFailed(let msg): return "Tool execution failed: \(msg)"
        case .toolNotFound(let name): return "Tool not found: \(name)"
        }
    }
}

// MARK: - LLM Conversation Types

/// A message in the LLM conversation (normalized across providers)
struct ToolCallingMessage: Codable {
    let role: ToolCallingRole
    let content: String?
    let toolCalls: [ToolCall]?
    let toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    static func system(_ content: String) -> ToolCallingMessage {
        ToolCallingMessage(role: .system, content: content, toolCalls: nil, toolCallId: nil)
    }

    static func user(_ content: String) -> ToolCallingMessage {
        ToolCallingMessage(role: .user, content: content, toolCalls: nil, toolCallId: nil)
    }

    static func assistant(toolCalls: [ToolCall]) -> ToolCallingMessage {
        ToolCallingMessage(role: .assistant, content: nil, toolCalls: toolCalls, toolCallId: nil)
    }

    static func assistant(text: String) -> ToolCallingMessage {
        ToolCallingMessage(role: .assistant, content: text, toolCalls: nil, toolCallId: nil)
    }

    static func toolResult(id: String, content: String) -> ToolCallingMessage {
        ToolCallingMessage(role: .tool, content: content, toolCalls: nil, toolCallId: id)
    }
}

enum ToolCallingRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

/// A tool call requested by the LLM
struct ToolCall: Codable {
    let id: String
    let name: String
    let arguments: String  // Raw JSON string

    /// Decode arguments as Data for tool execution
    var argumentsData: Data {
        arguments.data(using: .utf8) ?? Data()
    }
}

/// Response from the LLM proxy edge function
struct ToolCallingLLMResponse: Codable {
    let stopReason: String  // "tool_use", "end_turn", "max_tokens"
    let content: String?
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
        case content
        case toolCalls = "tool_calls"
    }

    var isToolUse: Bool { stopReason == "tool_use" }
    var isComplete: Bool { stopReason == "end_turn" }
}

// MARK: - Typed Argument Helpers

/// Convenience for decoding tool arguments with validation
struct ToolArguments {
    private let dict: [String: Any]

    init(from data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments("Expected JSON object")
        }
        self.dict = json
    }

    func requireString(_ key: String) throws -> String {
        guard let value = dict[key] as? String else {
            throw ToolError.missingRequiredArgument(key)
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        dict[key] as? String
    }

    func requireInt(_ key: String) throws -> Int {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? Double { return Int(value) }
        throw ToolError.missingRequiredArgument(key)
    }

    func optionalInt(_ key: String, default defaultValue: Int) -> Int {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? Double { return Int(value) }
        return defaultValue
    }

    func optionalDouble(_ key: String, default defaultValue: Double) -> Double {
        if let value = dict[key] as? Double { return value }
        if let value = dict[key] as? Int { return Double(value) }
        return defaultValue
    }

    func stringArray(_ key: String) -> [String] {
        (dict[key] as? [String]) ?? []
    }
}
