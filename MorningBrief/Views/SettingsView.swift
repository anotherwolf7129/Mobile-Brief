import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var store: BriefStore
    @EnvironmentObject private var scheduler: BriefScheduler
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = KeychainStore.apiKey() ?? ""
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        NavigationStack {
            Form {
                readoutSection
                voiceSection
                deliverySection
                accessSection
                proseSection
            }
            .navigationTitle("Morning Brief")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        KeychainStore.saveAPIKey(apiKey.isEmpty ? nil : apiKey)
                        dismiss()
                        Task { await store.refresh() }
                    }
                }
            }
            .onAppear { voices = BriefNarrator.availableVoices() }
        }
    }

    // MARK: - When

    private var readoutSection: some View {
        Section {
            Toggle("Daily readout", isOn: $settings.enabled)
                .onChange(of: settings.enabled) { _, enabled in
                    Task {
                        if enabled {
                            await scheduler.requestAuthorization()
                            await store.refresh()
                        } else {
                            scheduler.cancelAll()
                            AudioKeepAlive.shared.stop()
                        }
                    }
                }

            DatePicker(
                "Time",
                selection: Binding(
                    get: {
                        Calendar.current.date(
                            bySettingHour: settings.hour,
                            minute: settings.minute,
                            second: 0,
                            of: Date()
                        ) ?? Date()
                    },
                    set: { newValue in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                        settings.hour = parts.hour ?? 7
                        settings.minute = parts.minute ?? 0
                        Task { await store.refresh() }
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            .disabled(!settings.enabled)

            Toggle("Weekdays only", isOn: $settings.weekdaysOnly)
                .disabled(!settings.enabled)
                .onChange(of: settings.weekdaysOnly) { _, _ in
                    Task { await store.refresh() }
                }
        } header: {
            Text("Readout")
        } footer: {
            if let next = scheduler.nextFireDate, settings.enabled {
                Text("Next readout \(next, format: .dateTime.weekday().hour().minute()).")
            } else if settings.enabled {
                Text("No readout scheduled yet.")
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            Picker("Voice", selection: Binding(
                get: { settings.voiceIdentifier ?? "" },
                set: { settings.voiceIdentifier = $0.isEmpty ? nil : $0 }
            )) {
                Text("Best available").tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text(label(for: voice)).tag(voice.identifier)
                }
            }

            VStack(alignment: .leading) {
                Text("Speed")
                Slider(value: $settings.speechRate, in: 0.35...0.7)
            }

            Button("Preview") {
                BriefNarrator.shared.speak(
                    text: BriefScript(brief: store.brief).teaser
                )
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Enhanced and premium voices sound markedly better and are free — download them in Settings › Accessibility › Spoken Content › Voices.")
        }
    }

    private func label(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name) — Premium"
        case .enhanced: return "\(voice.name) — Enhanced"
        default: return voice.name
        }
    }

    // MARK: - How it reaches you

    private var deliverySection: some View {
        Section {
            Toggle("Hands-free full readout", isOn: $settings.handsFree)
                .onChange(of: settings.handsFree) { _, _ in
                    store.rearmTimer()
                }
        } header: {
            Text("Delivery")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("At the set time your notification's *sound* is the spoken brief — about 30 seconds, no tapping, and it works even if the app was closed or the phone restarted. iOS mutes notification sounds when the ringer is off or Silent Mode is on.")
                Text("Hands-free adds the **whole** brief, read aloud by the app itself. It keeps a quiet audio session open to stay awake, so it uses more battery, and it stops working if you force-quit the app or restart the phone.")
            }
        }
    }

    // MARK: - Sources

    private var accessSection: some View {
        Section {
            LabeledContent("Calendar") {
                Text(store.calendarAuthorized ? "Allowed" : "Not allowed")
                    .foregroundStyle(store.calendarAuthorized ? Theme.inkSoft : Theme.clay)
            }
            LabeledContent("Reminders") {
                Text(store.remindersAuthorized ? "Allowed" : "Not allowed")
                    .foregroundStyle(store.remindersAuthorized ? Theme.inkSoft : Theme.clay)
            }
            LabeledContent("Notifications") {
                Text(scheduler.notificationsAuthorized ? "Allowed" : "Not allowed")
                    .foregroundStyle(scheduler.notificationsAuthorized ? Theme.inkSoft : Theme.clay)
            }
            if !store.calendarAuthorized || !store.remindersAuthorized
                || !scheduler.notificationsAuthorized {
                Button("Request access") {
                    Task {
                        await scheduler.requestAuthorization()
                        await store.requestAccess()
                    }
                }
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Everything the brief says comes from your calendar and reminders on this device.")
        }
    }

    // MARK: - Prose

    private var proseSection: some View {
        Section {
            TextField("Your name", text: $settings.displayName)
                .textInputAutocapitalization(.words)

            Toggle("Let Claude write the prose", isOn: $settings.useClaude)
                .disabled(apiKey.isEmpty)

            SecureField("Anthropic API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Writing")
        } footer: {
            Text("Optional. Without a key the brief is written on device and never leaves the phone. With one, the day's titles and times are sent to the Anthropic API so Claude can rewrite the sentences — the facts, links, and structure always stay as built here. The key is stored in the Keychain.")
        }
    }
}
