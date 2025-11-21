//
//  MainTabView.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView()
                .tabItem {
                    Image(systemName: "music.note.house.fill")
                    Text("Discover")
                }
                .tag(0)
            
            SearchView()
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .tag(1)
            
            PlaylistsView()
                .tabItem {
                    Image(systemName: "music.note.list")
                    Text("Playlists")
                }
                .tag(2)
            
            TestAMLoginView()
                .tabItem {
                    Image(systemName: "testtube.2")
                    Text("Test AM Login")
                }
                .tag(3)
            
            TestSpotifyLoginView()
                .tabItem {
                    Image(systemName: "testtube.2")
                    Text("Test Spotify Login")
                }
                .tag(4)
        }
        .tint(.blue)
    }
}

#Preview {
    MainTabView()
}
