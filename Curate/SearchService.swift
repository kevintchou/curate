//
//  SearchService.swift
//  Curate
//
//  Created by Kevin Chou on 11/21/25.
//

import Foundation
import MusicKit

@MainActor
class SearchService {
    
    // MARK: - Private State
    private var searchTask: Task<Void, Never>?
    
    // MARK: - Types
    enum SearchType {
        case song
        case artist
    }
    
    // MARK: - Public Methods
    
    /// Performs a debounced search for songs with automatic cancellation of previous searches
    func searchAsYouType(query: String, delay: UInt64 = 300_000_000, completion: @escaping ([Song], Bool) -> Void) {
        searchTask?.cancel()
        
        guard !query.isEmpty else {
            completion([], false)
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: delay) // 0.3 seconds default
            guard !Task.isCancelled else { return }
            
            let results = await performSongSearch(query: query)
            completion(results, false)
        }
    }
    
    /// Performs a debounced search for artists with automatic cancellation of previous searches
    func searchArtistsAsYouType(query: String, delay: UInt64 = 300_000_000, completion: @escaping ([Artist], Bool) -> Void) {
        searchTask?.cancel()
        
        guard !query.isEmpty else {
            completion([], false)
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: delay) // 0.3 seconds default
            guard !Task.isCancelled else { return }
            
            let results = await performArtistSearch(query: query)
            completion(results, false)
        }
    }
    
    /// Performs the actual search for songs against Apple Music catalog
    func performSongSearch(query: String) async -> [Song] {
        do {
            let status = await MusicAuthorization.request()
            guard status == .authorized else {
                print("❌ Not authorized to access Apple Music")
                return []
            }
            
            var searchRequest = MusicCatalogSearchRequest(term: query, types: [Song.self])
            searchRequest.limit = 10
            
            let searchResponse = try await searchRequest.response()
            return Array(searchResponse.songs)
            
        } catch {
            print("❌ Search error: \(error)")
            return []
        }
    }
    
    /// Performs the actual search for artists against Apple Music catalog
    func performArtistSearch(query: String) async -> [Artist] {
        do {
            let status = await MusicAuthorization.request()
            guard status == .authorized else {
                print("❌ Not authorized to access Apple Music")
                return []
            }
            
            var searchRequest = MusicCatalogSearchRequest(term: query, types: [Artist.self])
            searchRequest.limit = 10
            
            let searchResponse = try await searchRequest.response()
            return Array(searchResponse.artists)
            
        } catch {
            print("❌ Search error: \(error)")
            return []
        }
    }
}
