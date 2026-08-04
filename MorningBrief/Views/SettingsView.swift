import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var store: BriefStore
    @EnvironmentObject private var scheduler: BriefScheduler
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = KeychainStore.apiKey() ?? ""
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var defaultVoiceLabel = "자동"

    var body: some View {
        NavigationStack {
            Form {
                readoutSection
                voiceSection
                deliverySection
                accessSection
                proseSection
            }
            .navigationTitle("모닝 브리핑")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        KeychainStore.saveAPIKey(apiKey.isEmpty ? nil : apiKey)
                        dismiss()
                        Task { await store.refresh() }
                    }
                }
            }
            .onAppear { reloadVoices() }
        }
    }

    // MARK: - When

    private var readoutSection: some View {
        Section {
            Toggle("매일 읽어 주기", isOn: $settings.enabled)
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
                "시간",
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

            Toggle("평일만", isOn: $settings.weekdaysOnly)
                .disabled(!settings.enabled)
                .onChange(of: settings.weekdaysOnly) { _, _ in
                    Task { await store.refresh() }
                }
        } header: {
            Text("읽어 주기")
        } footer: {
            if let next = scheduler.nextFireDate, settings.enabled {
                Text("다음 읽기 — \(next, format: .dateTime.weekday().hour().minute())")
            } else if settings.enabled {
                Text("아직 예약된 읽기가 없어요.")
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        Section {
            Picker("음성", selection: Binding(
                get: { settings.voiceIdentifier ?? "" },
                set: { settings.voiceIdentifier = $0.isEmpty ? nil : $0 }
            )) {
                Text(defaultVoiceLabel).tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text(label(for: voice)).tag(voice.identifier)
                }
            }

            VStack(alignment: .leading) {
                Text("속도")
                Slider(value: $settings.speechRate, in: 0.35...0.7)
            }

            Button("미리 듣기") {
                BriefNarrator.shared.speak(
                    text: BriefScript(brief: store.brief).teaser
                )
            }
        } header: {
            Text("음성")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("브리핑은 한국어로 쓰이고 한국어 음성으로 읽어요. 따로 고르지 않으면 기기에 설치된 한국어 여성 음성 중 가장 좋은 것을 써요.")
                Text("향상됨·프리미엄 음성이 기본 음성보다 훨씬 자연스럽고, 무료로 받을 수 있어요. 설정 › 손쉬운 사용 › 콘텐츠 말하기 › 음성 › 한국어에서 내려받으면 여기 목록에 나타나요.")
            }
        }
    }

    /// Enumerating the installed voices is not free, so it happens once on
    /// appear rather than on every pass through `body`.
    private func reloadVoices() {
        voices = BriefNarrator.availableVoices()
        // Name the voice the default actually resolves to, so "자동" isn't a guess.
        defaultVoiceLabel = BriefNarrator.defaultVoice()
            .map { "자동 (\(label(for: $0)))" } ?? "자동"
    }

    private func label(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name) — 프리미엄"
        case .enhanced: return "\(voice.name) — 향상됨"
        default: return voice.name
        }
    }

    // MARK: - How it reaches you

    private var deliverySection: some View {
        Section {
            Toggle("자동으로 전부 읽기", isOn: $settings.handsFree)
                .onChange(of: settings.handsFree) { _, _ in
                    store.rearmTimer()
                }
        } header: {
            Text("전달")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("정해 둔 시간에 알림 *소리* 자체가 브리핑이에요 — 30초 정도, 손댈 것 없이 재생되고, 앱을 닫아 두거나 기기를 다시 켠 뒤에도 울려요. 벨소리를 끄거나 무음 모드면 iOS가 알림 소리를 막아요.")
                Text("소리로 읽는 건 시간대 부분까지예요. **확인이 필요한 일**과 **이미 정리된 일**은 1분 뒤 알림으로 따로 와요 — 그 알림을 탭하면 해당 부분이 바로 열려요.")
                Text("자동으로 전부 읽기를 켜면 앱이 직접 시간대 부분 전체를 읽어요. 깨어 있기 위해 조용한 오디오 세션을 유지하니 배터리를 더 쓰고, 앱을 강제 종료하거나 기기를 다시 켜면 멈춰요.")
            }
        }
    }

    // MARK: - Sources

    private var accessSection: some View {
        Section {
            LabeledContent("캘린더") {
                Text(store.calendarAuthorized ? "허용됨" : "허용 안 됨")
                    .foregroundStyle(store.calendarAuthorized ? Theme.inkSoft : Theme.clay)
            }
            LabeledContent("미리 알림") {
                Text(store.remindersAuthorized ? "허용됨" : "허용 안 됨")
                    .foregroundStyle(store.remindersAuthorized ? Theme.inkSoft : Theme.clay)
            }
            LabeledContent("알림") {
                Text(scheduler.notificationsAuthorized ? "허용됨" : "허용 안 됨")
                    .foregroundStyle(scheduler.notificationsAuthorized ? Theme.inkSoft : Theme.clay)
            }
            if !store.calendarAuthorized || !store.remindersAuthorized
                || !scheduler.notificationsAuthorized {
                Button("권한 요청") {
                    Task {
                        await scheduler.requestAuthorization()
                        await store.requestAccess()
                    }
                }
            }
        } header: {
            Text("연결")
        } footer: {
            Text("브리핑에 나오는 모든 내용은 이 기기의 캘린더와 미리 알림에서 와요.")
        }
    }

    // MARK: - Prose

    private var proseSection: some View {
        Section {
            TextField("이름", text: $settings.displayName)
                .textInputAutocapitalization(.words)

            Toggle("Claude가 문장을 다듬게 하기", isOn: $settings.useClaude)
                .disabled(apiKey.isEmpty)

            SecureField("Anthropic API 키", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("문장")
        } footer: {
            Text("선택 사항이에요. 키가 없으면 브리핑은 기기에서 쓰이고 밖으로 나가지 않아요. 키를 넣으면 오늘의 제목과 시간이 Anthropic API로 전달되어 Claude가 문장을 다시 써요 — 사실, 링크, 구조는 항상 여기서 만든 그대로예요. 키는 키체인에 저장돼요.")
        }
    }
}
