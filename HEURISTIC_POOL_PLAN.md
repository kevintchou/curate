# Heuristic Pool Architecture Plan

## Overview

A third recommendation engine that replaces the LLM-based search plan generation with an on-device heuristic parser + light MLP, while reusing the existing pool building and track selection infrastructure.

**Key Differentiator**: No network call for intent parsing. Genre preferences are first-class citizens, not afterthoughts.

---

## System Comparison

| Component | Artist Seeds | Hybrid Pool (LLM) | Heuristic Pool (New) |
|-----------|--------------|-------------------|---------------------|
| Intent Parsing | LLM (Gemini) | LLM Edge Function | On-device heuristics + MLP |
| Genre Handling | LLM prompt injection | Weak prompt append | Explicit genre injection |
| Pool Building | Artist top tracks | Playlist + catalog search | Playlist + catalog search |
| Track Selection | TrackFilter | HybridRecommender | HybridRecommender (reused) |
| Latency | ~2-3s (LLM) | ~2-3s (Edge + LLM) | ~100-200ms (local) |
| Offline Capable | No | No | Yes (parsing only) |

---

## Architecture

### File Structure

```
Curate/
├── HeuristicPool/
│   ├── HeuristicPoolTypes.swift          # Data models
│   ├── VibeParser.swift                   # Rule-based + MLP parser
│   ├── SearchExpander.swift               # Vibe → search queries
│   ├── PlaylistMoodMatcher.swift          # Score playlists by description
│   ├── HeuristicSearchPlanService.swift   # Protocol-conforming service
│   ├── HeuristicPoolIntegration.swift     # Integration with LLMStationViewModel
│   └── Resources/
│       ├── MoodKeywords.json              # Keyword → mood mappings
│       ├── GenreSynonyms.json             # Genre normalization
│       └── VibeClassifier.mlmodel         # Future: Core ML model
```

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  User Input: "relaxing sunset drive"                                │
│  User Preferences: [Hip-Hop, R&B]                                   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  VibeParser (On-Device)                                             │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. Tokenize & normalize input                               │   │
│  │  2. Extract mood keywords via dictionary lookup              │   │
│  │  3. Detect activity context (drive, workout, study, etc.)    │   │
│  │  4. Detect time-of-day hints (sunset, morning, night)        │   │
│  │  5. (Future) MLP classifier for ambiguous inputs             │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Output: ParsedVibe {                                               │
│    rawInput: "relaxing sunset drive"                                │
│    moods: [.relaxed, .chill]                                        │
│    activity: .driving                                               │
│    timeContext: .evening                                            │
│    confidence: 0.85                                                 │
│  }                                                                   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  SearchExpander                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Input: ParsedVibe + UserPreferences (genres)                │   │
│  │                                                               │   │
│  │  Genre Injection Strategy:                                    │   │
│  │  - If user has genre prefs: inject into 70% of queries       │   │
│  │  - Keep 30% genre-free for mood-based discovery              │   │
│  │                                                               │   │
│  │  Expansion Rules:                                             │   │
│  │  1. [genre] + [raw input]                                     │   │
│  │  2. [genre] + [primary mood]                                  │   │
│  │  3. [genre] + [activity] + [mood]                            │   │
│  │  4. [mood] + [time context] (genre-free for discovery)        │   │
│  │  5. Editorial playlist patterns ("[mood] playlist")           │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Output: SearchQueries [                                            │
│    { term: "hip hop relaxing sunset drive", priority: 1 },          │
│    { term: "r&b chill vibes", priority: 2 },                        │
│    { term: "hip hop driving music", priority: 3 },                  │
│    { term: "sunset chill playlist", priority: 4 },  // genre-free   │
│    { term: "evening relaxing music", priority: 5 }, // genre-free   │
│  ]                                                                   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Apple Music API (Playlist Search)                                  │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  For each query:                                              │   │
│  │  1. MusicCatalogSearchRequest(term, types: [Playlist])       │   │
│  │  2. Fetch playlist metadata (name, description, curator)      │   │
│  │  3. Pass to PlaylistMoodMatcher for scoring                   │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PlaylistMoodMatcher                                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Score each playlist against ParsedVibe:                      │   │
│  │                                                               │   │
│  │  1. Keyword Match Score (0-1):                               │   │
│  │     - Count mood keywords in title/description               │   │
│  │     - Weighted by keyword importance                          │   │
│  │                                                               │   │
│  │  2. Editorial Bonus (+0.2 if Apple editorial):               │   │
│  │     - Apple playlists have better descriptions               │   │
│  │                                                               │   │
│  │  3. Genre Match Score (0-1):                                  │   │
│  │     - Check if playlist appears genre-relevant               │   │
│  │     - Based on curator name, title keywords                   │   │
│  │                                                               │   │
│  │  4. (Future) Embedding Similarity:                            │   │
│  │     - NaturalLanguage framework sentence embeddings           │   │
│  │     - Compare ParsedVibe embedding vs description embedding   │   │
│  │                                                               │   │
│  │  Final Score = 0.5*keyword + 0.3*genre + 0.2*editorial        │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Output: RankedPlaylists [                                          │
│    { playlist: "Chill Hip-Hop Beats", score: 0.92 },               │
│    { playlist: "R&B Slow Jams", score: 0.85 },                     │
│    { playlist: "Sunset Vibes", score: 0.78 },                      │
│  ]                                                                   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Pool Building (Reuse CandidatePoolService)                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  1. Take top-N ranked playlists                               │   │
│  │  2. Fetch tracks from each playlist                           │   │
│  │  3. Deduplicate by ISRC                                       │   │
│  │  4. Store as PoolTracks with source metadata                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  HybridRecommender (Reused)                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  - Same selection logic as LLM-based hybrid pool             │   │
│  │  - Artist repeat window enforcement                           │   │
│  │  - Source bucket balancing                                    │   │
│  │  - User overlay for skip/play tracking                        │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Component Specifications

