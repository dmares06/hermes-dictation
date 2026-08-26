import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WhisperDictLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        WhisperDictLiveActivityWidget()
    }
}

/// Presentation for one dictation phase. Kept in one place so the lock
/// screen banner and the Dynamic Island never disagree.
private struct PhaseLook {
    let icon: String
    let tint: Color
    let title: String
    let showsTimer: Bool
    let showsStop: Bool
    let showsStart: Bool

    init(_ phase: BackgroundDictationPhase) {
        switch phase {
        case .recording:
            self.init(icon: "waveform.circle.fill", tint: .red, title: "WhisperDict is listening", timer: true, stop: true, start: false)
        case .transcribing:
            self.init(icon: "ellipsis.circle.fill", tint: .mint, title: "Transcribing on this iPhone", timer: false, stop: false, start: false)
        case .ready:
            self.init(icon: "checkmark.circle.fill", tint: .mint, title: "Transcript ready", timer: false, stop: false, start: true)
        case .failed:
            self.init(icon: "exclamationmark.circle.fill", tint: .orange, title: "Dictation didn\u{2019}t finish", timer: false, stop: false, start: true)
        case .idle:
            self.init(icon: "mic.circle.fill", tint: .mint, title: "Ready to dictate", timer: false, stop: false, start: true)
        }
    }

    private init(icon: String, tint: Color, title: String, timer: Bool, stop: Bool, start: Bool) {
        self.icon = icon
        self.tint = tint
        self.title = title
        showsTimer = timer
        showsStop = stop
        showsStart = start
    }
}

struct WhisperDictLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WhisperDictActivityAttributes.self) { context in
            let look = PhaseLook(context.state.phase)
            HStack(spacing: 12) {
                Image(systemName: look.icon)
                    .font(.title2)
                    .foregroundStyle(look.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.title)
                        .font(.headline)
                    if look.showsTimer {
                        Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if look.showsStart {
                        Text("Tap to talk without leaving your app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                controlButton(look)
            }
            .padding(.horizontal)
            .activityBackgroundTint(Color.black.opacity(0.86))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let look = PhaseLook(context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: look.icon).foregroundStyle(look.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(look.title)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    controlButton(look, compact: true)
                }
            } compactLeading: {
                Image(systemName: look.showsTimer ? "waveform" : "mic").foregroundStyle(look.tint)
            } compactTrailing: {
                if look.showsTimer {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .frame(width: 40)
                } else if context.state.phase == .transcribing {
                    ProgressView().tint(.mint)
                } else {
                    Image(systemName: "mic.fill").foregroundStyle(look.tint)
                }
            } minimal: {
                Image(systemName: look.showsTimer ? "mic.fill" : "mic").foregroundStyle(look.tint)
            }
        }
    }

    @ViewBuilder
    private func controlButton(_ look: PhaseLook, compact: Bool = false) -> some View {
        if look.showsStop {
            styled(Button(intent: StopWhisperDictIntent()) {
                Image(systemName: "stop.fill").frame(width: compact ? nil : 38, height: compact ? nil : 38)
            }, compact: compact)
            .tint(.red)
        } else if look.showsStart {
            styled(Button(intent: StartListeningDictationIntent()) {
                Image(systemName: "mic.fill").frame(width: compact ? nil : 38, height: compact ? nil : 38)
            }, compact: compact)
            .tint(.mint)
        }
    }

    /// The Dynamic Island draws its own chrome; only the banner gets a filled button.
    @ViewBuilder
    private func styled<Content: View>(_ button: Content, compact: Bool) -> some View {
        if compact {
            button.buttonStyle(.plain)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}
