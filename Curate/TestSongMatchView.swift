//
//  TestSongMatchView.swift
//  Curate
//
//  Created by Kevin Chou on 12/5/25.
//

import SwiftUI
import MusicKit

struct TestSongMatchView: View {
    @State private var searchQuery: String = ""
    @State private var searchResults: [Song] = []
    @State private var isSearching: Bool = false
    @State private var selectedSong: Song?
    @State private var spotifySearchResult: String = ""
    @State private var isSearchingSpotify: Bool = false
    @State private var spotifyAccessToken: String?
    private let searchService = SearchService()
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Simple search input box
            TextField("Search for a song", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
                .onChange(of: searchQuery) { oldValue, newValue in
                    performSearch(query: newValue)
                }
            
            // Spotify Search Button
            Button(action: {
                searchSpotify()
            }) {
                HStack {
                    if isSearchingSpotify {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text("Search on Spotify")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(selectedSong != nil ? Color.green : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(selectedSong == nil || isSearchingSpotify)
            .padding(.horizontal, 40)
            
            // Spotify Search Result
            if !spotifySearchResult.isEmpty {
                Text(spotifySearchResult)
                    .font(.headline)
                    .foregroundStyle(spotifySearchResult.contains("not found") ? .red : .green)
                    .padding()
            }
            
            // Search results
            if isSearching {
                ProgressView()
            } else if !searchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(searchResults, id: \.id) { song in
                            Button {
                                selectSong(song)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(song.title)
                                            .font(.headline)
                                        Text(song.artistName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    // Show checkmark if selected
                                    if selectedSong?.id == song.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 40)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            
            Spacer()
        }
        .task {
            // Get Spotify access token on view appear
            await getSpotifyAccessToken()
        }
    }
    
    private func performSearch(query: String) {
        isSearching = !query.isEmpty
        
        searchService.searchAsYouType(query: query) { results, searching in
            searchResults = results
            isSearching = searching
        }
    }
    
    private func selectSong(_ song: Song) {
        selectedSong = song
        spotifySearchResult = "" // Clear previous Spotify result
        
        // Print song details to console
        print("=== Selected Song ===")
        print("Title: \(song.title)")
        print("Artist: \(song.artistName)")
        
        if let duration = song.duration {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            print("Duration: \(minutes):\(String(format: "%02d", seconds)) (\(duration) seconds)")
        } else {
            print("Duration: Not available")
        }
        
        if let isrc = song.isrc {
            print("ISRC: \(isrc)")
        } else {
            print("ISRC: Not available")
        }
        print("====================")
    }
    
    private func getSpotifyAccessToken() async {
        do {
            let token = try await SpotifyService.getAccessToken()
            await MainActor.run {
                spotifyAccessToken = token
            }
            print("✅ Got Spotify access token")
        } catch {
            print("❌ Error getting Spotify access token: \(error.localizedDescription)")
        }
    }
    
    private func searchSpotify() {
        guard let song = selectedSong else { return }
        guard let token = spotifyAccessToken else {
            print("❌ No Spotify access token available")
            spotifySearchResult = "Song not found"
            return
        }
        
        isSearchingSpotify = true
        spotifySearchResult = ""
        
        Task {
            do {
                // Try ISRC match first if available
                var spotifyResult: SpotifyService.SpotifyTrack? = nil
                
                if let isrc = song.isrc {
                    print("🔍 Searching Spotify with ISRC: \(isrc)")
                    spotifyResult = try await SpotifyService.searchTrackByISRC(
                        isrc: isrc,
                        token: token
                    )
                }
                
                // Fallback to title/artist search if ISRC not found or no match
                if spotifyResult == nil {
                    print("🔍 Fallback: Searching Spotify with title and artist")
                    spotifyResult = try await SpotifyService.searchTrack(
                        title: song.title,
                        artist: song.artistName,
                        token: token
                    )
                }
                
                await MainActor.run {
                    isSearchingSpotify = false
                    if let result = spotifyResult {
                        spotifySearchResult = "Song found"
                        print("=== Spotify Search Result ===")
                        print("Song: \(result.name)")
                        print("Artist: \(result.artist)")
                        print("Album: \(result.album)")
                        print("Duration: \(result.durationMs) ms")
                        print("Spotify ID: \(result.id)")
                        if let isrc = result.isrc {
                            print("ISRC: \(isrc)")
                        }
                        if let previewURL = result.previewURL {
                            print("Preview URL: \(previewURL)")
                        }
                        print("============================")
                    } else {
                        spotifySearchResult = "Song not found"
                        print("Song not found on Spotify")
                    }
                }
            } catch {
                await MainActor.run {
                    isSearchingSpotify = false
                    spotifySearchResult = "Song not found"
                    print("Error searching Spotify: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Spotify Service
struct SpotifyService {
    // MARK: - Configuration
    static let clientID = "2bbd31fbbf9e4812b5e7a2026b26380d"
    static let clientSecret = "a0e8ef105c9c4bf28e746adff852b352" // You need to add your client secret here
    
    struct SpotifyTrack {
        let id: String
        let name: String
        let artist: String
        let album: String
        let durationMs: Int
        let previewURL: String?
        let isrc: String?
    }
    
    // Helper structs for decoding
    private struct SpotifyTrackResponse: Codable {
        let id: String
        let name: String
        let artists: [SpotifyArtist]
        let album: SpotifyAlbum
        let durationMs: Int
        let previewURL: String?
        let externalIds: SpotifyExternalIds?
        
        enum CodingKeys: String, CodingKey {
            case id, name, artists, album
            case durationMs = "duration_ms"
            case previewURL = "preview_url"
            case externalIds = "external_ids"
        }
    }
    
    private struct SpotifyArtist: Codable {
        let name: String
    }
    
    private struct SpotifyAlbum: Codable {
        let name: String
    }
    
    private struct SpotifyExternalIds: Codable {
        let isrc: String?
    }
    
    private struct SpotifySearchResponse: Codable {
        let tracks: SpotifyTracksContainer
    }
    
    private struct SpotifyTracksContainer: Codable {
        let items: [SpotifyTrackResponse]
    }
    
    struct TokenResponse: Codable {
        let accessToken: String
        
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }
    
    // Get access token using Client Credentials flow
    static func getAccessToken() async throws -> String {
        let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
        
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Create Basic Auth header
        let credentials = "\(clientID):\(clientSecret)"
        let credentialsData = credentials.data(using: .utf8)!
        let base64Credentials = credentialsData.base64EncodedString()
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
        
        let bodyString = "grant_type=client_credentials"
        request.httpBody = bodyString.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
        
        return tokenResponse.accessToken
    }
    
    // Search for a track on Spotify by ISRC (most accurate)
    static func searchTrackByISRC(isrc: String, token: String) async throws -> SpotifyTrack? {
        let encodedISRC = isrc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? isrc
        let urlString = "https://api.spotify.com/v1/search?q=isrc:\(encodedISRC)&type=track&limit=1"
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(SpotifySearchResponse.self, from: data)
        
        guard let firstTrack = searchResponse.tracks.items.first else {
            return nil
        }
        
        return SpotifyTrack(
            id: firstTrack.id,
            name: firstTrack.name,
            artist: firstTrack.artists.first?.name ?? "Unknown Artist",
            album: firstTrack.album.name,
            durationMs: firstTrack.durationMs,
            previewURL: firstTrack.previewURL,
            isrc: firstTrack.externalIds?.isrc
        )
    }
    
    // Search for a track on Spotify by title and artist (fallback)
    static func searchTrack(title: String, artist: String, token: String) async throws -> SpotifyTrack? {
        // Build search query
        let searchQuery = "track:\(title) artist:\(artist)"
        let encodedQuery = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchQuery
        
        let urlString = "https://api.spotify.com/v1/search?q=\(encodedQuery)&type=track&limit=1"
        
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoder = JSONDecoder()
        let searchResponse = try decoder.decode(SpotifySearchResponse.self, from: data)
        
        // Convert the first result to our public SpotifyTrack type
        guard let firstTrack = searchResponse.tracks.items.first else {
            return nil
        }
        
        return SpotifyTrack(
            id: firstTrack.id,
            name: firstTrack.name,
            artist: firstTrack.artists.first?.name ?? "Unknown Artist",
            album: firstTrack.album.name,
            durationMs: firstTrack.durationMs,
            previewURL: firstTrack.previewURL,
            isrc: firstTrack.externalIds?.isrc
        )
    }
}

#Preview {
    TestSongMatchView()
}
