//
//  DynamicBackground.swift
//  Curate
//
//  Dynamic gradient background that extracts colors from album artwork
//

import SwiftUI
import MusicKit
import Combine

// MARK: - Album Art Color Extractor

@MainActor
class AlbumArtColorExtractor: ObservableObject {
    @Published var dominantColor: Color = Color(red: 0.55, green: 0.34, blue: 0.56) // Default pink/purple
    @Published var secondaryColor: Color = Color(red: 0.08, green: 0.04, blue: 0.1) // Dark purple-black
    @Published var isExtracting: Bool = false

    private var currentArtworkURL: URL?

    func extractColors(from artwork: Artwork?, size: CGSize = CGSize(width: 100, height: 100)) async {
        guard let artwork = artwork,
              let url = artwork.url(width: Int(size.width), height: Int(size.height)) else {
            // Reset to default colors if no artwork
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.dominantColor = Color(red: 0.55, green: 0.34, blue: 0.56)
                    self.secondaryColor = Color(red: 0.08, green: 0.04, blue: 0.1)
                }
            }
            return
        }

        // Skip if we're already processing this artwork
        if currentArtworkURL == url { return }
        currentArtworkURL = url

        await MainActor.run {
            self.isExtracting = true
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let uiImage = UIImage(data: data),
                  let cgImage = uiImage.cgImage else {
                await MainActor.run {
                    self.isExtracting = false
                }
                return
            }

            // Extract dominant colors
            let colors = extractDominantColors(from: cgImage)

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.8)) {
                    self.dominantColor = colors.dominant
                    self.secondaryColor = colors.secondary
                    self.isExtracting = false
                }
            }
        } catch {
            await MainActor.run {
                self.isExtracting = false
            }
        }
    }

    private func extractDominantColors(from cgImage: CGImage) -> (dominant: Color, secondary: Color) {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (Color(red: 0.3, green: 0.1, blue: 0.4), Color.black)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sample colors from upper portion of image (usually where important album art details are)
        var colorCounts: [String: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]

        let sampleHeight = height / 2 // Focus on upper half
        let step = max(1, min(width, sampleHeight) / 20) // Sample every Nth pixel

        for y in stride(from: 0, to: sampleHeight, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = (y * width + x) * bytesPerPixel

                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0

                // Skip very dark or very light colors
                let brightness = (r + g + b) / 3
                if brightness < 0.1 || brightness > 0.9 { continue }

                // Quantize colors to reduce similar shades
                let qR = Int(r * 8) // 8 levels per channel
                let qG = Int(g * 8)
                let qB = Int(b * 8)
                let key = "\(qR),\(qG),\(qB)"

                if var existing = colorCounts[key] {
                    existing.count += 1
                    existing.r += r
                    existing.g += g
                    existing.b += b
                    colorCounts[key] = existing
                } else {
                    colorCounts[key] = (1, r, g, b)
                }
            }
        }

        // Sort by count and get top colors
        let sortedColors = colorCounts.values.sorted { $0.count > $1.count }

        guard let topColor = sortedColors.first else {
            return (Color(red: 0.55, green: 0.34, blue: 0.56), Color(red: 0.08, green: 0.04, blue: 0.1))
        }

        // Average the color values
        let avgR = topColor.r / CGFloat(topColor.count)
        let avgG = topColor.g / CGFloat(topColor.count)
        let avgB = topColor.b / CGFloat(topColor.count)

        // Create dominant color (slightly saturated and dimmed for background use)
        let dominant = Color(
            red: min(avgR * 0.7, 0.6),
            green: min(avgG * 0.7, 0.5),
            blue: min(avgB * 0.7, 0.7)
        )

        // Secondary is a darker version for gradient bottom
        let secondary = Color(
            red: avgR * 0.15,
            green: avgG * 0.1,
            blue: avgB * 0.2
        )

        return (dominant, secondary)
    }

    func reset() {
        currentArtworkURL = nil
        withAnimation(.easeInOut(duration: 0.5)) {
            dominantColor = Color(red: 0.55, green: 0.34, blue: 0.56)
            secondaryColor = Color(red: 0.08, green: 0.04, blue: 0.1)
        }
    }
}

