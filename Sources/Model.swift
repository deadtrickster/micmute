import AppKit
import CoreAudio
import Combine
import Foundation

enum MicState {
    case offline      // can't reach the interface
    case idle         // unmuted, nothing capturing
    case live         // unmuted and something is capturing -> you are audible
    case mutedIdle    // muted, nothing capturing
    case mutedInUse   // muted, but an app is capturing (in a call)
}

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
    private var client: MotuClient?
    private var deviceID: AudioObjectID?
    private var routingApplied = false

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

    // MARK: - device

    func audioDevice() -> AudioObjectID? {
        if let deviceID, CA.deviceCount() > 0 { return deviceID }
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
        apply(found.1)
        return found.0
    }

    // MARK: - refresh

    private func log(_ m: String) { FileHandle.standardError.write(Data("[micmute] \(m)\n".utf8)) }

    func refresh() async {
        if client == nil {
            if let found = await MotuClient.discover(candidates: [host] + Cfg.hosts) {
                client = found.0
                Prefs.host = found.0.host
                host = found.0.host
                apply(found.1)
                connected = true
            } else {
                client = nil
                connected = false
                return
            }
        }
        guard let client else { return }
        do {
            let all = try await client.fetchAll()
            apply(all)
            connected = true
            lastError = nil
            await ensureRouting(client: client, all: all)
        } catch {
            log("refresh failed: \(error)")
            connected = false
            lastError = error.localizedDescription
        }
        capturing = CA.inputUsers()
    }

    private func apply(_ all: [String: Any]) {
        if let m = Val.bool(all[Cfg.mutePath]) { muted = m }
        if let g = Val.num(all[Cfg.trimPath]) { gainDb = g }
        if let r = Val.str(all[Cfg.trimRangePath]) {
            let parts = r.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { gainRange = parts[0]...parts[1] }
        }
        if let n = Val.str(all[Cfg.inputNamePath]), !n.isEmpty { inputName = n }
        if let model = Cfg.avbValue(all, "model_name") { deviceName = model }
    }

    /// Keep Computer 1 fed from the mixer, so the mute has something to act on.
    /// Re-applied after a preset change or a power cycle; a no-op when already correct.
    private func ensureRouting(client: MotuClient, all: [String: Any]) async {
        let src = Val.str(all[Cfg.computerSrcPath])
        let send = Val.num(all[Cfg.sendPath])
        let groupFader = Val.num(all[Cfg.groupFaderPath])
        let groupMute = Val.bool(all[Cfg.groupMutePath])

        let ok = (src == Cfg.groupSource)
            && (send.map { abs($0 - 1.0) < 0.001 } ?? false)
            && (groupFader.map { abs($0 - Cfg.groupFaderCompensation) < 0.01 } ?? false)
            && (groupMute == false)
        if ok { routingApplied = true; return }

        do {
            try await client.write([
                Cfg.computerSrcPath: Cfg.groupSource,
                Cfg.sendPath: 1.0,
                Cfg.groupFaderPath: Cfg.groupFaderCompensation,
                Cfg.groupMutePath: 0,
            ])
            routingApplied = true
            log("routing (re)applied")
        } catch {
            routingApplied = false
            let message = "Could not route the mic through the mixer: \(error.localizedDescription)"
            if lastError != message {
                log(message)
                lastError = message
            }
        }
    }

    /// Put the interface back the way it shipped: Computer 1 straight from Mic Inst 1.
    func restoreInterfaceRouting() async {
        guard let client = await ensureClient() else { return }
        try? await client.write([
            Cfg.computerSrcPath: Cfg.directSource,
            Cfg.sendPath: 0.0,
            Cfg.groupMutePath: 1,
            Cfg.groupFaderPath: 0.0,
            Cfg.mutePath: 0,
        ])
        await refresh()
    }

    // MARK: - actions

    func toggleMute() async {
        let target = !muted
        muted = target                              // optimistic: the button must feel instant
        guard let client = await ensureClient() else { return }
        do {
            try await client.write([Cfg.mutePath: target ? 1 : 0])
            connected = true
            lastError = nil
        } catch {
            muted = !target                         // roll back
            lastError = "Mute failed: \(error.localizedDescription)"
            return
        }
        capturing = CA.inputUsers()
    }

    private var gainWriteTask: Task<Void, Never>?
    private var pendingGain: Double?

    /// Slider is continuous; coalesce so we don't hammer the interface mid-drag.
    func setGain(_ value: Double) {
        gainDb = value
        pendingGain = value
        guard gainWriteTask == nil else { return }
        gainWriteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            let v = self.pendingGain
            self.pendingGain = nil
            self.gainWriteTask = nil
            guard let v else { return }
            if let client = await self.ensureClient() {
                try? await client.write([Cfg.trimPath: Int(v.rounded())])
            }
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
