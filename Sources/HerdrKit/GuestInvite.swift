import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A one-time invite to reach one agent on someone else's machine.
///
/// The payload is JSON, base64url-encoded without padding. Four link forms carry it:
/// the app link `herdrup://guest-invite#<payload>` (the QR code), the short web link
/// `https://<relay>/i/<id><key>` that owners share, the long web link
/// `https://<relay>/i/<payload>`, and the older web link `https://<relay>/i#<payload>`.
/// A short link names an invite the relay holds sealed with `key`; only `id` is ever sent
/// to the relay: `resolve` fetches the sealed invite from the link's own relay and opens
/// it. Messages splits a link at the `#`, so web links carry everything in the path; the
/// relay's landing page passes it through without storing or logging it. A web link only
/// counts on its own invite's relay.
public struct GuestInvite: Equatable, Sendable {
    public static let appLinkPrefix = "herdrup://guest-invite#"
    /// The longest label the app will display from an invite.
    public static let maxLabelLength = 128

    public let relay: URL
    public let hostID: String
    public let hostPublicKey: Data
    public let inviteID: String
    public let secret: String
    public let machineLabel: String
    public let ownerName: String
    public let agentName: String
    public let guestName: String
    public let expires: Date

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The text holds no guest invite link.
        case notAnInvite
        /// The payload is not base64url JSON with the expected fields.
        case malformed(String)
        /// A newer app wrote this invite.
        case unsupportedVersion(Int)
        case expired
        /// The relay no longer holds a short link's invite: it expired or the owner revoked it.
        case revoked
        /// A short link's invite could not be fetched; trying again may work.
        case unreachable

