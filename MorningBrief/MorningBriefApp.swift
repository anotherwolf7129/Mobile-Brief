import SwiftUI
import UIKit

@main
struct MorningBriefApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store = BriefStore.shared
    @StateObject private var scheduler = BriefScheduler.shared
    @StateObject private var settings = Settings.shared
    @StateObject private var narrator = BriefNarrator.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(scheduler)
                .environmentObject(settings)
                .environmentObject(narrator)
                .task {
                    await scheduler.refreshAuthorizationStatus()
                    await store.refresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await scheduler.refreshAuthorizationStatus()
                    await store.refresh()
                }
            case .background:
                scheduler.scheduleBackgroundRefresh()
                // The keep-alive session must stay up in the background — that
                // is the whole point of it — so it is deliberately not stopped.
                store.rearmTimer()
            default:
                break
            }
        }
    }
}

/// `BGTaskScheduler.register` has to happen before launch finishes, and the
/// notification delegate has to be set before any notification can be
/// delivered — so both belong here rather than in a view's `task`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BriefScheduler.shared.configure()
        BriefScheduler.shared.registerBackgroundTask {
            await BriefStore.backgroundRefresh()
        }
        BriefScheduler.shared.onReadRequested = {
            BriefStore.shared.readoutFired()
        }
        return true
    }
}

struct RootView: View {
    @EnvironmentObject private var store: BriefStore
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.state == .needsAccess {
                    AccessRequestView()
                } else if store.state != .ready && store.brief.acts.isEmpty {
                    // First run only — once anything is cached, show the page
                    // rather than a spinner.
                    LoadingView()
                } else {
                    BriefView(brief: store.brief)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.inkSoft)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(Theme.wash, for: .navigationBar)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .tint(Theme.clay)
    }
}

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading your day.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.wash)
    }
}

/// Nothing connected: two friendly sentences replace the whole page, shipped
/// with the button that actually fixes it.
private struct AccessRequestView: View {
    @EnvironmentObject private var store: BriefStore
    @EnvironmentObject private var scheduler: BriefScheduler

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your brief needs your calendar.")
                .font(Theme.headline)
                .foregroundStyle(Theme.ink)
            Text("Allow access to Calendar and Reminders and this page becomes the shape of your day, read out loud at whatever time you choose.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSoft)

            Button("Allow access") {
                Task {
                    await scheduler.requestAuthorization()
                    await store.requestAccess()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.clay)

            Text("Already denied? Settings › Privacy & Security › Calendars.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkGrey)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.wash)
    }
}
