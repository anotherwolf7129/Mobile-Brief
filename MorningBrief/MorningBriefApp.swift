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
                // This build is Korean-only, so every date and number SwiftUI
                // formats is Korean too — whatever language the phone is set to.
                .environment(\.locale, .brief)
                .task {
                    await scheduler.refreshAuthorizationStatus()
                    await store.refresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // The badge stands for "there are things to look at"; being here
                // is looking at them.
                scheduler.clearBadge()
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
        BriefScheduler.shared.onItemsRequested = {
            BriefStore.shared.showItems()
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
                    .accessibilityLabel("설정")
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
            Text("하루를 읽고 있어요.")
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
            Text("브리핑에는 캘린더가 필요해요.")
                .font(Theme.headline)
                .foregroundStyle(Theme.ink)
            Text("캘린더와 미리 알림을 허용하면 이 화면이 오늘 하루의 모양이 되고, 정해 둔 시간에 소리로 읽어 줘요.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSoft)

            Button("권한 허용") {
                Task {
                    await scheduler.requestAuthorization()
                    await store.requestAccess()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.clay)

            Text("이미 거절했다면 설정 › 개인정보 보호 및 보안 › 캘린더에서 바꿀 수 있어요.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkGrey)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.wash)
    }
}
