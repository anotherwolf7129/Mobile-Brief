import Foundation

/// Turns a `Brief` into something that sounds right read aloud.
///
/// Two lengths, for two different delivery paths:
/// - `full` is the whole brief, spoken when the app is alive at the set time
///   (or when the notification is tapped).
/// - `teaser` is trimmed to fit inside a notification sound, which iOS caps at
///   30 seconds. It has to stand on its own — most mornings it's all that plays.
struct BriefScript {
    let brief: Brief

    /// Rough words-per-second for AVSpeechSynthesizer at rate 0.5.
    private static let wordsPerSecond = 2.6

    /// The whole brief.
    var full: String {
        var lines: [String] = []
        lines.append("\(greeting). \(spokenDayLine).")
        lines.append(spoken(brief.headline))

        for act in brief.acts where !act.sentence.isEmpty {
            lines.append("\(spokenRange(act.range)). \(spoken(act.sentence))")
        }

        if brief.needsAttention.isEmpty && brief.resolved.isEmpty {
            lines.append("Nothing needs you this morning.")
        }

        if !brief.needsAttention.isEmpty {
            let count = brief.needsAttention.count
            let noun = count == 1 ? "thing needs" : "things need"
            lines.append("\(count.spelledOut.capitalizedFirst) \(noun) you today.")
            for (index, item) in brief.needsAttention.enumerated() {
                lines.append("\(ordinal(index + 1)). \(spoken(item.title)). \(spoken(item.sentence))")
            }
        }

        if !brief.resolved.isEmpty {
            lines.append("Already sorted:")
            for item in brief.resolved {
                lines.append("\(spoken(item.title)). \(spoken(item.sentence))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// A version that fits in a 30-second notification sound. Trimmed by
    /// dropping detail from the bottom up, never by cutting a sentence in half.
    var teaser: String {
        var lines = ["\(greeting). \(spoken(brief.headline))"]

        if brief.needsAttention.isEmpty {
            lines.append("Nothing needs you this morning.")
            return lines.joined(separator: " ")
        }

        let count = brief.needsAttention.count
        let noun = count == 1 ? "thing needs" : "things need"
        lines.append("\(count.spelledOut.capitalizedFirst) \(noun) you.")

        // Add titles while they still fit inside the budget.
        for item in brief.needsAttention {
            let candidate = lines + [spoken(item.title) + "."]
            if Self.estimatedSeconds(of: candidate.joined(separator: " ")) > 26 { break }
            lines = candidate
        }
        return lines.joined(separator: " ")
    }

    static func estimatedSeconds(of text: String) -> Double {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return Double(words) / wordsPerSecond
    }

    // MARK: - Making text speakable

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: brief.generatedAt)
        let name = Settings.shared.displayName.trimmingCharacters(in: .whitespaces)
        let salutation: String
        switch hour {
        case 0..<12: salutation = "Good morning"
        case 12..<18: salutation = "Good afternoon"
        default: salutation = "Good evening"
        }
        return name.isEmpty ? salutation : "\(salutation), \(name)"
    }

    /// "Monday · August 4 2026" reads badly; "Monday, August fourth" reads well.
    private var spokenDayLine: String {
        let weekday = DateFormatter.cached("EEEE").string(from: brief.generatedAt)
        let month = DateFormatter.cached("MMMM").string(from: brief.generatedAt)
        let day = Calendar.current.component(.day, from: brief.generatedAt)
        return "\(weekday), \(month) \(ordinal(day))"
    }

    /// Strip the typographic characters that the synthesizer stumbles over.
    private func spoken(_ text: String) -> String {
        text
            .replacingOccurrences(of: "·", with: ",")
            .replacingOccurrences(of: "—", with: " — ")
            .replacingOccurrences(of: "–", with: " to ")
            .replacingOccurrences(of: "…", with: ".")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "9:30 AM – 1 PM" -> "From nine thirty A M to one P M"
    private func spokenRange(_ range: String) -> String {
        "From " + range
            .replacingOccurrences(of: "–", with: "to")
            .replacingOccurrences(of: "AM", with: "A M")
            .replacingOccurrences(of: "PM", with: "P M")
    }

    private func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
