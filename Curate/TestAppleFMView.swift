//
//  TestAppleFMView.swift
//  Curate
//
//  Created by Kevin Chou on 12/13/25.
//

import SwiftUI
import FoundationModels

struct TestAppleFMView: View {
    // Reference to the system language model
    private let model = SystemLanguageModel.default
    
    // State for user input
    @State private var userInput: String = ""
    
    // State for the model's response
    @State private var response: String = ""
    
    // State for loading indicator
    @State private var isLoading: Bool = false
    
    // State for error messages
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Model availability status
                statusView
                
                // Input area
                inputSection
                
                // Response area
                responseSection
                
                Spacer()
            }
            .padding()
            .navigationTitle("Foundation Models Test")
        }
    }
    
    // MARK: - Status View
    
    @ViewBuilder
    private var statusView: some View {
        switch model.availability {
        case .available:
            Label("Model Available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
        case .unavailable(.deviceNotEligible):
            Label("Device not eligible for Apple Intelligence", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
        case .unavailable(.appleIntelligenceNotEnabled):
            Label("Please enable Apple Intelligence in Settings", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
        case .unavailable(.modelNotReady):
            Label("Model is downloading or not ready", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .font(.subheadline)
        case .unavailable(let other):
            Label("Model unavailable: \(String(describing: other))", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.subheadline)
        }
    }
    
    // MARK: - Input Section
    
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Prompt")
                .font(.headline)
            
            TextField("Ask anything...", text: $userInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            
            Button(action: generateResponse) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Generate Response")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(userInput.isEmpty || isLoading || model.availability != .available)
        }
    }
    
    // MARK: - Response Section
    
    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Response")
                .font(.headline)
            
            ScrollView {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if response.isEmpty {
                    Text("Your response will appear here...")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(response)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Generate Response
    
    private func generateResponse() {
        guard model.availability == .available else {
            errorMessage = "Model is not available"
            return
        }
        
        isLoading = true
        errorMessage = nil
        response = ""
        
        Task {
            do {
                // Create a new session
                let session = LanguageModelSession()
                
                // Generate response from the model
                let modelResponse = try await session.respond(to: userInput)
                
                // Update the UI with the response
                await MainActor.run {
                    response = modelResponse.content
                    isLoading = false
                }
            } catch {
                // Handle errors
                await MainActor.run {
                    errorMessage = "Error: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    TestAppleFMView()
}
