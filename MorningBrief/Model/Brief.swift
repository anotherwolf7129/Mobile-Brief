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
    /// "오전 9시 30분 ~ 오후 1시" — the 오전/오후 repeats on the trailing time only
    /// when the range crosses noon.
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
    /// "2026년 8월 4일 · 화요일"
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
            headline: "아직 하루를 읽지 않았어요.",
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
    /// "2026년 8월 4일 · 화요일"
    static func dayLine(for date: Date) -> String {
        let day = DateFormatter.cached("yyyy년 M월 d일").string(from: date)
        let weekday = DateFormatter.cached("EEEE").string(from: date)
        return "\(day) · \(weekday)"
    }

    /// "오전 9시 30분", or "9시 30분" when the 오전/오후 is carried by the other end
    /// of the range. Written out in full rather than as "9:30" because this same
    /// string is read aloud, and a Korean voice sounds out digits and colons
    /// inconsistently.
    static func time(_ date: Date, includeMeridiem: Bool) -> String {
        let calendar = Calendar.current
        let hour24 = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        var hour = hour24 % 12
        if hour == 0 { hour = 12 }
        let clock = minute == 0 ? "\(hour)시" : "\(hour)시 \(minute)분"
        guard includeMeridiem else { return clock }
        return (hour24 < 12 ? "오전 " : "오후 ") + clock
    }

    /// "오전 9시 30분 ~ 오후 1시" / "오전 9시 ~ 11시 30분" / "오후 3시 30분부터"
    static func range(from start: Date, to end: Date?) -> String {
        let calendar = Calendar.current
        guard let end else {
            return "\(time(start, includeMeridiem: true))부터"
        }
        // Korean puts 오전/오후 in front, so the leading time always carries it
        // and the trailing one repeats it only when the half of the day changes.
        let sameHalf = (calendar.component(.hour, from: start) < 12)
            == (calendar.component(.hour, from: end) < 12)
        let lead = time(start, includeMeridiem: true)
        let trail = time(end, includeMeridiem: !sameHalf)
        return "\(lead) ~ \(trail)"
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
        formatter.locale = .brief
        formatter.dateFormat = format
        cache[format] = formatter
        return formatter
    }
}
