import AppKit
import CoreAudio
import Combine
import Foundation

enum MicState: Equatable {
    case offline      // can't reach the interface
    case idle         // unmuted, nothing capturing
    case live         // unmuted and something is capturing -> you are audible
    case mutedIdle    // muted, nothing capturing
    case mutedInUse   // muted, but an app is capturing (in a call)
}

/// All state comes from two subscriptions, so nothing is polled:
///   * the interface's datastore long-poll (it holds the request and pushes deltas)
///   * CoreAudio property listeners for "an app started/stopped capturing"
/// The only timer in the app runs while the panel is open, for the level meter.
@MainActor
final class MicModel: ObservableObject {
    @Published var muted = false
    @Published var capturing: [String] = []
    @Published var connected = false
    @Published var gainDb: Double = 47
    @Published var gainRange: ClosedRange<Double> = 0...63
    @Published var levelDb: Float = -160
    @Published var micDenied = false
    @Published var host = Prefs.host ?? Cfg.hosts[0]
    @Published var inputName = "Mic Inst 1"
    @Published var deviceName = "828ES"
    @Published var lastError: String?

    let meter = Meter()
    private let usage = UsageMonitor()
    private var client: MotuClient?
    private var deviceID: AudioObjectID?
    private var watchTask: Task<Void, Never>?

    /// The last known value of every datastore key we care about, built up from deltas.
    private var values: [String: Any] = [:]

    // Echoes of our own writes arrive as deltas a moment later; ignoring them for a
    // beat keeps the slider and the button from flickering back under the user.
    private var localMuteWriteAt: Date?
    private var localGainWriteAt: Date?
    private var nextRoutingAttempt = Date.distantPast

    var state: MicState {
        if !connected { return .offline }
        if muted { return capturing.isEmpty ? .mutedIdle : .mutedInUse }
        return capturing.isEmpty ? .idle : .live
    }

    var headline: String {
        switch state {
        case .offline: return "Interface offline"
        case .idle:    return "Mic idle"
        case .live:    return "Live — you are being recorded"
        case .mutedIdle: return "Muted"
        case .mutedInUse: return "Muted — in use by \(capturing.first ?? "an app")"
        }
    }

    var detail: String {
        switch state {
        case .offline:
            return "No answer from \(host). Check the 828ES is on and on the network."
        case .idle:
            return "Not muted, nothing is capturing."
        case .live:
            return capturing.joined(separator: ", ") + " is capturing input 1."
        case .mutedIdle:
            return "Input 1 is silenced in the device itself."
        case .mutedInUse:
            return capturing.joined(separator: ", ") + " is capturing — but it gets silence."
        }
    }

    // MARK: - start

    func start() async {
        usage.onChange = { [weak self] names in self?.capturing = names }
        usage.start()
        await resync()
        startWatching()
    }

    private func log(_ m: String) { FileHandle.standardError.write(Data("[micmute] \(m)\n".utf8)) }

    func audioDevice() -> AudioObjectID? {
        if let deviceID, CA.deviceExists(deviceID) { return deviceID }
        deviceID = CA.findInterface()
        return deviceID
    }

    /// Establish the connection once; every action goes through here.
    @discardableResult
    private func ensureClient() async -> MotuClient? {
        if let client { return client }
        guard let found = await MotuClient.discover(candidates: [host] + Cfg.hosts) else {
            connected = false
            return nil
        }
        client = found.0
        Prefs.host = found.0.host
        host = found.0.host
        connected = true
        absorbFull(found.1)
        return found.0
    }

    // MARK: - the subscription

