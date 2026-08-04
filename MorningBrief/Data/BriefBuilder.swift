import Foundation

/// Turns gathered device data into a `Brief`: classifies the day, draws the
/// three acts, and sorts every candidate into Needs attention, Resolved, or
/// nothing at all.
///
/// This is the deterministic writer. `ClaudeBriefWriter` can polish the prose
/// afterwards, but the structure and every fact come from here — so the brief
/// works with no network and no API key.
struct BriefBuilder {
    let now: Date
    let displayName: String

    init(now: Date = Date(), displayName: String = "") {
        self.now = now
        self.displayName = displayName.trimmingCharacters(in: .whitespaces)
    }

    func build(from context: GatheredContext) -> Brief {
        let drawn = context.todayEvents.filter { !$0.isCanceled && !$0.isAllDay }
        let shape = classify(drawn)
        let window = dayWindow(for: drawn)
        let acts = buildActs(drawn, window: window, context: context)
        let meetings = buildDots(drawn, window: window)

        return Brief(
            generatedAt: now,
            dayLine: DateFormatting.dayLine(for: now),
            headline: headline(shape: shape, events: drawn, context: context),
            shape: shape,
            acts: acts,
            meetings: meetings,
            needsAttention: needsAttention(context),
            resolved: resolved(context),
            onlyCalendarConnected: context.onlyCalendarConnected
        )
    }

    // MARK: - Classify the day (calendar alone)

    func classify(_ events: [CalendarEvent]) -> DayShape {
        let confirmed = events.filter { !$0.isTentative }
        let totalMinutes = confirmed.reduce(0) { $0 + $1.durationMinutes }
        if totalMinutes >= 300 || longestCluster(confirmed) >= 3 { return .heavy }
        if confirmed.count <= 1 && totalMinutes <= 60 { return .open }
        return .normal
    }

