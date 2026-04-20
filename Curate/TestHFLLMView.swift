//
//  TestHFLLMView.swift
//  Curate
//
//  Created by Kevin Chou on 12/13/25.
//

import SwiftUI

// MARK: - SSE Stream Handler
class SSEStreamHandler: NSObject, URLSessionDataDelegate {
    var onDataReceived: ((String) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((Error) -> Void)?
    
    private var receivedData = Data()
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        
        if let string = String(data: data, encoding: .utf8) {
            print("Received chunk: \(string)")
            onDataReceived?(string)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onError?(error)
        } else {
            onComplete?()
        }
    }
}

struct TestHFLLMView: View {
    @State private var isLoading = false
    @State private var prompt = "What is Swift programming language?"
    @State private var response = ""
    @State private var statusMessage = "Press 'Test Connection' to begin"
    @State private var hasConnected = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("Hugging Face LLM Connection Test")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.bottom, 10)
                
                // Status indicator
                HStack {
                    Circle()
                        .fill(hasConnected ? Color.green : Color.gray)
                        .frame(width: 12, height: 12)
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                
                // Model info
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Llama 3.2 3B Instruct")
                        .font(.body)
                        .fontWeight(.medium)
                }
                
                // Test button
                Button(action: testConnection) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .tint(.white)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(isLoading ? "Testing Connection..." : "Test Connection")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isLoading ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isLoading)
                
                Divider()
                
                // Prompt section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    if !prompt.isEmpty {
                        Text(prompt)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                
                // Response section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Response")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    if response.isEmpty {
                        Text("No response yet")
                            .foregroundColor(.secondary)
                            .italic()
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                    } else {
                        ScrollView {
                            Text(response)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .frame(maxHeight: 300)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("LLM API Test")
    }
    
    private func testConnection() {
        isLoading = true
        statusMessage = "Connecting to Hugging Face API..."
        response = ""
        hasConnected = false
        
        // Log to console
        print("=== Starting LLM API Connection Test ===")
        print("Prompt: \(prompt)")
        print("Model: Llama 3.2 3B Instruct (meta-llama/Llama-3.2-3B-Instruct)")
        
        Task {
            do {
                let baseURL = "https://kevintchou-llm-ui-gradio.hf.space"
                
                // Step 1: Call the /gradio_api/call/chat endpoint to initiate the request
                guard let callURL = URL(string: "\(baseURL)/gradio_api/call/chat") else {
                    throw NSError(domain: "Invalid URL", code: -1)
                }
                
                print("API Call URL: \(callURL.absoluteString)")
                
                var callRequest = URLRequest(url: callURL)
                callRequest.httpMethod = "POST"
                callRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                
                // Create request with both message and model
                let requestDict: [String: Any] = [
                    "data": [prompt, "meta-llama/Llama-3.2-3B-Instruct"]
                ]
                
                callRequest.httpBody = try JSONSerialization.data(withJSONObject: requestDict)
                
                // Log request
                if let bodyString = String(data: callRequest.httpBody!, encoding: .utf8) {
                    print("Request body: \(bodyString)")
                }
                
                let (callData, callResponse) = try await URLSession.shared.data(for: callRequest)
                
                // Log response
                if let httpResponse = callResponse as? HTTPURLResponse {
                    print("Call HTTP Status: \(httpResponse.statusCode)")
                    
                    guard httpResponse.statusCode == 200 else {
                        throw NSError(domain: "HTTP Error: \(httpResponse.statusCode)", code: httpResponse.statusCode)
                    }
                }
                
                if let callResponseString = String(data: callData, encoding: .utf8) {
                    print("Call response: \(callResponseString)")
                }
                
                // Parse the event_id from the response
                struct CallResponse: Codable {
                    let event_id: String
                }
                
                let decoder = JSONDecoder()
                let eventResponse = try decoder.decode(CallResponse.self, from: callData)
                let eventId = eventResponse.event_id
                
                print("Event ID received: \(eventId)")
                
                // Update status
                await MainActor.run {
                    statusMessage = "Waiting for model response..."
                }
                
                // Step 2: Stream the result endpoint with SSE handling
                guard let resultURL = URL(string: "\(baseURL)/gradio_api/call/chat/\(eventId)") else {
                    throw NSError(domain: "Invalid result URL", code: -1)
                }
                
                print("Streaming from result URL: \(resultURL.absoluteString)")
                
                // Use async/await with bytes stream
                var resultRequest = URLRequest(url: resultURL)
                resultRequest.httpMethod = "GET"
                resultRequest.timeoutInterval = 120
                
                let (asyncBytes, urlResponse) = try await URLSession.shared.bytes(for: resultRequest)
                
                if let httpResponse = urlResponse as? HTTPURLResponse {
                    print("Stream HTTP Status: \(httpResponse.statusCode)")
                }
                
                var accumulatedData = ""
                var finalResult = ""
                var foundResult = false
                
                // Process the stream line by line
                for try await line in asyncBytes.lines {
                    print("SSE Line: \(line)")
                    
                    if line.hasPrefix("event: ") {
                        let eventType = String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                        print("Event type: \(eventType)")
                        
                        if eventType == "error" {
                            print("Received error event")
                        } else if eventType == "complete" {
                            print("Received complete event")
                        }
                    }
                    
                    if line.hasPrefix("data: ") {
                        let dataString = String(line.dropFirst(6))
                        
                        if dataString == "null" || dataString.isEmpty {
                            continue
                        }
                        
                        print("Data: \(dataString)")
                        
                        // Try to parse as JSON
                        if let jsonData = dataString.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                            
                            print("Parsed JSON: \(json)")
                            
                            // Check for different message types
                            if let msg = json["msg"] as? String {
                                print("Message type: \(msg)")
                                
                                if msg == "process_starts" {
                                    await MainActor.run {
                                        statusMessage = "Model is processing..."
                                    }
                                } else if msg == "process_generating" {
                                    await MainActor.run {
                                        statusMessage = "Model is generating response..."
                                    }
                                } else if msg == "process_completed" {
                                    // Extract the result
                                    if let output = json["output"] as? [String: Any],
                                       let data = output["data"] as? [Any],
                                       let responseText = data.first as? String {
                                        finalResult = responseText
                                        foundResult = true
                                        print("Found result: \(responseText)")
                                        break
                                    }
                                }
                            }
                            
                            // Also check for direct data array
                            if let dataArray = json["data"] as? [Any],
                               let responseText = dataArray.first as? String {
                                finalResult = responseText
                                foundResult = true
                                print("Found result in data array: \(responseText)")
                                break
                            }
                        }
                    }
                }
                
                if !foundResult || finalResult.isEmpty {
                    throw NSError(
                        domain: "No result found in SSE stream. Check console for full stream output.",
                        code: -1
                    )
                }
                
                await MainActor.run {
                    response = finalResult
                    hasConnected = true
                    statusMessage = "✓ Connection successful!"
                    isLoading = false
                    
                    // Log to console
                    print("\n=== Connection Successful ===")
                    print("Prompt: \(prompt)")
                    print("Response: \(finalResult)")
                    print("Status: Connection successful!")
                    print("================================\n")
                }
            } catch let decodingError as DecodingError {
                await MainActor.run {
                    let errorMessage: String
                    switch decodingError {
                    case .dataCorrupted(let context):
                        errorMessage = "Data corrupted: \(context.debugDescription)"
                    case .keyNotFound(let key, let context):
                        errorMessage = "Key '\(key.stringValue)' not found: \(context.debugDescription)"
                    case .typeMismatch(let type, let context):
                        errorMessage = "Type mismatch for \(type): \(context.debugDescription)"
                    case .valueNotFound(let type, let context):
                        errorMessage = "Value not found for \(type): \(context.debugDescription)"
                    @unknown default:
                        errorMessage = "Decoding error: \(decodingError.localizedDescription)"
                    }
                    
                    response = "Decoding Error: \(errorMessage)"
                    hasConnected = false
                    statusMessage = "✗ Connection failed"
                    isLoading = false
                    
                    print("\n=== Decoding Error ===")
                    print(errorMessage)
                    print("=====================\n")
                }
            } catch {
                await MainActor.run {
                    response = "Error: \(error.localizedDescription)"
                    hasConnected = false
                    statusMessage = "✗ Connection failed"
                    isLoading = false
                    
                    // Log error to console
                    print("\n=== Connection Failed ===")
                    print("Prompt: \(prompt)")
                    print("Error: \(error.localizedDescription)")
                    print("Full error: \(error)")
                    print("========================\n")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        TestHFLLMView()
    }
}

