//
//  BuildPlaylistMiningTool.swift
//  Curate
//
//  High-level approach tool: builds a station by mining Apple Music editorial playlists.
//  Expands intent to queries → finds playlists → extracts and ranks tracks.
//

import Foundation
import MusicKit

final class BuildPlaylistMiningTool: MusicTool {
    let name = "build_playlist_mining_station"
    let description = """
        Build a station by mining Apple Music editorial playlists. \
        Takes a mood/vibe description, finds matching playlists, extracts tracks, and ranks by diversity. \
        Best for mood/vibe/activity requests like "sad indie for a rainy day". \
        IMPORTANT: Always provide search_queries — 5-8 Apple Music search terms that capture the mood/vibe \
        (e.g. for "rainy afternoon": ["rainy day chill", "cozy afternoon", "grey day vibes", "mellow indie"]). \
        Think in terms of Apple Music editorial playlist names, not literal descriptions. \
        Returns deduplicated, ranked candidates.
        """

    let parameters = ToolParameterSchema(
        properties: [
            "intent": .string("Natural language description (e.g., 'chill electronic for late night coding')"),
            "search_queries": .stringArray("5-8 Apple Music search terms matching the mood/vibe (e.g. ['rainy day chill', 'cozy afternoon', 'grey day vibes']). Use terms that match Apple Music editorial playlist names."),
            "genre_hints": .stringArray("Optional genre hints to focus the search"),
            "track_count": .integer("Target number of tracks to return (default 50)"),
            "max_playlists": .integer("Maximum playlists to mine (default 5)")
        ],
        required: ["intent"]
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let args = try ToolArguments(from: arguments)
        let intent = try args.requireString("intent")
        let genreHints = args.stringArray("genre_hints")
        let trackCount = args.optionalInt("track_count", default: 50)
        let maxPlaylists = args.optionalInt("max_playlists", default: 5)

        // Step 1: Use LLM-provided search queries, or fall back to minimal intent-based queries.
        // The calling LLM (cloud: GPT-4o-mini, local: Apple Intelligence) is expected to provide
        // search_queries tailored to Apple Music editorial playlist naming conventions.
        // IntentClassifier path doesn't provide queries — the minimal fallback covers that case.
        let providedQueries = args.stringArray("search_queries")
        let queries: [String]
        if !providedQueries.isEmpty {
            queries = providedQueries
            print("🎵 PlaylistMining: \(queries.count) LLM-provided queries → [\(queries.joined(separator: ", "))]")
        } else {
            // Minimal fallback for IntentClassifier path (no LLM-generated queries).
            // Genre hints (from LLMStationConfig) are appended if available.
            var fallback = [intent, "\(intent) playlist", "\(intent) music", "\(intent) vibes"]
            for genre in genreHints.prefix(2) {
                fallback.append("\(genre) \(intent)")
            }
            queries = fallback
            print("🎵 PlaylistMining: No search_queries provided, using minimal fallback → [\(queries.joined(separator: ", "))]")
        }

        // Step 2: Search for playlists
        var playlistMap: [String: (Playlist, String)] = [:] // id -> (playlist, query)
        for query in queries.prefix(6) {
            var request = MusicCatalogSearchRequest(term: query, types: [Playlist.self])
            request.limit = 3
            let response = try await request.response()

            for playlist in response.playlists {
                if playlistMap[playlist.id.rawValue] == nil {
                    playlistMap[playlist.id.rawValue] = (playlist, query)
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000) // Rate limit
        }

        // Step 3: Score playlists by relevance (prefer editorial)
        let scoredPlaylists = playlistMap.values.map { playlist, query -> (Playlist, Double, String) in
            var score = 0.0
            let isEditorial = playlist.curatorName?.lowercased().contains("apple") ?? false
            if isEditorial { score += 0.3 }
            let nameWords = Set(playlist.name.lowercased().components(separatedBy: .whitespaces))
            let intentWords = Set(intent.lowercased().components(separatedBy: .whitespaces))
            let overlap = nameWords.intersection(intentWords)
            score += Double(overlap.count) * 0.15
            if playlist.name.lowercased().contains(intent.lowercased()) { score += 0.2 }
            return (playlist, score, query)
        }.sorted { $0.1 > $1.1 }

        print("🎵 PlaylistMining: Found \(playlistMap.count) unique playlists across all queries")

        // Step 4: Extract tracks per playlist into separate buckets for round-robin.
        // Tracks are deduplicated globally across all playlists by ISRC and title+artist.
        var playlistBuckets: [[PlaylistMinedTrack]] = []
        var seenISRCs: Set<String> = []
        var seenTitleArtist: Set<String> = []

        for (playlist, _, query) in scoredPlaylists.prefix(maxPlaylists) {
            var trackRequest = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: playlist.id)
            trackRequest.properties = [.tracks]
            let trackResponse = try await trackRequest.response()

            guard let tracks = trackResponse.items.first?.tracks else { continue }

            var bucketTracks: [PlaylistMinedTrack] = []
            for track in tracks.prefix(100) {
                // Deduplicate by ISRC where available
                let isrc = track.isrc ?? ""
                if !isrc.isEmpty && seenISRCs.contains(isrc) { continue }
                if !isrc.isEmpty { seenISRCs.insert(isrc) }

                // Deduplicate by normalised title + artist to catch same song with different ISRCs
                // (e.g. remastered versions, regional releases, label re-issues)
                let titleArtistKey = "\(track.title.lowercased().filter { !$0.isWhitespace })||\(track.artistName.lowercased().filter { !$0.isWhitespace })"
                if seenTitleArtist.contains(titleArtistKey) { continue }
                seenTitleArtist.insert(titleArtistKey)

                bucketTracks.append(PlaylistMinedTrack(
                    id: track.id.rawValue,
                    title: track.title,
                    artistName: track.artistName,
                    albumTitle: track.albumTitle,
                    isrc: track.isrc,
                    genreNames: track.genreNames,
                    releaseDate: track.releaseDate?.ISO8601Format(),
                    sourcePlaylist: playlist.name,
                    sourceQuery: query
                ))
            }

            if !bucketTracks.isEmpty {
                playlistBuckets.append(bucketTracks)
            }

            try await Task.sleep(nanoseconds: 100_000_000) // Rate limit
        }

        let totalCandidates = playlistBuckets.reduce(0) { $0 + $1.count }
        print("🎵 PlaylistMining: \(totalCandidates) unique tracks from \(playlistBuckets.count) playlists (after dedup)")

        // Step 5: Interleaved round-robin across playlist buckets.
        // Takes one track at a time from each bucket in rotation, respecting Apple's
        // within-playlist ordering (editorial playlists front-load their best tracks).
        // Commented out: diversity enforcement (artist cap of 2 per artist)
        var selected: [PlaylistMinedTrack] = []
        var indices = Array(repeating: 0, count: playlistBuckets.count)
        var anyProgress = true
        while selected.count < trackCount && anyProgress {
            anyProgress = false
            for i in 0..<playlistBuckets.count {
                guard selected.count < trackCount else { break }
                guard indices[i] < playlistBuckets[i].count else { continue }
                selected.append(playlistBuckets[i][indices[i]])
                indices[i] += 1
                anyProgress = true
            }
        }

        // var artistCounts: [String: Int] = [:]
        // for track in allTracks {
        //     let key = track.artistName.lowercased()
        //     if (artistCounts[key] ?? 0) >= 2 { continue }
        //     selected.append(track)
        //     artistCounts[key, default: 0] += 1
        //     if selected.count >= trackCount { break }
        // }

        print("🎵 PlaylistMining: Selected \(selected.count) tracks (target: \(trackCount))")
        return .encode(PlaylistMiningResult(
            intent: intent,
            playlistsSearched: scoredPlaylists.count,
            playlistsMined: playlistBuckets.count,
            totalCandidates: totalCandidates,
            tracks: selected
        ))
    }

