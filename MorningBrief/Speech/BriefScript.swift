import Foundation

/// Turns a `Brief` into something that sounds right read aloud in Korean.
///
/// Only the first section is spoken — the greeting, the day, the headline, and
/// the three time blocks. What needs attention and what is already sorted are
/// things to look at: they carry titles, links, and list names that a voice
/// turns into a wall of sound, so they arrive as a notification the reader taps
/// instead of being read out.
///
/// Two lengths, for two different delivery paths:
/// - `spoken` is the whole first section, read when the app is alive at the set
///   time (or when the notification is tapped).
/// - `teaser` is trimmed to fit inside a notification sound, which iOS caps at
///   30 seconds. It has to stand on its own — most mornings it's all that plays.
struct BriefScript {
    let brief: Brief

    /// Rough syllables-per-second for a Korean voice at rate 0.5. Counted in
    /// characters rather than words: Korean words are long and the spacing is
    /// nothing like English, so words are a poor proxy for duration.
    private static let charactersPerSecond = 5.5

    /// The time blocks, and nothing below them.
    var spoken: String {
        var lines = ["\(greeting). \(spokenDayLine)."]
        lines.append(spoken(brief.headline))

        for act in brief.acts where !act.sentence.isEmpty {
            lines.append("\(spokenRange(act.range)), \(spoken(act.sentence))")
        }

        return lines.joined(separator: "\n")
    }

    /// A version that fits in a 30-second notification sound. Trimmed by
    /// dropping time blocks from the bottom up, never by cutting a sentence in
    /// half.
    var teaser: String {
        var lines = ["\(greeting). \(spoken(brief.headline))"]

        for act in brief.acts where !act.sentence.isEmpty {
            let candidate = lines + ["\(spokenRange(act.range)), \(spoken(act.sentence))"]
            if Self.estimatedSeconds(of: candidate.joined(separator: " ")) > 26 { break }
            lines = candidate
        }
        return lines.joined(separator: " ")
    }

    static func estimatedSeconds(of text: String) -> Double {
        let characters = text.filter { !$0.isWhitespace }.count
        return Double(characters) / charactersPerSecond
    }

    // MARK: - Making text speakable

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: brief.generatedAt)
        let name = Settings.shared.displayName.trimmingCharacters(in: .whitespaces)
        let salutation: String
        switch hour {
        case 0..<12: salutation = "좋은 아침이에요"
        case 12..<18: salutation = "좋은 오후예요"
        default: salutation = "좋은 저녁이에요"
        }
        return name.isEmpty ? salutation : "\(name)님, \(salutation)"
    }

    /// The year adds nothing out loud, so only the month, the day, and the
    /// weekday are spoken: "8월 4일 화요일이에요".
    private var spokenDayLine: String {
        let month = Calendar.current.component(.month, from: brief.generatedAt)
        let day = Calendar.current.component(.day, from: brief.generatedAt)
        let weekday = DateFormatter.cached("EEEE").string(from: brief.generatedAt)
        return "\(month)월 \(day)일 \(weekday.josa(.copula))"
    }

    /// Strip the typographic characters that the synthesizer stumbles over. The
    /// dashes the brief writes for rhythm on the page become the comma a voice
    /// can actually pause on.
    private func spoken(_ text: String) -> String {
        text
            .replacingOccurrences(of: "—", with: ",")
            .replacingOccurrences(of: "–", with: ",")
            .replacingOccurrences(of: "·", with: ",")
            .replacingOccurrences(of: "…", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "오전 9시 30분 ~ 오후 1시" -> "오전 9시 30분부터 오후 1시까지".
    /// A voice reads "~" as its own word, or skips it, so it never survives to
    /// the synthesizer.
    private func spokenRange(_ range: String) -> String {
        let halves = range.components(separatedBy: " ~ ")
        guard halves.count == 2 else { return range }
        return "\(halves[0])부터 \(halves[1])까지"
    }
}
