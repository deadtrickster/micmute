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

/// Thin client for the MOTU datastore API.
///   read : GET  /datastore                  (returns the whole tree as one JSON object)
///   write: POST /datastore?client=<id>      multipart/form-data, field `json` = {path: value}
final class MotuClient {
    let host: String
    init(host: String) { self.host = host }

    private func url(_ path: String) -> URL? { URL(string: "http://\(host)/\(path)") }

    func fetchAll() async throws -> [String: Any] {
        guard let u = url("datastore") else { throw MotuError.badResponse }
        var req = URLRequest(url: u)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
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
        req.timeoutInterval = 4
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (_, resp) = try await URLSession.shared.data(for: req)
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
