#if DEBUG
import Lottie
import SwiftUI
import UIKit

/// Your profile photo, saved on the device. Shown wherever your avatar appears.
@MainActor
final class ProtoProfile: ObservableObject {
    static let shared = ProtoProfile()
    @Published private(set) var photo: UIImage?
    /// Your name, as the people you doodle with see it.
    @Published var name: String = UserDefaults.standard.string(forKey: "protoProfileName") ?? PrototypeStore.me.name {
        didSet { UserDefaults.standard.set(name, forKey: "protoProfileName") }
    }

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("proto-profile.jpg")

    private init() {
        if let data = try? Data(contentsOf: url) { photo = UIImage(data: data) }
    }

    func setPhoto(_ image: UIImage?) {
        guard let image else {
            photo = nil
            try? FileManager.default.removeItem(at: url)
            return
        }
        let square = Self.squareCrop(image, side: 400)
        photo = square
        try? square.jpegData(compressionQuality: 0.85)?.write(to: url)
    }

    /// Centre square, scaled down: avatars never need more.
    private static func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let scale = side / min(image.size.width, image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }
}

struct ProtoAvatar: View {
    let person: ProtoPerson
    var size: CGFloat = 32
    @ObservedObject private var profile = ProtoProfile.shared

    var body: some View {
        if person.id == PrototypeStore.me.id, let photo = profile.photo {
            Image(uiImage: photo)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(LinearGradient(colors: person.gradient, startPoint: .top, endPoint: .bottom))
                .frame(width: size, height: size)
                .overlay {
                    Text((person.id == PrototypeStore.me.id ? profile.name : person.name).prefix(1).uppercased())
                        .font(.system(size: size * 0.43, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
    }
}

/// Avatar + name (+ optional subtitle). The same header on the person page and the draw screen.
struct ProtoPersonHeader: View {
    let person: ProtoPerson
    var subtitle: String?
    var showsChevron = false
    /// A small › after the name: tapping the header opens their profile.
    var showsDisclosure = false
    var muted = false

    var body: some View {
        HStack(spacing: 8) {
            ProtoAvatar(person: person, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(person.name).font(.headline)
                    if muted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if showsDisclosure {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                }
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if showsChevron {
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ProtoPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.38), in: Capsule())
    }
}

/// Avatar + "Name · 2m" on a Wall tile; your own doodles show your avatar.
struct ProtoNamePill: View {
    let person: ProtoPerson
    let text: String
    var sent = false

    var body: some View {
        HStack(spacing: 5) {
            ProtoAvatar(person: sent ? PrototypeStore.me : person, size: 18)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.38), in: Capsule())
    }
}

/// The reaction on a doodle, in its own little circle that hangs off the doodle's bottom-left corner.
/// No avatar: with one person it can only be yours on theirs, or theirs on yours.
/// A new reaction pops in and plays; the one it replaces shrinks away.
struct ProtoReactionChip: View {
    let emoji: String
    var size: CGFloat = 32
    /// Play when the emoji appears (you just reacted). Off for reactions already there when the page opened.
    var animates = false

    var body: some View {
        ZStack {
            ProtoNotoEmoji(emoji: emoji, size: size * 0.62, autoplay: animates)
                .id(emoji)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.2).combined(with: .opacity),
                    removal: .scale(scale: 0.2).combined(with: .opacity)
                ))
        }
        .frame(width: size, height: size)
        .background(.white, in: Circle())
        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

/// Page dots; with many pages only seven show, the outer ones smaller.
struct ProtoPageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        let visible = min(count, 7)
        let start = max(0, min(index - 3, count - visible))
        HStack(spacing: 6) {
            ForEach(start..<(start + visible), id: \.self) { i in
                let edge = (i == start && start > 0) || (i == start + visible - 1 && start + visible < count)
                Capsule()
                    .fill(i == index ? DoodleTheme.pink : Color.primary.opacity(0.2))
                    .frame(width: i == index ? 18 : (edge ? 5 : 7), height: edge && i != index ? 5 : 7)
            }
        }
        .animation(.snappy, value: index)
    }
}

struct ProtoDoodleCard: View {
    let doodle: ProtoDoodle
    let them: ProtoPerson
    var cornerRadius: CGFloat = 32
    var animatesReaction = false
    /// Off where a label already says whose it is ("Sent by you").
    var showsAuthor = true

