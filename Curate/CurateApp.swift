//
//  CurateApp.swift
//  Curate
//
//  Created by Kevin Chou on 11/18/25.
//

import SwiftUI
import SwiftData

@main
struct CurateApp: App {
    @StateObject private var authManager = AuthManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
            Station.self,
            Feedback.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            CurateView()
                .withLLMServiceProvider()
                .environmentObject(authManager)
        }
        .modelContainer(sharedModelContainer)
    }
}
