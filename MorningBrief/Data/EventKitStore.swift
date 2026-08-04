import Foundation
import EventKit

/// A calendar event, flattened into a value type so it can cross actor
/// boundaries (`EKEvent` is a mutable reference type and not `Sendable`).
struct CalendarEvent: Sendable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// The user organizes this one — the prep is the agenda they'll open with.
    let isOrganizer: Bool
    /// Not yet accepted, or explicitly tentative: drawn grey and weightless.
    let isTentative: Bool
    /// Cancelled by the organizer — never drawn, but earns a Resolved line.
    let isCanceled: Bool
    let attendeeCount: Int
    let notes: String?
    let location: String?
    let url: URL?

    var durationMinutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
}

/// A reminder, flattened for the same reason.
struct ReminderItem: Sendable, Identifiable {
    let id: String
    let title: String
    let due: Date?
    let notes: String?
    let listName: String
    let priority: Int
    let isCompleted: Bool
    let completedAt: Date?
    let url: URL?
}

struct GatheredContext: Sendable {
    var todayEvents: [CalendarEvent] = []
    var tomorrowEvents: [CalendarEvent] = []
    var dueReminders: [ReminderItem] = []
    var recentlyCompleted: [ReminderItem] = []
    var calendarAuthorized = false
    var remindersAuthorized = false

    var nothingConnected: Bool { !calendarAuthorized && !remindersAuthorized }
    var onlyCalendarConnected: Bool { calendarAuthorized && !remindersAuthorized }
}

/// Reads Calendar and Reminders. Everything the brief says is anchored to a
/// real result from here — nothing is invented.
actor EventKitStore {
    private let store = EKEventStore()

    func requestAccess() async -> (calendar: Bool, reminders: Bool) {
        let calendar = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        let reminders = await withCheckedContinuation { continuation in
            store.requestFullAccessToReminders { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        return (calendar, reminders)
    }

    func gather(now: Date = Date()) async -> GatheredContext {
        var context = GatheredContext()
        context.calendarAuthorized =
            EKEventStore.authorizationStatus(for: .event) == .fullAccess
        context.remindersAuthorized =
            EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let endOfTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday)
        else { return context }

        if context.calendarAuthorized {
            // One fetch: today 00:00 -> tomorrow 24:00 in the home timezone.
            let predicate = store.predicateForEvents(
                withStart: startOfToday,
                end: endOfTomorrow,
                calendars: nil
            )
            let events = store.events(matching: predicate)
                .compactMap(Self.flatten)
                .sorted { $0.start < $1.start }

            context.todayEvents = events.filter { $0.start < startOfTomorrow }
            context.tomorrowEvents = events.filter { $0.start >= startOfTomorrow }
        }

        if context.remindersAuthorized {
            // Due through end of tomorrow: today's are asks, tomorrow's are prep.
            let duePredicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: endOfTomorrow,
                calendars: nil
            )
            context.dueReminders = await fetch(matching: duePredicate)
                .compactMap(Self.flatten)
                .sorted { lhs, rhs in
                    let l = lhs.due ?? .distantFuture
                    let r = rhs.due ?? .distantFuture
                    if l == r { return lhs.priority < rhs.priority }
                    return l < r
                }

            if let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: startOfToday) {
                let completedPredicate = store.predicateForCompletedReminders(
                    withCompletionDateStarting: twoDaysAgo,
                    ending: now,
                    calendars: nil
                )
                context.recentlyCompleted = await fetch(matching: completedPredicate)
                    .compactMap(Self.flatten)
                    .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            }
        }

        return context
    }

    private func fetch(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    // MARK: - Flattening

    private static func flatten(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let selfStatus = event.attendees?
            .first(where: { $0.isCurrentUser })?
            .participantStatus
        return CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "제목 없는 일정",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            isOrganizer: event.organizer?.isCurrentUser ?? false,
            isTentative: selfStatus == .tentative || selfStatus == .pending,
            isCanceled: event.status == .canceled,
            attendeeCount: event.attendees?.count ?? 0,
            notes: event.notes,
            location: event.location,
            url: event.url
        )
    }

    private static func flatten(_ reminder: EKReminder) -> ReminderItem? {
        ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "제목 없는 할 일",
            due: reminder.dueDateComponents?.date,
            notes: reminder.notes,
            listName: reminder.calendar?.title ?? "미리 알림",
            priority: reminder.priority,
            isCompleted: reminder.isCompleted,
            completedAt: reminder.completionDate,
            url: reminder.url
        )
    }
}
