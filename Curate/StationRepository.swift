//
//  StationRepository.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//

import Foundation
import SwiftData

// MARK: - Station Repository Protocol
protocol StationRepositoryProtocol {
    /// Create a new station
    func createStation(_ station: Station) async throws
    
    /// Get a station by ID
    func getStation(byId id: UUID) async throws -> Station?
    
    /// Get all stations for the current user
    func getAllStations() async throws -> [Station]
    
    /// Update a station
    func updateStation(_ station: Station) async throws
    
    /// Delete a station
    func deleteStation(_ station: Station) async throws
    
    /// Record feedback for a station
    func recordFeedback(_ feedback: Feedback) async throws
    
    /// Get feedback for a station
    func getFeedback(forStationId stationId: UUID) async throws -> [Feedback]
}

// MARK: - Local SwiftData Implementation
@MainActor
final class LocalStationRepository: StationRepositoryProtocol {
    private let modelContext: ModelContext
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func createStation(_ station: Station) async throws {
        modelContext.insert(station)
        try modelContext.save()
    }
    
    func getStation(byId id: UUID) async throws -> Station? {
        let predicate = #Predicate<Station> { station in
            station.id == id
        }
        let descriptor = FetchDescriptor<Station>(predicate: predicate)
        let results = try modelContext.fetch(descriptor)
        return results.first
    }
    
    func getAllStations() async throws -> [Station] {
        let descriptor = FetchDescriptor<Station>(
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
    
    func updateStation(_ station: Station) async throws {
        // SwiftData automatically tracks changes to managed objects
        try modelContext.save()
    }
    
    func deleteStation(_ station: Station) async throws {
        modelContext.delete(station)
        try modelContext.save()
    }
    
    func recordFeedback(_ feedback: Feedback) async throws {
        modelContext.insert(feedback)
        try modelContext.save()
    }
    
    func getFeedback(forStationId stationId: UUID) async throws -> [Feedback] {
        let predicate = #Predicate<Feedback> { feedback in
            feedback.stationId == stationId
        }
        let descriptor = FetchDescriptor<Feedback>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
}

// MARK: - In-Memory Implementation (for testing)
final class InMemoryStationRepository: StationRepositoryProtocol {
    private var stations: [UUID: Station] = [:]
    private var feedback: [Feedback] = []
    
    func createStation(_ station: Station) async throws {
        stations[station.id] = station
    }
    
    func getStation(byId id: UUID) async throws -> Station? {
        stations[id]
    }
    
    func getAllStations() async throws -> [Station] {
        Array(stations.values).sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }
    
    func updateStation(_ station: Station) async throws {
        stations[station.id] = station
    }
    
    func deleteStation(_ station: Station) async throws {
        stations.removeValue(forKey: station.id)
        feedback.removeAll { $0.stationId == station.id }
    }
    
    func recordFeedback(_ feedback: Feedback) async throws {
        self.feedback.append(feedback)
    }
    
    func getFeedback(forStationId stationId: UUID) async throws -> [Feedback] {
        feedback
            .filter { $0.stationId == stationId }
            .sorted { $0.timestamp > $1.timestamp }
    }
}