### 1. HeuristicPoolTypes.swift

```swift
// Parsed vibe output from VibeParser
struct ParsedVibe {
    let rawInput: String
    let moods: [MoodCategory]
    let activity: ActivityContext?
    let timeContext: TimeContext?
    let confidence: Float  // 0-1, for fallback decisions

    // Canonical intent for caching (hash of normalized components)
    var canonicalIntent: String { ... }
}

enum MoodCategory: String, CaseIterable, Codable {
    case energetic, relaxed, melancholic, uplifting, aggressive
    case romantic, nostalgic, focused, party, chill
    // ~15-20 total moods
}

enum ActivityContext: String, CaseIterable, Codable {
    case driving, workout, studying, sleeping, cooking
    case working, commuting, party, dinner, meditation
}

enum TimeContext: String, CaseIterable, Codable {
    case morning, afternoon, evening, night, lateNight
}

// Search query with metadata
struct HeuristicSearchQuery {
    let term: String
    let priority: Int
    let hasGenre: Bool  // For analytics
    let sourceRule: String  // Which expansion rule generated this
}

// Playlist with mood score
struct ScoredPlaylist {
    let playlist: ProviderPlaylist
    let moodScore: Float
    let genreScore: Float
    let editorialBonus: Float
    let totalScore: Float
}
```

### 2. VibeParser.swift

**Phase 1: Rule-Based (Initial Implementation)**

```swift
protocol VibeParserProtocol {
    func parse(input: String) -> ParsedVibe
}

final class RuleBasedVibeParser: VibeParserProtocol {
    // Loaded from MoodKeywords.json
    private let moodKeywords: [String: MoodCategory]
    private let activityKeywords: [String: ActivityContext]
    private let timeKeywords: [String: TimeContext]

    func parse(input: String) -> ParsedVibe {
        let tokens = tokenize(input)

        // 1. Direct keyword matching
        let moods = extractMoods(from: tokens)
        let activity = extractActivity(from: tokens)
        let timeContext = extractTimeContext(from: tokens)

        // 2. Synonym expansion (e.g., "chill" → relaxed)
        let expandedMoods = expandSynonyms(moods)

        // 3. Confidence based on match count
        let confidence = calculateConfidence(
            moodCount: expandedMoods.count,
            hasActivity: activity != nil,
            hasTime: timeContext != nil
        )

        return ParsedVibe(
            rawInput: input,
            moods: expandedMoods,
            activity: activity,
            timeContext: timeContext,
            confidence: confidence
        )
    }
}
```

**Phase 2: MLP Enhancement (Future)**

