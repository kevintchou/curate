//
//  PreferencesView.swift
//  Curate
//
//  Created by Kevin Chou on 12/12/25.
//

import SwiftUI

struct PreferencesView: View {
    @Environment(\.llmServiceProvider) private var llmServiceProvider
    @AppStorage("selectedGenres") private var selectedGenresData: Data = Data()
    @AppStorage("stationTemperature") private var temperature: Double = 0.5
    @AppStorage("recommendationEngine") private var recommendationEngineRaw: String = RecommendationEngine.toolCalling.rawValue
    @State private var selectedGenres: Set<String> = []

    private var recommendationEngine: Binding<RecommendationEngine> {
        Binding(
            get: { RecommendationEngine(rawValue: recommendationEngineRaw) ?? .toolCalling },
            set: { recommendationEngineRaw = $0.rawValue }
        )
    }
    
    private let availableGenres = [
        "Rock", "Pop", "Hip-Hop", "Electronic", "Jazz",
        "Classical", "Country", "R&B", "Metal", "Folk",
        "Blues", "Reggae", "Latin", "Indie", "Alternative"
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Temperature Control Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Temperature")
                            .font(.headline)
                        
                        Spacer()
                        
                        Text(temperatureLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("Controls how adventurous or conservative the station recommendations are")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Slider(value: $temperature, in: 0...1, step: 0.1)
                    
                    HStack {
                        Text("Exploit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Explore")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                
                // Genre Preferences Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Genre Preferences")
                            .font(.headline)
                        
                        Spacer()
                        
                        if !selectedGenres.isEmpty {
                            Button {
                                selectedGenres.removeAll()
                                saveGenres()
                            } label: {
                                Text("Clear")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    
                    Text(selectedGenres.isEmpty ? "Tap genres to boost them (3x) - others get 0.3x weight" : "Selected: \(selectedGenres.count) genre\(selectedGenres.count == 1 ? "" : "s") - 3x boost, others 0.3x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    // Genre grid
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 8) {
                        ForEach(availableGenres, id: \.self) { genre in
                            Button {
                                toggleGenre(genre)
                            } label: {
                                HStack(spacing: 4) {
                                    if selectedGenres.contains(genre) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                    }
                                    Text(genre)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    selectedGenres.contains(genre) ?
                                    Color.blue.opacity(0.2) : Color(.systemGray6)
                                )
                                .foregroundStyle(
                                    selectedGenres.contains(genre) ?
                                    .blue : .primary
                                )
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                // Developer Settings Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Developer Settings")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommendation Engine")
                            .font(.subheadline)

                        Picker("Engine", selection: recommendationEngine) {
                            ForEach(RecommendationEngine.allCases, id: \.self) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(recommendationEngine.wrappedValue.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                // AI Provider Section
                aiProviderSection
            }
            .padding()
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadGenres()
        }
    }
    
    // MARK: - AI Provider Section

    @ViewBuilder
    private var aiProviderSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Provider")
                .font(.headline)

            Text("Choose where AI processing runs for station generation and recommendations")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(LLMServiceType.allCases, id: \.self) { type in
                Button {
                    if type == .local && !llmServiceProvider.isLocalAvailable {
                        return
                    }
                    llmServiceProvider.switchService(to: type)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: type.icon)
                            .font(.system(size: 22))
                            .foregroundStyle(providerColor(for: type))
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(isProviderEnabled(type) ? .primary : .secondary)

                            Text(type.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)

                            if type == .local, let reason = llmServiceProvider.localUnavailableReason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Spacer()

                        if llmServiceProvider.activeServiceType == type {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.blue)
                        } else {
                            Circle()
                                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                                .frame(width: 22, height: 22)
                        }
                    }
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(llmServiceProvider.activeServiceType == type ?
                                  Color.blue.opacity(0.1) : Color(.systemGray6))
                            .overlay {
                                if llmServiceProvider.activeServiceType == type {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                                }
                            }
                    }
                    .opacity(isProviderEnabled(type) ? 1.0 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(type == .local && !llmServiceProvider.isLocalAvailable)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func providerColor(for type: LLMServiceType) -> Color {
        switch type {
        case .backend: return .blue
        case .local: return llmServiceProvider.isLocalAvailable ? .green : .gray
        }
    }

    private func isProviderEnabled(_ type: LLMServiceType) -> Bool {
        if type == .local {
            return llmServiceProvider.isLocalAvailable
        }
        return true
    }

    private func toggleGenre(_ genre: String) {
        if selectedGenres.contains(genre) {
            selectedGenres.remove(genre)
        } else {
            selectedGenres.insert(genre)
        }
        saveGenres()
    }
    
    private func saveGenres() {
        if let encoded = try? JSONEncoder().encode(Array(selectedGenres)) {
            selectedGenresData = encoded
        }
    }
    
    private func loadGenres() {
        if let decoded = try? JSONDecoder().decode([String].self, from: selectedGenresData) {
            selectedGenres = Set(decoded)
        }
    }
    
    private var temperatureLabel: String {
        switch temperature {
        case 0..<0.3: return "Conservative"
        case 0.3..<0.7: return "Balanced"
        default: return "Adventurous"
        }
    }
}

#Preview {
    NavigationStack {
        PreferencesView()
    }
}
