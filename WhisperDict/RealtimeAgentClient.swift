import AVFoundation
import Foundation
import WebRTC

/// What a function call hands back to the voice model.
struct RealtimeFunctionResult {
    let output: String
    /// Whether the model should respond now. False for a call that was
    /// overtaken by the user's next words: its output is recorded so the
    /// conversation stays well-formed, but only the newest call is spoken.
    let speak: Bool

    /// False only when the request never reached Hermes at all.
    var delivered = true

    static let superseded = RealtimeFunctionResult(
        output: "Superseded: the user kept talking, and this was answered together with their next request.",
        speak: false
    )

    /// The call ended before the queue got to this request.
    static let abandoned = RealtimeFunctionResult(
        output: "Not sent: the conversation ended before this could reach Hermes.",
        speak: false,
        delivered: false
    )
}

@MainActor
final class RealtimeAgentClient: NSObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case listening
        case responding
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onAssistantTranscript: ((String) -> Void)?
    /// Answers a function call from the voice model and returns what it
    /// should hear back. Realtime is only the ears and the mouth here: its
    /// one tool relays the user's words to Hermes Agent.
    var onFunctionCall: ((String, [String: Any]) async -> RealtimeFunctionResult)?

    private static let backendURL = URL(string: "https://whisperdict-realtime.vercel.app/api/realtime-session")!
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var assistantTranscript = ""
    private var isStopping = false
    /// One response at a time: see `RealtimeResponseGate`.
    private var responseGate = RealtimeResponseGate()
    /// The out-of-band progress line in flight, so its events are kept out
    /// of the transcript and off the phase, unlike a real turn's.
    private var narrationResponseID: String?
    // Fulfilled when ICE gathering reaches .complete, so the offer we send
    // carries its candidates. OpenAI does not accept trickle ICE and rejects
    // a candidate-less offer as an unparseable SDP.
    private var iceGatheringContinuation: CheckedContinuation<Void, Never>?
    private var iceGatheringComplete = false
    /// Speaker is the default: this is a phone the user talks to hands-free.
    private var usesSpeaker = true
    private var routeObserver: NSObjectProtocol?

    func start() async throws {
        guard peerConnection == nil else { return }
        guard let clientToken = Bundle.main.object(forInfoDictionaryKey: "WhisperDictRealtimeClientToken") as? String,
              !clientToken.isEmpty,
              !clientToken.contains("$(")
        else {
            throw RealtimeAgentError.missingClientToken
        }

        onStateChange?(.connecting)
        var connectionEstablished = false
        var created: RTCPeerConnection?
        var stage = RealtimeStartupStage.audioSession
        defer {
            // Only tear down our own attempt. Whatever cancelled this one may
            // already have opened a newer connection, and closing that here
            // would kill a session the user is about to talk into.
            if !connectionEstablished, created === peerConnection { stop() }
        }
        do {
            try configureAudioSession()

            stage = .peerConnection
            let configuration = RTCConfiguration()
            configuration.sdpSemantics = .unifiedPlan
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
            )
            guard let peerConnection = Self.factory.peerConnection(
                with: configuration,
                constraints: constraints,
                delegate: self
            ) else {
                throw RealtimeAgentError.connectionCreationFailed
            }
            self.peerConnection = peerConnection
            created = peerConnection

            stage = .audioTrack
            let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "whisperdict-audio")
            peerConnection.add(audioTrack, streamIds: ["whisperdict-stream"])

            stage = .eventChannel
            let channelConfiguration = RTCDataChannelConfiguration()
            channelConfiguration.isOrdered = true
            guard let dataChannel = peerConnection.dataChannel(forLabel: "oai-events", configuration: channelConfiguration) else {
                throw RealtimeAgentError.dataChannelCreationFailed
            }
            dataChannel.delegate = self
            self.dataChannel = dataChannel

            stage = .localOffer
            let offer = try await createOffer(on: peerConnection)
            try await setLocalDescription(offer, on: peerConnection)
            await waitForIceGathering(on: peerConnection)
            try checkStillLive(peerConnection)
            // Use the gathered local description, not the pre-ICE offer.
            let gatheredSDP = peerConnection.localDescription?.sdp ?? offer.sdp
            guard gatheredSDP.hasPrefix("v=0"), gatheredSDP.count > 100 else {
                throw RealtimeAgentError.offerCreationFailed
            }
            stage = .backend
            let answerSDP = try await requestAnswer(for: gatheredSDP, clientToken: clientToken)
            try checkStillLive(peerConnection)
            stage = .remoteAnswer
            try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP), on: peerConnection)
            connectionEstablished = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RealtimeStartupError(stage: stage, underlying: error)
        }
    }

    /// Throws if this attempt was torn down while it was awaiting. Ending the
    /// conversation or leaving the foreground closes the peer connection, and
    /// WebRTC then rejects every later call on it — the answer arrives to a
    /// "called wrong state: closed". That is a cancellation, not a failure the
    /// user should see reported as one.
    private func checkStillLive(_ connection: RTCPeerConnection) throws {
        guard peerConnection === connection, connection.signalingState != .closed else {
            throw CancellationError()
        }
    }

    func completeFunctionCall(id: String, result: RealtimeFunctionResult) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": id,
                "output": result.output,
            ],
        ])
        if result.speak { requestResponse() }
    }

    /// Asks the voice to respond, or queues the request if it is already
    /// mid-response — the user may have spoken while Hermes was thinking.
    private func requestResponse() {
        if responseGate.requestResponse() {
            send(["type": "response.create"])
        } else {
            AgentTurnLog.note("response deferred: the voice is mid-response")
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        assistantTranscript = ""
        responseGate.reset()
        narrationResponseID = nil
        iceGatheringContinuation?.resume()
        iceGatheringContinuation = nil
        iceGatheringComplete = false
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isStopping = false
        onStateChange?(.disconnected)
    }

    /// Routes the conversation to the speaker rather than the earpiece.
    ///
    /// `.voiceChat` mode takes the receiver as its default output and
    /// overrides `.defaultToSpeaker`, which is why a call otherwise arrives in
    /// the earpiece and the phone has to be held up. The mode is worth keeping
    /// for its echo cancellation, so the route is overridden explicitly
    /// instead — but never over headphones or a Bluetooth headset, where
    /// forcing the speaker would be plainly wrong.
    func setSpeakerEnabled(_ enabled: Bool) {
        usesSpeaker = enabled
        applyOutputRoute()
    }

    private func applyOutputRoute() {
        let audioSession = AVAudioSession.sharedInstance()
        guard !Self.routeHasHeadset(audioSession) else {
            try? audioSession.overrideOutputAudioPort(.none)
            return
        }
        try? audioSession.overrideOutputAudioPort(usesSpeaker ? .speaker : .none)
    }

    private static func routeHasHeadset(_ session: AVAudioSession) -> Bool {
        let wired: Set<AVAudioSession.Port> = [.headphones, .headsetMic]
        let wireless: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio]
        return session.currentRoute.outputs.contains { wired.contains($0.portType) || wireless.contains($0.portType) }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try audioSession.setActive(true)
        applyOutputRoute()

        if routeObserver == nil {
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] _ in
                // Plugging in or unplugging replaces the route, discarding the
                // override; without this the audio silently returns to the ear.
                Task { @MainActor in self?.applyOutputRoute() }
            }
        }
    }

    private func createOffer(on peerConnection: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveAudio": "true"],
                optionalConstraints: nil
            )
            peerConnection.offer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: error ?? RealtimeAgentError.offerCreationFailed)
                }
            }
        }
    }

    /// Waits up to a few seconds for ICE gathering to finish. Non-trickle is
    /// required by OpenAI; a timeout still sends whatever was gathered rather
    /// than hanging, since host candidates alone usually suffice.
    private func waitForIceGathering(on peerConnection: RTCPeerConnection) async {
        if peerConnection.iceGatheringState == .complete || iceGatheringComplete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            iceGatheringContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    guard let self, let pending = self.iceGatheringContinuation else { return }
                    self.iceGatheringContinuation = nil
                    pending.resume()
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription, on peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private func requestAnswer(for offerSDP: String, clientToken: String) async throws -> String {
        var request = URLRequest(url: Self.backendURL)
        request.httpMethod = "POST"
        request.httpBody = Data(offerSDP.utf8)
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RealtimeAgentError.backendRejected((response as? HTTPURLResponse)?.statusCode)
        }
        guard let answer = String(data: data, encoding: .utf8), answer.hasPrefix("v=0") else {
            throw RealtimeAgentError.invalidAnswer
        }
        return answer
    }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        guard let dataChannel, dataChannel.readyState == .open else {
            // Every turn now depends on a function-call round trip, so a
            // dropped event is a stalled conversation, not a detail.
            AgentTurnLog.note("realtime event dropped (channel not open): \(event["type"] ?? "?")")
            return
        }
        dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// A short progress line while Hermes works — "Checking flights now."
    /// Spoken out of band, so it never enters the conversation, with only
    /// these instructions as context, so the model cannot wander. Dropped
    /// rather than queued when the voice is busy: by the time the line
    /// frees up the note is stale.
    func narrate(_ line: String) {
        guard responseGate.requestResponseIfIdle() else {
            AgentTurnLog.note("progress line dropped, voice busy: \(line)")
            return
        }
        send([
            "type": "response.create",
            "response": [
                "conversation": "none",
                "output_modalities": ["audio"],
                "input": [],
                "instructions": "Say exactly this and nothing more: \(line)",
                "metadata": ["topic": Self.narrationTopic],
            ],
        ])
    }

    private static let narrationTopic = "progress"

    private func isNarration(_ object: [String: Any]) -> Bool {
        if let response = object["response"] as? [String: Any] {
            if let metadata = response["metadata"] as? [String: Any], metadata["topic"] as? String == Self.narrationTopic {
                return true
            }
            if let id = response["id"] as? String, id == narrationResponseID { return true }
        }
        if let id = object["response_id"] as? String, id == narrationResponseID { return true }
        return false
    }

    /// Tells the voice something that happened on the phone — a confirmation
    /// card tapped, an action carried out — and has it respond. Sent as a
    /// system message rather than through `session.update`, which would
    /// replace the instructions the backend built.
    func say(_ text: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "system",
                "content": [["type": "input_text", "text": text]],
            ],
        ])
        requestResponse()
    }

    private func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "input_audio_buffer.speech_started":
            onStateChange?(.listening)
        case "input_audio_buffer.speech_stopped":
            onStateChange?(.responding)
        case "response.created":
            responseGate.noteResponseCreated()
            if isNarration(object) {
                narrationResponseID = (object["response"] as? [String: Any])?["id"] as? String
            } else {
                onStateChange?(.responding)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = object["transcript"] as? String {
                onUserTranscript?(transcript)
            }
        case "response.output_audio_transcript.delta":
            guard !isNarration(object) else { return }
            assistantTranscript += object["delta"] as? String ?? ""
        case "response.output_audio_transcript.done":
            guard !isNarration(object) else { return }
            let transcript = (object["transcript"] as? String ?? assistantTranscript)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            assistantTranscript = ""
            if !transcript.isEmpty { onAssistantTranscript?(transcript) }
        case "response.done":
            if isNarration(object) {
                narrationResponseID = nil
            } else {
                handleCompletedResponse(object)
                onStateChange?(.listening)
            }
            if responseGate.noteResponseDone() {
                AgentTurnLog.note("sending the deferred response now")
                requestResponse()
            }
        case "error":
            handleError(object["error"] as? [String: Any])
        default:
            break
        }
    }

    /// Most errors are about one request of ours and leave the session
    /// running; only a lost session ends the call. Every one is logged —
    /// the old code ended the call on all of them without a trace.
    private func handleError(_ error: [String: Any]?) {
        let code = error?["code"] as? String
        let type = error?["type"] as? String
        let message = error?["message"] as? String ?? "The Realtime conversation failed."
        let verdict = responseGate.noteError(code: code, type: type)
        AgentTurnLog.note("realtime error (\(verdict)) \(code ?? type ?? "?"): \(message)")
        if verdict == .fatal { onStateChange?(.failed(message)) }
    }

    private func handleCompletedResponse(_ event: [String: Any]) {
        guard let response = event["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]]
        else { return }

        for item in output where item["type"] as? String == "function_call" {
            guard let callID = item["call_id"] as? String,
                  let name = item["name"] as? String,
                  let argumentsString = item["arguments"] as? String,
                  let argumentsData = argumentsString.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any]
            else { continue }
            // The answer may take a while; by then the call this came from
            // may have been ended and a new one started. Only the connection
            // that issued the call gets its output.
            let origin = peerConnection
            Task { [weak self] in
                let result = await self?.onFunctionCall?(name, arguments)
                guard let self, self.peerConnection === origin else {
                    AgentTurnLog.note("stale function result discarded after the call ended")
                    return
                }
                self.completeFunctionCall(
                    id: callID,
                    result: result ?? RealtimeFunctionResult(output: "No result was available.", speak: true)
                )
            }
        }
    }
}

