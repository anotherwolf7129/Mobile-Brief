import Foundation
import Combine
import EventKit
import os

/// The one place the pieces meet: gather from the device, build the brief,
/// optionally polish the prose, cache it, and hand it to the scheduler so the
/// pre-rendered audio stays in step with what the page says.
@MainActor
final class BriefStore: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready
        /// Neither Calendar nor Reminders is available — the page explains, the
        /// buttons act.
        case needsAccess
    }

    static let shared = BriefStore()

    @Published private(set) var brief: Brief
    @Published private(set) var state: State = .idle
    @Published private(set) var lastRefreshed: Date?

    /// Set when the items notification is tapped, cleared once the page has
    /// scrolled to the two lists. It is held here rather than handled in the view
    /// because a tap that launches the app arrives before there is a view to
    /// handle it.
    @Published private(set) var pendingItemsFocus = false

    private let store = EventKitStore()
    private let log = Logger(subsystem: "com.morningbrief", category: "store")

    private static var cacheURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("brief.json")
    }

    private init() {
        brief = Self.loadCache() ?? .placeholder()
    }

    // MARK: - Access

    func requestAccess() async {
        let granted = await store.requestAccess()
        log.info("Access — calendar: \(granted.calendar), reminders: \(granted.reminders)")
        await refresh()
    }

    var calendarAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var remindersAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    // MARK: - Refresh

    /// Rebuild the brief and re-arm everything around it. Safe to call on every
    /// foreground; cheap enough that it doesn't need debouncing.
    func refresh() async {
        if state != .loading { state = .loading }

        let context = await store.gather()
        guard !context.nothingConnected else {
            state = .needsAccess
            return
        }

        var built = BriefBuilder(displayName: Settings.shared.displayName).build(from: context)

        if Settings.shared.useClaude, let key = KeychainStore.apiKey() {
            built = await ClaudeBriefWriter(apiKey: key).polish(built)
        }

        brief = built
        lastRefreshed = Date()
        state = .ready
        Self.saveCache(built)

        await BriefScheduler.shared.schedule(brief: built)
        BriefScheduler.shared.scheduleBackgroundRefresh()
        rearmTimer()
    }

    /// The background-task entry point: refresh quietly, no UI state churn.
    static func backgroundRefresh() async {
        await shared.refresh()
    }

    // MARK: - Readout

    func speakNow() {
        BriefNarrator.shared.speak(brief)
    }

    func stopSpeaking() {
        BriefNarrator.shared.stop()
    }

    /// Called when the hands-free timer fires, or the notification is tapped.
    ///
    /// Tries for fresher data first, but a slow refresh must never push the
    /// readout past the moment it was scheduled for — after the deadline it
    /// speaks whatever it has and lets the refresh land behind it.
    func readoutFired() {
        Task {
            state = .loading
            Task { await self.refresh() }

            let deadline = Date().addingTimeInterval(8)
            while state == .loading, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            speakNow()
        }
    }

    // MARK: - Needs attention / Already sorted

    /// The items notification was tapped. Nothing is spoken — these two sections
    /// are read with the eyes.
    func showItems() {
        pendingItemsFocus = true
        BriefScheduler.shared.clearBadge()
        Task { await refresh() }
    }

    func itemsShown() {
        pendingItemsFocus = false
    }

    func rearmTimer() {
        if Settings.shared.handsFree && Settings.shared.enabled {
            AudioKeepAlive.shared.start()
            BriefScheduler.shared.armTimer { [weak self] in
                self?.readoutFired()
            }
        } else {
            AudioKeepAlive.shared.stop()
            BriefScheduler.shared.disarmTimer()
        }
    }

    // MARK: - Cache

    private static func saveCache(_ brief: Brief) {
        guard let url = cacheURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(brief).write(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "com.morningbrief", category: "store")
                .error("Cache write failed: \(error.localizedDescription)")
        }
    }

    private static func loadCache() -> Brief? {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cached = try? decoder.decode(Brief.self, from: data) else { return nil }
        // Yesterday's brief is not this morning's brief.
        guard Calendar.current.isDateInToday(cached.generatedAt) else { return nil }
        return cached
    }
}
