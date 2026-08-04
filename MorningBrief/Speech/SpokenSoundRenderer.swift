import Foundation
import AVFoundation
import os

/// Renders the brief to an audio file ahead of time, so a local notification can
/// *play the spoken brief as its own sound*.
///
/// This is what makes the readout work with no interaction and no Shortcut, even
/// when the app has been force-quit or the phone has been rebooted: iOS reads the
/// sound file out of the app container at delivery time and plays it. Two limits
/// come with that, and both are handled here:
///
/// - **30 seconds.** A longer sound is silently replaced with the default alert
///   tone, so the script is trimmed to fit before rendering.
/// - **`Library/Sounds/`.** The file has to live there, in the app container,
///   with a `.caf` / `.aiff` / `.wav` extension.
enum SpokenSoundRenderer {
    /// Notification sounds are capped at 30s; leave a margin for voice-rate drift.
    static let maximumDuration: TimeInterval = 29

    private static let log = Logger(subsystem: "com.morningbrief", category: "sound")

    /// Alternates so a freshly written file is never the one iOS has cached for
    /// an already-scheduled notification.
    static func nextFileName(current: String?) -> String {
        current == "brief-a.caf" ? "brief-b.caf" : "brief-a.caf"
    }

    static var soundsDirectory: URL? {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first else { return nil }
        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        return directory
    }

    /// Render `text` into `Library/Sounds/<fileName>` and return the name to hand
    /// to `UNNotificationSound`. Returns nil if speech synthesis produced nothing,
    /// in which case the caller should fall back to the default sound.
    @discardableResult
    static func render(text: String, fileName: String) async -> String? {
        guard let directory = soundsDirectory else { return nil }
        let url = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        // A single utterance — the write callback interleaves across queued ones.
        let utterance = BriefNarrator.utterance(for: text)
        utterance.postUtteranceDelay = 0

        let writer = OfflineWriter(url: url, limit: maximumDuration)
        let succeeded = await writer.write(utterance)

        guard succeeded else {
            log.error("Offline render produced no audio for \(fileName, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        log.info("Rendered spoken brief to \(fileName, privacy: .public)")
        return fileName
    }

    static func removeAll() {
        guard let directory = soundsDirectory else { return }
        for name in ["brief-a.caf", "brief-b.caf"] {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name)
            )
        }
    }
}

/// Drives `AVSpeechSynthesizer.write(_:toBufferCallback:)`, which renders speech
/// to PCM buffers instead of the speaker.
private final class OfflineWriter: NSObject, @unchecked Sendable {
    private let url: URL
    private let limit: TimeInterval
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()

    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var wroteAnything = false
    private var finished = false
    private var continuation: CheckedContinuation<Bool, Never>?

    init(url: URL, limit: TimeInterval) {
        self.url = url
        self.limit = limit
        super.init()
    }

    func write(_ utterance: AVSpeechUtterance) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            synthesizer.write(utterance) { [weak self] buffer in
                self?.handle(buffer)
            }
        }
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        // A zero-length buffer is how the synthesizer signals it is done.
        if pcm.frameLength == 0 {
            complete(success: wroteAnything)
            return
        }

        do {
            if file == nil {
                // Match the file's processing format to the buffer's exactly,
                // otherwise `write(from:)` throws on a format mismatch.
                file = try AVAudioFile(
                    forWriting: url,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            }
            guard let file else { return }

            let maximumFrames = AVAudioFramePosition(limit * pcm.format.sampleRate)
            let remaining = maximumFrames - framesWritten
            if remaining <= 0 {
                // Budget spent. Stop here rather than let iOS drop the whole
                // sound for being over 30 seconds.
                complete(success: wroteAnything)
                return
            }

            if AVAudioFramePosition(pcm.frameLength) > remaining {
                pcm.frameLength = AVAudioFrameCount(remaining)
            }
            try file.write(from: pcm)
            framesWritten += AVAudioFramePosition(pcm.frameLength)
            wroteAnything = true
        } catch {
            complete(success: false)
        }
    }

    /// Must be called with `lock` held.
    private func complete(success: Bool) {
        finished = true
        file = nil  // closes and finalizes the file
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: success)
    }
}
