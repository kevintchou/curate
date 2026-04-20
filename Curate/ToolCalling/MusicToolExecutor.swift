//
//  MusicToolExecutor.swift
//  Curate
//
//  Executes tool calls from the LLM. Looks up tools in the registry,
//  validates arguments, runs the tool, and returns results.
//

import Foundation

final class MusicToolExecutor {
    private let registry: MusicToolRegistry

    init(registry: MusicToolRegistry) {
        self.registry = registry
    }

    /// Execute a single tool call and return the result.
    func execute(_ toolCall: ToolCall) async -> ToolResult {
        guard let tool = registry.tool(named: toolCall.name) else {
            return .error("Unknown tool: \(toolCall.name)")
        }

        do {
            let result = try await tool.execute(arguments: toolCall.argumentsData)
            return result
        } catch let error as ToolError {
            return .error(error.localizedDescription)
        } catch {
            return .error("Tool '\(toolCall.name)' failed: \(error.localizedDescription)")
        }
    }

    /// Execute multiple tool calls in parallel and return results keyed by call ID.
    func execute(_ toolCalls: [ToolCall]) async -> [(id: String, result: ToolResult)] {
        await withTaskGroup(of: (String, ToolResult).self) { group in
            for call in toolCalls {
                group.addTask {
                    let result = await self.execute(call)
                    return (call.id, result)
                }
            }

            var results: [(id: String, result: ToolResult)] = []
            for await (id, result) in group {
                results.append((id: id, result: result))
            }

            // Maintain order matching the input tool calls
            let orderedIds = toolCalls.map(\.id)
            return results.sorted { a, b in
                (orderedIds.firstIndex(of: a.id) ?? 0) < (orderedIds.firstIndex(of: b.id) ?? 0)
            }
        }
    }
}
