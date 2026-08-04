import SwiftUI

/// The 30-second glance: two full-bleed bands that meet at a hard edge.
/// Top band is the visual anchor (day line, headline, drawing, three acts) and
/// the only part that is ever read aloud. Bottom band is the important things —
/// one column, full width, 확인이 필요한 일 above 이미 정리된 일 — reached by
/// tapping the morning's second notification.
struct BriefView: View {
    let brief: Brief

    @EnvironmentObject private var store: BriefStore
    @EnvironmentObject private var scheduler: BriefScheduler
    @EnvironmentObject private var narrator: BriefNarrator

    private static let itemsAnchor = "items"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    anchorBand
                    Rectangle()
                        .fill(Theme.bandEdge)
                        .frame(height: 1)
                    importantBand
                        .id(Self.itemsAnchor)
                }
            }
            .background(Theme.background)
            .refreshable { await store.refresh() }
            .task {
                guard store.pendingItemsFocus else { return }
                // Launched straight from the notification: give the page one
                // beat to lay itself out before moving it.
                try? await Task.sleep(for: .milliseconds(400))
                focusItems(with: proxy)
            }
            .onChange(of: store.pendingItemsFocus) { _, pending in
                if pending { focusItems(with: proxy) }
            }
        }
    }

    private func focusItems(with proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.45)) {
            proxy.scrollTo(Self.itemsAnchor, anchor: .top)
        }
        store.itemsShown()
    }

    // MARK: - Visual anchor

    private var anchorBand: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(brief.dayLine)
                .font(Theme.dayLine)
                .foregroundStyle(Theme.inkSoft)

            Text(brief.headline)
                .font(Theme.headline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            TerrainView(
                shape: brief.shape,
                meetings: brief.meetings,
                motifs: brief.acts.map(\.motif)
            )
            .padding(.top, 22)

            if !brief.acts.isEmpty {
                ActsView(acts: brief.acts)
                    .padding(.top, 4)
            }

            readoutRow
                .padding(.top, 26)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.wash)
    }

    /// Reading it out is the point of the app, so the control sits with the
    /// anchor rather than buried in a menu — but it stays a plain text control,
    /// not a filled button. It reads this band only, which is why it sits inside
    /// it.
    private var readoutRow: some View {
        HStack(spacing: 18) {
            Button {
                narrator.isSpeaking ? store.stopSpeaking() : store.speakNow()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: narrator.isSpeaking ? "stop.circle" : "play.circle")
                    Text(narrator.isSpeaking ? "멈추기" : "읽어 주기")
                }
                .font(Theme.body)
                .foregroundStyle(Theme.clay)
            }

            if let next = scheduler.nextFireDate {
                Text("다음 \(next, format: .dateTime.weekday(.abbreviated).hour().minute())")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkGrey)
            }
        }
    }

    // MARK: - Important things

    private var importantBand: some View {
        VStack(alignment: .leading, spacing: 30) {
            if brief.isEmpty {
                Text("오늘 아침은 따로 챙길 일이 없어요.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.inkSoft)
            } else {
                if !brief.needsAttention.isEmpty {
                    ItemListView(heading: "확인이 필요한 일", items: brief.needsAttention)
                }
                if !brief.resolved.isEmpty {
                    ItemListView(heading: "이미 정리된 일", items: brief.resolved)
                }
            }

            if brief.onlyCalendarConnected {
                Text("캘린더만 연결되어 있어요. 미리 알림까지 허용하면 오늘 실제로 해야 할 일이 함께 들어와요.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkGrey)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
    }
}

/// Three left-aligned text columns under the drawing, with faint hairline
/// dividers. Below 640pt they stack in order and the hairlines go horizontal.
private struct ActsView: View {
    let acts: [Act]

    var body: some View {
        // A phone in portrait is always under 640pt, so this is the stacked
        // layout in practice; the row layout is what an iPad gets.
        ViewThatFits(in: .horizontal) {
            row
            stack
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(acts.enumerated()), id: \.element.id) { index, act in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }
                column(act)
                    .padding(.horizontal, index == 0 ? 0 : 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(acts.enumerated()), id: \.element.id) { index, act in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.vertical, 14)
                }
                column(act)
            }
        }
    }

    private func column(_ act: Act) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(act.range)
                .font(Theme.actRange)
                .foregroundStyle(Theme.ink)
            Text(act.sentence)
                .font(Theme.body)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Both lists share one style: a system-sans heading, then faint grey numerals
/// beside a bold title and one sentence. The source phrase inside the sentence
/// is the only link in the item — underlined, ink-soft, no colour change.
private struct ItemListView: View {
    let heading: String
    let items: [BriefItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(heading)
                .font(Theme.sectionHeading)
                .foregroundStyle(Theme.ink)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(Theme.numeral)
                        .foregroundStyle(Theme.inkGrey)
                        .frame(width: 14, alignment: .leading)
                        .padding(.top, 3)

                    VStack(alignment: .leading, spacing: 4) {
                        titleView(for: item)
                        sentenceView(for: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func titleView(for item: BriefItem) -> some View {
        if let url = item.url {
            Link(destination: url) {
                Text(item.title)
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
            }
        } else {
            Text(item.title)
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
        }
    }

    /// Underline the source phrase in place, so the sentence keeps reading as a
    /// sentence rather than breaking into a link and some text.
    private func sentenceView(for item: BriefItem) -> some View {
        Text(attributed(item))
            .font(Theme.body)
            .foregroundStyle(Theme.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(_ item: BriefItem) -> AttributedString {
        var string = AttributedString(item.sentence)
        guard !item.sourcePhrase.isEmpty,
              let range = string.range(of: item.sourcePhrase)
        else { return string }
        string[range].underlineStyle = .single
        if let url = item.url {
            string[range].link = url
            // No colour change — the underline alone carries it.
            string[range].foregroundColor = Theme.inkSoft
        }
        return string
    }
}
