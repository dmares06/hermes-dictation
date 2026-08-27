import Foundation

/// Talks to the Hermes backend for things that need a server-held secret.
///
/// Authenticates with the same client token as the Realtime session; the
/// Google credentials never leave the server.
struct HermesBackendClient {
    enum Mode: String {
        case send
        case draft
    }

    struct Delivery: Decodable {
        let ok: Bool
        let id: String?
        let mode: String
    }

    struct Health: Decodable {
        let configured: Bool
        let gmail: Bool
    }

    enum ClientError: LocalizedError {
        case missingClientToken
        case rejected(code: String, status: Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingClientToken:
                "The app was built without a backend client token."
            case .rejected(let code, _):
                switch code {
                case "gmail_not_configured": "Gmail isn't connected on the Hermes backend yet."
                case "unauthorized": "The backend rejected this app's token."
                case "invalid_recipient": "That email address doesn't look right."
                case "send_failed", "draft_failed": "Gmail refused the message."
                case "search_failed": "The web search didn't come back."
                case "invalid_query", "query_too_long": "That search request wasn't valid."
                case "token_refresh_failed": "The Gmail connection expired; reconnect it on the backend."
                default: "The backend couldn't send the email (\(code))."
                }
            case .invalidResponse:
                "The backend returned something unexpected."
            }
        }
    }

    static let baseURL = URL(string: "https://whisperdict-realtime.vercel.app")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func health() async -> Health? {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/health"))
        request.timeoutInterval = 10
        guard let (data, _) = try? await session.data(for: request) else { return nil }
        return try? JSONDecoder().decode(Health.self, from: data)
    }

    struct SearchResult: Decodable {
        struct Source: Decodable {
            let title: String
            let url: String
        }
        let ok: Bool
        let answer: String
        let sources: [Source]
    }

    /// Runs a web search on the backend, which holds the OpenAI key.
    func search(_ query: String) async throws -> SearchResult {
        let token = try clientToken()
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/search"))
        request.httpMethod = "POST"
        // Long enough for a real search, short enough that the conversation
        // does not stall silently while Hermes waits.
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "http_\(http.statusCode)"
            throw ClientError.rejected(code: code, status: http.statusCode)
        }
        guard let result = try? JSONDecoder().decode(SearchResult.self, from: data), result.ok else {
            throw ClientError.invalidResponse
        }
        return result
    }

    func sendEmail(_ draft: EmailDraft, mode: Mode = .send) async throws -> Delivery {
        let token = try clientToken()
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/gmail-send"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "to": draft.recipient,
            "subject": draft.subject,
            "body": draft.body,
            "mode": mode.rawValue,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "http_\(http.statusCode)"
            throw ClientError.rejected(code: code, status: http.statusCode)
        }
        guard let delivery = try? JSONDecoder().decode(Delivery.self, from: data), delivery.ok else {
            throw ClientError.invalidResponse
        }
        return delivery
    }

    private func clientToken() throws -> String {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "WhisperDictRealtimeClientToken") as? String,
              !token.isEmpty,
              !token.contains("$(")
        else { throw ClientError.missingClientToken }
        return token
    }
}
