#if DEBUG
import SwiftUI

/// One person's page: today's doodles from them, what you've sent below, draw back.
/// It is the home screen when you have one person; with more, it opens from a Wall tile.
struct ProtoPersonView: View {
    @EnvironmentObject private var store: PrototypeStore
    let personID: String
    let isHome: Bool
    let onDraw: (_ personID: String) -> Void

    /// Doodles that were new during this visit. Kept after they're opened so "New" stays put while swiping.
    @State private var sessionNew: Set<String> = []
    @State private var currentID: String?
    @State private var pageWidth: CGFloat = 393
    @State private var showsProfile = false
    @State private var openSent: ProtoSentSelection?
    @Namespace private var pickerNamespace
    /// Long-pressed: the doodle stays where it is, the rest dims, reactions open below it.
    @State private var reacting = false
    @State private var pickerOpen = false
    /// The pill's emoji, taken from your recents when the page opens so they don't jump while you tap.
    @State private var pillRow = ProtoReactions.recents
    @State private var justPicked: String?
    @State private var searchingEmoji = false
    /// Doodles you reacted to on this visit: their reaction chip plays when it changes.
    @State private var reactedThisVisit: Set<String> = []

    var body: some View {
        if let person = store.person(personID) {
            content(person)
        }
    }

    // MARK: - Layout

