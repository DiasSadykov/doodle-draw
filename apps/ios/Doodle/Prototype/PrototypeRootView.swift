#if DEBUG
import PhotosUI
import SwiftUI

extension Notification.Name {
    /// Posted by the app delegate when a doodle notification is tapped.
    static let doodleNotificationTapped = Notification.Name("doodleNotificationTapped")
}

struct ProtoDrawTarget: Identifiable {
    let id = UUID()
    let personID: String
}

/// Multiple users redesign (prototype). Home is the person's page with one person, and the Wall from two.
struct ProtoRootView: View {
    @StateObject private var store = PrototypeStore()
    @State private var path: [String] = []
    @State private var drawing: ProtoDrawTarget?

    private var showsWall: Bool { store.people.count > 1 }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if showsWall {
                    ProtoWallView(onDraw: draw)
                } else if let only = store.people.first {
                    ProtoPersonView(personID: only.id, isHome: true, onDraw: draw)
                        .id(only.id + store.scenario.rawValue)
                } else {
                    ProtoNoOneView()
                }
            }
            .navigationDestination(for: String.self) { id in
                ProtoPersonView(personID: id, isHome: false, onDraw: draw)
            }
        }
        .animation(.snappy, value: showsWall)
        .fullScreenCover(item: $drawing) { target in
            ProtoDrawView(target: target) {
                // Sent: back to the Wall, if there is one.
                if showsWall { path = [] }
            }
        }
        .environmentObject(store)
        .onReceive(NotificationCenter.default.publisher(for: .doodleNotificationTapped)) { note in
            drawing = nil
            store.handleNotificationTap(note.userInfo ?? [:])
        }
        .onChange(of: store.focus) { _, focus in
            guard let focus, showsWall, path.last != focus.personID else { return }
            path = [focus.personID]
        }
        .onChange(of: store.scenario) { _, _ in path = [] }
        .onChange(of: store.people.map(\.id)) { _, ids in path.removeAll { !ids.contains($0) } }
    }

    private func draw(_ personID: String) {
        drawing = ProtoDrawTarget(personID: personID)
    }
}

/// Your avatar, top-left. Holds the prototype's controls for now.
struct ProtoAccountMenu: View {
    @EnvironmentObject private var store: PrototypeStore
    @AppStorage("prototypeMode") private var prototypeMode = false
    @State private var editingProfile = false

    var body: some View {
        Menu {
            Button("Edit Profile", systemImage: "person.crop.circle") { editingProfile = true }
            Divider()
            Picker("Scenario", selection: Binding(get: { store.scenario }, set: { store.load($0) })) {
                ForEach(PrototypeStore.Scenario.allCases) { Text($0.rawValue).tag($0) }
            }
            Menu("Get a doodle in 5s from…", systemImage: "bell.badge") {
                ForEach(store.connectedPeople) { person in
                    Button(person.name) { Task { await store.simulateIncoming(from: person.id) } }
                }
            }
            Divider()
            Button("Leave prototype", systemImage: "rectangle.portrait.and.arrow.right") { prototypeMode = false }
        } label: {
            ProtoAvatar(person: PrototypeStore.me, size: 32)
        }
        .sheet(isPresented: $editingProfile) { ProtoProfileSheet() }
    }
}

/// Your photo, so your avatar looks like you (and not like the other person's).
struct ProtoProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var profile = ProtoProfile.shared
    @State private var choosing = false
    @State private var taking = false
    @State private var item: PhotosPickerItem?
    @State private var name = ProtoProfile.shared.name
    @FocusState private var editingName: Bool

    /// Empty or blank names keep the previous one.
    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { name = profile.name } else { profile.name = String(trimmed.prefix(30)); name = profile.name }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        ProtoAvatar(person: PrototypeStore.me, size: 112)
                        TextField("Your name", text: $name)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .focused($editingName)
                            .onSubmit(saveName)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button("Choose Photo", systemImage: "photo.on.rectangle") { choosing = true }
                    Button("Take Photo", systemImage: "camera") { taking = true }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    if profile.photo != nil {
                        Button("Remove Photo", systemImage: "trash", role: .destructive) {
                            withAnimation { profile.setPhoto(nil) }
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        saveName()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .photosPicker(isPresented: $choosing, selection: $item, matching: .images)
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    withAnimation { profile.setPhoto(image) }
                }
                item = nil
            }
        }
        .fullScreenCover(isPresented: $taking) {
            ProtoCameraView { image in profile.setPhoto(image) }
                .ignoresSafeArea()
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
    }
}

