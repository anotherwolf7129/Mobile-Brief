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
                // Nothing is left running behind us: the morning readout is a
                // pre-rendered notification sound, not a live process.
                store.stopSpeaking()
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
    /// Set by 나중에 on the explainer. Deliberately not persisted: it stands for
    /// "not right now", not "never ask again", so a later launch offers the
    /// explainer once more rather than hiding the connect step for good.
    @State private var accessDeferred = false

    var body: some View {
        NavigationStack {
            Group {
                if store.state == .needsAccess && !accessDeferred {
                    AccessRequestView(onDefer: { accessDeferred = true })
                } else if store.state == .needsAccess {
                    NotConnectedView()
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

/// Nothing connected yet: what the app reads and what it makes of it, then the
/// two ways on. 계속 hands over to the system prompt, which is the only thing
/// that can actually grant anything; 나중에 goes into the app without it. The
/// copy describes the use, and asks for nothing — the ask is iOS's to make.
private struct AccessRequestView: View {
    let onDefer: () -> Void

    @EnvironmentObject private var store: BriefStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("모닝 브리핑은 캘린더를 읽어 하루를 그려요.")
                .font(Theme.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("오늘과 내일의 일정, 그리고 마감이 있는 미리 알림을 읽어서 이 화면의 하루 모양과 시간대별 문장을 만들어요. 알림은 정해 둔 시간에 그 브리핑을 소리로 들려주는 데 써요.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            Text("읽은 내용은 이 기기 안에만 있어요.")
                .font(Theme.body)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 20) {
                // 계속 while there is a prompt left for it to lead to. Once the
                // question has been answered, iOS won't ask again, so the button
                // says where it actually goes.
                Button(store.canPromptForAccess ? "계속" : "설정 열기") {
                    Task { await store.connect(openURL: openURL) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.clay)

                Button("나중에", action: onDefer)
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(.top, 4)

            Text(store.canPromptForAccess
                 ? "다음 화면에서 iOS가 캘린더·미리 알림 접근을 물어봐요."
                 : "이 기기에서는 이미 답한 항목이라 iOS가 다시 묻지 않아요. 설정 › 개인정보 보호 및 보안 › 캘린더에서 바꿀 수 있어요.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkGrey)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.wash)
    }
}

/// Where 나중에 lands. The same connect step is still here, as one plain control
/// among the app's own furniture rather than the only thing on screen.
private struct NotConnectedView: View {
    @EnvironmentObject private var store: BriefStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("아직 캘린더가 연결되어 있지 않아요.")
                .font(Theme.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("연결하면 오늘 하루의 모양이 여기에 그려져요. 설정에서 언제든 다시 할 수 있어요.")
                .font(Theme.caption)
                .foregroundStyle(Theme.inkGrey)
                .fixedSize(horizontal: false, vertical: true)

            Button(store.canPromptForAccess ? "연결하기" : "설정 열기") {
                Task { await store.connect(openURL: openURL) }
            }
            .font(Theme.body)
            .foregroundStyle(Theme.clay)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.wash)
    }
}
