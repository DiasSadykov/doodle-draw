#if DEBUG
import Combine
import SwiftUI
import UIKit
import UserNotifications

/// Multiple users redesign (prototype): sample people and doodles, no server.
/// Lets the new multi-person design be tried in the simulator before the API supports it.
struct ProtoPerson: Identifiable, Hashable {
    enum Status: Hashable {
        case connected(since: Date)
        case invited
    }

    let id: String
    let name: String
    let gradient: [Color]
    var status: Status

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }
}

struct ProtoDoodle: Identifiable, Hashable {
    let id: String
    let personID: String
    let fromMe: Bool
    let createdAt: Date
    let image: UIImage
    var opened: Bool
    /// Reaction from the other side of this doodle: theirs on mine, mine on theirs.
    var reaction: String?
}

struct ProtoFocus: Equatable {
    let personID: String
    let doodleID: String
}

@MainActor
final class PrototypeStore: ObservableObject {
    enum Scenario: String, CaseIterable, Identifiable {
        case onePersonNew = "1 person · new from Dias"
        case onePersonSentLast = "1 person · you sent last"
        case onePersonJustConnected = "1 person · just connected"
        case twoPeople = "2 people"
        case wall = "5 people"
        var id: String { rawValue }
    }

    static let me = ProtoPerson(id: "me", name: "Clara", gradient: [.init(hex: 0xFF885E), .init(hex: 0xFF516A)], status: .invited)

    @Published private(set) var scenario: Scenario = .onePersonNew
    @Published private(set) var people: [ProtoPerson] = []
    @Published private(set) var doodles: [ProtoDoodle] = []
    /// A doodle to bring into view, e.g. after a notification tap.
    @Published var focus: ProtoFocus?
    /// Bumps once a second while something time-based is waiting (a doodle "in flight", relative labels).
    @Published private(set) var now = Date()

    private var ticker: AnyCancellable?

