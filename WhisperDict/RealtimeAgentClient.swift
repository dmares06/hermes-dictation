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

    private static let backendURL = URL(string: "https://whisperdict-realtime.vercel.app/api/realtime-session")!
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var assistantTranscript = ""
    private var isStopping = false

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
            stage = .backend
            let answerSDP = try await requestAnswer(for: offer.sdp, clientToken: clientToken)
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isStopping = false
        onStateChange?(.disconnected)
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try audioSession.setActive(true)
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
            guard let action = preparedAction(name: name, arguments: arguments) else {
                completeFunctionCall(id: callID, output: "Rejected: the requested action did not pass local validation.")
                continue
            }
            onPreparedAction?(RealtimePreparedAction(callID: callID, action: action))
        }
    }

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
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
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
