import Combine
import PencilKit
import UserNotifications
import SwiftUI
import UIKit

struct PendingInvite: Identifiable, Equatable {
    let code: String
    let inviter: APIUser
    var id: String { code }
}

@MainActor
final class AppState: ObservableObject {
    enum Route: Hashable {
        case launching
        case signIn
        case pair
        case canvas
        case latest
        case history
    }

    enum CanvasTool {
        case pen
        case eraser
    }

    @Published var route: Route = .launching
    @Published var me: APIUser?
    @Published var partner: APIUser?
    @Published var inviteCode: String?
    @Published var history: [DoodleDrawing] = []
    @Published var latestFromPartner: DoodleDrawing?

    @Published var canvasDrawing = PKDrawing()
    @Published var selectedInk: UIColor = UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1)
    @Published var tool: CanvasTool = .pen
    @Published var backgroundPhoto: UIImage?

    /// "Clara invited you": set when a link was opened, or found for a fresh install.
    @Published var pendingInvite: PendingInvite?

    @Published var isSending = false
    @Published var isBusy = false
    @Published var launchError: String?
    @Published var alertMessage: String?

    var partnerName: String { partner?.name ?? "your person" }

    private var imageCache: [String: UIImage] = [:]

    // An invite link can be opened before sign-in, so the code waits here until we can use it.
    private static let storedCodeKey = "pendingInviteCode"
    private static let triedClaimKey = "triedInviteClaim"
    private var storedInviteCode: String? {
        get { UserDefaults.standard.string(forKey: Self.storedCodeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.storedCodeKey) }
    }
    private var triedClaim: Bool {
        get { UserDefaults.standard.bool(forKey: Self.triedClaimKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.triedClaimKey) }
    }

    // MARK: - Invite links

    func handle(url: URL) async {
        guard let code = DoodleAPI.inviteCode(from: url) else { return }
        if partner != nil { return } // already paired: nothing to accept
        storedInviteCode = code
        await resolvePendingInvite()
    }

    /// Turns a stored link (or, on a fresh install, a link this device just opened) into a prompt.
    func resolvePendingInvite() async {
        guard route == .pair, pendingInvite == nil else { return }

        if let code = storedInviteCode {
            storedInviteCode = nil
            triedClaim = true
            do {
                pendingInvite = PendingInvite(code: code, inviter: try await DoodleAPI.inviter(code: code))
            } catch let error as APIError where ["own_invite", "already_paired"].contains(error.code) {
                // Nothing to ask the user.
            } catch {
                alertMessage = error.localizedDescription
            }
            return
        }

        if !triedClaim {
            triedClaim = true
            if let found = try? await DoodleAPI.claimInvite() {
                pendingInvite = PendingInvite(code: found.code, inviter: found.inviter)
            }
        }
    }

    func accept(_ invite: PendingInvite) async {
        pendingInvite = nil
        await join(code: invite.code)
    }

    func declineInvite() {
        pendingInvite = nil
    }

    // MARK: - Launch + sign-in

    func bootstrap() async {
        guard DoodleSession.token != nil else {
            route = .signIn
            return
        }
        launchError = nil
        do {
            try await loadMe()
        } catch let error as APIError where error.status == 401 {
            signOut()
        } catch {
            launchError = error.localizedDescription
        }
    }

    func signInWithApple(identityToken: String, givenName: String?) async {
        // Apple only reveals the name once. Keep it so a failed first attempt doesn't lose it.
        let defaults = UserDefaults.standard
        if let givenName, !givenName.isEmpty { defaults.set(givenName, forKey: "appleGivenName") }
        await signIn {
            try await DoodleAPI.signIn(provider: "apple", token: identityToken, name: defaults.string(forKey: "appleGivenName"))
        }
    }

    /// Fake-person login for trying pairing in debug builds.
    func signInForTesting(name: String, devKey: String) async {
        await signIn { try await DoodleAPI.signInForTesting(name: name, devKey: devKey) }
    }

    private func signIn(_ perform: () async throws -> APIUser) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await perform()
            try await loadMe()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func signOut() {
        // Stop pushes to this phone for the person who just left.
        if let token = DoodleSession.token {
            Task { await DoodleAPI.unregisterDevice(bearer: token) }
        }
        DoodleSession.token = nil
        DoodleSharedStore.clear()
        resetSessionState()
        route = .signIn
    }

    private func loadMe() async throws {
        let response = try await DoodleAPI.me()
        me = response.user
        partner = response.partner
        route = response.partner == nil ? .pair : .canvas
        if response.partner != nil { storedInviteCode = nil }
        if route == .pair { Task { await resolvePendingInvite() } }
    }

    private func resetSessionState() {
        me = nil
        partner = nil
        inviteCode = nil
        pendingInvite = nil
        history = []
        latestFromPartner = nil
        imageCache = [:]
        canvasDrawing = PKDrawing()
        backgroundPhoto = nil
    }

    // MARK: - Notifications

    /// Asked once the person is paired, when "your person sent a doodle" actually makes sense.
    func enableNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        await DoodleDevice.register()
    }

    // MARK: - Pairing

    func refreshInvite() async {
        do {
            inviteCode = try await DoodleAPI.createInvite().code
        } catch let error as APIError where error.code == "already_paired" {
            try? await loadMe()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// While the pair screen is showing, notice when the other person enters our code.
    func watchForPartner() async {
        while !Task.isCancelled, route == .pair {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            if let response = try? await DoodleAPI.me(), let found = response.partner {
                partner = found
                route = .canvas
                return
            }
        }
    }

    func join(code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            partner = try await DoodleAPI.pair(code: trimmed)
            route = .canvas
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func unpair() async {
        do {
            try await DoodleAPI.unpair()
            partner = nil
            history = []
            latestFromPartner = nil
            imageCache = [:]
            DoodleSharedStore.clear()
            route = .pair
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Doodles

    /// Loads recent doodles, caches their images, and hands the newest partner doodle to the widget.
    func refresh() async {
        guard partner != nil else { return }
        do {
            let items = try await DoodleAPI.doodles(limit: 20)

            let missing = items.map(\.id).filter { imageCache[$0] == nil }
            await withTaskGroup(of: (String, Data?).self) { group in
                for id in missing {
                    group.addTask { (id, try? await DoodleAPI.imageData(id: id)) }
                }
                for await (id, data) in group {
                    if let data, let image = UIImage(data: data) { imageCache[id] = image }
                }
            }

            history = items.map { item in
                DoodleDrawing(
                    id: item.id,
                    from: item.from == "you" ? .you : .partner,
                    createdAt: item.createdAt,
                    previewImage: imageCache[item.id],
                    hasPhoto: item.hasPhoto
                )
            }
            latestFromPartner = history.first { $0.from == .partner }
            publishLatestToWidget(items)
        } catch let error as APIError where error.status == 401 {
            signOut()
        } catch {
            // Offline: keep showing what we already have.
        }
    }

    func sendCurrentDoodle() async {
        guard !isSending, !canvasDrawing.strokes.isEmpty || backgroundPhoto != nil else { return }
        isSending = true
        defer { isSending = false }

        let image = renderPreview()
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }
        do {
            let sent = try await DoodleAPI.sendDoodle(jpeg: jpeg, hasPhoto: backgroundPhoto != nil)
            imageCache[sent.id] = image
            history.insert(
                DoodleDrawing(id: sent.id, from: .you, createdAt: sent.createdAt, previewImage: image, hasPhoto: sent.hasPhoto),
                at: 0
            )
            canvasDrawing = PKDrawing()
            backgroundPhoto = nil
        } catch let error as APIError where error.status == 401 {
            signOut()
        } catch {
            // The drawing stays on the canvas so nothing is lost.
            alertMessage = error.localizedDescription
        }
    }

    func clearCanvas() {
        canvasDrawing = PKDrawing()
        backgroundPhoto = nil
    }

    // MARK: - Helpers

    private func publishLatestToWidget(_ items: [APIDoodle]) {
        guard
            let partner,
            let latest = items.first(where: { $0.from == "partner" }),
            let image = imageCache[latest.id]
        else { return }
        if DoodleSharedStore.loadMeta()?.id == latest.id, DoodleSharedStore.loadImage() != nil { return }
        DoodleSharedStore.save(
            image: image,
            meta: SharedDoodleMeta(id: latest.id, senderName: partner.name, createdAt: latest.createdAt, hasPhoto: latest.hasPhoto)
        )
    }

    private func renderPreview() -> UIImage {
        let size = CGSize(width: 360, height: 360)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor(DoodleTheme.paper).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            if let photo = backgroundPhoto {
                photo.draw(in: CGRect(origin: .zero, size: size))
            }
            let bounds = CGRect(origin: .zero, size: size)
            let drawn = canvasDrawing.image(from: bounds, scale: 2)
            drawn.draw(in: bounds)
        }
    }
}
