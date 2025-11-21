# Curate

Curate is an iOS music discovery app that helps you find and play music based on various categories like song, artist, genre, decade, activity, or mood.

## Features

### 🎵 Music Search & Discovery
- **Real-time search**: Search for songs as you type with instant results
- **Multiple curation categories**: Find music by:
  - Song
  - Artist
  - Genre
  - Decade
  - Activity
  - Mood
- **Visual feedback**: Album artwork display with song and artist information
- **Quick selection**: Tap to select songs or press enter to select the first result

### 🎼 Music Playback
- Integrated with Apple Music via MusicKit
- Direct playback of selected songs
- System music player integration
- Real-time playback status updates

### 🎨 Modern UI/UX
- Clean, intuitive interface with SwiftUI
- Search results with album artwork
- Visual selection indicators (checkmarks)
- Bottom-anchored search control panel
- Dismiss keyboard by tapping outside
- Loading indicators during search

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+
- Active Apple Music subscription (for playback)

## Technologies Used

- **SwiftUI**: Modern declarative UI framework
- **MusicKit**: Apple Music integration for search and playback
- **Swift Concurrency**: Async/await for asynchronous operations
- **SwiftData**: Data persistence layer
- **Observation Framework**: Modern state management with `@Observable` macro

## Project Structure

```
Curate/
├── CurateApp.swift              # App entry point
├── CurateView.swift             # Main curation interface
├── CurateViewModel.swift        # Business logic and state management
├── SearchService.swift          # Music search functionality
├── SwipeableContainerView.swift # Container for swipeable navigation
├── Item.swift                   # Data models
└── ...
```

## Setup

1. Clone the repository
2. Open `Curate.xcodeproj` in Xcode
3. Ensure you have an active Apple Developer account
4. Configure signing & capabilities:
   - Enable MusicKit capability
   - Add your development team
5. Build and run on a device or simulator

### MusicKit Configuration

This app requires MusicKit entitlements. Ensure the following capability is enabled in your project:

- **MusicKit** (com.apple.developer.music)

You'll also need to request user authorization for Apple Music access when first launching the app.

## Usage

1. **Launch the app** and grant Apple Music permissions when prompted
2. **Select a curation category** from the dropdown menu (Song, Artist, Genre, etc.)
3. **Type to search** for music in the text field
4. **Select a song** from the search results
5. **Tap the play button** to start playback

## Architecture

### MVVM Pattern
The app follows the Model-View-ViewModel (MVVM) architecture:

- **View** (`CurateView`): SwiftUI views that present the UI
- **ViewModel** (`CurateViewModel`): Business logic and state management using the `@Observable` macro
- **Service Layer** (`SearchService`): Handles MusicKit integration

### State Management
- Uses Swift's modern `@Observable` macro for reactive state updates
- `@State` and `@FocusState` for local view state
- MainActor-isolated view model for UI safety

## Key Components

### CurateView
The main view that displays:
- Search results list with album artwork
- Status messages and feedback
- Search input field with category selector
- Control buttons (placeholders for future features)
- Play button for selected songs

### CurateViewModel
Manages:
- Search query and results
- Song selection
- Playback through MusicKit
- Curation category selection
- Loading and status states

### SearchService
Handles:
- Real-time music search
- Debouncing search requests
- MusicKit API integration

## Future Enhancements

The UI includes placeholder buttons for upcoming features:
- ➕ **Add button**: Save songs to collections or playlists
- 🕐 **History button**: View recently played or searched songs
- 🎚️ **Controls button**: Advanced playback or filter options

## Privacy

This app requires access to Apple Music. Users must grant permission for the app to:
- Access their Apple Music library
- Search the Apple Music catalog
- Control music playback

No personal data is collected or stored outside of the device.

## Author

Created by Kevin Chou

## License

Copyright © 2025. All rights reserved.

---

**Note**: This app requires an active Apple Music subscription for full functionality. Some features may be limited without a subscription.
