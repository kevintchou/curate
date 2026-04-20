//
//  SidebarView.swift
//  Curate
//
//  Created by Kevin Chou on 4/14/26.
//

import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var isOpen: Bool
    @Binding var showPreferences: Bool
    @Query(sort: \Station.lastPlayedAt, order: .reverse) private var stations: [Station]
    var onSelectStation: (Station) -> Void
    var onDeleteStation: (Station) -> Void

    // Gesture state
    @GestureState private var dragOffset: CGFloat = 0

    private let sidebarWidth: CGFloat = UIScreen.main.bounds.width * 0.8

    var body: some View {
        ZStack(alignment: .leading) {
            // Dimmed background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isOpen = false
                    }
                }

            // Sidebar panel
            sidebarContent
                .frame(width: sidebarWidth)
                .offset(x: dragOffset)
                .gesture(
                    DragGesture()
                        .updating($dragOffset) { value, state, _ in
                            if value.translation.width < 0 {
                                state = value.translation.width
                            }
                        }
                        .onEnded { value in
                            if value.translation.width < -80 {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    isOpen = false
                                }
                            }
                        }
                )
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("History")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Spacer()

                    Button {
                        withAnimation(.easeOut(duration: 0.25)) {
                            isOpen = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .padding(.bottom, 20)

                // Station list
                if stations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No stations yet")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(sortedSectionKeys, id: \.self) { section in
                                sectionHeader(section)
                                ForEach(groupedStations[section] ?? [], id: \.id) { station in
                                    stationRow(station)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 80)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // Floating translucent settings button overlaying the history
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    isOpen = false
                }
                showPreferences = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Grouped Stations

    private var groupedStations: [String: [Station]] {
        let calendar = Calendar.current
        var groups: [String: [Station]] = [:]

        for station in stations {
            let key: String
            if calendar.isDateInToday(station.lastPlayedAt) {
                key = "Today"
            } else if calendar.isDateInYesterday(station.lastPlayedAt) {
                key = "Yesterday"
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()),
                      station.lastPlayedAt > weekAgo {
                key = "This Week"
            } else {
                key = "Older"
            }
            groups[key, default: []].append(station)
        }

        return groups
    }

    private var sortedSectionKeys: [String] {
        groupedStations.keys.sorted { sectionSortOrder($0) < sectionSortOrder($1) }
    }

    private func sectionSortOrder(_ section: String) -> Int {
        switch section {
        case "Today": return 0
        case "Yesterday": return 1
        case "This Week": return 2
        default: return 3
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func stationRow(_ station: Station) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) {
                isOpen = false
            }
            onSelectStation(station)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconForStation(station))
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(station.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.05))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                onDeleteStation(station)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func iconForStation(_ station: Station) -> String {
        switch station.type {
        case .llmGenerated: return "sparkles"
        case .mood: return "face.smiling"
        case .songSeed: return "music.note"
        case .artistSeed: return "person.fill"
        case .genreSeed: return "guitars"
        case .decadeSeed: return "calendar"
        case .fitness: return "figure.run"
        }
    }
}
