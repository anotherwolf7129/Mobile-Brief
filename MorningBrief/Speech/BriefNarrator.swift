import Foundation
import Combine
import AVFoundation
import os

/// Speaks the brief out loud.
@MainActor
final class BriefNarrator: NSObject, ObservableObject {
    static let shared = BriefNarrator()

    @Published private(set) var isSpeaking = false
    @Published private(set) var spokenLine: String?

    private let synthesizer = AVSpeechSynthesizer()
    private let log = Logger(subsystem: "com.morningbrief", category: "narrator")

    // Cannot be `private`: an override may not be less accessible than the
    // `NSObject.init()` it overrides.
    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Read the whole brief. Raises the audio session first so this is audible
    /// from the background and from the lock screen.
    func speak(_ brief: Brief) {
        let script = BriefScript(brief: brief).full
        speak(text: script)
    }

    func speak(text: String) {
        guard !text.isEmpty else { return }
        do {
            try AudioKeepAlive.shared.activateForSpeech()
        } catch {
            log.error("Could not activate audio session: \(error.localizedDescription)")
        }

        synthesizer.stopSpeaking(at: .immediate)
        // One utterance per line, so there is a real pause between sections
        // instead of one unbroken wall of speech.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            synthesizer.speak(Self.utterance(for: String(line)))
        }
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        spokenLine = nil
    }

    // These three are `nonisolated` so the offline renderer can build an
    // utterance from a background context without hopping to the main actor.
    nonisolated static func utterance(for line: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: line)
        let settings = Settings.shared
        utterance.rate = Float(settings.speechRate)
        utterance.postUtteranceDelay = 0.28
        utterance.voice = preferredVoice()
        return utterance
    }

    /// `BriefScript` writes the brief in English, so an English voice is the one
    /// that pronounces it correctly. A voice built for another language will
    /// still read it — through that language's phonetics, which is what makes it
    /// sound wrong — so the device language is the wrong thing to follow here.
    nonisolated static var scriptLanguagePrefix: String { "en" }

    /// The language the brief is read in: whatever the user picked, else the
    /// best English match for where they are.
    nonisolated static func narrationLanguage() -> String {
        let installed = availableLanguages()
        if let chosen = Settings.shared.voiceLanguage, installed.contains(chosen) {
            return chosen
        }
        return defaultLanguage(among: installed)
    }

    /// Keeps the regional accent when there is one to keep — an English device
    /// in Australia gets `en-AU`, a Korean device gets `en-US` rather than a
    /// Korean voice sounding out English words.
    nonisolated static func defaultLanguage(
        among installed: [String] = BriefNarrator.availableLanguages()
    ) -> String {
        let device = AVSpeechSynthesisVoice.currentLanguageCode()
        if device.hasPrefix(scriptLanguagePrefix), installed.contains(device) {
            return device
        }
        if let region = Locale.current.region?.identifier,
           installed.contains("\(scriptLanguagePrefix)-\(region)") {
            return "\(scriptLanguagePrefix)-\(region)"
        }
        if installed.contains("en-US") { return "en-US" }
        return installed.first { $0.hasPrefix(scriptLanguagePrefix) } ?? device
    }

    /// The user's chosen voice, else the best available for `narrationLanguage()`.
    /// Enhanced and premium voices sound markedly better than the default and
    /// are free once downloaded in Settings › Accessibility › Spoken Content.
    nonisolated static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = narrationLanguage()
        // A voice chosen under a different language would put the brief back in
        // the accent the language picker was used to get away from, so it only
        // counts while it still matches.
        if let identifier = Settings.shared.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier),
           voice.language == language {
            return voice
        }
        return availableVoices(for: language).first
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Languages offered in Settings: every language with a voice installed on
    /// the device, English first because that is what the brief is written in.
    nonisolated static func availableLanguages() -> [String] {
        Set(AVSpeechSynthesisVoice.speechVoices().map(\.language)).sorted { lhs, rhs in
            let lhsEnglish = lhs.hasPrefix(scriptLanguagePrefix)
            let rhsEnglish = rhs.hasPrefix(scriptLanguagePrefix)
            if lhsEnglish != rhsEnglish { return lhsEnglish }
            return languageLabel(for: lhs) < languageLabel(for: rhs)
        }
    }

    /// `en-GB` as "English (United Kingdom)", in the reader's own language.
    nonisolated static func languageLabel(for language: String) -> String {
        let identifier = language.replacingOccurrences(of: "-", with: "_")
        return Locale.current.localizedString(forIdentifier: identifier) ?? language
    }

    /// Voices offered in Settings, best quality first. Matched on the full tag,
    /// not just the two-letter prefix: the accent is the point of the choice.
    nonisolated static func availableVoices(
        for language: String = BriefNarrator.narrationLanguage()
    ) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
    }
}

extension BriefNarrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let line = utterance.speechString
        Task { @MainActor in
            self.spokenLine = line
            self.isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            // Only settled once the queue has actually drained.
            if !synthesizer.isSpeaking {
                self.isSpeaking = false
                self.spokenLine = nil
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.isSpeaking = false
            self.spokenLine = nil
        }
    }
}
