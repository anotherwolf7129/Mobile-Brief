import Foundation
import Combine
import UserNotifications
import BackgroundTasks
import os

/// Owns everything time-related: the daily notification whose *sound is the
/// spoken brief*, the silent notification that points at the two lists, the
/// in-process timer that reads the time blocks aloud, and the background refresh
/// that keeps all of it current.
///
/// Three tiers, deliberately overlapping, so the readout happens without the
/// user touching anything:
///
/// 1. **Notification with a spoken sound** — fires at the set time whether or not
///    the app is running, and survives a force-quit and a reboot. Capped at 30
///    seconds by iOS, and suppressed by the ringer switch and by Silent Mode.
/// 2. **Hands-free timer** — when the keep-alive session is on, the time blocks
///    are spoken at the set time. Survives backgrounding and lock, not a
///    force-quit.
/// 3. **Tap to hear it** — opening the notification reads the time blocks again.
///
/// Only the time blocks are ever spoken. What needs attention and what is
/// already sorted arrive as their own banner a minute later — tapping it opens
/// the app on those two sections.
@MainActor
final class BriefScheduler: NSObject, ObservableObject {
    static let shared = BriefScheduler()

    static let refreshTaskIdentifier = "com.morningbrief.refresh"
    private static let categoryIdentifier = "MORNING_BRIEF"
    private static let itemsCategoryIdentifier = "MORNING_BRIEF_ITEMS"
    private static let readActionIdentifier = "READ_FULL"
    private static let requestPrefix = "morning-brief-"
    private static let itemsRequestPrefix = "morning-brief-items-"

    /// Every identifier this class ever schedules, so a rebuild can clear the
    /// slate without knowing which shape the last one took.
    private static var allRequestIdentifiers: [String] {
        [requestPrefix, itemsRequestPrefix].flatMap { prefix in
            (1...7).map { "\(prefix)\($0)" } + ["\(prefix)daily"]
        }
    }

    @Published private(set) var notificationsAuthorized = false
    @Published private(set) var nextFireDate: Date?

    /// Set by the app so a tapped notification can trigger a readout.
    var onReadRequested: (() -> Void)?

    /// Set by the app so the items notification can open the page on the two
    /// lists instead of reading anything out.
    var onItemsRequested: (() -> Void)?

    private var timer: Timer?
    private var currentSoundName: String?
    /// Speech synthesis is not free, and `schedule` runs on every foreground —
    /// so re-render only when the words have actually changed.
    private var lastRenderedTeaser: String?
    private let log = Logger(subsystem: "com.morningbrief", category: "scheduler")

    // Cannot be `private`: an override may not be less accessible than the
    // `NSObject.init()` it overrides.
    override init() {
        super.init()
    }

    // MARK: - Authorization

    func configure() {
        UNUserNotificationCenter.current().delegate = self

        let readAction = UNNotificationAction(
            identifier: Self.readActionIdentifier,
            title: "읽어 주기",
            options: [.foreground]
        )
        let readout = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [readAction],
            intentIdentifiers: [],
            options: []
        )
        // No action of its own: the whole point of this one is the tap.
        let items = UNNotificationCategory(
            identifier: Self.itemsCategoryIdentifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([readout, items])
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            notificationsAuthorized = granted
        } catch {
            log.error("Notification authorization failed: \(error.localizedDescription)")
            notificationsAuthorized = false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    // MARK: - Tier 1: the notification whose sound is the brief

    /// Re-render the spoken teaser and rebuild the daily notifications around it.
    func schedule(brief: Brief) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.allRequestIdentifiers)

        let settings = Settings.shared
        guard settings.enabled else {
            nextFireDate = nil
            return
        }

        let teaser = BriefScript(brief: brief).teaser
        let rendered: String?
        if teaser == lastRenderedTeaser, let existing = currentSoundName {
            rendered = existing
        } else {
            // Alternate file names so a freshly written file is never the one
            // iOS has already cached for a pending notification.
            let fileName = SpokenSoundRenderer.nextFileName(current: currentSoundName)
            rendered = await SpokenSoundRenderer.render(text: teaser, fileName: fileName)
            currentSoundName = rendered
            lastRenderedTeaser = rendered == nil ? nil : teaser
        }

        let readout = UNMutableNotificationContent()
        readout.title = "모닝 브리핑"
        readout.body = teaser
        readout.categoryIdentifier = Self.categoryIdentifier
        readout.interruptionLevel = .timeSensitive
        readout.sound = rendered.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
            ?? .default

        var components = DateComponents()
        components.hour = settings.hour
        components.minute = settings.minute