    /// One long-poll at a time, forever. The device answers `unchanged` after its ~10 s
    /// window, or `changed` with just the keys that moved — no polling, no full reads.
    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            var backoff: UInt64 = 0
            while !Task.isCancelled {
                guard let self else { return }
                guard let client = await self.ensureClient() else {
                    backoff = self.nextBackoff(backoff)
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    await self.resync()
                    continue
                }
                do {
                    switch try await client.poll() {
                    case .unchanged:
                        backoff = 0
                    case .changed(let delta):
                        backoff = 0
                        await self.absorb(delta)
                    }
                } catch {
                    await self.markOffline(error)
                    backoff = self.nextBackoff(backoff)
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    await self.resync()
                }
            }
        }
    }

    private func nextBackoff(_ current: UInt64) -> UInt64 {
        current == 0 ? 1 : min(current * 2, 10)
    }

    /// Full read: used at startup, after an error, and after we changed the routing.
    func resync() async {
        guard let client = await ensureClient() else { return }
        do {
            let all = try await client.fetchAll()
            connected = true
            lastError = nil
            absorbFull(all)
        } catch {
            await markOffline(error)
        }
    }

    /// Keep only the keys we use, so the 200 KB tree is not held on to.
    private func absorbFull(_ all: [String: Any]) {
        for key in Cfg.watchedKeys where all[key] != nil { values[key] = all[key] }
        if let model = Cfg.avbValue(all, "model_name") { deviceName = model }
        apply(values)
        Task { await ensureRoutingIfNeeded() }
    }

    private func absorb(_ delta: [String: Any]) async {
        // A delta carries only the keys that changed — but if the device no longer knew
        // our ETag (a reboot, say) it answers with the whole 200 KB tree instead, so
        // keep only the keys we track and never let the dictionary grow into that.
        for (key, value) in delta where Cfg.watchedKeys.contains(key) { values[key] = value }
        if let model = Cfg.avbValue(delta, "model_name") { deviceName = model }
        connected = true
        lastError = nil
        if ProcessInfo.processInfo.environment["MICMUTE_DEBUG"] != nil {
            log("delta \(delta.keys.sorted().prefix(6))\(delta.count > 6 ? " +" : "")")
        }
        apply(values)
        await ensureRoutingIfNeeded()
    }

    private func apply(_ v: [String: Any]) {
        if let m = Val.bool(v[Cfg.mutePath]), !isRecent(localMuteWriteAt) { muted = m }
        if let g = Val.num(v[Cfg.trimPath]), !isRecent(localGainWriteAt) { gainDb = g }
        if let r = Val.str(v[Cfg.trimRangePath]) {
            let parts = r.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { gainRange = parts[0]...parts[1] }
        }
        if let n = Val.str(v[Cfg.inputNamePath]), !n.isEmpty { inputName = n }
    }

    private func isRecent(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < 1.5
    }

    private func markOffline(_ error: Error) async {
        connected = false
        log("device unreachable: \(error.localizedDescription)")
        lastError = error.localizedDescription
    }

    /// Set once the user asks for the interface's own routing back: nothing this app
    /// does may then put the mixer in the path again.
    private var enforcementStopped = false

    /// Keep Computer 1 fed from the mixer, so the mute has something to act on.
    /// Re-applied after a preset change or a power cycle; a no-op when already correct.
    /// Rate limited: without it a rejected write would bounce off the delta forever.
    private func ensureRoutingIfNeeded() async {
        guard !enforcementStopped, Date() >= nextRoutingAttempt else { return }
        let ok = (Val.str(values[Cfg.computerSrcPath]) == Cfg.groupSource)
            && (Val.num(values[Cfg.sendPath]).map { abs($0 - 1.0) < 0.001 } ?? false)
            && (Val.num(values[Cfg.groupFaderPath]).map { abs($0 - Cfg.groupFaderCompensation) < 0.01 } ?? false)
            && (Val.bool(values[Cfg.groupMutePath]) == false)
        if ok { return }

        nextRoutingAttempt = Date().addingTimeInterval(3)
        guard let client = await ensureClient() else { return }
        do {
            try await client.write([
                Cfg.computerSrcPath: Cfg.groupSource,
                Cfg.sendPath: 1.0,
                Cfg.groupFaderPath: Cfg.groupFaderCompensation,
                Cfg.groupMutePath: 0,
            ])
            log("routing (re)applied")
        } catch {
            let message = "Could not route the mic through the mixer: \(error.localizedDescription)"
            if lastError != message {
                log(message)
                lastError = message
            }
        }
    }

    /// Put the interface back the way it shipped: Computer 1 straight from Mic Inst 1.
    /// The mute needs the mixer, so after this the hardware mute no longer does anything —
    /// the caller is expected to quit, and enforcement is switched off either way.
    func restoreInterfaceRouting() async {
        enforcementStopped = true
        guard let client = await ensureClient() else { return }
        try? await client.write([
            Cfg.computerSrcPath: Cfg.directSource,
            Cfg.sendPath: 0.0,
            Cfg.groupMutePath: 1,
            Cfg.groupFaderPath: 0.0,
            Cfg.mutePath: 0,
        ])
        muted = false
        localMuteWriteAt = Date()
        await resync()
    }

    // MARK: - actions

    func toggleMute() async {
        let target = !muted
        muted = target                       // optimistic: the button must feel instant
        localMuteWriteAt = Date()
        guard let client = await ensureClient() else { connected = false; return }
        do {
            try await client.write([Cfg.mutePath: target ? 1 : 0])
            connected = true
            lastError = nil
        } catch {
            muted = !target                  // roll back
            lastError = "Mute failed: \(error.localizedDescription)"
        }
    }

    private var gainWriteTask: Task<Void, Never>?
    private var pendingGain: Double?

    /// The slider is continuous; coalesce a drag into as few writes as possible and
    /// keep going until no newer value is waiting, so the last value is never lost.
    func setGain(_ value: Double) {
        gainDb = value
        localGainWriteAt = Date()
        pendingGain = value
        guard gainWriteTask == nil else { return }
        gainWriteTask = Task { [weak self] in
            while true {
                guard (try? await Task.sleep(nanoseconds: 120_000_000)) != nil else { break }
                guard let self, let v = self.pendingGain else { break }
                self.pendingGain = nil
                if let client = await self.ensureClient() {
                    try? await client.write([Cfg.trimPath: Int(v.rounded())])
                }
            }
            self?.gainWriteTask = nil
        }
    }

    // MARK: - metering (only while the panel is visible)

    func startMetering() async {
        guard let dev = audioDevice() else { micDenied = false; return }
        if !Meter.microphoneAuthorized() {
            let granted = await Meter.requestMicrophone()
            if !granted { micDenied = true; return }
        }
        micDenied = false
        meter.onLevel = { [weak self] db in
            guard let self else { return }
            // fast attack, gentle release so the bar reads like a meter
            self.levelDb = db > self.levelDb ? db : max(db, self.levelDb - 1.5)
        }
        meter.start(device: dev, channel: Cfg.computerChannel)
    }

    func stopMetering() {
        meter.onLevel = nil
        meter.stop()
        levelDb = -160
    }
}