    var body: some View {
        Image(uiImage: doodle.image)
            .resizable()
            .scaledToFill()
            .background(DoodleTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Same places as on a Wall tile: "New" top-left, time bottom-right.
            .overlay(alignment: .bottomTrailing) {
                // On their page it's clear who theirs are from: just the time. Yours keep your avatar.
                Group {
                    if doodle.fromMe && showsAuthor {
                        ProtoNamePill(person: them, text: PrototypeStore.timeLabel(doodle.createdAt), sent: true)
                    } else {
                        ProtoPill(text: PrototypeStore.timeLabel(doodle.createdAt))
                    }
                }
                .padding(12)
            }
            .shadow(color: .black.opacity(0.1), radius: 12, y: 8)
            .overlay(alignment: .bottomLeading) {
                // Outside the canvas, overlapping its edge by 10pt.
                if let emoji = doodle.reaction {
                    ProtoReactionChip(emoji: emoji, animates: animatesReaction)
                        .padding(.leading, 12)
                        .offset(y: 22)
                        .transition(.scale.combined(with: .opacity))
                }
            }
    }
}

// MARK: - Reactions

/// Reactions use Google's Noto Animated Emoji (CC BY 4.0): bundled stills, Lottie animations from Google's CDN.
enum ProtoReactions {
    static let quick = ["❤️", "😂", "😮", "🔥", "🥹", "😍"]
    static let all = quick + [
        "👏", "😭", "🤯", "✨", "😀", "😁", "🤣", "😊", "😇", "🥰", "😘", "😋",
        "😜", "🤪", "🤗", "🤔", "🫡", "😴", "🥳", "😎", "🤓", "😏", "😢", "😡", "🥺", "😱",
        "🤢", "💀", "👻", "🤡", "🙈", "💩", "👍", "👎", "🙏", "💪", "👀", "💯", "💔", "🌈",
        "🌸", "🎉", "⭐", "🐱",
    ]

    /// Names and keywords for search.
    static let keywords: [String: String] = [
        "❤️": "red heart love like", "😂": "joy laugh tears lol funny", "😮": "wow surprised open mouth", "🔥": "fire hot lit",
        "🥹": "holding back tears touched aww", "😍": "heart eyes love crush", "👏": "clap applause bravo", "😭": "sob crying sad",
        "🤯": "mind blown exploding head shocked", "✨": "sparkles magic shiny", "😀": "grinning smile happy", "😁": "beaming grin smile",
        "🤣": "rolling floor laughing rofl lol", "😊": "blush smile happy", "😇": "halo angel innocent", "🥰": "smiling hearts love",
        "😘": "kiss blow love", "😋": "yum delicious tongue", "😜": "wink tongue silly", "🤪": "zany crazy silly goofy",
        "🤗": "hug hugging", "🤔": "thinking hmm", "🫡": "salute respect", "😴": "sleeping tired zzz", "🥳": "party celebrate",
        "😎": "cool sunglasses", "🤓": "nerd glasses", "😏": "smirk", "😢": "cry sad tear", "😡": "angry mad rage",
        "🥺": "pleading puppy eyes please", "😱": "scream fear shocked", "🤢": "nauseated sick gross", "💀": "skull dead lol",
        "👻": "ghost boo", "🤡": "clown", "🙈": "see no evil monkey shy", "💩": "poop", "👍": "thumbs up yes like ok",
        "👎": "thumbs down no dislike", "🙏": "pray please thanks", "💪": "muscle strong flex", "👀": "eyes look",
        "💯": "hundred 100 perfect", "💔": "broken heart sad", "🌈": "rainbow", "🌸": "cherry blossom flower",
        "🎉": "party popper tada celebrate", "⭐": "star", "🐱": "cat kitty",
    ]

    static func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { emoji in
            emoji == q || (keywords[emoji] ?? "").split(separator: " ").contains { $0.hasPrefix(q) }
        }
    }

    private static let recentsKey = "protoRecentReactions"

