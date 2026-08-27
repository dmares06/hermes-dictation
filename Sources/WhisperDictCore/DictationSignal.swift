import Foundation

#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Low-latency "something changed" pings between the keyboard, the Live
/// Activity, the App Intent, and the resident app.
///
/// Darwin notifications carry no payload and are not queued, so the payload
/// always lives in the app group (`ListeningWindowState`, `BackgroundDictationState`)
/// and the resident app *also* polls it. The ping only makes the response
/// immediate instead of waiting for the next poll.
public enum DictationSignal: String, CaseIterable, Sendable {
    case start = "com.dmares06.whisperdict.signal.start"
    case stop = "com.dmares06.whisperdict.signal.stop"
    /// A finished transcript is in the app group. Without it the keyboard
    /// would not show the text until its next poll, adding up to a quarter
    /// second to every dictation for no reason.
    case transcriptReady = "com.dmares06.whisperdict.signal.transcriptReady"

    public var name: CFNotificationName { CFNotificationName(rawValue as CFString) }
}

public enum DictationSignalCenter {
    public static func post(_ signal: DictationSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            signal.name,
            nil,
            nil,
            true
        )
    }

    /// Starts observing `signal`; the returned token stops observation when
    /// deallocated. The handler runs on an arbitrary thread.
    public static func observe(
        _ signal: DictationSignal,
        handler: @escaping @Sendable () -> Void
    ) -> DictationSignalObservation {
        DictationSignalObservation(signal: signal, handler: handler)
    }
}

public final class DictationSignalObservation: @unchecked Sendable {
    private let signal: DictationSignal
    private let handler: @Sendable () -> Void

    fileprivate init(signal: DictationSignal, handler: @escaping @Sendable () -> Void) {
        self.signal = signal
        self.handler = handler
        // The C callback cannot capture Swift context, so the observer pointer
        // is the only way back to this object.
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DictationSignalObservation>.fromOpaque(observer)
                    .takeUnretainedValue()
                    .handler()
            },
            signal.rawValue as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            signal.name,
            nil
        )
    }
}
