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

/// Client for the MOTU datastore API.
///
///   read  : GET /datastore — once at startup, and again only when something suggests the
///           device changed: it reappeared in CoreAudio, the panel was opened, or a write
///           failed. The device also offers a long-poll (`If-None-Match` answers `304`
///           after ~10 s, or `200` with just the changed keys), and an earlier version of
///           this app used it; it is deliberately not used here. The app reads once and
///           then owns the microphone, so idle means no traffic and no wakeups at all.
///   write : POST /datastore?client=<id>, multipart/form-data, field `json` = {path: value}
final class MotuClient {
    let host: String

    /// Ephemeral, no URL cache: nothing is written to disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    init(host: String) { self.host = host }

    private func url(_ path: String) -> URL? { URL(string: "http://\(host)/\(path)") }

    /// The whole datastore: startup, resync after an error, or after the device came back.
    func fetchAll() async throws -> [String: Any] {
        guard let u = url("datastore") else { throw MotuError.badResponse }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MotuError.badResponse }
        guard http.statusCode == 200 else { throw MotuError.http(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MotuError.badResponse
        }
        return obj
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
