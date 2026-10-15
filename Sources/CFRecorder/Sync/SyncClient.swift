import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// Pushes call folders to any server that speaks the sync API (README // SYNC_API).
/// Everything about the server is discovered from its URL: a bare request gets a 401
/// pointing at RFC 9728 resource metadata, which names the issuer, whose RFC 8414 metadata
/// has the registration, authorize, and token endpoints. The app registers itself (RFC 7591),
/// signs in through the browser with PKCE and a loopback redirect (RFC 8252), and keeps the
/// tokens in the Keychain.
enum SyncClient {
    static let defaultServer = "https://askscottpierce.com/recordings"
    /// meeting.json goes last: it's what puts the call in the server's list, so it lands
    /// only after the audio it points at.
    static let syncedFiles = ["me.m4a", "them.m4a", "transcript.md", "notes.md", "meeting.json"]
    private static let singlePutLimit = 90 * 1024 * 1024
    private static let partSize = 50 * 1024 * 1024

    struct Session: Codable {
        var server: String
        var resource: String
        var issuer: String
        var tokenEndpoint: String
        var clientId: String
        var accessToken: String
        var accessExpiry: Date
        var refreshToken: String?
        var email: String?
    }

    struct Report {
        var uploaded: [String] = []
        var skipped: [String] = []
    }

    // MARK: Connecting