```swift
final class MLPVibeParser: VibeParserProtocol {
    private let ruleParser = RuleBasedVibeParser()
    private let mlModel: VibeClassifier?  // Core ML model

    func parse(input: String) -> ParsedVibe {
        // 1. Try rule-based first
        let ruleParsed = ruleParser.parse(input: input)

        // 2. If low confidence, use MLP
        if ruleParsed.confidence < 0.5, let model = mlModel {
            return mlpParse(input: input, fallback: ruleParsed)
        }

        return ruleParsed
    }

    private func mlpParse(input: String, fallback: ParsedVibe) -> ParsedVibe {
        // Use NaturalLanguage framework for tokenization
        // Feed to Core ML model
        // Model outputs: mood probabilities, activity probabilities
        // Threshold and return
    }
}
```

### 3. SearchExpander.swift

```swift
protocol SearchExpanderProtocol {
    func expand(vibe: ParsedVibe, genres: [String]) -> [HeuristicSearchQuery]
}

final class SearchExpander: SearchExpanderProtocol {

    // Configuration
    private let genreInjectionRatio: Float = 0.7  // 70% of queries get genre
    private let maxQueries: Int = 8

    func expand(vibe: ParsedVibe, genres: [String]) -> [HeuristicSearchQuery] {
        var queries: [HeuristicSearchQuery] = []
        var priority = 1

        // Rule 1: Genre + raw input (highest priority)
        if !genres.isEmpty {
            for genre in genres.prefix(2) {
                queries.append(HeuristicSearchQuery(
                    term: "\(genre.lowercased()) \(vibe.rawInput)",
                    priority: priority,
                    hasGenre: true,
                    sourceRule: "genre_raw"
                ))
                priority += 1
            }
        }

        // Rule 2: Genre + primary mood
        if !genres.isEmpty, let primaryMood = vibe.moods.first {
            for genre in genres.prefix(2) {
                queries.append(HeuristicSearchQuery(
                    term: "\(genre.lowercased()) \(primaryMood.searchTerm)",
                    priority: priority,
                    hasGenre: true,
                    sourceRule: "genre_mood"
                ))
                priority += 1
            }
        }

        // Rule 3: Genre + activity + mood (if activity present)
        if !genres.isEmpty, let activity = vibe.activity, let mood = vibe.moods.first {
            queries.append(HeuristicSearchQuery(
                term: "\(genres[0].lowercased()) \(activity.searchTerm) \(mood.searchTerm)",
                priority: priority,
                hasGenre: true,
                sourceRule: "genre_activity_mood"
            ))
            priority += 1
        }

        // Rule 4: Genre-free mood queries (for discovery)
        for mood in vibe.moods.prefix(2) {
            if let time = vibe.timeContext {
                queries.append(HeuristicSearchQuery(
                    term: "\(time.searchTerm) \(mood.searchTerm) music",
                    priority: priority,
                    hasGenre: false,
                    sourceRule: "time_mood"
                ))
            } else {
                queries.append(HeuristicSearchQuery(
                    term: "\(mood.searchTerm) playlist",
                    priority: priority,
                    hasGenre: false,
                    sourceRule: "mood_playlist"
                ))
            }
            priority += 1
        }

        // Rule 5: Activity-based (genre-free)
        if let activity = vibe.activity {
            queries.append(HeuristicSearchQuery(
                term: "\(activity.searchTerm) music",
                priority: priority,
                hasGenre: false,
                sourceRule: "activity"
            ))
        }

        return Array(queries.prefix(maxQueries))
    }
}
```

### 4. PlaylistMoodMatcher.swift

