import AVFoundation
import Foundation
import WebRTC

struct RealtimePreparedAction {
    let callID: String
    let action: VoiceAgentAction
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
    var onPreparedAction: ((RealtimePreparedAction) -> Void)?
    /// Runs a read-only tool and returns what the model should hear back.
    var onInformationRequest: ((String, [String: Any]) async -> String)?

    private static let backendURL = URL(string: "https://whisperdict-realtime.vercel.app/api/realtime-session")!
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var assistantTranscript = ""
    private var isStopping = false
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
        var stage = RealtimeStartupStage.audioSession
        defer {
            if !connectionEstablished { stop() }
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
            // Use the gathered local description, not the pre-ICE offer.
            let gatheredSDP = peerConnection.localDescription?.sdp ?? offer.sdp
            guard gatheredSDP.hasPrefix("v=0"), gatheredSDP.count > 100 else {
                throw RealtimeAgentError.offerCreationFailed
            }
            stage = .backend
            let answerSDP = try await requestAnswer(for: gatheredSDP, clientToken: clientToken)
            stage = .remoteAnswer
            try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP), on: peerConnection)
            connectionEstablished = true
        } catch {
            throw RealtimeStartupError(stage: stage, underlying: error)
        }
    }

    func completeFunctionCall(id: String, output: String) {
        send([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": id,
                "output": output,
            ],
        ])
        send(["type": "response.create"])
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
        guard let dataChannel,
              dataChannel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: event)
        else { return }
        dataChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "input_audio_buffer.speech_started":
            onStateChange?(.listening)
        case "input_audio_buffer.speech_stopped", "response.created":
            onStateChange?(.responding)
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = object["transcript"] as? String {
                onUserTranscript?(transcript)
            }
        case "response.output_audio_transcript.delta":
            assistantTranscript += object["delta"] as? String ?? ""
        case "response.output_audio_transcript.done":
            let transcript = (object["transcript"] as? String ?? assistantTranscript)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            assistantTranscript = ""
            if !transcript.isEmpty { onAssistantTranscript?(transcript) }
        case "response.done":
            handleCompletedResponse(object)
            onStateChange?(.listening)
        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "The Realtime conversation failed."
            onStateChange?(.failed(message))
        default:
            break
        }
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
            if Self.informationTools.contains(name) {
                Task { [weak self] in
                    let output = await self?.onInformationRequest?(name, arguments)
                    self?.completeFunctionCall(id: callID, output: output ?? "No result was available.")
                }
                continue
            }
            guard let action = preparedAction(name: name, arguments: arguments) else {
                completeFunctionCall(id: callID, output: "Rejected: the requested action did not pass local validation.")
                continue
            }
            onPreparedAction?(RealtimePreparedAction(callID: callID, action: action))
        }
    }

    /// Tools that only read. They carry no side effect to confirm, so making
    /// the user approve them would turn "what's the weather" into a dialog.
    static let informationTools: Set<String> = [
        "search_web", "search_notes", "list_reminders", "get_datetime",
    ]

    private func preparedAction(name: String, arguments: [String: Any]) -> VoiceAgentAction? {
        switch name {
        case "prepare_message":
            guard let body = arguments["body"] as? String else { return nil }
            return VoiceAgentAction.validatedMessage(body)
        case "prepare_email":
            guard let recipient = arguments["recipient"] as? String,
                  let subject = arguments["subject"] as? String,
                  let body = arguments["body"] as? String
            else { return nil }
            return VoiceAgentAction.validatedEmail(recipient: recipient, subject: subject, body: body)
        case "send_email":
            guard let recipient = arguments["recipient"] as? String,
                  let subject = arguments["subject"] as? String,
                  let body = arguments["body"] as? String
            else { return nil }
            return VoiceAgentAction.validatedSentEmail(recipient: recipient, subject: subject, body: body)
        case "prepare_note":
            guard let body = arguments["body"] as? String else { return nil }
            return VoiceAgentAction.validatedNote(body)
        case "save_note":
            guard let body = arguments["body"] as? String else { return nil }
            return VoiceAgentAction.validatedSavedNote(body)
        case "create_reminder":
            guard let title = arguments["title"] as? String else { return nil }
            let due = (arguments["due"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            return VoiceAgentAction.validatedReminder(title: title, dueDate: due)
        case "open_destination":
            guard let destination = arguments["destination"] as? String else { return nil }
            return VoiceAgentAction.validatedDestination(destination)
        case "run_shortcut":
            guard let name = arguments["name"] as? String else { return nil }
            return VoiceAgentAction.validatedShortcut(name)
        default:
            return nil
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
            guard let self else { return }
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
            guard let self else { return }
            self.iceGatheringComplete = true
            self.iceGatheringContinuation?.resume()
            self.iceGatheringContinuation = nil
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            dataChannel.delegate = self
            self?.dataChannel = dataChannel
        }
    }
}

extension RealtimeAgentClient: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        Task { @MainActor [weak self] in self?.onStateChange?(.listening) }
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