        public var description: String {
            switch self {
            case .notAnInvite: return "this isn't a HerdrUp invite link"
            case .malformed(let field): return "this invite is damaged (\(field))"
            case .unsupportedVersion(let v): return "this invite needs a newer HerdrUp (version \(v))"
            case .expired: return "this invite has expired; ask for a new one"
            case .revoked: return "this invite has expired or was revoked."
            case .unreachable: return "couldn't reach the invite server; check your connection and try again"
            }
        }
    }

    public init(
        relay: URL, hostID: String, hostPublicKey: Data, inviteID: String, secret: String,
        machineLabel: String, ownerName: String, agentName: String, guestName: String, expires: Date
    ) {
        self.relay = relay
        self.hostID = hostID
        self.hostPublicKey = hostPublicKey
        self.inviteID = inviteID
        self.secret = secret
        self.machineLabel = machineLabel
        self.ownerName = ownerName
        self.agentName = agentName
        self.guestName = guestName
        self.expires = expires
    }

    /// Parses an invite from a link that carries its payload (every form but the short web
    /// link), or from text that contains one (a pasted message, a scanned QR). Expiry is
    /// checked against `now`. A short link needs the network: use `resolve`.
    public static func parse(_ text: String, now: Date = Date()) throws -> GuestInvite {
        try first(in: text) { link in
            guard case .payload(let payload) = link.content else { throw Failure.notAnInvite }
            let invite = try decode(json: try json(fromPayload: payload))
            if let web = link.web, !web.isOnRelay(invite.relay) { throw Failure.notAnInvite }
            if invite.isExpired(now: now) { throw Failure.expired }
            return invite
        }
    }

    /// Fetches a short link's sealed invite from `url`. Returns the blob, throws
    /// `Failure.revoked` when the relay no longer holds it and `Failure.unreachable` when
    /// it could not be asked.
    public typealias SealedInviteFetch = @Sendable (_ url: URL) async throws -> Data

    /// `parse`, plus the short web link: its sealed invite is fetched from the link's own
    /// relay with `fetch`, opened with the link's key, and must name that relay. Any error
    /// `fetch` throws other than a `Failure` counts as `Failure.unreachable`.
    public static func resolve(
        _ text: String, now: Date = Date(), fetch: SealedInviteFetch = GuestInvite.fetchSealedInvite
    ) async throws -> GuestInvite {
        guard let short = shortLink(in: text) else { return try parse(text, now: now) }
        guard case .sealed(let id, let key) = short.content, let web = short.web else {
            throw Failure.notAnInvite
        }
        let blob: Data
        do {
            blob = try await fetch(web.sealedInviteURL(id: id))
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
        let invite = try decode(json: try open(sealed: blob, id: id, key: key))
        guard web.isOnRelay(invite.relay) else { throw Failure.malformed("relay") }
        if invite.isExpired(now: now) { throw Failure.expired }
        return invite
    }

    /// The first short web link in `text`, if any.
    static func shortLink(in text: String) -> Link? {
        candidates(in: text).lazy.compactMap(Link.init).first {
            if case .sealed = $0.content { return true }
            return false
        }
    }

    /// The longest sealed invite the relay stores.
    public static let maxSealedInviteSize = 2048

    /// Opens a sealed invite: AES-128-GCM with the link's 16-byte key, laid out as
    /// nonce (12) || ciphertext || tag (16), authenticated with the ASCII invite id.
    static func open(sealed blob: Data, id: String, key: String) throws -> Data {
        guard let keyBytes = Base64URL.decode(key), keyBytes.count == 16 else { throw Failure.malformed("key") }
        guard blob.count > 12 + 16, blob.count <= maxSealedInviteSize else { throw Failure.malformed("seal") }
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            return try AES.GCM.open(box, using: SymmetricKey(data: keyBytes), authenticating: Data(id.utf8))
        } catch {
            throw Failure.malformed("seal")
        }
    }

    /// What arrives for `GET /v1/invite/{id}`: the response head, then the body in pieces.
    enum SealedInviteChunk: Sendable {
        /// `expectedLength` is the Content-Length, when the relay sent one.
        case response(status: Int, expectedLength: Int64?)
        case body(Data)
    }

    /// Reads a relay's answer to `GET /v1/invite/{id}`: 200 is the sealed invite, 404 an
    /// invite it no longer holds, anything else (a redirect included) a relay that could not
    /// answer. A body declared or found to be longer than `maxSealedInviteSize` is not a
    /// sealed invite: reading stops at the first byte past the cap, so a hostile host
    /// cannot make the phone hold more than that.
    static func readSealedInvite<Chunks: AsyncSequence>(_ chunks: Chunks) async throws -> Data
    where Chunks.Element == SealedInviteChunk {
        var answered = false
        var body = Data()
        for try await chunk in chunks {
            switch chunk {
            case .response(let status, let expectedLength):
                guard !answered else { throw Failure.unreachable }
                answered = true
                switch status {
                case 200: break
                case 404: throw Failure.revoked
                default: throw Failure.unreachable
                }
                if let expectedLength, expectedLength > Int64(maxSealedInviteSize) { throw Failure.malformed("seal") }
            case .body(let data):
                guard answered else { throw Failure.unreachable }
                guard body.count + data.count <= maxSealedInviteSize else { throw Failure.malformed("seal") }
                body.append(data)
            }
        }
        try Task.checkCancellation()
        guard answered else { throw Failure.unreachable }
        return body
    }

    /// The whole fetch, connecting included, gets this long; a trickling host is cut off.
    static let fetchDeadline: TimeInterval = 15

    /// `operation`, or `Failure.unreachable` once `seconds` have passed, whichever is first.
    static func withinDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.unreachable
            }
            defer { group.cancelAll() }
            // The first child to finish decides; the other is cancelled.
            return try await group.next()!
        }
    }

    /// The real `SealedInviteFetch`: one uncached GET that stays on the link's relay (no
    /// redirects), streamed through `readSealedInvite` and cut off after `fetchDeadline`.
    public static let fetchSealedInvite: SealedInviteFetch = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: fetchDeadline)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = fetchDeadline
        config.timeoutIntervalForResource = fetchDeadline
        let (chunks, continuation) = AsyncThrowingStream<SealedInviteChunk, Error>.makeStream()
        let download = SealedInviteDownload(continuation)
        let session = URLSession(configuration: config, delegate: download, delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in task.cancel() }
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        task.resume()
        return try await withinDeadline(fetchDeadline) { try await readSealedInvite(chunks) }
    }

    /// The text itself, then each whitespace-separated word in it.
    private static func candidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [trimmed] + trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The invite `read` makes of the first link in `text` it accepts; otherwise the first
    /// failure, or `notAnInvite` when there was no link at all.
    private static func first(in text: String, _ read: (Link) throws -> GuestInvite) throws -> GuestInvite {
        var damaged: Failure?
        for candidate in candidates(in: text) {
            guard let link = Link(candidate) else { continue }
            do {
                return try read(link)
            } catch let failure as Failure {
                damaged = damaged ?? failure
            }
        }
        throw damaged ?? Failure.notAnInvite
    }

    /// Whether `text` has the shape of an invite link in any form. The payload and the
    /// relay are only checked by `parse` and `resolve`.
    public static func isInviteLink(_ text: String) -> Bool {
        Link(text) != nil
    }

    /// `text` with an older `…/i#<payload>` web link rewritten to the `…/i/<payload>`
    /// form that survives Messages; any other text comes back unchanged.
    public static func pathFormWebLink(_ text: String) -> String {
        guard let link = Link(text), case .payload(let payload) = link.content,
              let web = link.web, web.fragmentForm, let base = web.base.string
        else { return text }
        return "\(base)/i/\(payload)"
    }

    /// An invite link split into what it carries and, for a web link, where it points.
    struct Link {
        enum Content: Equatable {
            /// The base64url invite itself.
            case payload(String)
            /// A short link: the relay's id for the sealed invite and the key that opens it.
            case sealed(id: String, key: String)
        }

        let content: Content
        let web: Web?

        /// A short link's id: 9 random bytes, base64url without padding.
        static let sealedIDLength = 12
        /// A short link's key: 16 random bytes, base64url without padding.
        static let sealedKeyLength = 22

        /// A web link's origin and the path before `/i`, which must be its relay's.
        struct Web {
            /// Scheme, host, port and relay path; no query or fragment.
            let base: URLComponents
            /// `/i#<payload>` rather than `/i/<payload>`.
            let fragmentForm: Bool

            func isOnRelay(_ relay: URL) -> Bool {
                guard let relay = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { return false }
                var relayPath = relay.percentEncodedPath
                while relayPath.hasSuffix("/") { relayPath.removeLast() }
                return relay.scheme == base.scheme
                    && relay.host?.lowercased() == base.host?.lowercased()
                    && relay.port == base.port
                    && relayPath == base.percentEncodedPath
            }

            /// Where this relay serves the sealed invite `id`.
            func sealedInviteURL(id: String) -> URL {
                var components = base
                components.percentEncodedPath = base.percentEncodedPath + "/v1/invite/" + id
                // Built from a URL that already parsed, plus a validated id.
                return components.url!
            }
        }

        /// Exactly `herdrup://guest-invite#<payload>`, `https://<host>[/<path>]/i/<id><key>`,
        /// `https://<host>[/<path>]/i/<payload>` or `https://<host>[/<path>]/i#<payload>`;
        /// nil for anything else.
        init?(_ text: String) {
            if text.hasPrefix(GuestInvite.appLinkPrefix) {
                let payload = String(text.dropFirst(GuestInvite.appLinkPrefix.count))
                guard !payload.isEmpty else { return nil }
                self.init(content: .payload(payload), web: nil)
                return
            }
            guard let components = URLComponents(string: text),
                  components.scheme == "https",
                  components.host?.isEmpty == false,
                  components.user == nil, components.password == nil,
                  components.percentEncodedQuery == nil
            else { return nil }
            let path = components.percentEncodedPath
            let fragment = components.percentEncodedFragment
            let content: Content
            let basePath: Substring
            let fragmentForm: Bool
            if let short = Self.shortForm(path: path, fragment: fragment) {
                content = .sealed(id: short.id, key: short.key)
                basePath = short.basePath
                fragmentForm = false
            } else if let fragment, path.hasSuffix("/i") {
                guard !fragment.isEmpty else { return nil }
                content = .payload(fragment)
                basePath = path.dropLast(2)
                fragmentForm = true
            } else {
                // A long payload is hundreds of characters and has no fragment.
                guard fragment == nil, let marker = path.range(of: "/i/", options: .backwards) else { return nil }
                let payload = String(path[marker.upperBound...])
                basePath = path[..<marker.lowerBound]
                guard !payload.isEmpty, !payload.contains("/") else { return nil }
                content = .payload(payload)
                fragmentForm = false
            }
            var base = URLComponents()
            base.scheme = components.scheme
            base.percentEncodedHost = components.percentEncodedHost
            base.port = components.port
            base.percentEncodedPath = String(basePath)
            self.init(content: content, web: Web(base: base, fragmentForm: fragmentForm))
        }

        private init(content: Content, web: Web?) {
            self.content = content
            self.web = web
        }

        /// The one place that knows a short link's shape, `<base>/i/<id><key>`: short iff
        /// the last path segment is exactly 34 base64url characters (a 12-char id, then a
        /// 22-char key) and there is no fragment. Returns the relay path before `/i` with
        /// the id and key, or nil for any other link.
        static func shortForm(path: String, fragment: String?) -> (basePath: Substring, id: String, key: String)? {
            guard fragment == nil, let marker = path.range(of: "/i/", options: .backwards) else { return nil }
            let segment = path[marker.upperBound...]
            guard segment.count == sealedIDLength + sealedKeyLength,
                  segment.unicodeScalars.allSatisfy(isBase64URL)
            else { return nil }
            let id = segment.prefix(sealedIDLength)
            return (path[..<marker.lowerBound], String(id), String(segment[id.endIndex...]))
        }

        private static func isBase64URL(_ scalar: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "-" || scalar == "_"
        }
    }

    private struct Wire: Codable {
        let v: Int
        let relay: String
        let hostID: String
        let hostPub: String
        let inviteID: String
        let secret: String
        let machineLabel: String
        let ownerName: String
        let agentName: String
        let guestName: String
        let expiresUnix: Int64

        enum CodingKeys: String, CodingKey {
            case v, relay, secret
            case hostID = "host_id"
            case hostPub = "host_pub"
            case inviteID = "invite_id"
            case machineLabel = "machine_label"
            case ownerName = "owner_name"
            case agentName = "agent_name"
            case guestName = "guest_name"
            case expiresUnix = "expires_unix"
        }
    }

    private struct VersionProbe: Decodable { let v: Int }

    static func json(fromPayload payload: String) throws -> Data {
        guard let json = Base64URL.decode(payload) else { throw Failure.malformed("encoding") }
        return json
    }

    static func decode(json: Data) throws -> GuestInvite {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: json) else {
            throw Failure.malformed("json")
        }
        guard probe.v == 1 else { throw Failure.unsupportedVersion(probe.v) }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: json)
        } catch DecodingError.keyNotFound(let key, _) {
            throw Failure.malformed(key.stringValue)
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context) {
            throw Failure.malformed(context.codingPath.last?.stringValue ?? "json")
        } catch {
            throw Failure.malformed("json")
        }

        guard let relay = URL(string: wire.relay), Self.isAllowedRelay(relay) else {
            throw Failure.malformed("relay")
        }
        guard Base64URL.decode(wire.hostID)?.count == 16 else { throw Failure.malformed("host_id") }
        guard let hostPub = Base64URL.decode(wire.hostPub), hostPub.count == 32 else {
            throw Failure.malformed("host_pub")
        }
        guard Base64URL.decode(wire.inviteID)?.count == 16 else { throw Failure.malformed("invite_id") }
        guard Base64URL.decode(wire.secret)?.count == 32 else { throw Failure.malformed("secret") }
        guard GuestName.isValid(wire.guestName) else { throw Failure.malformed("guest_name") }
        for (field, value) in [("machine_label", wire.machineLabel), ("owner_name", wire.ownerName),
                               ("agent_name", wire.agentName)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, value.count <= maxLabelLength,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw Failure.malformed(field) }
        }
        guard wire.expiresUnix > 0 else { throw Failure.malformed("expires_unix") }

        return GuestInvite(
            relay: relay, hostID: wire.hostID, hostPublicKey: hostPub, inviteID: wire.inviteID,
            secret: wire.secret, machineLabel: wire.machineLabel, ownerName: wire.ownerName,
            agentName: wire.agentName, guestName: wire.guestName,
            expires: Date(timeIntervalSince1970: TimeInterval(wire.expiresUnix)))
    }

    /// HTTPS, or plain HTTP to this machine for a relay under local development.
    /// The relay only forwards Noise ciphertext, but a guest socket still must not
    /// be steered to an arbitrary cleartext endpoint.
    static func isAllowedRelay(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        switch url.scheme {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        default: return false
        }
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now >= expires
    }

    /// The base64url payload every link form carries.
    public var payload: String {
        let wire = Wire(
            v: 1, relay: relay.absoluteString, hostID: hostID, hostPub: Base64URL.encode(hostPublicKey),
            inviteID: inviteID, secret: secret, machineLabel: machineLabel, ownerName: ownerName,
            agentName: agentName, guestName: guestName, expiresUnix: Int64(expires.timeIntervalSince1970))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a struct of strings and integers cannot fail.
        return Base64URL.encode(try! encoder.encode(wire))
    }

    public var appLink: URL {
        URL(string: Self.appLinkPrefix + payload)!
    }

    /// The shareable web link, in the path form the daemon hands out.
    public var webLink: URL {
        var base = relay.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/i/\(payload)")!
    }
}

