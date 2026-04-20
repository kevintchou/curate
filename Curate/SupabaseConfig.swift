//
//  SupabaseConfig.swift
//  Curate
//
//  Created by Kevin Chou on 12/11/25.
//

import Foundation
import Supabase

// MARK: - Supabase Setup Instructions
/*
 To set up Supabase in your Xcode project:
 
 1. Add the Supabase Swift SDK via Swift Package Manager:
    - In Xcode, go to File > Add Package Dependencies
    - Enter: https://github.com/supabase-community/supabase-swift
    - Select version 2.0.0 or later
    - Add the "Supabase" product to your target
 
 2. Fill in your Supabase credentials below:
    - Go to your Supabase project dashboard
    - Navigate to Settings > API
    - Copy the "Project URL" and "anon public" key
 
 3. (Optional) For Row Level Security, you'll need to set up auth later
*/

enum SupabaseConfig {
    // MARK: - Replace these with your actual Supabase credentials
    static let projectURL = "https://yaykqmambliikwqirenx.supabase.co"  // e.g., "https://xxxxx.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlheWtxbWFtYmxpaWt3cWlyZW54Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjUzMTk3MzgsImV4cCI6MjA4MDg5NTczOH0._eT4xUmDt7xT3ygo1R7S3x90HbtHP3mXx5Gpno6MTb4"        // The anon/public key
    
    // MARK: - Supabase Client
    static let client: SupabaseClient = {
        guard !projectURL.isEmpty && !anonKey.isEmpty else {
            fatalError("Please configure your Supabase credentials in SupabaseConfig.swift")
        }
        
        return SupabaseClient(
            supabaseURL: URL(string: projectURL)!,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    // Opt-in to new behavior to silence deprecation warning
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }()
}
