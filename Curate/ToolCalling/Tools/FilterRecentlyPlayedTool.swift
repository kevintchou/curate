//
//  FilterRecentlyPlayedTool.swift
//  Curate
//
//  Removes tracks that have been recently played from a candidate list.
//  Uses ISRC for cross-session dedup, track ID as fallback.
//

import Foundation

final class FilterRecentlyPlayedTool: MusicTool {
    /// Session history — ISRCs played in the current station session.
    /// Updated externally by the orchestrator as tracks play.
    var sessionHistory: Set<String> = []

    /// Persistent history provider for cross-session filtering.
    private let feedbackRepository: FeedbackRepositoryProtocol?
    private let userId: UUID?

    init(feedbackRepository: FeedbackRepositoryProtocol? = nil, userId: UUID? = nil) {
        self.feedbackRepository = feedbackRepository
        self.userId = userId
    }

    let name = "filter_recently_played"
    let description = """
        Remove recently played tracks from a candidate list. \
        Filters out tracks played in the current session and optionally \
        tracks played in recent days. Pass candidate song IDs or ISRCs to filter.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "candidate_isrcs": .stringArray("ISRCs of candidate tracks to filter"),
            "candidate_ids": .stringArray("Apple Music IDs of candidate tracks to filter (fallback if no ISRC)"),
            "recency_days": .integer("Also filter tracks played in the last N days (default 0, session only)")
        ],
        required: ["candidate_isrcs"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let candidateISRCs = args.stringArray("candidate_isrcs")
        let candidateIds = args.stringArray("candidate_ids")
        let recencyDays = args.optionalInt("recency_days", default: 0)

        var excludeISRCs = sessionHistory

        // Add persistent history if available
        if recencyDays > 0, let repo = feedbackRepository, let uid = userId {
            if let recentISRCs = try? await repo.getRecentlyPlayedISRCs(userId: uid, days: recencyDays) {
                excludeISRCs.formUnion(recentISRCs)
            }
        }

        let filteredISRCs = candidateISRCs.filter { !excludeISRCs.contains($0) }

        // Also filter IDs if provided
        var filteredIds = candidateIds
        if !candidateIds.isEmpty, let repo = feedbackRepository, let uid = userId, recencyDays > 0 {
            if let recentIds = try? await repo.getRecentlyPlayedTrackIds(userId: uid, days: recencyDays) {
                let excludeIds = Set(recentIds)
                filteredIds = candidateIds.filter { !excludeIds.contains($0) }
            }
        }

        return .encode(FilterResult(
            filteredIsrcs: filteredISRCs,
            filteredIds: filteredIds,
            removedCount: (candidateISRCs.count - filteredISRCs.count) + (candidateIds.count - filteredIds.count)
        ))
    }
}

struct FilterResult: Codable {
    let filteredIsrcs: [String]
    let filteredIds: [String]
    let removedCount: Int
}