    // MARK: - Commented out: static synonym-based query generation
    // Replaced by LLM-provided search_queries parameter.
    // The calling LLM (cloud: GPT-4o-mini, local: Apple Intelligence) generates
    // semantically appropriate Apple Music search terms on the fly, which is more
    // accurate and flexible than a hardcoded synonym dictionary.
    // Kept for reference / easy rollback.
    //
    // private func generateQueries(intent: String, genres: [String]) -> [String] {
    //     var queries: [String] = []
    //     let lower = intent.lowercased()
    //
    //     queries.append(intent)
    //     queries.append("\(intent) playlist")
    //
    //     let synonymMap: [String: [String]] = [
    //         "rainy":        ["rainy day", "cozy", "grey day", "stormy"],
    //         "rain":         ["rainy day", "cozy", "stormy"],
    //         "rainy afternoon": ["rainy afternoon chill", "cozy afternoon", "grey day chill", "mellow rainy"],
    //         "rainy morning":   ["rainy morning", "grey morning", "cozy morning", "slow morning"],
    //         "rainy night":     ["rainy night", "late night rain", "moody night", "stormy night"],
    //         "morning":      ["morning coffee", "wake up", "sunrise", "good morning"],
    //         "afternoon":    ["afternoon chill", "lazy afternoon", "mellow afternoon", "sunday afternoon"],
    //         "evening":      ["evening wind down", "sunset", "after work"],
    //         "night":        ["late night", "midnight", "night drive", "after dark"],
    //         "coffee":       ["coffee shop", "cafe", "morning coffee", "study"],
    //         "tea":          ["cozy", "calm", "peaceful", "afternoon chill"],
    //         "study":        ["focus", "concentration", "studying", "deep focus"],
    //         "focus":        ["deep focus", "concentration", "productivity"],
    //         "workout":      ["gym", "training", "pump up", "exercise", "fitness"],
    //         "gym":          ["workout", "training", "pump up", "fitness"],
    //         "chill":        ["chilled", "relaxed", "mellow", "laid back"],
    //         "relax":        ["relaxing", "calm", "peaceful", "chill"],
    //         "sad":          ["melancholy", "heartbreak", "emotional", "sad songs"],
    //         "happy":        ["feel good", "upbeat", "positive", "good vibes"],
    //         "hype":         ["pump up", "energy", "adrenaline", "intense"],
    //         "party":        ["dance", "club", "upbeat", "party hits"],
    //         "sleep":        ["sleep", "ambient", "calm", "peaceful sleep"],
    //         "drive":        ["road trip", "driving", "cruise"],
    //         "cooking":      ["kitchen", "dinner party", "cooking"],
    //         "dinner":       ["dinner party", "evening", "sophisticated"],
    //         "summer":       ["summer hits", "beach", "warm"],
    //         "winter":       ["winter", "cozy", "christmas", "cold"],
    //         "acoustic":     ["acoustic", "unplugged", "singer-songwriter"],
    //         "vibey":        ["vibes", "chill", "mellow"],
    //         "cozy":         ["cozy", "comfort", "warm", "hygge"],
    //     ]
    //
    //     var synTerms: [String] = []
    //     let intentWords = lower.components(separatedBy: .whitespaces)
    //     for word in intentWords {
    //         if let synonyms = synonymMap[word] {
    //             synTerms.append(contentsOf: synonyms.prefix(2))
    //         }
    //     }
    //
    //     if intentWords.count >= 2 {
    //         let bigram = intentWords.prefix(2).joined(separator: " ")
    //         if let synonyms = synonymMap[bigram] {
    //             synTerms.append(contentsOf: synonyms.prefix(2))
    //         }
    //     }
    //
    //     var seenTerms: Set<String> = []
    //     for term in synTerms {
    //         guard seenTerms.insert(term).inserted else { continue }
    //         queries.append(term)
    //         queries.append("\(term) playlist")
    //     }
    //
    //     for genre in genres.prefix(2) {
    //         queries.append("\(genre) \(intent)")
    //     }
    //
    //     var seen: Set<String> = []
    //     return queries.filter { seen.insert($0.lowercased()).inserted }.prefix(8).map { $0 }
    // }
}

struct PlaylistMinedTrack: Codable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let isrc: String?
    let genreNames: [String]
    let releaseDate: String?
    let sourcePlaylist: String
    let sourceQuery: String
}

struct PlaylistMiningResult: Codable {
    let intent: String
    let playlistsSearched: Int
    let playlistsMined: Int
    let totalCandidates: Int
    let tracks: [PlaylistMinedTrack]
}
