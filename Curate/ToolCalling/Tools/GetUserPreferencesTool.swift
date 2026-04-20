//
//  GetUserPreferencesTool.swift
//  Curate
//
//  Reads stored user preferences (genres, temperature, etc.).
//  Lets the LLM factor in user settings before making decisions.
//

import Foundation

final class GetUserPreferencesTool: MusicTool {
    let name = "get_user_preferences"
    let description = """
        Get the user's stored music preferences — preferred genres, \
        exploration temperature (0=familiar, 1=adventurous), and any \
        other saved settings. Use this to personalize your track selection.
        """

    let parameters = ToolParameterSchema(
        properties: [:],
        required: []
    )

    func execute(arguments: Data) async throws -> ToolResult {
        let prefs = UserPreferences.loadFromStorage()

        return .encode(UserPreferencesResult(
            preferredGenres: prefs.preferredGenres,
            nonPreferredGenres: prefs.nonPreferredGenres,
            temperature: prefs.temperature,
            temperatureLabel: temperatureLabel(prefs.temperature)
        ))
    }

    private func temperatureLabel(_ t: Double) -> String {
        switch t {
        case 0..<0.3: return "conservative"
        case 0.3..<0.7: return "balanced"
        default: return "adventurous"
        }
    }
}

struct UserPreferencesResult: Codable {
    let preferredGenres: [String]
    let nonPreferredGenres: [String]
    let temperature: Double
    let temperatureLabel: String
}
