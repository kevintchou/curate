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
    
    // MARK: - Public Methods
    
    /// Performs a debounced search with automatic cancellation of previous searches
    func searchAsYouType(query: String, delay: UInt64 = 300_000_000, completion: @escaping ([Song], Bool) -> Void) {
        searchTask?.cancel()
        
        guard !query.isEmpty else {
            completion([], false)
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: delay) // 0.3 seconds default
            guard !Task.isCancelled else { return }
            
            let results = await performSearch(query: query)
            completion(results, false)
        }
    }
    
    /// Performs the actual search against Apple Music catalog
    func performSearch(query: String) async -> [Song] {
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
}
