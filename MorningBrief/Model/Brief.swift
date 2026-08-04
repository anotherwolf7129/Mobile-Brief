import Foundation

/// How loaded the day is, derived from the calendar alone.
/// Sets the headline's tone and the terrain's vertical scale.
enum DayShape: String, Codable {
    case heavy   // >= 5h in meetings, or a cluster of 3+ back-to-back
    case normal
    case open    // <= 1 short meeting

    var terrainScale: Double {
        switch self {
        case .heavy: return 1.0
        case .normal: return 0.62
        case .open: return 0.22
        }
    }
}

/// A supporting motif drawn above one act. At most one per act.
enum Motif: String, Codable {
    case sun            // open creative time
    case dawn           // pre-7:30 start (half-risen sun on a horizon)
    case moon           // late finish
    case birds          // room to breathe
    case flag           // deadline
    case ridge          // depth on heavy days
}

/// A meeting rendered as a dot on the terrain line.
struct MeetingDot: Codable, Identifiable {
    let id: String
    /// 0...1 across the drawn day (start of first act -> end of last).
    let position: Double
    /// Minutes long; drives radius (6...13pt).
    let weight: Int
    /// Optional / unanswered meetings are drawn grey and weightless.
    let isTentative: Bool
    /// Genuine overlap with another meeting: drawn as two hollow circles.
    let overlaps: Bool

    var radius: Double {
        guard !isTentative else { return 5 }
        return min(13, max(6, 6 + Double(weight) / 15.0))
    }
}

/// One of the three columns beneath the drawing.
struct Act: Codable, Identifiable {
    var id: String { range }
    /// "9:30 AM – 1 PM" — uppercase AM/PM on the trailing time, and on the
    /// leading time too when the range crosses noon.
    let range: String
    /// One sentence earned from the calendar. Never padded.
    let sentence: String
    let motif: Motif?
}

struct BriefItem: Codable, Identifiable {
    enum Kind: String, Codable {
        /// It would cost something to ignore until tomorrow.
        case needsAttention
        /// Closed recently and worth a glance.
        case resolved
    }

    let id: String
    /// <= 10 words.
    let title: String
    /// One sentence: the source in prose plus the substance.
    let sentence: String
    /// The phrase inside `sentence` that carries the link ("on your calendar").
    /// Plain text when `url` is nil.
    let sourcePhrase: String
    let url: URL?
    let kind: Kind
}

struct Brief: Codable {
    let generatedAt: Date
    /// "Monday · August 4 2026"
    let dayLine: String
    /// One serif line, spoken like a friend handing over the day.
    let headline: String
    let shape: DayShape
    let acts: [Act]
    let meetings: [MeetingDot]
    let needsAttention: [BriefItem]
    let resolved: [BriefItem]

    var isEmpty: Bool { needsAttention.isEmpty && resolved.isEmpty }

    /// Only the calendar was reachable — invite an inbox or reminders connection.
    let onlyCalendarConnected: Bool

    static func placeholder(now: Date = Date()) -> Brief {
        Brief(
            generatedAt: now,
            dayLine: DateFormatting.dayLine(for: now),
            headline: "Your day hasn't been read yet.",
            shape: .open,
            acts: [],
            meetings: [],
            needsAttention: [],
            resolved: [],
            onlyCalendarConnected: false
        )
    }
}

enum DateFormatting {
    /// "Monday · August 4 2026"
    static func dayLine(for date: Date) -> String {
        let weekday = DateFormatter.cached("EEEE").string(from: date)
        let month = DateFormatter.cached("MMMM").string(from: date)
        let day = Calendar.current.component(.day, from: date)
        let year = Calendar.current.component(.year, from: date)
        return "\(weekday) · \(month) \(day) \(year)"
    }

    /// "9:30 AM", or "1" when the meridiem is carried by the other end of the range.
    static func time(_ date: Date, includeMeridiem: Bool) -> String {
        let cal = Calendar.current
        let hour24 = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        var hour = hour24 % 12
        if hour == 0 { hour = 12 }
        var text = minute == 0 ? "\(hour)" : String(format: "%d:%02d", hour, minute)
        if includeMeridiem { text += hour24 < 12 ? " AM" : " PM" }
        return text
    }

    /// "9:30 AM – 1 PM" / "1 – 3:30 PM" / "3:30 PM onward"
    static func range(from start: Date, to end: Date?) -> String {
        let cal = Calendar.current
        guard let end else {
            return "\(time(start, includeMeridiem: true)) onward"
        }
        let crossesNoon = cal.component(.hour, from: start) < 12
            && cal.component(.hour, from: end) >= 12
        let lead = time(start, includeMeridiem: crossesNoon)
        let trail = time(end, includeMeridiem: true)
        return "\(lead) – \(trail)"
    }
}

extension DateFormatter {
    private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    static func cached(_ format: String) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[format] { return existing }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = .autoupdatingCurrent
        cache[format] = formatter
        return formatter
    }
}