/// Feeds one `GET /v1/invite/{id}` into `GuestInvite.readSealedInvite` as it arrives,
/// refuses every redirect (the GET must stay on the link's relay) and cancels the task
/// itself once more than `maxSealedInviteSize` bytes came in.
private final class SealedInviteDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let chunks: AsyncThrowingStream<GuestInvite.SealedInviteChunk, Error>.Continuation
    private let lock = NSLock()
    private var received = 0

    init(_ chunks: AsyncThrowingStream<GuestInvite.SealedInviteChunk, Error>.Continuation) {
        self.chunks = chunks
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            chunks.finish(throwing: GuestInvite.Failure.unreachable)
            completionHandler(.cancel)
            return
        }
        let length = http.expectedContentLength
        chunks.yield(.response(status: http.statusCode, expectedLength: length >= 0 ? length : nil))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        chunks.yield(.body(data))
        let total = lock.withLock { () -> Int in
            received += data.count
            return received
        }
        if total > GuestInvite.maxSealedInviteSize { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The redirect response itself then completes the task, and reads as unreachable.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            chunks.finish(throwing: error)
        } else {
            chunks.finish()
        }
    }
}

/// base64url without padding, as the guest protocol uses everywhere.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: rejects padding and the standard-alphabet `+` and `/`.
    public static func decode(_ text: String) -> Data? {
        guard !text.contains(where: { $0 == "=" || $0 == "+" || $0 == "/" }) else { return nil }
        var standard = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { standard += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: standard)
    }
}