    /// Signs in through the browser and stores the session. `log` gets progress lines.
    static func connect(server raw: String, log: @escaping (String) -> Void = { _ in }) async throws -> Session {
        let server = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let serverURL = URL(string: server), serverURL.scheme == "https" || serverURL.host == "localhost" || serverURL.host == "127.0.0.1" else {
            throw SyncError("The server address has to start with https://")
        }
        let api = serverURL.appendingPathComponent("api/v1")

        log("Looking up \(server)…")
        let (_, challenge) = try await URLSession.shared.data(from: api)
        guard let http = challenge as? HTTPURLResponse, http.statusCode == 401,
              let header = http.value(forHTTPHeaderField: "WWW-Authenticate"),
              let prmURL = quoted("resource_metadata", in: header).flatMap(URL.init(string:))
        else { throw SyncError("\(server) doesn't look like a CF Recorder sync server.") }

        let prm = try await getJSON(prmURL)
        guard let resource = prm["resource"] as? String,
              let issuer = (prm["authorization_servers"] as? [String])?.first,
              let issuerURL = URL(string: issuer), let host = issuerURL.host
        else { throw SyncError("The server's resource metadata is incomplete.") }

        // RFC 8414: the issuer's path goes after the well-known segment.
        var metadataURL = URLComponents()
        metadataURL.scheme = issuerURL.scheme
        metadataURL.host = host
        metadataURL.port = issuerURL.port
        metadataURL.path = "/.well-known/oauth-authorization-server" + (issuerURL.path == "/" ? "" : issuerURL.path)
        let asm = try await getJSON(metadataURL.url!)
        guard asm["issuer"] as? String == issuer,
              let authorize = (asm["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = asm["token_endpoint"] as? String,
              let register = (asm["registration_endpoint"] as? String).flatMap(URL.init(string:))
        else { throw SyncError("The server's OAuth metadata is incomplete or doesn't support app registration.") }

        log("Registering CF Recorder with the server…")
        let registration = try await postJSON(register, [
            "client_name": "CF Recorder on \(Host.current().localizedName ?? "a Mac")",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        guard let clientId = registration["client_id"] as? String else {
            throw SyncError("The server refused to register the app: \(registration["error_description"] ?? registration["error"] ?? "no reason given")")
        }

        let verifier = randomString(32)
        let challengeValue = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomString(16)
        let listener = try await LoopbackListener.start()
        let redirect = "http://127.0.0.1:\(listener.port)/callback"

        var auth = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        auth.queryItems = (auth.queryItems ?? []) + [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challengeValue),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: "recordings:read recordings:write offline_access"),
            .init(name: "resource", value: resource),
        ]
        log("Finish signing in in your browser. If it didn't open, visit:\n\(auth.url!.absoluteString)")
        let authURL = auth.url!
        _ = await MainActor.run { NSWorkspace.shared.open(authURL) }

        let callback = try await listener.waitForCallback(timeout: 300)
        if let error = callback["error"] {
            throw SyncError(error == "access_denied" ? "You cancelled the connection." : "Sign-in failed: \(callback["error_description"] ?? error)")
        }
        guard callback["state"] == state, let code = callback["code"] else {
            throw SyncError("The sign-in response didn't match. Try connecting again.")
        }
        if let iss = callback["iss"], iss != issuer { throw SyncError("The sign-in came back from the wrong server.") }

        let tokens = try await postForm(URL(string: token)!, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": clientId, "code_verifier": verifier, "resource": resource,
        ])
        var session = try Session(server: server, resource: resource, issuer: issuer, tokenEndpoint: token,
                                  clientId: clientId, tokens: tokens)
        session.email = try? await getJSON(api, token: session.accessToken)["user"] as? String
        try Keychain.save(session)
        log("Connected\(session.email.map { " as \($0)" } ?? "").")
        return session
    }

    static func disconnect() {
        Keychain.delete()
    }

    static var session: Session? { Keychain.load() }

    /// A fresh access token, refreshing it when it's about to run out.
    static func accessToken() async throws -> (Session, String) {
        guard var session = Keychain.load() else { throw SyncError("Sync isn't connected. Connect in Settings → Sync.") }
        if session.accessExpiry.timeIntervalSinceNow > 60 { return (session, session.accessToken) }
        guard let refresh = session.refreshToken else { throw SyncError("The sync sign-in expired. Connect again in Settings → Sync.") }
        let tokens = try await postForm(URL(string: session.tokenEndpoint)!, [
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": session.clientId, "resource": session.resource,
        ])
        guard tokens["access_token"] != nil else {
            throw SyncError("The sync sign-in expired. Connect again in Settings → Sync.")
        }
        let email = session.email
        session = try Session(server: session.server, resource: session.resource, issuer: session.issuer,
                              tokenEndpoint: session.tokenEndpoint, clientId: session.clientId, tokens: tokens,
                              keepingRefresh: refresh)
        session.email = email
        try Keychain.save(session)
        return (session, session.accessToken)
    }

    // MARK: Syncing

    /// Uploads whatever in `folder` differs from the server's copy. Pass `skipAudio` while
    /// the call is still recording, since the m4a files are half-written.
    static func sync(folder: URL, skipAudio: Bool = false) async throws -> Report {
        let (session, token) = try await accessToken()
        let id = folder.lastPathComponent
        let callURL = URL(string: session.server)!.appendingPathComponent("api/v1/calls").appendingPathComponent(id)

        var remote: [String: String] = [:]
        let (data, response) = try await authed(URLRequest(url: callURL), token: token)
        if (response as? HTTPURLResponse)?.statusCode == 200,
           let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = body["files"] as? [[String: Any]] {
            for f in files { if let n = f["name"] as? String { remote[n] = f["sha256"] as? String ?? "" } }
        }

        var report = Report()
        for name in syncedFiles {
            let file = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            if skipAudio && name.hasSuffix(".m4a") { continue }
            let hash = try sha256(of: file)
            if remote[name] == hash {
                report.skipped.append(name)
                continue
            }
            try await upload(file, to: callURL.appendingPathComponent("files").appendingPathComponent(name), sha256: hash)
            report.uploaded.append(name)
        }
        return report
    }

    private static func upload(_ file: URL, to url: URL, sha256 hash: String) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size <= singlePutLimit {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(hash, forHTTPHeaderField: "X-Content-SHA256")
            let (_, token) = try await accessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
            try check(response, data, "Uploading \(file.lastPathComponent)")
            return
        }

        // Too big for one Worker request: go in parts.
        var start = URLRequest(url: url.appendingPathComponent("uploads"))
        start.httpMethod = "POST"
        start.setValue(hash, forHTTPHeaderField: "X-Content-SHA256")
        let (startData, startResponse) = try await authed(start)
        try check(startResponse, startData, "Starting the upload of \(file.lastPathComponent)")
        guard let uploadId = (try JSONSerialization.jsonObject(with: startData) as? [String: Any])?["uploadId"] as? String else {
            throw SyncError("The server didn't start the upload.")
        }
        let base = url.appendingPathComponent("uploads").appendingPathComponent(uploadId)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parts: [[String: Any]] = []
        var number = 1
        while let chunk = try handle.read(upToCount: partSize), !chunk.isEmpty {
            var put = URLRequest(url: base.appendingPathComponent(String(number)))
            put.httpMethod = "PUT"
            let (_, token) = try await accessToken()
            put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.upload(for: put, from: chunk)
            try check(response, data, "Uploading part \(number) of \(file.lastPathComponent)")
            if let part = try JSONSerialization.jsonObject(with: data) as? [String: Any] { parts.append(part) }
            number += 1
        }
        var finish = URLRequest(url: base)
        finish.httpMethod = "POST"
        finish.setValue("application/json", forHTTPHeaderField: "Content-Type")
        finish.httpBody = try JSONSerialization.data(withJSONObject: ["parts": parts])
        let (data, response) = try await authed(finish)
        try check(response, data, "Finishing the upload of \(file.lastPathComponent)")
    }