```swift
protocol PlaylistMoodMatcherProtocol {
    func score(playlist: ProviderPlaylist, against vibe: ParsedVibe, genres: [String]) -> ScoredPlaylist
    func rankPlaylists(_ playlists: [ProviderPlaylist], against vibe: ParsedVibe, genres: [String]) -> [ScoredPlaylist]
}

final class PlaylistMoodMatcher: PlaylistMoodMatcherProtocol {

    // Loaded from MoodKeywords.json
    private let moodKeywords: [MoodCategory: [String]]

    func score(playlist: ProviderPlaylist, against vibe: ParsedVibe, genres: [String]) -> ScoredPlaylist {
        let searchableText = "\(playlist.name) \(playlist.description ?? "")".lowercased()

        // 1. Mood keyword match score
        var moodMatchCount = 0
        var totalKeywords = 0
        for mood in vibe.moods {
            let keywords = moodKeywords[mood] ?? []
            totalKeywords += keywords.count
            for keyword in keywords {
                if searchableText.contains(keyword) {
                    moodMatchCount += 1
                }
            }
        }
        let moodScore = totalKeywords > 0 ? Float(moodMatchCount) / Float(totalKeywords) : 0.5

        // 2. Genre match score
        var genreScore: Float = 0.5  // Neutral if no genre preference
        if !genres.isEmpty {
            let genreMatches = genres.filter { searchableText.contains($0.lowercased()) }
            genreScore = Float(genreMatches.count) / Float(genres.count)
        }

        // 3. Editorial bonus
        let editorialBonus: Float = playlist.isEditorial ? 0.2 : 0.0

        // 4. Calculate total score
        let totalScore = (0.5 * moodScore) + (0.3 * genreScore) + editorialBonus

        return ScoredPlaylist(
            playlist: playlist,
            moodScore: moodScore,
            genreScore: genreScore,
            editorialBonus: editorialBonus,
            totalScore: min(1.0, totalScore)
        )
    }

    func rankPlaylists(_ playlists: [ProviderPlaylist], against vibe: ParsedVibe, genres: [String]) -> [ScoredPlaylist] {
        playlists
            .map { score(playlist: $0, against: vibe, genres: genres) }
            .sorted { $0.totalScore > $1.totalScore }
    }
}
```

### 5. HeuristicSearchPlanService.swift

Conforms to `SearchPlanServiceProtocol` so it can be swapped with the LLM version:

```swift
final class HeuristicSearchPlanService: SearchPlanServiceProtocol {

    private let vibeParser: VibeParserProtocol
    private let searchExpander: SearchExpanderProtocol

    init(
        vibeParser: VibeParserProtocol = RuleBasedVibeParser(),
        searchExpander: SearchExpanderProtocol = SearchExpander()
    ) {
        self.vibeParser = vibeParser
        self.searchExpander = searchExpander
    }

    func getSearchPlan(
        for prompt: String,
        platform: MusicPlatform
    ) async throws -> SearchPlan {
        // Load user's genre preferences
        let genres = loadGenrePreferences()

        // 1. Parse the vibe
        let parsedVibe = vibeParser.parse(input: prompt)

        // 2. Expand to search queries
        let queries = searchExpander.expand(vibe: parsedVibe, genres: genres)

        // 3. Convert to SearchPlan format (existing type)
        return SearchPlan(
            canonicalIntent: parsedVibe.canonicalIntent,
            moodCategories: parsedVibe.moods.map { $0.rawValue },
            flavorTags: [parsedVibe.activity?.rawValue, parsedVibe.timeContext?.rawValue].compactMap { $0 },
            intentConfidence: Double(parsedVibe.confidence),
            playlistSearches: queries.map { PlaylistSearch(term: $0.term, priority: $0.priority) },
            catalogSearches: [],  // Heuristic pool focuses on playlists
            artistSeedConfig: nil,
            stationPolicy: SuggestedStationPolicy(
                playlistSourceRatio: 0.8,  // Playlist-heavy
                searchSourceRatio: 0.15,
                artistSeedSourceRatio: 0.05,
                explorationWeight: 0.25,
                artistRepeatWindow: 10
            ),
            isCached: false
        )
    }

    private func loadGenrePreferences() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: "selectedGenres"),
              let genres = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return genres
    }
}
```

### 6. HeuristicPoolIntegration.swift

Integration layer similar to `HybridPoolIntegration.swift`:

