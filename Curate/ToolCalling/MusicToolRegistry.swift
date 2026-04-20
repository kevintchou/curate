//
//  MusicToolRegistry.swift
//  Curate
//
//  Registry that holds all available tools. The orchestrator queries this
//  for tool definitions to send to the LLM. Tools can be registered or
//  deregistered at runtime (e.g., disable personalization tools if unauthorized).
//

import Foundation

final class MusicToolRegistry {
    private var tools: [String: any MusicTool] = [:]

    /// Register a tool. Overwrites if name already exists.
    func register(_ tool: any MusicTool) {
        tools[tool.name] = tool
    }

    /// Register multiple tools at once.
    func register(_ newTools: [any MusicTool]) {
        for tool in newTools {
            tools[tool.name] = tool
        }
    }

    /// Remove a tool by name.
    func deregister(_ name: String) {
        tools.removeValue(forKey: name)
    }

    /// Look up a tool by name.
    func tool(named name: String) -> (any MusicTool)? {
        tools[name]
    }

    /// All tool definitions for sending to the LLM.
    var definitions: [ToolDefinition] {
        tools.values.map(\.definition)
    }

    /// All registered tool names.
    var registeredNames: [String] {
        Array(tools.keys).sorted()
    }

    /// Number of registered tools.
    var count: Int {
        tools.count
    }
}
