//
//  Feedback.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//

import Foundation
import SwiftData

// MARK: - Feedback Type
enum FeedbackType: String, Codable, CaseIterable {
    case like = "like"
    case dislike = "dislike"
    case skip = "skip"
    case listenThrough = "listen_through"
    
    /// Weight for Thompson Sampling update
    /// Positive = liked, Negative = disliked
    var weight: Float {
        switch self {
        case .like: return 1.0
        case .dislike: return -1.0
        case .skip: return -0.3          // Weak negative
        case .listenThrough: return 0.5  // Moderate positive
        }
    }
    
    var isPositive: Bool {
        weight > 0
    }
}

// MARK: - Feedback Model (SwiftData for local persistence)
@Model
final class Feedback {
    var id: UUID
    var stationId: UUID
    var trackISRC: String
    var feedbackTypeRaw: String  // FeedbackType raw value
    var timestamp: Date
    
    // Context at time of feedback (for debugging/analysis)
    var trackFeaturesData: Data?
    
    // Track metadata for display
    var trackTitle: String?
    var trackArtist: String?
    
    init(
        id: UUID = UUID(),
        stationId: UUID,
        trackISRC: String,
        feedbackType: FeedbackType,
        trackTitle: String? = nil,
        trackArtist: String? = nil,
        trackFeatures: TrackFeatures? = nil
    ) {
        self.id = id
        self.stationId = stationId
        self.trackISRC = trackISRC
        self.feedbackTypeRaw = feedbackType.rawValue
        self.timestamp = Date()
        self.trackTitle = trackTitle
        self.trackArtist = trackArtist
        self.trackFeaturesData = try? JSONEncoder().encode(trackFeatures)
    }
    
    // MARK: - Computed Properties
    
    var feedbackType: FeedbackType {
        FeedbackType(rawValue: feedbackTypeRaw) ?? .skip
    }
    
    var trackFeatures: TrackFeatures? {
        guard let data = trackFeaturesData else { return nil }
        return try? JSONDecoder().decode(TrackFeatures.self, from: data)
    }
}

// MARK: - Feedback Summary (for analytics)
struct FeedbackSummary {
    let totalFeedback: Int
    let likes: Int
    let dislikes: Int
    let skips: Int
    let listensThrough: Int
    
    var likeRate: Float {
        guard totalFeedback > 0 else { return 0 }
        return Float(likes) / Float(totalFeedback)
    }
    
    var engagementRate: Float {
        guard totalFeedback > 0 else { return 0 }
        return Float(likes + listensThrough) / Float(totalFeedback)
    }
}