```swift
@MainActor
final class HeuristicPoolIntegrationService {

    private let candidatePoolService: CandidatePoolServiceProtocol
    private let playlistMatcher: PlaylistMoodMatcherProtocol
    private let musicProvider: (any PlaylistDiscoveryProtocol)?

    // ... similar structure to HybridPoolIntegrationService

    func getRecommendedTracks(
        prompt: String,
        userId: UUID,
        stationId: UUID,
        count: Int
    ) async throws -> [ProviderTrack] {
        // 1. Get search plan from heuristic service
        let searchPlan = try await heuristicSearchPlanService.getSearchPlan(
            for: prompt,
            platform: .appleMusic
        )

        // 2. Execute playlist searches with mood matching
        var allScoredPlaylists: [ScoredPlaylist] = []

        for playlistSearch in searchPlan.playlistSearches.prefix(5) {
            let playlists = try await musicProvider?.searchPlaylists(
                term: playlistSearch.term,
                limit: 10
            ) ?? []

            let scored = playlistMatcher.rankPlaylists(
                playlists,
                against: parsedVibe,
                genres: loadGenrePreferences()
            )

            allScoredPlaylists.append(contentsOf: scored)
        }

        // 3. Deduplicate and take top playlists
        let topPlaylists = deduplicateAndRank(allScoredPlaylists).prefix(8)

        // 4. Fetch tracks from top playlists
        var poolTracks: [PoolTrack] = []
        for scored in topPlaylists {
            let tracks = try await musicProvider?.getPlaylistTracks(
                playlistId: scored.playlist.id,
                limit: 30
            ) ?? []

            poolTracks.append(contentsOf: tracks.map { track in
                PoolTrack(
                    trackId: track.id,
                    artistId: track.artistId ?? "",
                    isrc: track.isrc,
                    source: .playlist,
                    sourceDetail: "heuristic:\(scored.playlist.name)"
                )
            })
        }

        // 5. Use HybridRecommender for selection (reused)
        let selectedTracks = recommender.selectTracks(
            from: pool,
            userOverlay: overlay,
            policy: searchPlan.effectivePolicy(),
            dislikedArtistIds: dislikedArtists,
            count: count
        )

        // 6. Resolve to ProviderTracks
        return try await resolveProviderTracks(selectedTracks)
    }
}
```

---

## Feature Flag & UI

### PreferencesView Update

```swift
// Add to Developer Settings section:

enum RecommendationEngine: String, CaseIterable {
    case artistSeeds = "Artist Seeds"
    case hybridPool = "Hybrid Pool (LLM)"
    case heuristicPool = "Heuristic Pool"
}

@AppStorage("recommendationEngine") private var recommendationEngine: String = RecommendationEngine.artistSeeds.rawValue

Picker("Recommendation Engine", selection: $recommendationEngine) {
    ForEach(RecommendationEngine.allCases, id: \.rawValue) { engine in
        Text(engine.rawValue).tag(engine.rawValue)
    }
}
```

### Feature Flag Code

```swift
enum RecommendationEngineFlag {
    static var current: RecommendationEngine {
        let raw = UserDefaults.standard.string(forKey: "recommendationEngine") ?? ""
        return RecommendationEngine(rawValue: raw) ?? .artistSeeds
    }

    static var isHeuristicPoolEnabled: Bool {
        current == .heuristicPool
    }

    static var isHybridPoolEnabled: Bool {
        current == .hybridPool
    }

    static var isArtistSeedsEnabled: Bool {
        current == .artistSeeds
    }
}
```

---

## JSON Resource Files

### MoodKeywords.json

```json
{
  "relaxed": ["chill", "calm", "peaceful", "mellow", "soothing", "laid back", "easy"],
  "energetic": ["upbeat", "hype", "pump", "high energy", "intense", "powerful"],
  "melancholic": ["sad", "emotional", "heartbreak", "moody", "dark", "somber"],
  "uplifting": ["happy", "joyful", "positive", "feel good", "optimistic", "bright"],
  "focused": ["study", "concentration", "work", "productive", "ambient", "minimal"],
  "party": ["dance", "club", "turnt", "lit", "celebration", "fun"],
  "romantic": ["love", "sensual", "intimate", "date night", "smooth"],
  "nostalgic": ["throwback", "retro", "classic", "old school", "memories", "90s", "80s"]
}
```

### GenreSynonyms.json

```json
{
  "hip-hop": ["hip hop", "hiphop", "rap", "trap", "boom bap"],
  "r&b": ["rnb", "r and b", "rhythm and blues", "soul"],
  "electronic": ["edm", "house", "techno", "trance", "dubstep"],
  "rock": ["alternative rock", "indie rock", "hard rock"],
  "pop": ["top 40", "mainstream", "chart"],
  "jazz": ["smooth jazz", "bebop", "jazz fusion"],
  "classical": ["orchestra", "symphony", "chamber music"]
}
```

---

## Security Considerations

1. **Input Sanitization**: VibeParser must sanitize user input before using in search queries
   - Strip special characters
   - Limit input length (max 200 chars)
   - Prevent injection of malicious search terms

2. **Resource File Integrity**: JSON files should be bundled in the app (not fetched remotely)
   - No risk of remote tampering
   - Versioned with app releases

