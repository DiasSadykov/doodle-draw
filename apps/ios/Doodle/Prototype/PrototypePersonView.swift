#if DEBUG
import SwiftUI

/// One person's page: their new doodles (or the latest exchange), reactions, earlier doodles, draw back.
/// It is the home screen when you have one person; with more, it opens from a Wall tile.
struct ProtoPersonView: View {
    @EnvironmentObject private var store: PrototypeStore
    let personID: String
    let isHome: Bool
    let onDraw: (_ personID: String) -> Void

    /// Doodles that were new during this visit. Kept after they're opened so "1 of 2 new" stays stable while swiping.
    @State private var sessionNew: Set<String> = []
    @State private var currentID: String?
    @State private var enlarged: ProtoDoodle?
    @State private var showsGallery = false
    @State private var pageWidth: CGFloat = 393
    @Namespace private var pickerNamespace
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
        let current = currentID.flatMap(doodle) ?? pages.last.flatMap(doodle)
        return ScrollView {
            VStack(spacing: 0) {
                if pages.isEmpty {
                    emptyCard(person)
                } else {
                    pager(pages, person: person)
                    indicator(pages, current: current, person: person)
                        .frame(height: 20)
                        .padding(.top, 16)
                    if let current, !current.fromMe {
                        Group {
                            if pickerOpen {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 54)
                            } else {
                                ProtoReactionPill(
                                    selected: current.reaction,
                                    row: pillRow,
                                    justPicked: justPicked,
                                    namespace: pickerNamespace,
                                    onPick: { react($0, to: current) },
                                    onMore: { setPicker(open: true) }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .anchorPreference(key: ProtoPillAnchor.self, value: .bounds) { $0 }
                        .padding(.top, 16)
                    }
                    earlier(excluding: Set(pages), person: person)
                        .padding(.top, 24)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(alignment: .top) { background(person) }
        .safeAreaInset(edge: .bottom) {
            drawButton(person, current: current)
                .opacity(pickerOpen ? 0 : 1)
        }
        .overlayPreferenceValue(ProtoPillAnchor.self) { anchor in
            GeometryReader { proxy in
                if pickerOpen, let current, let anchor {
                    // Opens where the pill is and grows down; rises to the top while search has the keyboard.
                    let pillTop = proxy[anchor].minY
                    let top = searchingEmoji ? 8 : min(pillTop, proxy.size.height - ProtoReactionPicker.height - 8)
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                            .onTapGesture { setPicker(open: false) }
                            .transition(.opacity)
                        ProtoReactionPicker(
                            selected: current.reaction,
                            namespace: pickerNamespace,
                            onPick: { pickFromPicker($0, on: current) },
                            onClose: { setPicker(open: false) },
                            onSearching: { isSearching in
                                withAnimation(.smooth(duration: 0.3)) { searchingEmoji = isSearching }
                            }
                        )
                        .padding(.top, top)
                        // The surface itself morphs from the pill; only fade on the way out.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.12))))
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ProtoPersonHeader(person: person, subtitle: store.subtitle(for: person))
                    .animation(.default, value: store.subtitle(for: person))
            }
            if isHome {
                ToolbarItem(placement: .topBarLeading) { ProtoAccountMenu() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add someone", systemImage: "person.badge.plus") { store.invitePerson() }
                }
            }
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
        .sheet(item: $enlarged) { doodle in
            ProtoDoodleCard(doodle: doodle, them: person)
                .padding(24)
                .presentationDetents([.medium])
                .presentationBackground(.thinMaterial)
        }
    }

    private func background(_ person: ProtoPerson) -> some View {
        LinearGradient(colors: [person.gradient[1].opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 520)
            .ignoresSafeArea()
    }

    private func pager(_ pages: [String], person: ProtoPerson) -> some View {
        let side = max(pageWidth - 32, 0)
        return ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(pages, id: \.self) { id in
                    if let doodle = doodle(id) {
                        ProtoDoodleCard(doodle: doodle, them: person, animatesReaction: reactedThisVisit.contains(id))
                            .frame(width: side, height: side)
                            .overlay(alignment: .topLeading) {
                                if sessionNew.contains(id) {
                                    newBadge.padding(12)
                                }
                            }
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

    @ViewBuilder
    private func indicator(_ pages: [String], current: ProtoDoodle?, person: ProtoPerson) -> some View {
        let index = (currentID.flatMap { pages.firstIndex(of: $0) } ?? pages.count - 1)
        if !sessionNew.isEmpty, pages.count > 1 {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == index ? DoodleTheme.pink : Color.primary.opacity(0.2))
                            .frame(width: i == index ? 18 : 7, height: 7)
                    }
                }
            }
            .animation(.snappy, value: index)
        } else if let current, current.fromMe {
            Text("Now on \(person.name)’s Home Screen")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
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
    private func earlier(excluding shown: Set<String>, person: ProtoPerson) -> some View {
        let all = store.doodles(with: personID)
        let older = all.filter { !shown.contains($0.id) }.reversed().prefix(10)
        if !older.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Earlier")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showsGallery = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("See all \(all.count)")
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DoodleTheme.pink)
                    }
                }
                .padding(.horizontal, 16)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(older)) { doodle in
                            Button { enlarged = doodle } label: {
                                ProtoDoodleThumb(doodle: doodle, them: person, size: 64, cornerRadius: 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationDestination(isPresented: $showsGallery) {
                ProtoGalleryView(person: person)
            }
        }
    }

    private func emptyCard(_ person: ProtoPerson) -> some View {
        VStack(spacing: 16) {
            Button { onDraw(personID) } label: {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(DoodleTheme.paper)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
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
    }

    private func drawButton(_ person: ProtoPerson, current: ProtoDoodle?) -> some View {
        let title: String
        switch current {
        case .none: title = "Draw"
        case .some(let d) where d.fromMe: title = "Draw another"
        default: title = "Draw back"
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
    }

    // MARK: - State

    /// New doodles from this visit if any, otherwise the latest exchange.
    private var pageIDs: [String] {
        let all = store.doodles(with: personID)
        // Newest first: a new doodle always comes in as the first card.
        if !sessionNew.isEmpty { return all.filter { sessionNew.contains($0.id) }.reversed().map(\.id) }
        return all.last.map { [$0.id] } ?? []
    }

    private func doodle(_ id: String) -> ProtoDoodle? { store.doodles.first { $0.id == id } }

    private func startVisit() {
        sessionNew = Set(store.newDoodles(from: personID).map(\.id))
        currentID = pageIDs.first
        applyFocus(store.focus)
        markSeen(upTo: currentID)
    }

    /// "New" clears once you've swiped through all of them: pages before the current one,
    /// and every page once you reach the last.
    private func markSeen(upTo id: String?) {
        let pages = pageIDs
        guard let id, let index = pages.firstIndex(of: id) else { return }
        let seen = index == pages.count - 1 ? pages : Array(pages[..<index])
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

    private func setPicker(open: Bool) {
        withAnimation(.smooth(duration: 0.38)) {
            pickerOpen = open
            if !open { searchingEmoji = false }
        }
    }

    /// Picked in the full picker: it joins the pill, which plays it as the picker shrinks back.
    private func pickFromPicker(_ emoji: String, on doodle: ProtoDoodle) {
        let adding = doodle.reaction != emoji
        if adding, !pillRow.contains(emoji) { pillRow = Array(([emoji] + pillRow).prefix(6)) }
        justPicked = adding ? emoji : nil
        setPicker(open: false)
        react(emoji, to: doodle)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if justPicked == emoji { justPicked = nil }
        }
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

/// Where the reaction pill sits, so the picker can open from it.
private struct ProtoPillAnchor: PreferenceKey {
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

/// Every doodle with one person: newest first, by date, filterable by who drew it.
struct ProtoGalleryView: View {
    @EnvironmentObject private var store: PrototypeStore
    let person: ProtoPerson

    enum Filter: Hashable { case all, theirs, mine }
    @State private var filter: Filter = .all
    @State private var enlarged: ProtoDoodle?

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

    var body: some View {
        let all = store.doodles(with: person.id).reversed()
        let shown = all.filter { filter == .all || (filter == .mine) == $0.fromMe }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.createdAt) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(person.name).font(.headline)
                    Text("\(all.count) doodles").font(.caption).foregroundStyle(.secondary)
                }
            }
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
