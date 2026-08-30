import Foundation

/// Talks to a Hermes Agent gateway — the Nous Research agent runtime — over
/// its OpenAI-compatible `/v1/chat/completions` endpoint.
///
/// Hermes is the brain: its tools, memory, skills, and MCP servers all live on
/// the Mac running the gateway. This app is the voice. Each conversation is a
/// gateway session (`X-Hermes-Session-Id`), so the transcript accumulates in
/// Hermes's own session store and the phone only ever sends the newest turn;
/// a stable session key lets Hermes's long-term memory recognise the phone as
/// one channel across every conversation.
///
/// Why not `/v1/responses` with a named `conversation`: that chaining was
/// measured re-appending the whole history on every turn (904 messages, one
/// utterance repeated 64 times, after a few minutes), so every turn cost more
/// than the last. Session continuity keeps history linear.
struct HermesAgentClient {
    struct Configuration {
        let baseURL: URL
        let key: String
        /// Names the gateway session for one conversation.
        let conversation: String
        /// A model to ask for on this request only, or nil for the gateway's
        /// default. The API server honours a per-request `model`, which is
        /// how the phone gets a faster model for speech without changing
        /// what Hermes uses anywhere else.
        let model: String?
    }

    enum ClientError: LocalizedError {
        case missingKey
        case invalidServerURL(String)
        case rejected(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                "This build has no Hermes API key. Run ios_run.sh on the Mac that hosts Hermes."
            case .invalidServerURL(let value):
                "The Hermes server address \"\(value)\" is not a valid URL."
            case .rejected(let status, let message):
                switch status {
                case 401: "Hermes rejected this app's API key."
                case 404: "Hermes is running, but the API server is not enabled on it."
                default: "Hermes could not answer (\(status)): \(message)"
                }
            }
        }
    }

    /// The Mac mini on the tailnet, reached through `tailscale serve` so the
    /// connection has a real certificate and never leaves the tailnet.
    static let defaultServerURL = "https://dylans-mac-mini.tail86ac05.ts.net:8643"

    /// Stable across conversations: how Hermes's memory knows it is the phone.
    static let sessionKey = "whisperdict-iphone"

    /// Asked for on the phone's requests only (the gateway needs
    /// `platforms.api_server.extra.direct_model_requests: true`).
    ///
    /// Measured 2026-08-28 through the gateway. Gemini 3 Flash was fastest
    /// (2–4 s a call) but Google's API rejects Hermes's deferred-tool bridge
    /// (the tool result is named after the real tool, not the `tool_call`
    /// that invoked it → 400), so every MCP tool such as flights fell back to
    /// DeepSeek and looped. gpt-5-mini handles the bridge; with reasoning
    /// turned down it is 2–5 s a call instead of 6–12 s.
    static let defaultVoiceModel = "openai/gpt-5-mini"

    /// Sent as `model_options` for models whose reasoning can be dialled
    /// down. Only the gpt-5 family: for others "enabled" would switch
    /// thinking on rather than tone it down.
    static func modelOptions(for model: String) -> [String: Any]? {
        guard model.hasPrefix("openai/gpt-5") else { return nil }
        return ["reasoning": ["effort": "low"]]
    }

    /// What Hermes needs to know about the medium. The person hears the reply
    /// read aloud, and the phone can do a few things Hermes on a Mac cannot.
    static var instructions: String { instructions(now: Date()) }

    /// Dated so "this weekend" and "next weekend" resolve before a tool call:
    /// without it a Friday request for next weekend's flights was searched
    /// for the same day.
    static func instructions(now: Date, place: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let today = formatter.string(from: now)
        let zone = TimeZone.current.identifier
        let whereabouts = place.map {
            "The user is in \($0) right now: use that for anything local — \"here\", nearby places, the weather — " +
            "and as the default departure city and airport for travel. "
        } ?? ""
        return """
        Today is \(today) in the \(zone) time zone. "This weekend" means the coming Saturday and Sunday; \
        "next weekend" means the one after that. Work out exact dates before calling any tool. \
        \(whereabouts)\
        You are Hermes, and you are talking to the user through the WhisperDict app on their iPhone. \
        They speak; your reply is read aloud by a voice model. Answer in plain spoken sentences: \
        no markdown, no lists, no headings, no code, and no URLs except a picture's address as \
        described below. Lead with the answer and keep it to one \
        to three sentences unless they ask for detail. Greetings, small talk, and questions you can \
        answer from what you already know need no tools: answer straight away. Your tools are there \
        for anything that depends on current facts or on your memory, but they hear silence while a \
        tool runs, so prefer quick ones and never narrate what you are about to do: no "let me check", \
        no "one moment", no describing a search or a tool — your reply is the answer itself and \
        nothing else. Answer only the newest message. If it is garbled, a stray sound, or clearly \
        not a request, say in a few words that you didn't catch it; never guess at what was meant \
        and never answer with unrelated work, inboxes, or tasks they did not just ask about. \
        When they want something current — weather, flights, prices, news, hours — do one web search \
        and answer from its results; open a page only if the results truly lack the answer, and do not \
        look through skills, past sessions, or notes for these. Give the two or three best options in \
        two or three sentences and offer more. \
        When they ask to see, show, or look at a picture, photo, or image of something, or to make, \
        generate, draw, or imagine one, reply with one short sentence and one picture: put its address \
        on its own line as ![two or three words](https://...). The phone displays it and never reads \
        it aloud; never describe a picture instead of showing it. For a photo of a real thing — an \
        animal, food, plant, place, object, or public figure — fetch \
        https://en.wikipedia.org/api/rest_v1/page/summary/<Article_Title> with web_extract and use \
        the originalimage source address from it (thumbnail if there is no originalimage). If no \
        article fits, or they asked you to make, generate, draw, or imagine it, call image_generate \
        and use the address it returns. If image_generate fails, say in one sentence that making \
        pictures is not set up yet and offer a photo instead; never answer with links to pages. \
        For flights, use the flights tool: search your tools for search_flights and call it with IATA \
        codes and dates; never web search for flights, and never state a departure time, airline, or \
        fare the tool did not return. Say airline, departure time, stops, and price for each option. \
        Some things happen on the phone itself and you cannot do them directly: sending an iMessage, \
        drafting or sending an email, saving a note, adding a reminder, opening Maps, Calendar, Music, \
        YouTube, Spotify, Gmail or Settings, or running an Apple Shortcut. For those, say in one \
        sentence what you prepared, then append exactly one block on its own line: \
        <hermes-action>{...}</hermes-action> containing one of \
        {"type":"message","body":"..."} · \
        {"type":"email","recipient":"...","subject":"...","body":"...","send":true} (send false for a draft) · \
        {"type":"note","body":"...","apple":false} (apple true only if they name Apple Notes) · \
        {"type":"reminder","title":"...","due":"2026-08-28T09:00:00-04:00"} (due optional, ISO 8601 with offset) · \
        {"type":"open","destination":"maps"} (maps, calendar, music, youtube, spotify, gmail, settings) · \
        {"type":"shortcut","name":"..."}. \
        The phone shows the block for approval before anything happens, so never say it was sent, \
        saved, or opened. The words "confirm" and "cancel" are handled on the phone.
        """
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func configuration(serverURL: String, conversationID: UUID, model: String? = nil) throws -> Configuration {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, url.host != nil,
              ["https", "http"].contains(scheme.lowercased())
        else { throw ClientError.invalidServerURL(trimmed) }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "WhisperDictHermesKey") as? String,
              !key.isEmpty, !key.contains("$(")
        else { throw ClientError.missingKey }
        let requestedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Configuration(
            baseURL: url,
            key: key,
            conversation: "whisperdict-\(conversationID.uuidString.lowercased())",
            model: requestedModel?.isEmpty == false ? requestedModel : nil
        )
    }

    /// Sends one turn and streams Hermes's reply back as it is produced. The
    /// stream ends after `.completed` or `.failed`; transport failures throw.
    /// Turns in one conversation must not overlap: the gateway session is
    /// shared, and the controller serialises them.
    /// `imageDataURLs` are pre-encoded `data:image/...` URLs sent alongside
    /// the text as OpenAI-style image content parts, so Hermes can look at
    /// photos the user attaches.
    func reply(
        to input: String,
        configuration: Configuration,
        place: String? = nil,
        imageDataURLs: [String] = []
    ) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(input: input, configuration: configuration, place: place, imageDataURLs: imageDataURLs) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        input: String,
        configuration: Configuration,
        place: String?,
        imageDataURLs: [String],
        onEvent: (HermesStreamEvent) -> Void
    ) async throws {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        // A turn that runs tools can take a while; the stream's keepalives
        // stop the request from idling out before Hermes is done.
        request.timeoutInterval = 180
        request.setValue("Bearer \(configuration.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        request.setValue(configuration.conversation, forHTTPHeaderField: "X-Hermes-Session-Id")
        // A plain string when there is nothing to look at — the widest
        // compatibility — and content parts only when images ride along.
        let userContent: Any
        if imageDataURLs.isEmpty {
            userContent = input
        } else {
            var parts: [[String: Any]] = imageDataURLs.map {
                ["type": "image_url", "image_url": ["url": $0]]
            }
            parts.append(["type": "text", "text": input])
            userContent = parts
        }
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": Self.instructions(now: Date(), place: place)],
                ["role": "user", "content": userContent],
            ],
            "stream": true,
        ]
        if let model = configuration.model {
            body["model"] = model
            if let options = Self.modelOptions(for: model) { body["model_options"] = options }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.rejected(status: 0, message: "no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw ClientError.rejected(status: http.statusCode, message: await Self.errorMessage(from: bytes))
        }

        // Split on newlines by hand rather than through `bytes.lines`: SSE
        // frames end at an empty line, and the parser needs to see it.
        var parser = HermesChatStreamParser()
        var line: [UInt8] = []
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let event = parser.feed(line: text.hasSuffix("\r") ? String(text.dropLast()) : text) {
                    onEvent(event)
                    if Self.isTerminal(event) { return }
                }
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty, let event = parser.feed(line: String(decoding: line, as: UTF8.self)) { onEvent(event) }
        if let event = parser.finish() { onEvent(event) }
    }

    private static func isTerminal(_ event: HermesStreamEvent) -> Bool {
        switch event {
        case .completed, .failed: true
        default: false
        }
    }

    private static func errorMessage(from bytes: URLSession.AsyncBytes) async -> String {
        var collected: [UInt8] = []
        do {
            for try await byte in bytes {
                if collected.count >= 2_000 { break }
                collected.append(byte)
            }
        } catch {
            // A truncated error body is still worth showing.
        }
        let body = String(decoding: collected, as: UTF8.self)
        guard let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return body.isEmpty ? "empty reply" : body }
        return message
    }
}
