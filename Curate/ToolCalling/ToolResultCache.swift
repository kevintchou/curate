//
//  ToolResultCache.swift
//  Curate
//
//  Unified cache for tool call results. Keyed by tool name + arguments hash.
//  Each tool type has its own configurable TTL.
//

import Foundation

final class ToolResultCache {
    private var entries: [String: CacheEntry] = [:]
    private let lock = NSLock()

    /// Per-tool TTL overrides. Tools not listed use defaultTTL.
    private var toolTTLs: [String: TimeInterval] = [:]
    private let defaultTTL: TimeInterval

    init(defaultTTL: TimeInterval = 300) {  // 5 minutes default
        self.defaultTTL = defaultTTL
    }

    /// Set TTL for a specific tool.
    func setTTL(_ ttl: TimeInterval, for toolName: String) {
        lock.lock()
        defer { lock.unlock() }
        toolTTLs[toolName] = ttl
    }

    /// Look up a cached result for a tool call. Returns nil if not cached or expired.
    func get(tool: String, arguments: Data) -> ToolResult? {
        let key = cacheKey(tool: tool, arguments: arguments)
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else { return nil }

        if Date() > entry.expiresAt {
            entries.removeValue(forKey: key)
            return nil
        }

        return entry.result
    }

    /// Cache a tool result.
    func set(tool: String, arguments: Data, result: ToolResult) {
        // Don't cache errors
        guard !result.isError else { return }

        let key = cacheKey(tool: tool, arguments: arguments)
        let ttl = toolTTLs[tool] ?? defaultTTL

        lock.lock()
        defer { lock.unlock() }

        entries[key] = CacheEntry(
            result: result,
            cachedAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
    }

    /// Clear all cached results.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    /// Clear cached results for a specific tool.
    func clear(tool: String) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { !$0.key.hasPrefix(tool + ":") }
    }

    /// Remove expired entries.
    func evictExpired() {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value.expiresAt > now }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Private

    private func cacheKey(tool: String, arguments: Data) -> String {
        let argsHash = arguments.sha256HexString
        return "\(tool):\(argsHash)"
    }
}

private struct CacheEntry {
    let result: ToolResult
    let cachedAt: Date
    let expiresAt: Date
}

// MARK: - Data SHA256

extension Data {
    var sha256HexString: String {
        // Simple hash using built-in — avoids CryptoKit import for portability
        var hash = 0
        for byte in self {
            hash = hash &* 31 &+ Int(byte)
        }
        return String(format: "%016lx", abs(hash))
    }
}
