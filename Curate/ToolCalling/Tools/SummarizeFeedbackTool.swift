//
//  SummarizeFeedbackTool.swift
//  Curate
//
//  Summarizes user feedback for a station — liked/disliked/skipped tracks
//  and derived patterns. Tells the LLM what's working.
//

import Foundation

final class SummarizeFeedbackTool: MusicTool {
    private let feedbackRepository: FeedbackRepositoryProtocol?
    private let userId: UUID?

    init(feedbackRepository: FeedbackRepositoryProtocol? = nil, userId: UUID? = nil) {
        self.feedbackRepository = feedbackRepository
        self.userId = userId
    }

    let name = "summarize_feedback"
    let description = """
        Get a summary of the user's feedback history — liked artists/genres, \
        disliked artists, skip patterns. Use this to understand what's working \
        and adjust your track selection accordingly. \
        Returns aggregated data, not individual events.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "days": .integer("Number of days of feedback to include (default 30)")
        ],
        required: []
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let days = args.optionalInt("days", default: 30)

        guard let repo = feedbackRepository, let uid = userId else {
            return .encode(FeedbackSummaryResult(
                hasData: false,
                likedArtists: [],
                dislikedArtists: [],
                likedGenres: [],
                totalLikes: 0,
                totalDislikes: 0,
                totalSkips: 0,
                message: "No feedback data available"
            ))
        }

        let scores = try await repo.getArtistScores(userId: uid)

        let likedArtists = scores
            .filter { $0.isPreferred }
            .sorted { $0.weightedScore > $1.weightedScore }
            .prefix(10)
            .map { ArtistFeedbackSummary(name: $0.artistName, score: $0.weightedScore, likeCount: $0.likeCount) }

        let dislikedArtists = scores
            .filter { $0.shouldAvoid }
            .sorted { $0.weightedScore < $1.weightedScore }
            .prefix(10)
            .map { ArtistFeedbackSummary(name: $0.artistName, score: $0.weightedScore, likeCount: $0.likeCount) }

        let totalLikes = scores.reduce(0) { $0 + $1.likeCount }
        let totalDislikes = scores.reduce(0) { $0 + $1.dislikeCount }
        let totalSkips = scores.reduce(0) { $0 + $1.skipCount }

        return .encode(FeedbackSummaryResult(
            hasData: !scores.isEmpty,
            likedArtists: Array(likedArtists),
            dislikedArtists: Array(dislikedArtists),
            likedGenres: [],  // Would need genre data from tracks
            totalLikes: totalLikes,
            totalDislikes: totalDislikes,
            totalSkips: totalSkips,
            message: nil
        ))
    }
}

struct ArtistFeedbackSummary: Codable {
    let name: String
    let score: Double
    let likeCount: Int
}

struct FeedbackSummaryResult: Codable {
    let hasData: Bool
    let likedArtists: [ArtistFeedbackSummary]
    let dislikedArtists: [ArtistFeedbackSummary]
    let likedGenres: [String]
    let totalLikes: Int
    let totalDislikes: Int
    let totalSkips: Int
    let message: String?
}