3. **Core ML Model Security** (Future):
   - Model must be signed and bundled
   - No dynamic model loading from network
   - Validate model outputs are within expected ranges

4. **Rate Limiting**: Even though parsing is local, still respect Apple Music API limits
   - Reuse existing rate limiting in AppleMusicProvider

---

## Testing Strategy

### Unit Tests

```swift
// VibeParserTests.swift
func testParseRelaxingSunsetDrive() {
    let parser = RuleBasedVibeParser()
    let result = parser.parse(input: "relaxing sunset drive")

    XCTAssertTrue(result.moods.contains(.relaxed))
    XCTAssertEqual(result.activity, .driving)
    XCTAssertEqual(result.timeContext, .evening)
    XCTAssertGreaterThan(result.confidence, 0.7)
}

func testParseAmbiguousInput() {
    let parser = RuleBasedVibeParser()
    let result = parser.parse(input: "good music")

    XCTAssertLessThan(result.confidence, 0.5)  // Should trigger MLP fallback
}

// SearchExpanderTests.swift
func testGenreInjection() {
    let expander = SearchExpander()
    let vibe = ParsedVibe(rawInput: "chill vibes", moods: [.relaxed], ...)

    let queries = expander.expand(vibe: vibe, genres: ["Hip-Hop", "R&B"])

    let genreQueries = queries.filter { $0.hasGenre }
    let genreFreeQueries = queries.filter { !$0.hasGenre }

    XCTAssertGreaterThan(genreQueries.count, genreFreeQueries.count)
    XCTAssertTrue(queries[0].term.lowercased().contains("hip hop"))
}

// PlaylistMoodMatcherTests.swift
func testEditorialBonus() {
    let matcher = PlaylistMoodMatcher()
    let editorial = ProviderPlaylist(id: "1", name: "Chill Vibes", isEditorial: true, ...)
    let userPlaylist = ProviderPlaylist(id: "2", name: "Chill Vibes", isEditorial: false, ...)

    let vibe = ParsedVibe(moods: [.relaxed], ...)

    let editorialScore = matcher.score(playlist: editorial, against: vibe, genres: [])
    let userScore = matcher.score(playlist: userPlaylist, against: vibe, genres: [])

    XCTAssertGreaterThan(editorialScore.totalScore, userScore.totalScore)
}
```

### Integration Tests

```swift
// HeuristicPoolIntegrationTests.swift
func testEndToEndRecommendation() async {
    let service = HeuristicPoolIntegrationService(...)

    // Set genre preferences
    UserDefaults.standard.set(try! JSONEncoder().encode(["Hip-Hop"]), forKey: "selectedGenres")

    let tracks = try await service.getRecommendedTracks(
        prompt: "relaxing sunset drive",
        userId: UUID(),
        stationId: UUID(),
        count: 10
    )

    XCTAssertEqual(tracks.count, 10)
    // Verify genre preference was respected (check track metadata if available)
}
```

---

## Implementation Phases

### Phase 1: Core Parser & Expander (MVP)
- [ ] HeuristicPoolTypes.swift
- [ ] VibeParser.swift (rule-based only)
- [ ] SearchExpander.swift
- [ ] MoodKeywords.json & GenreSynonyms.json
- [ ] Unit tests for parser and expander

### Phase 2: Playlist Matching
- [ ] PlaylistMoodMatcher.swift
- [ ] Integration with AppleMusicProvider
- [ ] Unit tests for mood matching

### Phase 3: Integration
- [ ] HeuristicSearchPlanService.swift
- [ ] HeuristicPoolIntegration.swift
- [ ] Feature flag (RecommendationEngineFlag)
- [ ] PreferencesView picker update
- [ ] LLMStationViewModel integration

### Phase 4: Polish & Testing
- [ ] Integration tests
- [ ] A/B comparison logging
- [ ] Performance benchmarks (latency)

### Phase 5: MLP Enhancement (Future)
- [ ] Collect training data from user interactions
- [ ] Train Core ML model
- [ ] MLPVibeParser implementation
- [ ] Model bundling and signing

---

## Success Metrics

1. **Latency**: Intent parsing < 50ms (vs ~2s for LLM)
2. **Genre Accuracy**: > 80% of tracks match user's genre preference
3. **Mood Relevance**: User skip rate < 30% in first 10 tracks
4. **Diversity**: < 3 tracks from same artist in first 15 tracks