    /// Your six last used reactions, newest first, saved across launches.
    static var recents: [String] {
        let saved = (UserDefaults.standard.string(forKey: recentsKey) ?? "").split(separator: " ").map(String.init)
        return Array((saved + quick.filter { !saved.contains($0) }).prefix(6))
    }

    static func remember(_ emoji: String) {
        let next = ([emoji] + recents.filter { $0 != emoji }).prefix(6)
        UserDefaults.standard.set(next.joined(separator: " "), forKey: recentsKey)
    }

    /// Bundled still, e.g. ❤️ → noto-still-2764. Emoji without one fall back to the system font.
    static func stillName(for emoji: String) -> String? {
        let hex = emoji.unicodeScalars.filter { $0.value != 0xFE0F }.map { String($0.value, radix: 16) }.joined(separator: "_")
        let name = "noto-still-\(hex)"
        return UIImage(named: name) == nil ? nil : name
    }

    /// The animation lives on Google's Noto CDN and is downloaded (then cached) on first play,
    /// so the app bundle only carries the small stills.
    static func animationURL(for emoji: String) -> URL? {
        let code = emoji.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: "_")
        return URL(string: "https://fonts.gstatic.com/s/e/notoemoji/latest/\(code)/lottie.json")
    }

    /// Warm the cache for the bar, so the first tap plays straight away.
    static func prefetch(_ emojis: [String]) {
        for emoji in emojis {
            guard let url = animationURL(for: emoji) else { continue }
            LottieAnimation.loadedFrom(url: url, closure: { _ in }, animationCache: DefaultAnimationCache.sharedCache)
        }
    }
}

/// A Noto emoji: shows its first frame, plays once each time `plays` goes up (or right away with `autoplay`).
struct ProtoNotoEmoji: View {
    let emoji: String
    var size: CGFloat = 26
    var plays = 0
    var autoplay = false
    var active = true

    var body: some View {
        if ProtoReactions.stillName(for: emoji) != nil {
            ProtoNotoAnimation(emoji: emoji, plays: plays, autoplay: autoplay, active: active)
                .frame(width: size, height: size)
                .allowsHitTesting(false) // the UIKit view would otherwise swallow the button's tap
        } else {
            Text(emoji).font(.system(size: size * 0.85))
        }
    }
}

extension View {
    /// Solid surface for the reaction pill and picker: enough contrast on the light page,
    /// and matched between the two so the pill grows into the picker.
    func protoPickerSurface(cornerRadius: CGFloat, in namespace: Namespace.ID) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.systemBackground))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
                .matchedGeometryEffect(id: "reactionPicker", in: namespace)
        }
    }
}

/// Your six last used reactions; the chevron opens the full picker.
struct ProtoReactionPill: View {
    let selected: String?
    let row: [String]
    /// Just picked in the full picker: plays as the pill comes back.
    let justPicked: String?
    let namespace: Namespace.ID
    let onPick: (String) -> Void
    let onMore: () -> Void
    @State private var plays: [String: Int] = [:]
    /// Only one emoji animates at a time: starting another stops this one.
    @State private var playing: String?

