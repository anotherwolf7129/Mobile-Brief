import Foundation
import AVFoundation
import os

/// Keeps the app running in the background so a timer can fire at the set time
/// and speak the whole brief with no interaction.
///
/// This is the alarm-clock pattern: with `UIBackgroundModes: audio` declared and
/// an active audio session playing, iOS does not suspend the process. The looped
/// audio is near-silent rather than actually silent — a digitally-silent buffer
/// can get the session torn down.
///
/// Trade-offs, stated plainly:
/// - Survives backgrounding and lock. Does **not** survive a force-quit or a
///   reboot; the notification tier below is what covers those.
/// - Costs battery. That is why it is behind an explicit setting.
@MainActor
final class AudioKeepAlive {
    static let shared = AudioKeepAlive()

    private var player: AVAudioPlayer?
    private let log = Logger(subsystem: "com.morningbrief", category: "keepalive")

    var isRunning: Bool { player?.isPlaying ?? false }

    private init() {}

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)

            let url = try Self.nearSilentLoopURL()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.005
            player.prepareToPlay()
            player.play()
            self.player = player
            log.info("Keep-alive session started")
        } catch {
            log.error("Keep-alive failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("Keep-alive session stopped")
    }

    /// Raise the session for the duration of a readout, so the brief is audible
    /// even though the keep-alive loop underneath it is not.
    func activateForSpeech() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    // MARK: - The looped file

    /// One second of a 60 Hz tone at an amplitude far below audibility, written
    /// once into Caches. Loud enough that the session stays up, quiet enough
    /// that nobody hears it.
    private static func nearSilentLoopURL() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("keepalive.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44_100
        let frames = sampleRate
        let amplitude = 24.0  // out of 32767

        var samples = [Int16]()
        samples.reserveCapacity(frames)
        for frame in 0..<frames {
            let phase = 2.0 * Double.pi * 60.0 * Double(frame) / Double(sampleRate)
            samples.append(Int16(amplitude * sin(phase)))
        }

        var data = Data()
        let byteCount = samples.count * 2

        func appendASCII(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }
        func appendUInt16(_ value: UInt16) { data.append(contentsOf: withUnsafeBytes(of: value.littleEndian, Array.init)) }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + byteCount))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)                                  // PCM header size
        appendUInt16(1)                                   // PCM
        appendUInt16(1)                                   // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))              // byte rate
        appendUInt16(2)                                   // block align
        appendUInt16(16)                                  // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(byteCount))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

        try data.write(to: url, options: .atomic)
        return url
    }
}