        // A repeating calendar trigger can't express "weekdays only" on its own,
        // so weekdays get one repeating request each.
        let weekdays = settings.weekdaysOnly ? Array(2...6) : []
        do {
            try await add(readout, prefix: Self.requestPrefix, at: components, weekdays: weekdays)
            if let items = Self.itemsContent(for: brief) {
                try await add(
                    items,
                    prefix: Self.itemsRequestPrefix,
                    at: Self.minuteAfter(components),
                    weekdays: weekdays
                )
            }
            nextFireDate = settings.nextFireDate()
            log.info("Scheduled brief for \(self.nextFireDate?.description ?? "nil", privacy: .public)")
        } catch {
            log.error("Failed to schedule notification: \(error.localizedDescription)")
        }
    }

    /// One repeating request per weekday, or a single daily one when every day
    /// counts.
    private func add(
        _ content: UNNotificationContent,
        prefix: String,
        at components: DateComponents,
        weekdays: [Int]
    ) async throws {
        let center = UNUserNotificationCenter.current()
        guard !weekdays.isEmpty else {
            try await center.add(UNNotificationRequest(
                identifier: "\(prefix)daily",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            ))
            return
        }
        for weekday in weekdays {
            var dayComponents = components
            dayComponents.weekday = weekday
            try await center.add(UNNotificationRequest(
                identifier: "\(prefix)\(weekday)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: dayComponents, repeats: true)
            ))
        }
    }

    // MARK: - Tier 1b: the tap-to-view notification

    /// The banner that stands in for the two sections nobody wants read to them.
    /// Silent — the spoken readout is still playing a minute earlier, and a chime
    /// over the top of it would be the one jarring thing in the morning. Nil when
    /// there is nothing in either list, because a notification that opens an
    /// empty page is worse than no notification.
    private static func itemsContent(for brief: Brief) -> UNMutableNotificationContent? {
        guard !brief.isEmpty else { return nil }

        var parts: [String] = []
        if !brief.needsAttention.isEmpty {
            parts.append("확인이 필요한 일 \(brief.needsAttention.count)건")
        }
        if !brief.resolved.isEmpty {
            parts.append("이미 정리된 일 \(brief.resolved.count)건")
        }

        let content = UNMutableNotificationContent()
        content.title = "오늘 확인할 것"
        content.body = "\(parts.joined(separator: ", ")) — 탭하면 바로 열려요."
        content.categoryIdentifier = itemsCategoryIdentifier
        content.interruptionLevel = .active
        content.sound = nil
        // A silent banner is easy to miss on the lock screen, so anything that
        // actually needs the reader also lands on the app icon and stays there
        // until the page is opened. A morning with nothing owed sets zero, which
        // clears the badge rather than nagging about things already sorted.
        content.badge = NSNumber(value: brief.needsAttention.count)
        return content
    }

    /// The readout owns the minute the reader chose; this lands the minute after,
    /// once the spoken section — 29 seconds at most — has finished.
    private static func minuteAfter(_ components: DateComponents) -> DateComponents {
        var shifted = components
        var minute = (components.minute ?? 0) + 1
        var hour = components.hour ?? 0
        if minute > 59 {
            minute = 0
            hour += 1
        }
        if hour > 23 {
            hour = 0
            // A readout set for 23:59 pushes this into tomorrow, so the weekday
            // has to move with it.
            if let weekday = components.weekday {
                shifted.weekday = weekday % 7 + 1
            }
        }
        shifted.hour = hour
        shifted.minute = minute
        return shifted
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        SpokenSoundRenderer.removeAll()
        currentSoundName = nil
        lastRenderedTeaser = nil
        nextFireDate = nil
        disarmTimer()
        clearBadge()
    }

    /// The items badge is a pointer at a page; once the app is open it has done
    /// its job.
    func clearBadge() {
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }

    // MARK: - Tier 2: hands-free full readout

    /// Arm an in-process timer for the next readout. Only useful while the
    /// process is alive, which is what the keep-alive audio session buys.
    func armTimer(_ handler: @escaping () -> Void) {
        disarmTimer()
        guard Settings.shared.enabled,
              Settings.shared.handsFree,
              let fireDate = Settings.shared.nextFireDate()
        else { return }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                handler()
                // Re-arm for tomorrow immediately.
                self?.armTimer(handler)
            }
        }
        // `.common` so the timer still fires while the run loop is in a
        // tracking mode (scrolling, etc.).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nextFireDate = fireDate
        log.info("Armed hands-free timer for \(fireDate.description, privacy: .public)")
    }

    func disarmTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Background refresh

    /// Registered once at launch. Keeps the pre-rendered audio and the
    /// notification body from going stale overnight.
    func registerBackgroundTask(refresh: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            let work = Task {
                await refresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
            Task { @MainActor in self.scheduleBackgroundRefresh() }
        }
    }

    /// Ask for a refresh a couple of hours before the readout. iOS decides when
    /// it actually runs — this is opportunistic, which is exactly why tier 1
    /// doesn't depend on it.
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        let target = Settings.shared.nextFireDate()?.addingTimeInterval(-2 * 3600)
        request.earliestBeginDate = max(target ?? Date().addingTimeInterval(3600),
                                        Date().addingTimeInterval(900))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.debug("Background refresh not submitted: \(error.localizedDescription)")
        }
    }
}

extension BriefScheduler: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            guard category != Self.itemsCategoryIdentifier else {
                // This one was never about the voice: open the page on the two
                // sections it stands for.
                self.onItemsRequested?()
                return
            }
            // Both a tap on the banner and the explicit action mean "read it".
            self.onReadRequested?()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        await MainActor.run {
            // The items banner is already redundant with whatever is on screen,
            // so it shows and does nothing else — moving the page under someone
            // who is reading it would be the wrong kind of helpful.
            guard category != Self.itemsCategoryIdentifier else { return }
            // Already in the app at the set time: let the app speak it rather
            // than playing the 30-second rendering over the top.
            self.onReadRequested?()
        }
        return [.banner]
    }
}
