import Foundation
import UIKit

// MARK: - Models (mirror packages/contracts/doodle.schema.json)

struct APIUser: Codable, Equatable {
    let id: String
    let name: String
}

struct APIDoodle: Codable, Identifiable, Equatable {
    let id: String
    let from: String // "you" | "partner"
    let hasPhoto: Bool
    let createdAt: Date
}

struct APIInvite: Codable {
    let code: String
    let expiresAt: Date
}

struct APIMe: Codable {
    let user: APIUser
    let partner: APIUser?
}

struct APIError: Error, LocalizedError {
    /// HTTP status, or 0 when the request never got an answer.
    let status: Int
    let code: String

    var errorDescription: String? {
        switch code {
        case "offline": return "Can't reach Doodle. Check your connection."
        case "invalid_token": return "That sign-in didn't work. Check your name and test key."
        case "unauthorized": return "You've been signed out. Please sign in again."
        case "invite_not_found": return "That code doesn't exist. Double-check it."
        case "invite_expired": return "That code has expired. Ask for a new one."
        case "own_invite": return "That's your own code. Send it to your person instead."
        case "already_paired": return "You're already paired."
        case "not_paired": return "Pair with someone first."
        case "too_large": return "That doodle is too big to send."
        default: return "Something went wrong (\(code))."
        }
    }
}

// MARK: - Session (shared with the widget through the App Group)

enum DoodleSession {
    private static let tokenKey = "sessionToken"
    private static var defaults: UserDefaults { DoodleAppGroup.sharedDefaults ?? .standard }

    static var token: String? {
        get { defaults.string(forKey: tokenKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: tokenKey) } else { defaults.removeObject(forKey: tokenKey) }
        }
    }
}

// MARK: - Client

enum DoodleAPI {
    static let baseURL = URL(string: "https://157-180-74-100.sslip.io")!

    /// The link people share: opens the app if installed, otherwise explains what Doodle is.
    static func inviteLink(code: String) -> URL {
        baseURL.appendingPathComponent("i").appendingPathComponent(code)
    }

    /// Pulls an invite code out of `doodle://invite/CODE` or `https://<host>/i/CODE`.
    static func inviteCode(from url: URL) -> String? {
        let parts: [String]
        if url.scheme == "doodle", url.host == "invite" {
            parts = url.pathComponents.filter { $0 != "/" }
        } else if url.host == baseURL.host {
            let path = url.pathComponents.filter { $0 != "/" }
            guard path.first == "i" else { return nil }
            parts = Array(path.dropFirst())
        } else {
            return nil
        }
        guard let code = parts.first, !code.isEmpty else { return nil }
        return code.uppercased()
    }

    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: string) ?? plain.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Bad date: \(string)"))
        }
        return decoder
    }()

    // Auth

    /// Test sign-in (server provider "dev"). Replaced by Google / Apple later.
    @discardableResult
    static func signIn(name: String, devKey: String) async throws -> APIUser {
        struct Response: Decodable { let token: String; let user: APIUser }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = devKey.isEmpty ? trimmed : "\(devKey):\(trimmed)"
        let data = try await perform("POST", "/auth", json: ["provider": "dev", "token": token], auth: false)
        let response = try decode(Response.self, data)
        DoodleSession.token = response.token
        return response.user
    }

    static func me() async throws -> APIMe {
        try decode(APIMe.self, try await perform("GET", "/me"))
    }

    // Pairing

    static func createInvite() async throws -> APIInvite {
        try decode(APIInvite.self, try await perform("POST", "/invites"))
    }

    /// Who is behind this invite code? (Shown before the user accepts.)
    static func inviter(code: String) async throws -> APIUser {
        struct Response: Decodable { let inviter: APIUser }
        let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? code
        return try decode(Response.self, try await perform("GET", "/invites/\(escaped)")).inviter
    }

    /// Did this device just open an invite link before installing? Answers at most once.
    static func claimInvite() async throws -> (code: String, inviter: APIUser) {
        struct Response: Decodable { let code: String; let inviter: APIUser }
        let response = try decode(Response.self, try await perform("POST", "/invites/claim"))
        return (response.code, response.inviter)
    }

    static func pair(code: String) async throws -> APIUser {
        struct Response: Decodable { let partner: APIUser }
        let data = try await perform("POST", "/pair", json: ["code": code])
        return try decode(Response.self, data).partner
    }

    static func unpair() async throws {
        _ = try await perform("DELETE", "/pair")
    }

    // Doodles

    static func sendDoodle(jpeg: Data, hasPhoto: Bool) async throws -> APIDoodle {
        let boundary = "doodle-\(UUID().uuidString)"
        var body = Data()
        func add(_ string: String) { body.append(Data(string.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"hasPhoto\"\r\n\r\n\(hasPhoto)\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"doodle.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        add("\r\n--\(boundary)--\r\n")
        let data = try await perform("POST", "/doodles", multipart: (body, boundary))
        return try decode(APIDoodle.self, data)
    }

    static func doodles(limit: Int = 20) async throws -> [APIDoodle] {
        let data = try await perform("GET", "/doodles", query: [URLQueryItem(name: "limit", value: String(limit))])
        return try decode([APIDoodle].self, data)
    }

    static func imageData(id: String) async throws -> Data {
        try await perform("GET", "/doodles/\(id)/image")
    }

    // Plumbing

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) } catch { throw APIError(status: 0, code: "bad_response") }
    }

    private static func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        json: [String: Any]? = nil,
        multipart: (body: Data, boundary: String)? = nil,
        auth: Bool = true
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method

        if auth {
            guard let token = DoodleSession.token else { throw APIError(status: 401, code: "unauthorized") }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        if let multipart {
            request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = multipart.body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw APIError(status: 0, code: "offline")
        }

        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, code: "bad_response") }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "http_\(http.statusCode)"
            throw APIError(status: http.statusCode, code: code)
        }
        return data
    }
}

// MARK: - Widget sync

enum DoodleSync {
    /// Pulls the partner's newest doodle into the App Group so the widget can show it.
    /// Safe to call from the widget itself (pass `reloadTimelines: false` there).
    static func refreshWidgetStore(reloadTimelines: Bool) async {
        guard DoodleSession.token != nil else { return }
        do {
            guard let partner = try await DoodleAPI.me().partner else {
                DoodleSharedStore.clear(reloadTimelines: reloadTimelines)
                return
            }
            let doodles = try await DoodleAPI.doodles(limit: 10)
            guard let latest = doodles.first(where: { $0.from == "partner" }) else { return }

            if DoodleSharedStore.loadMeta()?.id == latest.id, DoodleSharedStore.loadImage() != nil { return }

            let data = try await DoodleAPI.imageData(id: latest.id)
            guard let image = UIImage(data: data) else { return }
            DoodleSharedStore.save(
                image: image,
                meta: SharedDoodleMeta(id: latest.id, senderName: partner.name, createdAt: latest.createdAt, hasPhoto: latest.hasPhoto),
                reloadTimelines: reloadTimelines
            )
        } catch {
            // Offline or signed out: keep showing whatever we already have.
        }
    }
}