    /// The most meetings running back-to-back (gaps under 15 minutes).
    private func longestCluster(_ events: [CalendarEvent]) -> Int {
        guard !events.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for (previous, next) in zip(events, events.dropFirst()) {
            let gap = next.start.timeIntervalSince(previous.end) / 60
            if gap < 15 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    // MARK: - Day window and acts

    private func dayWindow(for events: [CalendarEvent]) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        let defaultStart = calendar.date(byAdding: .hour, value: 9, to: midnight) ?? now
        let defaultEnd = calendar.date(byAdding: .hour, value: 18, to: midnight) ?? now

        let earliest = events.map(\.start).min()
        let latest = events.map(\.end).max()
        return (
            start: min(earliest ?? defaultStart, defaultStart),
            end: max(latest ?? defaultEnd, defaultEnd)
        )
    }

    private func buildActs(
        _ events: [CalendarEvent],
        window: (start: Date, end: Date),
        context: GatheredContext
    ) -> [Act] {
        guard context.calendarAuthorized else { return [] }

        let span = window.end.timeIntervalSince(window.start)
        guard span > 0 else { return [] }

        // Three equal slices, then snapped outward to the nearest meeting
        // boundary so no meeting is cut in half across two columns.
        let rawBoundaries = [
            window.start,
            window.start.addingTimeInterval(span / 3),
            window.start.addingTimeInterval(span * 2 / 3),
            window.end,
        ]
        let boundaries = rawBoundaries.enumerated().map { index, date -> Date in
            guard index == 1 || index == 2 else { return date }
            return snap(date, to: events) ?? date
        }

        return (0..<3).map { index in
            let start = boundaries[index]
            let end = index == 2 ? nil : boundaries[index + 1]
            let slice = events.filter { event in
                event.start >= start && (end == nil || event.start < end!)
            }
            return Act(
                range: DateFormatting.range(from: start, to: end),
                sentence: actSentence(for: slice, index: index, allEvents: events),
                motif: motif(for: slice, index: index, allEvents: events, context: context)
            )
        }
    }

    /// Move a boundary to the nearest gap between meetings, within 45 minutes.
    private func snap(_ date: Date, to events: [CalendarEvent]) -> Date? {
        let candidates = events.flatMap { [$0.start, $0.end] }
        return candidates
            .filter { abs($0.timeIntervalSince(date)) <= 45 * 60 }
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    /// One sentence, specific to what is actually on the calendar in this slice.
    private func actSentence(
        for slice: [CalendarEvent],
        index: Int,
        allEvents: [CalendarEvent]
    ) -> String {
        let confirmed = slice.filter { !$0.isTentative }

        if confirmed.isEmpty {
            if allEvents.isEmpty {
                return index == 0
                    ? "Nothing on the calendar."
                    : "Still clear."
            }
            let longest = longestGap(in: allEvents)
            if index == 1, let longest, longest >= 90 {
                return "The longest open stretch of the day."
            }
            return index == 2 ? "Clear after the last meeting." : "No meetings in here."
        }

        let minutes = confirmed.reduce(0) { $0 + $1.durationMinutes }
        let names = confirmed.map(\.title)

        if confirmed.count == 1 {
            let event = confirmed[0]
            let length = event.durationMinutes >= 60
                ? "\(event.durationMinutes / 60)-hour"
                : "\(event.durationMinutes)-minute"
            return "One \(length) block: \(event.title)."
        }

        if longestCluster(confirmed) >= 3 {
            return "\(confirmed.count.spelledOut.capitalizedFirst) back to back, ending with \(names.last ?? "the last one")."
        }

        let hours = Double(minutes) / 60
        let load = hours >= 2
            ? String(format: "%.1f hours", hours).replacingOccurrences(of: ".0", with: "")
            : "\(minutes) minutes"
        return "\(confirmed.count.spelledOut.capitalizedFirst) meetings, \(load) in total — \(names.first ?? "") opens it."
    }

    private func longestGap(in events: [CalendarEvent]) -> Int? {
        guard events.count >= 2 else { return nil }
        return zip(events, events.dropFirst())
            .map { Int($1.start.timeIntervalSince($0.end) / 60) }
            .max()
    }

    /// At most one motif per act.
    private func motif(
        for slice: [CalendarEvent],
        index: Int,
        allEvents: [CalendarEvent],
        context: GatheredContext
    ) -> Motif? {
        let calendar = Calendar.current

        if index == 0, let first = allEvents.first {
            let hour = calendar.component(.hour, from: first.start)
            let minute = calendar.component(.minute, from: first.start)
            if hour < 7 || (hour == 7 && minute < 30) { return .dawn }
        }

        if index == 1 && slice.isEmpty && !allEvents.isEmpty { return .sun }

        if index == 2 {
            if let last = allEvents.last,
               calendar.component(.hour, from: last.end) >= 19 { return .moon }
            if slice.isEmpty && !allEvents.isEmpty { return .birds }
            if context.dueReminders.contains(where: { reminder in
                guard let due = reminder.due else { return false }
                return calendar.isDate(due, inSameDayAs: now)
            }) { return .flag }
        }

        if index == 1 && classify(allEvents) == .heavy { return .ridge }
        return nil
    }

    // MARK: - Terrain dots

    private func buildDots(
        _ events: [CalendarEvent],
        window: (start: Date, end: Date)
    ) -> [MeetingDot] {
        let span = window.end.timeIntervalSince(window.start)
        guard span > 0 else { return [] }

        return events.map { event in
            let overlaps = events.contains { other in
                other.id != event.id
                    && other.start < event.end
                    && event.start < other.end
            }
            let position = event.start.timeIntervalSince(window.start) / span
            return MeetingDot(
                id: event.id,
                position: min(0.97, max(0.03, position)),
                weight: event.durationMinutes,
                isTentative: event.isTentative,
                overlaps: overlaps
            )
        }
    }

    // MARK: - Headline

    /// One line. If a single thing genuinely makes today distinct, name that.
    /// Otherwise name the shape. Never both.
    private func headline(
        shape: DayShape,
        events: [CalendarEvent],
        context: GatheredContext
    ) -> String {
        guard context.calendarAuthorized || context.remindersAuthorized else {
            return "Nothing is connected yet."
        }
        let name = displayName.isEmpty ? "" : ", \(displayName)"

        // Something distinct: the user is running something today.
        if let owned = events.first(where: { $0.isOrganizer && $0.attendeeCount > 1 }) {
            return "You're running \(owned.title)\(name) — the rest of the day bends around it."
        }

        switch shape {
        case .heavy:
            if let lastMorning = events.last(where: {
                Calendar.current.component(.hour, from: $0.end) <= 14
            }), events.last?.id != lastMorning.id {
                let time = DateFormatting.time(lastMorning.end, includeMeridiem: false)
                return "A steady climb until \(time)\(name), then the day opens up."
            }
            return "A full day of meetings\(name) — pace yourself through it."
        case .normal:
            let hasEarly = events.first.map {
                Calendar.current.component(.hour, from: $0.start) < 11
            } ?? false
            let hasLate = events.last.map {
                Calendar.current.component(.hour, from: $0.start) >= 15
            } ?? false
            if hasEarly && hasLate {
                return "Meetings bookend the day\(name) — the middle is yours."
            }
            return "A manageable shape today\(name), with room to think between things."
        case .open:
            return "The whole day is yours\(name). Use it on the thing that's been waiting."
        }
    }

    // MARK: - Sort into two lists

    /// It would cost something to ignore until tomorrow: a window closes today,
    /// or tomorrow goes better if something is read or decided now.
    private func needsAttention(_ context: GatheredContext) -> [BriefItem] {
        let calendar = Calendar.current
        var items: [BriefItem] = []

        // Reminders that are overdue or due today.
        for reminder in context.dueReminders {
            guard let due = reminder.due else { continue }
            guard due < calendar.startOfDay(for: now).addingTimeInterval(86_400) else { continue }
            let when: String
            if due < calendar.startOfDay(for: now) {
                let days = calendar.dateComponents([.day], from: due, to: now).day ?? 1
                when = days <= 1 ? "was due yesterday" : "has been open \(days) days"
            } else {
                when = "is due today"
            }
            items.append(BriefItem(
                id: "due-\(reminder.id)",
                title: reminder.title.clipped(toWords: 10),
                sentence: "In \(reminder.listName), this \(when)\(reminder.notes.map { " — \($0.firstSentence)" } ?? ".")",
                sourcePhrase: "In \(reminder.listName)",
                url: reminder.url,
                kind: .needsAttention
            ))
        }

        // Prep: something tomorrow that goes better if read, decided, or drafted today.
        for event in context.tomorrowEvents.prefix(4) where !event.isTentative {
            guard let prep = prepSentence(for: event) else { continue }
            items.append(BriefItem(
                id: "prep-\(event.id)",
                title: "Prep: \(event.title.clipped(toWords: 8))",
                sentence: prep,
                sourcePhrase: "on your calendar",
                url: event.url,
                kind: .needsAttention
            ))
        }

        // Tomorrow's due reminders, as prep rather than as asks.
        for reminder in context.dueReminders {
            guard let due = reminder.due,
                  calendar.isDate(due, inSameDayAs: now.addingTimeInterval(86_400))
            else { continue }
            items.append(BriefItem(
                id: "prep-\(reminder.id)",
                title: reminder.title.clipped(toWords: 10),
                sentence: "In \(reminder.listName), due tomorrow — starting it today leaves room to get it wrong once.",
                sourcePhrase: "In \(reminder.listName)",
                url: reminder.url,
                kind: .needsAttention
            ))
        }

        return Array(items.prefix(6))
    }

    /// A prep item needs a concrete anchor: an agenda to open with, a doc to
    /// skim, a decision that will be asked for. No anchor, no item.
    private func prepSentence(for event: CalendarEvent) -> String? {
        let day = Calendar.current.isDateInTomorrow(event.start) ? "tomorrow" : "soon"
        let time = DateFormatting.time(event.start, includeMeridiem: true)

        if event.isOrganizer && event.attendeeCount > 1 {
            return "You're the organizer for \(time) \(day) — the prep is the agenda you'll open with."
        }
        let lowered = event.title.lowercased()
        if lowered.contains("retro") || lowered.contains("review") || lowered.contains("1:1") {
            return "At \(time) \(day) — arrive holding two or three thoughts rather than forming them in the room."
        }
        if let notes = event.notes, !notes.isEmpty {
            return "At \(time) \(day), with notes attached — skim them tonight so the context is already loaded."
        }
        if event.url != nil {
            return "At \(time) \(day), with a doc linked — reading it first is most of the prep."
        }
        return nil
    }

    /// Things that closed recently and are worth a glance.
    private func resolved(_ context: GatheredContext) -> [BriefItem] {
        var items: [BriefItem] = []

        for reminder in context.recentlyCompleted.prefix(4) {
            let when = reminder.completedAt.map { completed -> String in
                Calendar.current.isDateInToday(completed) ? "earlier today" : "yesterday"
            } ?? "recently"
            items.append(BriefItem(
                id: "done-\(reminder.id)",
                title: reminder.title.clipped(toWords: 10),
                sentence: "Closed \(when) in \(reminder.listName) — nothing left on it.",
                sourcePhrase: "in \(reminder.listName)",
                url: reminder.url,
                kind: .resolved
            ))
        }

        for event in context.todayEvents where event.isCanceled {
            items.append(BriefItem(
                id: "cancel-\(event.id)",
                title: event.title.clipped(toWords: 10),
                sentence: "Cancelled by the organizer, freeing \(event.durationMinutes) minutes at \(DateFormatting.time(event.start, includeMeridiem: true)).",
                sourcePhrase: "on your calendar",
                url: event.url,
                kind: .resolved
            ))
        }

        return Array(items.prefix(5))
    }
}

// MARK: - Small text helpers

extension Int {
    var spelledOut: String {
        let words = ["zero", "one", "two", "three", "four", "five",
                     "six", "seven", "eight", "nine", "ten"]
        return self >= 0 && self < words.count ? words[self] : "\(self)"
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    /// The first sentence, without a trailing space.
    var firstSentence: String {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        if let index = firstIndex(where: { terminators.contains($0) }) {
            return String(self[..<index]).trimmingCharacters(in: .whitespaces)
        }
        return trimmingCharacters(in: .whitespaces)
    }

    /// Item titles cap at 10 words.
    func clipped(toWords limit: Int) -> String {
        let words = split(separator: " ")
        guard words.count > limit else { return self }
        return words.prefix(limit).joined(separator: " ") + "…"
    }
}
