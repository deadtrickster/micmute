import Foundation

enum MotuError: LocalizedError {
    case http(Int)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .http(let code): return "device answered HTTP \(code)"
        case .badResponse: return "unreadable answer from device"
        }
    }
}

enum DatastoreEvent {
    /// The device held the request for its full window and nothing changed.
    case unchanged
    /// Changed keys only (small delta), or the whole tree if the device no longer
    /// knows our version.
    case changed([String: Any])
}

/// Client for the MOTU datastore API.
///
///   read  : GET  /datastore, optionally `If-None-Match: <etag>` — this is a long-poll:
///           the device holds the request ~10 s and then answers either
///           `304` with an empty body (nothing changed) or `200` with a JSON object
///           holding *only the keys that changed*. That is how the app subscribes
///           instead of polling.
///   write : POST /datastore?client=<id>, multipart/form-data, field `json` = {path: value}
final class MotuClient {
    let host: String
    private var etag: String?

    /// Ephemeral, no URL cache: nothing is written to disk, and the connection is
    /// kept alive so the long-poll cycle costs one socket rather than one handshake.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 40      // the device holds ~10 s
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    init(host: String) { self.host = host }

    private func url(_ path: String) -> URL? { URL(string: "http://\(host)/\(path)") }

    /// Full read: first sync, resync after an error. Learns the ETag.
    func fetchAll() async throws -> [String: Any] {
        guard let u = url("datastore") else { throw MotuError.badResponse }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MotuError.badResponse }
        guard http.statusCode == 200 else { throw MotuError.http(http.statusCode) }
        etag = http.value(forHTTPHeaderField: "ETag")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MotuError.badResponse
        }
        return obj
    }

    /// One long-poll. Returns after the device answers — up to ~10 s of doing nothing.
    func poll() async throws -> DatastoreEvent {
        guard let u = url("datastore") else { throw MotuError.badResponse }
        var req = URLRequest(url: u)
        req.timeoutInterval = 40
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MotuError.badResponse }
        if let newTag = http.value(forHTTPHeaderField: "ETag") { etag = newTag }
        switch http.statusCode {
        case 304:
            return .unchanged
        case 200:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MotuError.badResponse
            }
            return .changed(obj)
        default:
            throw MotuError.http(http.statusCode)
        }
    }

    func write(_ values: [String: Any]) async throws {
        guard let u = url("datastore?client=micmute") else { throw MotuError.badResponse }
        let boundary = "----MicMute\(UInt32.random(in: 1000...999999))"
        let json = try JSONSerialization.data(withJSONObject: values)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"json\"\r\n\r\n".data(using: .utf8)!)
        body.append(json)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (_, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MotuError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw MotuError.http(http.statusCode) }
    }

    /// First host in `candidates` whose datastore answers.
    static func discover(candidates: [String]) async -> (MotuClient, [String: Any])? {
        for host in candidates {
            let client = MotuClient(host: host)
            if let all = try? await client.fetchAll(), all[Cfg.mutePath] != nil {
                return (client, all)
            }
        }
        return nil
    }
}

/// Datastore values arrive as numbers, strings or bools; normalise the ones we care about.
enum Val {
    static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
    static func bool(_ any: Any?) -> Bool? {
        guard let n = num(any) else { return nil }
        return n != 0
    }
    static func str(_ any: Any?) -> String? { any as? String }
}