    private func content(_ person: ProtoPerson) -> some View {
        let pages = pageIDs
        let current = currentID.flatMap(doodle) ?? pages.first.flatMap(doodle)
        return ScrollView {
            VStack(spacing: 0) {
                if pages.isEmpty {
                    emptyCard(person)
                } else {
                    pager(pages, person: person)
                        .anchorPreference(key: ProtoPagerAnchor.self, value: .bounds) { $0 }
                    ProtoPageDots(count: pages.count, index: currentIndex(in: pages))
                        .frame(height: 20)
                        .padding(.top, 16)
                        .opacity(pages.count > 1 ? 1 : 0)
                }
                sentByYou(person)
                    .padding(.top, 24)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(reacting)
        .background(alignment: .top) { background(person) }
        .safeAreaInset(edge: .bottom) {
            drawButton(person)
        }
        .overlayPreferenceValue(ProtoPagerAnchor.self) { anchor in
            GeometryReader { proxy in
                if reacting, let current, let anchor {
                    reactOverlay(current, person: person, pager: proxy[anchor], in: proxy.size)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showsProfile = true } label: {
                    ProtoPersonHeader(
                        person: person,
                        subtitle: store.subtitle(for: person),
                        showsDisclosure: true,
                        muted: store.muted.contains(personID)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.default, value: store.subtitle(for: person))
            }
            if isHome {
                ToolbarItem(placement: .topBarLeading) { ProtoAccountMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add someone", systemImage: "person.badge.plus") { store.invitePerson() }
                }
            }
        }
        .navigationDestination(isPresented: $showsProfile) {
            ProtoProfileView(person: person)
        }
        .onAppear(perform: startVisit)
        .onChange(of: store.newDoodles(from: personID).map(\.id)) { _, ids in
            // A doodle arrived while the page is open: it joins at the front, and we go to it.
            let arrived = ids.filter { !sessionNew.contains($0) }
            withAnimation(.snappy) {
                sessionNew.formUnion(ids)
                if !arrived.isEmpty { currentID = pageIDs.first }
            }
        }
        .onChange(of: store.focus) { _, focus in applyFocus(focus) }
        .onChange(of: currentID) { _, id in markSeen(upTo: id) }
        .sheet(item: $openSent) { selection in
            ProtoSentSheet(person: person, startID: selection.id) {
                openSent = nil
                onDraw(personID)
            }
        }
    }

    private func background(_ person: ProtoPerson) -> some View {
        LinearGradient(colors: [person.gradient[1].opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 520)
            .ignoresSafeArea()
    }

    private var cardSide: CGFloat { max(pageWidth - 32, 0) }

    private func pager(_ pages: [String], person: ProtoPerson) -> some View {
        let side = cardSide
        return ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(pages, id: \.self) { id in
                    if let doodle = doodle(id) {
                        card(doodle, person: person)
                            .frame(width: side, height: side)
                            .onLongPressGesture(minimumDuration: 0.3) { startReacting(on: id) }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $currentID, anchor: .center)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(height: side)
    }

    private func card(_ doodle: ProtoDoodle, person: ProtoPerson) -> some View {
        ProtoDoodleCard(doodle: doodle, them: person, animatesReaction: reactedThisVisit.contains(doodle.id))
            .overlay(alignment: .topLeading) {
                if sessionNew.contains(doodle.id) {
                    newBadge.padding(12)
                }
            }
    }

    /// The pressed doodle is drawn again above the dim, exactly where it sits, so nothing moves.
    private func reactOverlay(_ current: ProtoDoodle, person: ProtoPerson, pager: CGRect, in size: CGSize) -> some View {
        let side = cardSide
        let cardRect = CGRect(x: pager.midX - side / 2, y: pager.minY, width: side, height: side)
        let barTop = cardRect.maxY + 28
        let pickerTop = searchingEmoji ? 8 : min(barTop, size.height - ProtoReactionPicker.height - 8)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { stopReacting() }
            card(current, person: person)
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.2), radius: 24, y: 14)
                .offset(x: cardRect.minX, y: cardRect.minY)
                .allowsHitTesting(false)
            if pickerOpen {
                ProtoReactionPicker(
                    selected: current.reaction,
                    namespace: pickerNamespace,
                    onPick: { pickFromPicker($0, on: current) },
                    onClose: { setPicker(open: false) },
                    onSearching: { isSearching in
                        withAnimation(.smooth(duration: 0.3)) { searchingEmoji = isSearching }
                    }
                )
                .frame(width: size.width)
                .offset(y: pickerTop)
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else {
                ProtoReactionPill(
                    selected: current.reaction,
                    row: pillRow,
                    justPicked: justPicked,
                    namespace: pickerNamespace,
                    onPick: { emoji in
                        react(emoji, to: current)
                        stopReacting()
                    },
                    onMore: { setPicker(open: true) }
                )
                .padding(.horizontal, 16)
                .frame(width: size.width)
                .offset(y: barTop)
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
        }
        .transition(.opacity)
    }

    private var newBadge: some View {
        Text("New")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DoodleTheme.pink, in: Capsule())
    }

    @ViewBuilder
    private func sentByYou(_ person: ProtoPerson) -> some View {
        let mine = store.sentByMe(to: personID)
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sent by you")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(mine) { doodle in
                            Button { openSent = ProtoSentSelection(id: doodle.id) } label: {
                                ProtoSentThumb(doodle: doodle)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12) // room for the reaction hanging below
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func emptyCard(_ person: ProtoPerson) -> some View {
        let all = store.doodles(with: personID)
        if all.isEmpty {
            VStack(spacing: 16) {
                Button { onDraw(personID) } label: {
                    dashedCard {
                        VStack(spacing: 10) {
                            Image(systemName: "pencil")
                                .font(.title2.weight(.semibold))
                                .frame(width: 56, height: 56)
                                .background(DoodleTheme.pink.opacity(0.12), in: Circle())
                            Text("Tap to draw the first one").font(.headline)
                        }
                        .foregroundStyle(DoodleTheme.pink)
                    }
                }
                .buttonStyle(.plain)
                Text("It lands on \(person.name)’s Home Screen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        } else {
            // They've never sent one, or just not today. Earlier ones are on their profile.
            let never = !all.contains { !$0.fromMe }
            dashedCard {
                VStack(spacing: 12) {
                    ProtoAvatar(person: person, size: 52).opacity(0.5)
                    Text(never ? "Nothing from \(person.name) yet" : "Nothing from \(person.name) today")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func dashedCard(@ViewBuilder _ content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(DoodleTheme.paper)
            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            .aspectRatio(1, contentMode: .fit)
            .overlay { content() }
    }

    private func drawButton(_ person: ProtoPerson) -> some View {
        let all = store.doodles(with: personID)
        let title: String
        if let last = all.last, Calendar.current.isDateInToday(last.createdAt) {
            title = last.fromMe ? "Draw another" : "Draw back"
        } else if !all.isEmpty, !all.contains(where: { !$0.fromMe }) {
            title = "Draw another"
        } else {
            title = "Draw"
        }
        return Button {
            onDraw(personID)
        } label: {
            Label(title, systemImage: "pencil")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(.glassProminent)
        .tint(DoodleTheme.pink)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .opacity(reacting ? 0.4 : 1)
        .disabled(reacting)
    }

    // MARK: - State

    /// Today's doodles from them, newest first: a new doodle always comes in as the first card.
    private var pageIDs: [String] { store.todayFromThem(personID).map(\.id) }

    private func currentIndex(in pages: [String]) -> Int {
        currentID.flatMap { pages.firstIndex(of: $0) } ?? 0
    }

    private func doodle(_ id: String) -> ProtoDoodle? { store.doodles.first { $0.id == id } }

    private func startVisit() {
        sessionNew = Set(store.newDoodles(from: personID).map(\.id))
        currentID = pageIDs.first
        applyFocus(store.focus)
        markSeen(upTo: currentID)
    }

    /// "New" clears once you've swiped through the new ones: those before the current card,
    /// and all of them once you reach the last new one.
    private func markSeen(upTo id: String?) {
        let pages = pageIDs
        guard let id, let index = pages.firstIndex(of: id) else { return }
        let newPages = pages.filter { sessionNew.contains($0) }
        let seen = index >= newPages.count - 1 ? pages : Array(pages[..<index])
        seen.forEach(store.markOpened)
    }

    private func applyFocus(_ focus: ProtoFocus?) {
        guard let focus, focus.personID == personID else { return }
        if store.newDoodles(from: personID).contains(where: { $0.id == focus.doodleID }) {
            sessionNew.formUnion(store.newDoodles(from: personID).map(\.id))
        }
        withAnimation(.snappy) { currentID = focus.doodleID }
        store.focus = nil
    }

    private func startReacting(on id: String) {
        guard id == (currentID ?? pageIDs.first) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        pillRow = ProtoReactions.recents
        withAnimation(.smooth(duration: 0.25)) { reacting = true }
    }

    private func stopReacting() {
        withAnimation(.smooth(duration: 0.25)) {
            reacting = false
            pickerOpen = false
            searchingEmoji = false
        }
    }

    private func setPicker(open: Bool) {
        withAnimation(.smooth(duration: 0.38)) {
            pickerOpen = open
            if !open { searchingEmoji = false }
        }
    }

    /// Picked in the full picker: it joins your recents, and the reaction lands on the doodle.
    private func pickFromPicker(_ emoji: String, on doodle: ProtoDoodle) {
        let adding = doodle.reaction != emoji
        if adding, !pillRow.contains(emoji) { pillRow = Array(([emoji] + pillRow).prefix(6)) }
        react(emoji, to: doodle)
        stopReacting()
    }

    private func react(_ emoji: String, to doodle: ProtoDoodle) {
        let removing = doodle.reaction == emoji
        reactedThisVisit.insert(doodle.id)
        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.15)) { store.react(removing ? nil : emoji, to: doodle.id) }
        guard !removing else { return }
        ProtoReactions.remember(emoji)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

struct ProtoSentSelection: Identifiable {
    let id: String
}

/// One of your doodles in "Sent by you": no avatar (the label says whose), their reaction hanging off the corner.
struct ProtoSentThumb: View {
    let doodle: ProtoDoodle
    var size: CGFloat = 80

    var body: some View {
        Image(uiImage: doodle.image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .background(DoodleTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
            .overlay(alignment: .bottomLeading) {
                if let emoji = doodle.reaction {
                    ProtoReactionChip(emoji: emoji, size: 26)
                        .padding(.leading, 6)
                        .offset(y: 8)
                }
            }
    }
}

/// Your doodles to one person, opened from "Sent by you". Swipe through them; the newest is on their Home Screen.
struct ProtoSentSheet: View {
    @EnvironmentObject private var store: PrototypeStore
    @Environment(\.dismiss) private var dismiss
    let person: ProtoPerson
    let startID: String
    let onDraw: () -> Void
    @State private var currentID: String?

    var body: some View {
        let mine = store.sentByMe(to: person.id)
        let ids = mine.map(\.id)
        let index = currentID.flatMap { ids.firstIndex(of: $0) } ?? 0
        VStack(spacing: 0) {
            ZStack {
                Text("Sent by you").font(.headline)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            GeometryReader { proxy in
                let side = max(proxy.size.width - 32, 0)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(mine) { doodle in
                            ProtoDoodleCard(doodle: doodle, them: person, showsAuthor: false)
                                .frame(width: side, height: side)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $currentID, anchor: .center)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.top, 24)
            ProtoPageDots(count: ids.count, index: index)
                .frame(height: 20)
                .padding(.top, 16)
                .opacity(ids.count > 1 ? 1 : 0)
            Text("On \(person.name)’s Home Screen")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .opacity(index == 0 ? 1 : 0)
            Spacer()
            Button(action: onDraw) {
                Label("Draw another", systemImage: "pencil")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.glassProminent)
            .tint(DoodleTheme.pink)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .onAppear { currentID = startID }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

/// Where the pager sits, so a long-pressed doodle can be drawn again in exactly the same place.
private struct ProtoPagerAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// A doodle thumbnail with the avatar of whoever drew it.
struct ProtoDoodleThumb: View {
    let doodle: ProtoDoodle
    let them: ProtoPerson
    let size: CGFloat
    var cornerRadius: CGFloat = 12

    var body: some View {
        let mark = min(18, size * 0.22)
        Image(uiImage: doodle.image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .background(DoodleTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(.black.opacity(0.06), lineWidth: 0.5))
            .overlay(alignment: .bottomLeading) {
                // Whoever drew it: their avatar, or yours.
                ProtoAvatar(person: doodle.fromMe ? PrototypeStore.me : them, size: mark)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .padding(size > 80 ? 8 : 4)
            }
    }
}

/// Their profile, opened from the header: every doodle between you (newest first, by date,
/// filterable by who drew it), plus mute and remove.
struct ProtoProfileView: View {
    @EnvironmentObject private var store: PrototypeStore
    @Environment(\.dismiss) private var dismiss
    let person: ProtoPerson

    enum Filter: Hashable { case all, theirs, mine }
    @State private var filter: Filter = .all
    @State private var enlarged: ProtoDoodle?
    @State private var confirmsRemove = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    /// "Today", "Yesterday", the weekday within the last week, then "Sat 20 Sep".
    static func dateHeader(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: .now)).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }

    private var details: String {
        let count = store.doodles(with: person.id).count
        var parts = [count == 1 ? "1 doodle" : "\(count) doodles"]
        if case .connected(let since) = person.status {
            parts.append("connected since \(since.formatted(.dateTime.day().month(.abbreviated)))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let all = store.doodles(with: person.id).reversed()
        let shown = all.filter { filter == .all || (filter == .mine) == $0.fromMe }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.createdAt) }
        let muted = store.muted.contains(person.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 6) {
                    ProtoAvatar(person: person, size: 80)
                    HStack(spacing: 4) {
                        Text(person.name).font(.title2.weight(.bold))
                        if muted {
                            Image(systemName: "bell.slash.fill").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                    Text(details).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Picker("Show", selection: $filter) {
                    Text("All").tag(Filter.all)
                    Text("From \(person.name)").tag(Filter.theirs)
                    Text("From you").tag(Filter.mine)
                }
                .pickerStyle(.segmented)

                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    let doodles = days[day] ?? []
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.dateHeader(day)).font(.headline)
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(doodles) { doodle in
                                Button { enlarged = doodle } label: {
                                    Color.clear
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay {
                                            GeometryReader { proxy in
                                                ProtoDoodleThumb(doodle: doodle, them: person, size: proxy.size.width, cornerRadius: 12)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if shown.isEmpty {
                    Text(filter == .mine ? "You haven’t sent \(person.name) a doodle yet" : "Nothing from \(person.name) yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [person.gradient[1].opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(muted ? "Unmute notifications" : "Mute notifications", systemImage: muted ? "bell" : "bell.slash") {
                        withAnimation { store.toggleMute(person.id) }
                    }
                    Divider()
                    Button("Remove \(person.name)", systemImage: "person.badge.minus", role: .destructive) {
                        confirmsRemove = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .alert("Remove \(person.name)?", isPresented: $confirmsRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                dismiss()
                Task {
                    try? await Task.sleep(for: .seconds(0.45))
                    withAnimation { store.remove(person.id) }
                }
            }
        } message: {
            Text("You’ll stop sending each other doodles. You can connect again with a new invite.")
        }
        .sheet(item: $enlarged) { doodle in
            ProtoDoodleCard(doodle: doodle, them: person)
                .padding(24)
                .presentationDetents([.medium])
                .presentationBackground(.thinMaterial)
        }
    }
}
#endif