// MARK: - Dynamic Gradient Background View

struct DynamicGradientBackground: View {
    let dominantColor: Color
    let secondaryColor: Color
    var blurRadius: CGFloat = 100
    var showGlow: Bool = true
    var useDefaultStyle: Bool = false // When true, uses the concept-style horizontal gradient

    // Default colors from ui-concept.png
    private let defaultPink = Color(red: 0.56, green: 0.35, blue: 0.52)   // Left (pink): R:144, G:89, B:133
    private let defaultMiddle = Color(red: 0.55, green: 0.34, blue: 0.59) // Middle: R:141, G:88, B:150
    private let defaultPurple = Color(red: 0.39, green: 0.26, blue: 0.45) // Right (purple): R:99, G:66, B:116
    private let darkPurple = Color(red: 0.12, green: 0.08, blue: 0.15)    // Subtle dark purple at bottom

    var body: some View {
        ZStack {
            // Base black
            Color.black

            // Layer 1: Horizontal pink-to-purple gradient at top
            LinearGradient(
                colors: [
                    useDefaultStyle ? defaultPink : dominantColor,
                    useDefaultStyle ? defaultMiddle : dominantColor.opacity(0.9),
                    useDefaultStyle ? defaultPurple : secondaryColor.opacity(0.7)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()

            // Layer 2: Vertical fade from clear (top) to black (bottom)
            // This creates a smooth transition from the horizontal gradient to black
            LinearGradient(
                stops: [
                    .init(color: Color.clear, location: 0.0),
                    .init(color: Color.clear, location: 0.25),
                    .init(color: Color.black.opacity(0.3), location: 0.35),
                    .init(color: Color.black.opacity(0.6), location: 0.45),
                    .init(color: Color.black.opacity(0.85), location: 0.55),
                    .init(color: Color.black, location: 0.65),
                    .init(color: Color.black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Layer 3: Subtle dark purple glow at bottom
            VStack {
                Spacer()
                LinearGradient(
                    colors: [
                        Color.clear,
                        darkPurple.opacity(0.25)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: UIScreen.main.bounds.height * 0.2)
            }
            .ignoresSafeArea()

            // Optional glow effect for dynamic backgrounds (when music is playing)
            if showGlow && !useDefaultStyle {
                RadialGradient(
                    colors: [
                        dominantColor.opacity(0.4),
                        dominantColor.opacity(0.15),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: 350
                )
                .blur(radius: blurRadius)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Dynamic Background Modifier

struct DynamicBackgroundModifier: ViewModifier {
    @ObservedObject var colorExtractor: AlbumArtColorExtractor
    var blurRadius: CGFloat = 100
    var showGlow: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                DynamicGradientBackground(
                    dominantColor: colorExtractor.dominantColor,
                    secondaryColor: colorExtractor.secondaryColor,
                    blurRadius: blurRadius,
                    showGlow: showGlow
                )
            }
    }
}

extension View {
    func dynamicBackground(
        colorExtractor: AlbumArtColorExtractor,
        blurRadius: CGFloat = 100,
        showGlow: Bool = true
    ) -> some View {
        modifier(DynamicBackgroundModifier(
            colorExtractor: colorExtractor,
            blurRadius: blurRadius,
            showGlow: showGlow
        ))
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        DynamicGradientBackground(
            dominantColor: Color(red: 0.5, green: 0.2, blue: 0.6), // Purple from the concept
            secondaryColor: Color(red: 0.1, green: 0.05, blue: 0.15),
            blurRadius: 100,
            showGlow: true
        )

        VStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.1))
                .frame(width: 200, height: 200)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.white.opacity(0.5))
                )

            Text("Now Playing")
                .font(.title)
                .foregroundStyle(.white)
        }
    }
}
