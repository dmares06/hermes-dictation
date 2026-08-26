import SwiftUI

struct SettingsView: View {
    @Environment(SharedState.self) private var state

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Model", selection: Bindable(state).modelSize) {
                    ForEach(ModelSize.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                Toggle("Remove filler words", isOn: Bindable(state).removeFillers)
                Toggle("Auto-punctuate", isOn: Bindable(state).autoPunctuate)
                Toggle("Auto-capitalize", isOn: Bindable(state).autoCapitalize)
            }
            Section("Appearance") {
                ColorPicker("Keyboard color", selection: keyboardColor, supportsOpacity: false)
                ColorPicker("Record button color", selection: recordButtonColor, supportsOpacity: false)
                AppearancePreview(
                    keyboardColor: state.keyboardColor,
                    recordButtonColor: state.recordButtonColor
                )
                Button("Restore default colors", action: state.resetAppearance)
            }
            Section("Privacy") {
                Label("Audio is processed on this device.", systemImage: "lock.shield")
                Text("WhisperDict does not send your dictated audio to a server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Setup") {
                Button("Run setup again") {
                    state.welcomeDone = false
                }
                Text("Review microphone, speech model, keyboard, and Action Button setup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Platform", value: "iOS 17+")
            }
        }
        .navigationTitle("Settings")
    }

    private var keyboardColor: Binding<Color> {
        Binding(
            get: { Color(appearanceColor: state.keyboardColor) },
            set: { color in
                guard let appearanceColor = color.appearanceColor else { return }
                state.keyboardColor = appearanceColor
            }
        )
    }

    private var recordButtonColor: Binding<Color> {
        Binding(
            get: { Color(appearanceColor: state.recordButtonColor) },
            set: { color in
                guard let appearanceColor = color.appearanceColor else { return }
                state.recordButtonColor = appearanceColor
            }
        )
    }
}

private struct AppearancePreview: View {
    let keyboardColor: AppearanceColor
    let recordButtonColor: AppearanceColor

    var body: some View {
        VStack(spacing: 10) {
            Text("Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Label("Record", systemImage: "mic.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .foregroundStyle(recordButtonColor.prefersDarkForeground ? Color.black : .white)
                    .background(Color(appearanceColor: recordButtonColor), in: .rect(cornerRadius: 8))
                ForEach(["A", "B", "C"], id: \.self) { letter in
                    Text(letter)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(.background, in: .rect(cornerRadius: 6))
                }
            }
        }
        .padding(10)
        .background(Color(appearanceColor: keyboardColor).opacity(0.24), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keyboard and Record button color preview")
    }
}
