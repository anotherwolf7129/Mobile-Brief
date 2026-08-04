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
                    ? "캘린더에 아무것도 없어요."
                    : "계속 비어 있어요."
            }
            let longest = longestGap(in: allEvents)
            if index == 1, let longest, longest >= 90 {
                return "하루 중 가장 길게 비어 있는 구간이에요."
            }
            return index == 2 ? "마지막 일정 뒤로는 비어 있어요." : "이 구간에는 일정이 없어요."
        }

        let minutes = confirmed.reduce(0) { $0 + $1.durationMinutes }
        let names = confirmed.map(\.title)

        if confirmed.count == 1 {
            let event = confirmed[0]
            let length = KoreanDuration.spelled(minutes: event.durationMinutes)
            return "\(length)짜리 일정 하나 — \(spokenTitle(event.title, fallback: "제목 없는 일정"))."
        }

        if longestCluster(confirmed) >= 3 {
            let last = spokenTitle(names.last, fallback: "마지막 일정")
            return "\(confirmed.count)개가 연달아 이어지고, 끝은 \(last.josa(.copula))."
        }

        let load = KoreanDuration.spelled(minutes: minutes)
        let first = spokenTitle(names.first, fallback: "첫 일정")
        return "일정 \(confirmed.count)개, 합쳐서 \(load)이고 \(first.josa(.by)) 시작해요."
    }

    /// A blank title would leave a particle attached to nothing, so a sentence
    /// that leans on a title names something either way.
    private func spokenTitle(_ title: String?, fallback: String) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return fallback
        }
        return title
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
            return "아직 아무것도 연결되지 않았어요."
        }
        // Korean puts the name at the front rather than after the clause.
        let name = displayName.isEmpty ? "" : "\(displayName)님, "

        // Something distinct: the user is running something today.
        if let owned = events.first(where: { $0.isOrganizer && $0.attendeeCount > 1 }) {
            let title = spokenTitle(owned.title, fallback: "직접 잡은 일정")
            return "\(name)오늘은 \(title.josa(.object)) 직접 진행하는 날이고, 나머지는 그 일을 중심으로 움직여요."
        }

        switch shape {
        case .heavy:
            if let lastMorning = events.last(where: {
                Calendar.current.component(.hour, from: $0.end) <= 14
            }), events.last?.id != lastMorning.id {
                let time = DateFormatting.time(lastMorning.end, includeMeridiem: true)
                return "\(name)\(time)까지 쉼 없이 이어지고, 그 뒤로 하루가 열려요."
            }
            return "\(name)일정이 하루를 가득 채우는 날이에요."
        case .normal:
            let hasEarly = events.first.map {
                Calendar.current.component(.hour, from: $0.start) < 11
            } ?? false
            let hasLate = events.last.map {
                Calendar.current.component(.hour, from: $0.start) >= 15
            } ?? false
            if hasEarly && hasLate {
                return "\(name)일정이 하루의 앞뒤를 잡아 주고, 가운데는 비어 있어요."
            }
            return "\(name)무리 없는 하루예요. 일정 사이에 생각할 틈이 있어요."
        case .open:
            return "\(name)하루가 온전히 비어 있어요. 미뤄 둔 일을 할 수 있는 날이에요."
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
                when = days <= 1 ? "어제까지였어요" : "\(days)일째 열려 있어요"
            } else {
                when = "오늘까지예요"
            }
            let list = "\(reminder.listName) 목록"
            items.append(BriefItem(
                id: "due-\(reminder.id)",
                title: reminder.title.clipped(toCharacters: 24),
                sentence: "\(list)에 있고, \(when)\(reminder.notes.map { " — \($0.firstSentence)" } ?? ".")",
                sourcePhrase: list,
                url: reminder.url,
                kind: .needsAttention
            ))
        }

        // Prep: something tomorrow that goes better if read, decided, or drafted today.
        for event in context.tomorrowEvents.prefix(4) where !event.isTentative {
            guard let prep = prepSentence(for: event) else { continue }
            items.append(BriefItem(
                id: "prep-\(event.id)",
                title: "준비: \(event.title.clipped(toCharacters: 20))",
                sentence: prep,
                sourcePhrase: "캘린더",
                url: event.url,
                kind: .needsAttention
            ))
        }

        // Tomorrow's due reminders, as prep rather than as asks.
        for reminder in context.dueReminders {
            guard let due = reminder.due,
                  calendar.isDate(due, inSameDayAs: now.addingTimeInterval(86_400))
            else { continue }
            let list = "\(reminder.listName) 목록"
            items.append(BriefItem(
                id: "prep-\(reminder.id)",
                title: reminder.title.clipped(toCharacters: 24),
                sentence: "\(list)에 있고 내일까지예요 — 오늘 시작해 두면 한 번 틀릴 여유가 남아요.",
                sourcePhrase: list,
                url: reminder.url,
                kind: .needsAttention
            ))
        }

        return Array(items.prefix(6))
    }

    /// A prep item needs a concrete anchor: an agenda to open with, a doc to
    /// skim, a decision that will be asked for. No anchor, no item.
    /// Every sentence here has to contain the word "캘린더", because that is the
    /// source phrase the item links from.
    private func prepSentence(for event: CalendarEvent) -> String? {
        let day = Calendar.current.isDateInTomorrow(event.start) ? "내일" : "곧"
        // "오전 9시로", but "오전 9시 30분으로".
        let when = "\(day) \(DateFormatting.time(event.start, includeMeridiem: true).josa(.by))"

        if event.isOrganizer && event.attendeeCount > 1 {
            return "캘린더에 \(when) 올라와 있고 진행을 맡았어요 — 준비는 처음에 펼칠 안건이에요."
        }
        let lowered = event.title.lowercased()
        let koreanCues = ["회고", "리뷰", "면담", "원온원", "일대일"]
        if lowered.contains("retro") || lowered.contains("review") || lowered.contains("1:1")
            || koreanCues.contains(where: { event.title.contains($0) }) {
            return "캘린더에 \(when) 올라와 있어요 — 생각 두세 개를 들고 들어가면 그 자리에서 만들지 않아도 돼요."
        }
        if let notes = event.notes, !notes.isEmpty {
            return "캘린더에 \(when) 올라와 있고 메모가 붙어 있어요 — 오늘 훑어 두면 맥락이 미리 잡혀요."
        }
        if event.url != nil {
            return "캘린더에 \(when) 올라와 있고 문서가 걸려 있어요 — 먼저 읽는 것이 준비의 대부분이에요."
        }
        return nil
    }

    /// Things that closed recently and are worth a glance.
    private func resolved(_ context: GatheredContext) -> [BriefItem] {
        var items: [BriefItem] = []

        for reminder in context.recentlyCompleted.prefix(4) {
            let when = reminder.completedAt.map { completed -> String in
                Calendar.current.isDateInToday(completed) ? "오늘" : "어제"
            } ?? "최근에"
            let list = "\(reminder.listName) 목록"
            items.append(BriefItem(
                id: "done-\(reminder.id)",
                title: reminder.title.clipped(toCharacters: 24),
                sentence: "\(list)에서 \(when) 닫혔어요 — 남은 건 없어요.",
                sourcePhrase: list,
                url: reminder.url,
                kind: .resolved
            ))
        }

        for event in context.todayEvents where event.isCanceled {
            let time = DateFormatting.time(event.start, includeMeridiem: true)
            let freed = KoreanDuration.spelled(minutes: event.durationMinutes)
            items.append(BriefItem(
                id: "cancel-\(event.id)",
                title: event.title.clipped(toCharacters: 24),
                sentence: "캘린더에서 주최자가 취소했고, \(time)의 \(freed)이 비었어요.",
                sourcePhrase: "캘린더",
                url: event.url,
                kind: .resolved
            ))
        }

        return Array(items.prefix(5))
    }
}

// MARK: - Small text helpers

extension String {
    /// The first sentence, without a trailing space.
    var firstSentence: String {
        let terminators: Set<Character> = [".", "!", "?", "。", "\n"]
        if let index = firstIndex(where: { terminators.contains($0) }) {
            return String(self[..<index]).trimmingCharacters(in: .whitespaces)
        }
        return trimmingCharacters(in: .whitespaces)
    }

    /// Item titles are capped by character count rather than by word: Korean
    /// packs far more into a word than English does, and plenty of Korean
    /// titles have no spaces to count at all.
    func clipped(toCharacters limit: Int) -> String {
        guard count > limit else { return self }
        return prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}
