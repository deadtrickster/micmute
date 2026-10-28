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
    private let devices = DeviceMonitor()
    private var client: MotuClient?
    private var deviceID: AudioObjectID?

    /// The last values we read from (or wrote to) the device. The app is the only thing
    /// that manages this microphone, so this cache is the truth once the first read is in.
    private var values: [String: Any] = [:]

    /// Kept so a stale in-flight read cannot undo an optimistic click.
    private var localMuteWriteAt: Date?
    private var localGainWriteAt: Date?
    private var nextRoutingAttempt = Date.distantPast
    private var lastSyncAt = Date.distantPast
    private var interfaceWasPresent = true

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

        // Nothing polls. The one thing that can invalidate our picture is the interface
        // itself changing — unplugged, powered off, or back with its own routing again —
        // and CoreAudio tells us that for free.
        devices.onChange = { [weak self] in
            Task { @MainActor in await self?.interfaceListChanged() }
        }
        devices.start()

        await resync()
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

    // MARK: - reading the device

    /// Read the whole datastore. Called at startup, when the interface reappears, when the
    /// panel is opened (it may be hours later, and the front-panel gain knob is physical),
    /// and after a write fails.
    func resync() async {
        guard let client = await ensureClient() else { return }
        do {
            let all = try await client.fetchAll()
            connected = true
            lastError = nil
            lastSyncAt = Date()
            absorbFull(all)
        } catch {
            await markOffline(error)
        }
    }

    /// Cheap guard so opening the panel twice in a row does not read twice.
    func resyncIfStale(olderThan seconds: TimeInterval = 5) async {
        guard Date().timeIntervalSince(lastSyncAt) > seconds else { return }
        await resync()
    }

    /// The set of audio devices changed. Only a change in the interface's own presence is
    /// worth a read: plugging in headphones should not cost a datastore trip.
    private func interfaceListChanged() async {
        deviceID = nil
        let present = CA.findInterface() != nil
        let wasPresent = interfaceWasPresent
        interfaceWasPresent = present
        guard present else {
            connected = false              // unplugged or off: say so rather than guess
            return
        }
        // Back from the dead: a power cycle reverts the device to its own routing.
        if !wasPresent || !connected { await resync() }
    }

    /// Keep only the keys we use, so the 200 KB tree is not held on to.
    private func absorbFull(_ all: [String: Any]) {
        for key in Cfg.watchedKeys where all[key] != nil { values[key] = all[key] }
        if let model = Cfg.avbValue(all, "model_name") { deviceName = model }
        apply(values)
        Task { await ensureRoutingIfNeeded() }
    }

    /// Not called while idle — there is nothing listening for changes on the device side.
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
            values[Cfg.mutePath] = target ? 1.0 : 0.0
            connected = true
            lastError = nil
        } catch {
            muted = !target                  // roll back
            lastError = "Mute failed: \(error.localizedDescription)"
            self.client = nil                // force rediscovery on the next try
            await resync()
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
                    do {
                        try await client.write([Cfg.trimPath: Int(v.rounded())])
                        self.values[Cfg.trimPath] = Int(v.rounded())
                    } catch {
                        self.lastError = "Gain failed: \(error.localizedDescription)"
                        self.client = nil
                        await self.resync()
                    }
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