extension RealtimeAgentClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            // A connection we already replaced still reports its own teardown;
            // letting that through would fail the session that superseded it.
            guard let self, self.peerConnection === peerConnection else { return }
            switch newState {
            case .connected, .completed: self.onStateChange?(.listening)
            case .failed: self.onStateChange?(.failed("The Realtime connection failed."))
            case .disconnected, .closed: self.onStateChange?(.disconnected)
            default: break
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            self.iceGatheringComplete = true
            self.iceGatheringContinuation?.resume()
            self.iceGatheringContinuation = nil
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection === peerConnection else { return }
            dataChannel.delegate = self
            self.dataChannel = dataChannel
        }
    }
}

extension RealtimeAgentClient: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        Task { @MainActor [weak self] in
            self?.onStateChange?(.listening)
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor [weak self] in self?.receive(buffer.data) }
    }
}

enum RealtimeAgentError: LocalizedError {
    case missingClientToken
    case connectionCreationFailed
    case dataChannelCreationFailed
    case offerCreationFailed
    case backendRejected(Int?)
    case invalidAnswer

    var errorDescription: String? {
        switch self {
        case .missingClientToken: "This build is missing its private Realtime access token."
        case .connectionCreationFailed: "The iPhone could not create a Realtime connection."
        case .dataChannelCreationFailed: "The iPhone could not create the Realtime event channel."
        case .offerCreationFailed: "The iPhone could not start the Realtime audio session."
        case .backendRejected(let status): "The Realtime server rejected the connection\(status.map { " (\($0))" } ?? "")."
        case .invalidAnswer: "The Realtime server returned an invalid audio connection."
        }
    }
}

private enum RealtimeStartupStage: String {
    case audioSession = "audio setup"
    case peerConnection = "WebRTC setup"
    case audioTrack = "microphone track"
    case eventChannel = "event channel"
    case localOffer = "local connection offer"
    case backend = "Hermes server"
    case remoteAnswer = "remote connection answer"
}

private struct RealtimeStartupError: LocalizedError {
    let stage: RealtimeStartupStage
    let underlying: Error

    var errorDescription: String? {
        let detail = (underlying as? LocalizedError)?.errorDescription
            ?? underlying.localizedDescription
        return "Realtime failed during \(stage.rawValue): \(detail)"
    }
}