    // MARK: Helpers

    private static func authed(_ request: URLRequest, token: String? = nil) async throws -> (Data, URLResponse) {
        var request = request
        let bearer: String
        if let token { bearer = token } else { bearer = try await accessToken().1 }
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: request)
    }

    private static func check(_ response: URLResponse, _ data: Data, _ what: String) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw SyncError("\(what) failed (\(http.statusCode))\(message.map { ": \($0)" } ?? "").")
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func getJSON(_ url: URL, token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data, "Reading \(url.path)")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func postForm(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        request.httpBody = fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            throw SyncError("The server refused the token request: \(body["error_description"] ?? body["error"] ?? "no reason given").")
        }
        return body
    }

    private static func quoted(_ key: String, in header: String) -> String? {
        guard let range = header.range(of: "\(key)=\"") else { return nil }
        let rest = header[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    private static func randomString(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(data)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

extension SyncClient.Session {
    init(server: String, resource: String, issuer: String, tokenEndpoint: String, clientId: String,
         tokens: [String: Any], keepingRefresh: String? = nil) throws {
        guard let access = tokens["access_token"] as? String else {
            throw SyncError("The server didn't hand back an access token.")
        }
        let ttl = (tokens["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        self.init(server: server, resource: resource, issuer: issuer, tokenEndpoint: tokenEndpoint,
                  clientId: clientId, accessToken: access, accessExpiry: Date().addingTimeInterval(ttl),
                  refreshToken: tokens["refresh_token"] as? String ?? keepingRefresh, email: nil)
    }
}

struct SyncError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The session lives in one Keychain item so the app and the `sync` command share it.
private enum Keychain {
    static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.askscottpierce.cf-recorder.sync",
        kSecAttrAccount as String: "session",
    ]

    static func save(_ session: SyncClient.Session) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw SyncError("Couldn't save the sync sign-in to the Keychain (\(added)).") }
        } else if status != errSecSuccess {
            throw SyncError("Couldn't save the sync sign-in to the Keychain (\(status)).")
        }
    }

    static func load() -> SyncClient.Session? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SyncClient.Session.self, from: data)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cf-recorder.oauth-callback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private(set) var port: UInt16 = 0

    private init(_ listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let me = LoopbackListener(try NWListener(using: params))
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            // Handlers run on `queue`, one at a time, so this flag needs no lock.
            nonisolated(unsafe) var resumed = false
            me.listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    me.port = me.listener.port?.rawValue ?? 0
                    ready.resume()
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: error)
                default: break
                }
            }
            me.listener.newConnectionHandler = { me.handle($0) }
            me.listener.start(queue: me.queue)
        }
        return me
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        defer { listener.cancel() }
        return try await withCheckedThrowingContinuation { c in
            queue.async {
                self.continuation = c
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(SyncError("Timed out waiting for the browser sign-in.")))
                }
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            let isCallback = target.hasPrefix("/callback")
            let ok = isCallback && items.contains { $0.name == "code" }
            let html = """
            <!doctype html><meta charset="utf-8"><title>CF Recorder</title>
            <body style="margin:0;display:grid;place-items:center;height:100vh;background:#1a1a1a;color:#e0e0e0;font:15px -apple-system,sans-serif">
            <div><p style="font:600 12px Menlo,monospace;letter-spacing:.08em;color:#8a8a8a"><span style="color:#e85d00">//</span> \(ok ? "CONNECTED" : "NOT_CONNECTED")</p>
            <p style="font-size:20px">\(ok ? "CF Recorder is connected. You can close this tab." : "That didn't work. Head back to CF Recorder.")</p></div>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback {
                var params: [String: String] = [:]
                for item in items { params[item.name] = item.value ?? "" }
                self.finish(.success(params))
            }
        }
    }
}
