import AVFoundation
import Foundation
import Observation

/// Runs the resident listening window: keeps the process alive, publishes
/// the heartbeat other processes check, and turns start signals from the
/// keyboard, Action Button, or Live Activity into recordings.
@MainActor
@Observable
final class ListeningWindowController {
    private(set) var isListening = false
    private(set) var expiresAt: Date?
    private(set) var lastError: String?

    /// Called on the main actor when another process asks for a recording.
    @ObservationIgnored var onStartRequested: (@MainActor () async -> Void)?
    /// Lets the owner hold the window open while a dictation is in flight.
    @ObservationIgnored var isBusy: (@MainActor () -> Bool)?

    private let keepalive = ResidentAudioKeepalive()
    private let activityHost: DictationActivityHost
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var startObservation: DictationSignalObservation?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    private var duration: ListeningWindowDuration = .off
    private var lastActivity = Date()

    private static let pollInterval: Duration = .milliseconds(250)
    /// Heartbeat every 2 s against an 8 s stale threshold leaves room for a
    /// busy main actor without the keyboard concluding the app is gone.
    private static let heartbeatEveryPolls = 8

    init(activityHost: DictationActivityHost) {
        self.activityHost = activityHost
    }

    /// Starts or refreshes the window. Safe to call on every foreground.
    func activate(duration: ListeningWindowDuration) {
        self.duration = duration
        guard duration.isEnabled else {
            deactivate()
            return
        }
        noteActivity()
        guard !isListening else { return }

        do {
            try keepalive.start()
        } catch {
            lastError = error.localizedDescription
            NSLog("WhisperDict listening window could not start: \(error.localizedDescription)")
            return
        }
        lastError = nil
        isListening = true
        activityHost.keepsActivityAlive = true
        ListeningWindowState.markAlive()
        observeSignals()
        startLoop()
        Task { await activityHost.ensureStarted(BackgroundDictationActivityContent.idle()) }
    }

    /// Resets the idle clock; called whenever the user does something.
    func noteActivity() {
        lastActivity = Date()
        expiresAt = ListeningWindowPolicy.expiry(lastActivity: lastActivity, duration: duration)
    }

    func deactivate() {
        loopTask?.cancel()
        loopTask = nil
        startObservation = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        keepalive.stop()
        ListeningWindowState.end()
        activityHost.keepsActivityAlive = false
        let wasListening = isListening
        isListening = false
        expiresAt = nil
        guard wasListening else { return }
        Task { await activityHost.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Signals

    private func observeSignals() {
        startObservation = DictationSignalCenter.observe(.start) { [weak self] in
            Task { @MainActor [weak self] in await self?.consumePendingStart() }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleInterruption(notification) }
        }
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            var polls = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.consumePendingStart()
                polls += 1
                guard polls % Self.heartbeatEveryPolls == 0 else { continue }
                self.tick()
            }
        }
    }

    private func consumePendingStart() async {
        guard isListening, ListeningWindowState.consumeStartRequest() else { return }
        noteActivity()
        await onStartRequested?()
    }

    private func tick() {
        ListeningWindowState.markAlive()
        guard let expiresAt, Date() >= expiresAt else { return }
        if isBusy?() == true {
            // Never cut a dictation short; expire on the next quiet tick.
            noteActivity()
            return
        }
        deactivate()
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            // A call or Siri took the session; the keepalive engine is stopped
            // by the system. Drop residency so callers fall back to launching.
            keepalive.stop()
            ListeningWindowState.end()
        case .ended:
            guard isListening else { return }
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard options.contains(.shouldResume) else {
                deactivate()
                return
            }
            do {
                try keepalive.start()
                ListeningWindowState.markAlive()
            } catch {
                deactivate()
            }
        @unknown default:
            break
        }
    }
}
