import Foundation
import Combine
import UserNotifications
import BackgroundTasks
import os

/// Owns everything time-related: the daily notification whose *sound is the
/// spoken brief*, the in-process timer that reads the whole thing aloud, and the
/// background refresh that keeps both current.
///
/// Three tiers, deliberately overlapping, so the readout happens without the
/// user touching anything:
///
/// 1. **Notification with a spoken sound** — fires at the set time whether or not
///    the app is running, and survives a force-quit and a reboot. Capped at 30
///    seconds by iOS, and suppressed by the ringer switch and by Silent Mode.
/// 2. **Hands-free timer** — when the keep-alive session is on, the *whole*
///    brief is spoken at the set time. Survives backgrounding and lock, not a
///    force-quit.
/// 3. **Tap to hear it** — opening the notification reads the full brief.
@MainActor
final class BriefScheduler: NSObject, ObservableObject {
    static let shared = BriefScheduler()

    static let refreshTaskIdentifier = "com.morningbrief.refresh"
    private static let categoryIdentifier = "MORNING_BRIEF"
    private static let readActionIdentifier = "READ_FULL"
    private static let requestPrefix = "morning-brief-"

    @Published private(set) var notificationsAuthorized = false
    @Published private(set) var nextFireDate: Date?

    /// Set by the app so a tapped notification can trigger a readout.
    var onReadRequested: (() -> Void)?

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
            title: "Read it to me",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [readAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
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
        center.removePendingNotificationRequests(
            withIdentifiers: (1...7).map { "\(Self.requestPrefix)\($0)" } + ["\(Self.requestPrefix)daily"]
        )

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

        let content = UNMutableNotificationContent()
        content.title = "Morning brief"
        content.body = teaser
        content.categoryIdentifier = Self.categoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.sound = rendered.map { UNNotificationSound(named: UNNotificationSoundName($0)) }
            ?? .default

        var components = DateComponents()
        components.hour = settings.hour
        components.minute = settings.minute

        // A repeating calendar trigger can't express "weekdays only" on its own,
        // so weekdays get one repeating request each.
        let weekdays = settings.weekdaysOnly ? Array(2...6) : []
        do {
            if weekdays.isEmpty {
                try await center.add(UNNotificationRequest(
                    identifier: "\(Self.requestPrefix)daily",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                ))
            } else {
                for weekday in weekdays {
                    var dayComponents = components
                    dayComponents.weekday = weekday
                    try await center.add(UNNotificationRequest(
                        identifier: "\(Self.requestPrefix)\(weekday)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: dayComponents, repeats: true)
                    ))
                }
            }
            nextFireDate = settings.nextFireDate()
            log.info("Scheduled brief for \(self.nextFireDate?.description ?? "nil", privacy: .public)")
        } catch {
            log.error("Failed to schedule notification: \(error.localizedDescription)")
        }
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        SpokenSoundRenderer.removeAll()
        currentSoundName = nil
        lastRenderedTeaser = nil
        nextFireDate = nil
        disarmTimer()
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
        await MainActor.run {
            // Both a tap on the banner and the explicit action mean "read it".
            self.onReadRequested?()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Already in the app at the set time: let the app speak it rather than
        // playing the 30-second rendering over the top.
        await MainActor.run {
            self.onReadRequested?()
        }
        return [.banner]
    }
}