    var body: some View {
        let current = playing ?? justPicked
        HStack(spacing: 0) {
            ForEach(row, id: \.self) { emoji in
                Button {
                    tap(emoji)
                } label: {
                    ProtoNotoEmoji(
                        emoji: emoji,
                        size: 30,
                        plays: plays[emoji, default: 0],
                        autoplay: justPicked == emoji,
                        active: current == emoji
                    )
                        .frame(width: 44, height: 44)
                        .background(selected == emoji ? DoodleTheme.pink.opacity(0.14) : .clear, in: Circle())
                        .frame(maxWidth: .infinity) // spread across the full-width bar
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 24)
            Button(action: onMore) {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .protoPickerSurface(cornerRadius: 27, in: namespace)
        .onAppear { ProtoReactions.prefetch(row) }
    }

    /// Picking (not removing) always plays, and stops whatever else was playing.
    private func tap(_ emoji: String) {
        if selected != emoji {
            playing = emoji
            plays[emoji, default: 0] += 1
        }
        onPick(emoji)
    }
}

/// All reactions with search. Opens out of the pill and grows downward.
struct ProtoReactionPicker: View {
    static let height: CGFloat = 302

    let selected: String?
    let namespace: Namespace.ID
    let onPick: (String) -> Void
    let onClose: () -> Void
    /// Search has the keyboard: the page lifts the picker above it.
    var onSearching: (Bool) -> Void = { _ in }
    @State private var query = ""
    @FocusState private var searching: Bool
    /// Contents fade in once the surface has mostly grown out of the pill.
    @State private var showsContent = false

    var body: some View {
        let results = ProtoReactions.search(query)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search emoji", text: $query)
                        .focused($searching)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color(.tertiarySystemFill), in: Capsule())
                Button {
                    searching = false
                    onClose()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(Color(.tertiarySystemFill), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            ScrollView {
                if results.isEmpty {
                    Text("No emoji found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                        ForEach(results, id: \.self) { emoji in
                            Button {
                                searching = false
                                onPick(emoji)
                            } label: {
                                ProtoNotoEmoji(emoji: emoji, size: 32)
                                    .frame(width: 44, height: 44)
                                    .background(selected == emoji ? DoodleTheme.pink.opacity(0.14) : .clear, in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            .scrollIndicators(.visible)
            .scrollDismissesKeyboard(.immediately)
            .frame(height: 248)
        }
        .frame(maxWidth: .infinity)
        .opacity(showsContent ? 1 : 0)
        .onChange(of: searching) { _, isSearching in onSearching(isSearching) }
        .onAppear {
            withAnimation(.easeOut(duration: 0.2).delay(0.18)) { showsContent = true }
        }
        .protoPickerSurface(cornerRadius: 28, in: namespace)
        .padding(.horizontal, 16)
    }
}

/// A Noto emoji: the still at rest; plays its Lottie animation once whenever `plays` goes up.
struct ProtoNotoAnimation: UIViewRepresentable {
    let emoji: String
    var plays = 0
    var autoplay = false
    /// Set to false to stop a running animation (e.g. another emoji started playing).
    var active = true

    func makeUIView(context: Context) -> ProtoNotoView {
        let view = ProtoNotoView()
        view.load(emoji)
        context.coordinator.plays = plays
        if autoplay { view.play() }
        return view
    }

    func updateUIView(_ view: ProtoNotoView, context: Context) {
        // The same view can be handed a different emoji (e.g. the reaction chip after you change your reaction).
        if view.emoji != emoji { view.load(emoji) }
        if !active { view.stop() }
        guard plays != context.coordinator.plays else { return }
        context.coordinator.plays = plays
        view.play()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var plays = 0
    }

    /// Take the size SwiftUI offers, not the image's pixel size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ProtoNotoView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 26, height: proposal.height ?? 26)
    }
}

final class ProtoNotoView: UIView {
    private let still = UIImageView()
    private var animationView: LottieAnimationView?
    private(set) var emoji = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        still.contentMode = .scaleAspectFit
        still.frame = bounds
        still.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(still)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func load(_ emoji: String) {
        self.emoji = emoji
        animationView?.removeFromSuperview()
        animationView = nil
        still.isHidden = false
        still.image = ProtoReactions.stillName(for: emoji).flatMap { UIImage(named: $0) }
    }

    func play() {
        if let animationView {
            start(animationView)
            return
        }
        guard let url = ProtoReactions.animationURL(for: emoji) else { return }
        let requested = emoji
        LottieAnimation.loadedFrom(url: url, closure: { [weak self] animation in
            guard let self, let animation, self.emoji == requested else { return }
            let view = LottieAnimationView(animation: animation)
            view.contentMode = .scaleAspectFit
            view.loopMode = .playOnce
            view.backgroundBehavior = .stop
            view.frame = self.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.addSubview(view)
            self.animationView = view
            self.start(view)
        }, animationCache: DefaultAnimationCache.sharedCache)
    }

    func stop() {
        animationView?.stop()
        animationView?.isHidden = true
        still.isHidden = false
    }

    private func start(_ view: LottieAnimationView) {
        still.isHidden = true
        view.isHidden = false
        view.currentProgress = 0
        view.play { [weak self, weak view] _ in
            view?.isHidden = true
            self?.still.isHidden = false
        }
    }
}

#endif
