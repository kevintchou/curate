// Swift example for calling the Gradio LLM API from iOS
// Add this to your iOS project

import Foundation

// MARK: - Data Models

struct ChatRequest: Codable {
    let data: [ChatRequestData]

    enum ChatRequestData: Codable {
        case string(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Data type not supported"
            )
        }
    }
}

struct ChatResponse: Codable {
    let data: String
    let duration: Double?
}

// MARK: - API Service

class LLMAPIService {
    static let shared = LLMAPIService()

    // Replace with your actual Hugging Face Space URL
    private let baseURL = "https://kevintchou-llm-ui-gradio.hf.space"

    enum Model: String {
        case llama32_3B = "meta-llama/Llama-3.2-3B-Instruct"
        case llama31_8B = "meta-llama/Llama-3.1-8B-Instruct"
        case mistral7B = "mistralai/Mistral-7B-Instruct-v0.3"
        case qwen25_7B = "Qwen/Qwen2.5-7B-Instruct"
    }

    private init() {}

    // MARK: - Main API Call

    func chat(
        message: String,
        model: Model = .llama32_3B,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: "\(baseURL)/gradio_api/call/chat") else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Create request body
        let requestBody = ChatRequest(data: [
            .string(message),
            .string(model.rawValue)
        ])

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            completion(.failure(error))
            return
        }

        // Make the request
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data received", code: -1)))
                return
            }

            do {
                let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
                completion(.success(chatResponse.data))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Async/Await Version (iOS 13+)

    @available(iOS 13.0.0, *)
    func chat(message: String, model: Model = .llama32_3B) async throws -> String {
        guard let url = URL(string: "\(baseURL)/gradio_api/call/chat") else {
            throw NSError(domain: "Invalid URL", code: -1)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = ChatRequest(data: [
            .string(message),
            .string(model.rawValue)
        ])

        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)
        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)

        return chatResponse.data
    }
}

// MARK: - Conversation Manager (for maintaining history)

class ConversationManager {
    struct Message {
        let role: String  // "user" or "assistant"
        let content: String
    }

    private var history: [Message] = []
    private let apiService = LLMAPIService.shared

    func sendMessage(
        _ message: String,
        model: LLMAPIService.Model = .llama32_3B,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Build context from history
        var contextMessage = message

        if !history.isEmpty {
            var contextParts: [String] = []

            // Add last 5 exchanges (10 messages) for context
            let recentHistory = Array(history.suffix(10))

            for msg in recentHistory {
                let role = msg.role == "user" ? "User" : "Assistant"
                contextParts.append("\(role): \(msg.content)")
            }

            contextParts.append("User: \(message)")
            contextMessage = contextParts.joined(separator: "\n")
        }

        // Call API with context
        apiService.chat(message: contextMessage, model: model) { [weak self] result in
            switch result {
            case .success(let response):
                // Update history
                self?.history.append(Message(role: "user", content: message))
                self?.history.append(Message(role: "assistant", content: response))
                completion(.success(response))

            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    @available(iOS 13.0.0, *)
    func sendMessage(_ message: String, model: LLMAPIService.Model = .llama32_3B) async throws -> String {
        // Build context from history
        var contextMessage = message

        if !history.isEmpty {
            var contextParts: [String] = []
            let recentHistory = Array(history.suffix(10))

            for msg in recentHistory {
                let role = msg.role == "user" ? "User" : "Assistant"
                contextParts.append("\(role): \(msg.content)")
            }

            contextParts.append("User: \(message)")
            contextMessage = contextParts.joined(separator: "\n")
        }

        let response = try await apiService.chat(message: contextMessage, model: model)

        // Update history
        history.append(Message(role: "user", content: message))
        history.append(Message(role: "assistant", content: response))

        return response
    }

    func clearHistory() {
        history.removeAll()
    }

    func getHistory() -> [Message] {
        return history
    }
}

// MARK: - Usage Examples

// Example 1: Simple callback-based usage
func exampleCallbackUsage() {
    LLMAPIService.shared.chat(message: "What is Swift?") { result in
        switch result {
        case .success(let response):
            print("Bot response: \(response)")
        case .failure(let error):
            print("Error: \(error.localizedDescription)")
        }
    }
}

// Example 2: Async/await usage (iOS 13+)
@available(iOS 13.0.0, *)
func exampleAsyncUsage() async {
    do {
        let response = try await LLMAPIService.shared.chat(
            message: "Explain SwiftUI in simple terms",
            model: .llama32_3B
        )
        print("Bot response: \(response)")
    } catch {
        print("Error: \(error.localizedDescription)")
    }
}

// Example 3: Using ConversationManager
func exampleConversationUsage() {
    let conversation = ConversationManager()

    // First message
    conversation.sendMessage("My name is Kevin and I'm learning iOS development") { result in
        if case .success(let response) = result {
            print("Bot: \(response)")

            // Follow-up message (context will be included automatically)
            conversation.sendMessage("What should I learn first?") { result in
                if case .success(let response) = result {
                    print("Bot: \(response)")
                }
            }
        }
    }
}

// Example 4: Different models
func exampleDifferentModels() {
    LLMAPIService.shared.chat(
        message: "Write a haiku about coding",
        model: .mistral7B  // Try different models
    ) { result in
        if case .success(let response) = result {
            print(response)
        }
    }
}
