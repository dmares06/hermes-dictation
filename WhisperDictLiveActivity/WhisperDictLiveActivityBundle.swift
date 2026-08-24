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

struct WhisperDictLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WhisperDictActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.phase == .recording ? "waveform.circle.fill" : "ellipsis.circle.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.phase == .recording ? .red : .mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase == .recording ? "WhisperDict is listening" : "Transcribing on this iPhone")
                        .font(.headline)
                    if context.state.phase == .recording {
                        Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if context.state.phase == .recording {
                    Button(intent: StopWhisperDictIntent()) {
                        Image(systemName: "stop.fill")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(.horizontal)
            .activityBackgroundTint(Color.black.opacity(0.86))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform.circle.fill").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase == .recording ? "Listening" : "Transcribing")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .recording {
                        Button(intent: StopWhisperDictIntent()) {
                            Image(systemName: "stop.fill").foregroundStyle(.red)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.red)
            } compactTrailing: {
                if context.state.phase == .recording {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .frame(width: 40)
                } else {
                    ProgressView().tint(.mint)
                }
            } minimal: {
                Image(systemName: context.state.phase == .recording ? "mic.fill" : "ellipsis")
                    .foregroundStyle(context.state.phase == .recording ? .red : .mint)
            }
        }
    }
}
