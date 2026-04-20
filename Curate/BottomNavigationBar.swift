import SwiftUI

// MARK: - Main Tab Enum

enum MainTab: String, CaseIterable, Identifiable {
    case home
    case playlists
    case createStation
    case feature1
    case feature2

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .playlists: return "music.note.list"
        case .createStation: return "plus.circle.fill"
        case .feature1: return "star"
        case .feature2: return "person.fill"
        }
    }

    var label: String {
        switch self {
        case .home: return "Home"
        case .playlists: return "Playlists"
        case .createStation: return "Create"
        case .feature1: return "Discover"
        case .feature2: return "Profile"
        }
    }
}

// MARK: - Bottom Navigation Bar

struct BottomNavigationBar: View {
    @Binding var selectedTab: MainTab
    let onCreateStationTap: () -> Void

    // Theme colors
    private let selectedColor = Color(red: 0.6, green: 0.2, blue: 0.8) // Purple
    private let unselectedColor = Color.gray.opacity(0.6)

    var body: some View {
        HStack(spacing: 0) {
            // Home
            tabButton(for: .home)

            // Playlists
            tabButton(for: .playlists)

            // Create Station (Center)
            createStationButton

            // Feature 1
            tabButton(for: .feature1)

            // Feature 2
            tabButton(for: .feature2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 16)
    }

    // MARK: - Regular Tab Button

    private func tabButton(for tab: MainTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 24))
                .foregroundColor(selectedTab == tab ? selectedColor : unselectedColor)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Create Station Button (Center)

    private var createStationButton: some View {
        Button {
            onCreateStationTap()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.6, green: 0.2, blue: 0.8),
                                Color(red: 0.9, green: 0.3, blue: 0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .shadow(color: Color(red: 0.6, green: 0.2, blue: 0.8).opacity(0.4), radius: 8, x: 0, y: 2)

                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack {
            Spacer()

            BottomNavigationBar(
                selectedTab: .constant(.home),
                onCreateStationTap: { print("Create station tapped") }
            )
            .background(.ultraThinMaterial)
        }
    }
}
