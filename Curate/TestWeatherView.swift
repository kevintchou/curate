//
//  TestWeatherView.swift
//  Curate
//
//  Created by Kevin Chou on 1/25/26.
//

import SwiftUI
import WeatherKit
import CoreLocation
import Combine

struct TestWeatherView: View {
    @State private var weather: Weather?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var locationName: String?
    @StateObject private var locationManager = WeatherLocationManager()

    private let weatherService = WeatherService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Show location permission status if not authorized
                    if locationManager.authorizationStatus == .denied {
                        locationDeniedView
                    } else if locationManager.authorizationStatus == .notDetermined {
                        requestLocationView
                    } else if isLoading {
                        ProgressView("Fetching weather...")
                            .padding()
                    } else if let error = errorMessage {
                        errorView(error)
                    } else if let weather = weather {
                        weatherContent(weather)
                    } else {
                        initialView
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Weather Test")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Check current authorization status on appear
                locationManager.checkAuthorizationStatus()
            }
        }
    }

    // MARK: - Location Permission Views

    @ViewBuilder
    private var requestLocationView: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.circle")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Location Access Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("To show weather for your current location, please allow location access.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Enable Location") {
                locationManager.requestPermission()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private var locationDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.slash")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Location Access Denied")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Location access was denied. Please enable it in Settings to see weather for your location.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private var initialView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.sun")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Tap to fetch weather")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Get Weather") {
                Task {
                    await fetchWeather()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(error)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await fetchWeather()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    @ViewBuilder
    private func weatherContent(_ weather: Weather) -> some View {
        VStack(spacing: 20) {
            // Location name
            if let name = locationName {
                Text(name)
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            // Current conditions
            VStack(spacing: 8) {
                Image(systemName: weather.currentWeather.symbolName)
                    .font(.system(size: 80))
                    .symbolRenderingMode(.multicolor)

                Text(weather.currentWeather.condition.description)
                    .font(.title2)
                    .fontWeight(.medium)

                Text("\(Int(weather.currentWeather.temperature.converted(to: .fahrenheit).value.rounded()))°F")
                    .font(.system(size: 60, weight: .thin))
            }

            // Additional details
            VStack(spacing: 12) {
                WeatherDetailRow(
                    icon: "thermometer",
                    label: "Feels Like",
                    value: "\(Int(weather.currentWeather.apparentTemperature.converted(to: .fahrenheit).value.rounded()))°F"
                )

                WeatherDetailRow(
                    icon: "humidity",
                    label: "Humidity",
                    value: "\(Int(weather.currentWeather.humidity * 100))%"
                )

                WeatherDetailRow(
                    icon: "wind",
                    label: "Wind",
                    value: "\(Int(weather.currentWeather.wind.speed.converted(to: .milesPerHour).value.rounded())) mph"
                )

                WeatherDetailRow(
                    icon: "eye",
                    label: "Visibility",
                    value: "\(Int(weather.currentWeather.visibility.converted(to: .miles).value.rounded())) mi"
                )

                WeatherDetailRow(
                    icon: "gauge",
                    label: "Pressure",
                    value: "\(String(format: "%.2f", weather.currentWeather.pressure.converted(to: .inchesOfMercury).value)) inHg"
                )

                WeatherDetailRow(
                    icon: "sun.max",
                    label: "UV Index",
                    value: "\(weather.currentWeather.uvIndex.value)"
                )
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)

            // Location coordinates
            if let location = locationManager.location {
                Text("Coordinates: \(String(format: "%.4f", location.coordinate.latitude)), \(String(format: "%.4f", location.coordinate.longitude))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Refresh button
            Button {
                Task {
                    await fetchWeather()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private func fetchWeather() async {
        isLoading = true
        errorMessage = nil

        // Wait for location with better handling
        let location = await waitForLocation()

        guard let location = location else {
            await MainActor.run {
                errorMessage = "Unable to get your location. Please check location permissions."
                isLoading = false
            }
            return
        }

        // Reverse geocode to get location name
        await reverseGeocode(location)

        // Fetch weather
        await fetchWeatherForLocation(location)
    }

    private func waitForLocation() async -> CLLocation? {
        // If we already have a location, use it
        if let location = locationManager.location {
            return location
        }

        // Request permission and location
        await MainActor.run {
            locationManager.requestPermission()
        }

        // Wait up to 10 seconds for location
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if let location = locationManager.location {
                return location
            }
        }

        return nil
    }

    private func reverseGeocode(_ location: CLLocation) async {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                await MainActor.run {
                    if let city = placemark.locality, let state = placemark.administrativeArea {
                        locationName = "\(city), \(state)"
                    } else if let city = placemark.locality {
                        locationName = city
                    } else if let name = placemark.name {
                        locationName = name
                    }
                }
            }
        } catch {
            print("Reverse geocoding error: \(error.localizedDescription)")
        }
    }

    private func fetchWeatherForLocation(_ location: CLLocation) async {
        do {
            let weather = try await weatherService.weather(for: location)
            await MainActor.run {
                self.weather = weather
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to fetch weather: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

// MARK: - Weather Detail Row

struct WeatherDetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.blue)
                .frame(width: 24)

            Text(label)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Location Manager

@MainActor
class WeatherLocationManager: NSObject, ObservableObject {
    @Published var location: CLLocation?
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    func checkAuthorizationStatus() {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func requestPermission() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

extension WeatherLocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.location = locations.first
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if self.authorizationStatus == .authorizedWhenInUse || self.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}

#Preview {
    TestWeatherView()
}