/// Nobody connected (e.g. after removing your only person): home is the invite.
struct ProtoNoOneView: View {
    @EnvironmentObject private var store: PrototypeStore

    var body: some View {
        ScrollView {
            Button { store.invitePerson() } label: {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "person.badge.plus")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(DoodleTheme.pink)
                                .frame(width: 56, height: 56)
                                .background(DoodleTheme.pink.opacity(0.12), in: Circle())
                            Text("Add someone").font(.headline).foregroundStyle(DoodleTheme.pink)
                            Text("Send an invite link. Your doodles land on their Home Screen.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Doodle")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ProtoAccountMenu() }
        }
    }
}

// MARK: - Wall

struct ProtoWallView: View {
    @EnvironmentObject private var store: PrototypeStore
    let onDraw: (_ personID: String) -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.people) { person in
                        if person.isConnected {
                            NavigationLink(value: person.id) { tile(person) }
                                .buttonStyle(.plain)
                        } else {
                            invitedTile(person)
                        }
                    }
                    Button { store.invitePerson() } label: { addTile }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Doodle")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ProtoAccountMenu() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add someone", systemImage: "person.badge.plus") { store.invitePerson() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                let recent = store.connectedPeople.max { (store.latest(with: $0.id)?.createdAt ?? .distantPast) < (store.latest(with: $1.id)?.createdAt ?? .distantPast) }
                if let recent { onDraw(recent.id) }
            } label: {
                Label("Draw", systemImage: "pencil")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
            }
            .buttonStyle(.glassProminent)
            .tint(DoodleTheme.pink)
            .padding(.bottom, 8)
        }
    }

    private func tile(_ person: ProtoPerson) -> some View {
        // Their latest doodle (what's on your widget); yours until they've sent one. History lives on their page.
        let doodle = store.latestFromThem(person.id) ?? store.latest(with: person.id)
        let isNew = !store.newDoodles(from: person.id).isEmpty
        return ZStack {
            if let doodle {
                let age = PrototypeStore.relative(store.now.timeIntervalSince(doodle.createdAt))
                Image(uiImage: doodle.image)
                    .resizable()
                    .scaledToFill()
                    .overlay(alignment: .bottomTrailing) {
                        ProtoNamePill(
                            person: person,
                            text: "\(doodle.fromMe ? "You" : person.name) · \(age)",
                            sent: doodle.fromMe
                        )
                        .padding(12)
                    }
            } else {
                Color(.secondarySystemGroupedBackground)
                VStack(spacing: 6) {
                    ProtoAvatar(person: person, size: 52)
                    Text(person.name).font(.subheadline.weight(.semibold))
                    Text("Draw the first one")
                        .font(.footnote)
                        .foregroundStyle(DoodleTheme.pink)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(DoodleTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .topLeading) {
            if isNew {
                Text("New")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DoodleTheme.pink, in: Capsule())
                    .padding(12)
            }
        }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
    }

    private func invitedTile(_ person: ProtoPerson) -> some View {
        Color(.secondarySystemGroupedBackground)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                VStack(spacing: 8) {
                    ProtoAvatar(person: person, size: 52).opacity(0.5)
                    Text(person.name).font(.subheadline.weight(.semibold))
                    Text("Invite sent").font(.footnote).foregroundStyle(.secondary)
                }
            }
    }

    private var addTile: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.title2.weight(.semibold))
                    Text("Add someone").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(DoodleTheme.pink)
            }
            .contentShape(Rectangle())
    }
}
#endif