    init() {
        // `-prototypeScenario wall` etc. picks the starting scenario from the command line.
        let requested = UserDefaults.standard.string(forKey: "prototypeScenario")
        load(Scenario.allCases.first { String(describing: $0) == requested } ?? .onePersonNew)
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] date in
            self?.now = date
        }
    }

    // MARK: - Reading

    var connectedPeople: [ProtoPerson] { people.filter(\.isConnected) }

    func person(_ id: String) -> ProtoPerson? { people.first { $0.id == id } }

    /// Oldest first. Doodles "in flight" (created in the future) stay hidden until they arrive.
    func doodles(with personID: String) -> [ProtoDoodle] {
        doodles.filter { $0.personID == personID && $0.createdAt <= now }.sorted { $0.createdAt < $1.createdAt }
    }

    func newDoodles(from personID: String) -> [ProtoDoodle] {
        doodles(with: personID).filter { !$0.fromMe && !$0.opened }
    }

    func latest(with personID: String) -> ProtoDoodle? { doodles(with: personID).last }

    func latestFromThem(_ personID: String) -> ProtoDoodle? { doodles(with: personID).last { !$0.fromMe } }

    /// Header subtitle rule (Figma, "C · One person"): show at most one line, top rule wins.
    func subtitle(for person: ProtoPerson) -> String? {
        let unread = newDoodles(from: person.id).count
        if unread > 0 { return unread == 1 ? "1 new doodle" : "\(unread) new doodles" }
        if case .connected(let since) = person.status, doodles(with: person.id).isEmpty {
            let age = now.timeIntervalSince(since)
            if age < 24 * 3600 { return "Connected \(Self.relative(age, suffix: " ago"))" }
        }
        return nil
    }

    static func relative(_ seconds: TimeInterval, suffix: String = "") -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m\(suffix)" }
        if s < 86400 { return "\(s / 3600)h\(suffix)" }
        return "\(s / 86400)d\(suffix)"
    }

    static func timeLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: - Actions

    func markOpened(_ doodleID: String) {
        guard let i = doodles.firstIndex(where: { $0.id == doodleID }), !doodles[i].opened else { return }
        doodles[i].opened = true
    }

    func react(_ emoji: String?, to doodleID: String) {
        guard let i = doodles.firstIndex(where: { $0.id == doodleID }) else { return }
        doodles[i].reaction = emoji
    }

    func send(_ image: UIImage, to personID: String) {
        doodles.append(ProtoDoodle(id: UUID().uuidString, personID: personID, fromMe: true, createdAt: .now, image: image, opened: true))
    }

    /// Invite someone; they "accept" a few seconds later, so the switch from one person to the Wall can be tried.
    func invitePerson() {
        guard let next = Self.everyone.first(where: { candidate in !people.contains { $0.id == candidate.id } }) else { return }
        var invited = next
        invited.status = .invited
        people.append(invited)
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let i = people.firstIndex(where: { $0.id == next.id }) else { return }
            people[i].status = .connected(since: .now)
        }
    }

    /// A doodle from `personID` arrives in `delay` seconds, with a notification, so the
    /// notification → doodle landing can be tried (lock the simulator with ⌘L to see it on the Lock Screen).
    func simulateIncoming(from personID: String, delay: TimeInterval = 5) async {
        guard let person = person(personID) else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let doodle = ProtoDoodle(
            id: UUID().uuidString,
            personID: personID,
            fromMe: false,
            createdAt: .now.addingTimeInterval(delay),
            image: Self.samples.randomElement()!,
            opened: false
        )
        doodles.append(doodle)

        let content = UNMutableNotificationContent()
        content.title = person.name
        content.body = "Sent you a doodle"
        content.sound = .default
        content.userInfo = ["doodleId": doodle.id, "prototypePersonId": personID]
        let request = UNNotificationRequest(
            identifier: doodle.id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        try? await center.add(request)
    }

    func handleNotificationTap(_ userInfo: [AnyHashable: Any]) {
        guard
            let personID = userInfo["prototypePersonId"] as? String,
            let doodleID = userInfo["doodleId"] as? String,
            person(personID) != nil
        else { return }
        now = .now
        focus = ProtoFocus(personID: personID, doodleID: doodleID)
    }

    // MARK: - Sample data

    func load(_ scenario: Scenario) {
        self.scenario = scenario
        focus = nil
        let s = Self.self
        let ago = { (minutes: Double) in Date.now.addingTimeInterval(-minutes * 60) }
        let longAgo = ago(60 * 24 * 40)
        func d(_ person: String, me: Bool, _ minutesAgo: Double, _ image: UIImage, opened: Bool = true, reaction: String? = nil) -> ProtoDoodle {
            ProtoDoodle(id: UUID().uuidString, personID: person, fromMe: me, createdAt: ago(minutesAgo), image: image, opened: opened, reaction: reaction)
        }
        func connected(_ p: ProtoPerson, since: Date = longAgo) -> ProtoPerson {
            var c = p
            c.status = .connected(since: since)
            return c
        }
        // About two months of older doodles, so the gallery has something to scroll.
        let names = ["cat", "sun", "hi", "plant", "note"]
        let older = (0..<34).map { i in
            d("dias", me: i % 2 == 0, 60 * 24 * (3 + Double(i) * 1.7), s.image(names[i % names.count]), reaction: i % 5 == 1 ? "❤️" : nil)
        }.reversed()
        let history = Array(older) + [
            d("dias", me: true, 60 * 50, s.image("sun")),
            d("dias", me: false, 60 * 49, s.image("hi")),
            d("dias", me: true, 60 * 30, s.image("plant")),
            d("dias", me: false, 60 * 26, s.image("note"), reaction: "😂"),
            d("dias", me: true, 60 * 20, s.image("cat"), reaction: "❤️"),
        ]

        switch scenario {
        case .onePersonNew:
            people = [connected(s.dias)]
            doodles = history + [
                d("dias", me: false, 9, s.image("note"), opened: false),
                d("dias", me: false, 2, s.image("cat"), opened: false),
            ]
        case .onePersonSentLast:
            people = [connected(s.dias)]
            doodles = history + [
                d("dias", me: false, 60 * 3, s.image("hi")),
                d("dias", me: true, 12, s.image("sun"), reaction: "❤️"),
            ]
        case .onePersonJustConnected:
            people = [connected(s.dias, since: ago(1.5))]
            doodles = []
        case .twoPeople:
            people = [connected(s.dias), connected(s.mom, since: ago(4))]
            doodles = history + [d("dias", me: false, 60 * 2, s.image("cat"))]
        case .wall:
            people = [connected(s.dias), connected(s.mom), connected(s.aruzhan), connected(s.sasha), s.timur]
            doodles = history + [
                d("dias", me: false, 9, s.image("note"), opened: false),
                d("dias", me: false, 2, s.image("cat"), opened: false),
                d("mom", me: true, 60 * 5, s.image("hi")),
                d("mom", me: false, 60, s.image("plant"), opened: false),
                d("aruzhan", me: false, 60 * 22, s.image("sun")),
                d("sasha", me: true, 60 * 24 * 2, s.image("cat")),
            ]
        }
    }

    private static let dias = ProtoPerson(id: "dias", name: "Dias", gradient: [.init(hex: 0x72D5FD), .init(hex: 0x2A9EF1)], status: .invited)
    private static let mom = ProtoPerson(id: "mom", name: "Mom", gradient: [.init(hex: 0xFEBB5B), .init(hex: 0xF68136)], status: .invited)
    private static let aruzhan = ProtoPerson(id: "aruzhan", name: "Aruzhan", gradient: [.init(hex: 0xE0A2F3), .init(hex: 0xD669ED)], status: .invited)
    private static let sasha = ProtoPerson(id: "sasha", name: "Sasha", gradient: [.init(hex: 0x53EDD6), .init(hex: 0x28C9B7)], status: .invited)
    private static let timur = ProtoPerson(id: "timur", name: "Timur", gradient: [.init(hex: 0xA0DE7E), .init(hex: 0x54CB68)], status: .invited)
    private static let everyone = [dias, mom, aruzhan, sasha, timur]

    private static func image(_ name: String) -> UIImage { UIImage(named: "proto-doodle-\(name)") ?? UIImage() }
    private static var samples: [UIImage] { ["cat", "sun", "hi", "plant", "note"].map(image) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
#endif
