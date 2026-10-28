import AVFoundation
import CoreAudio
import Foundation

/// `MicMute --probe`: print what the app can see, then exit. For debugging a setup
/// without opening the panel. Also useful to see which datastore values are in force.
enum Probe {
    static func run() async {
        print("=== MicMute probe ===")
        guard let found = await MotuClient.discover(candidates: Cfg.hosts + [Prefs.host].compactMap { $0 }) else {
            print("no answer from the interface (tried \(Cfg.hosts.joined(separator: ", ")))")
            return
        }
        let (client, all) = found
        print("host:            \(client.host)")
        print("model:           \(Cfg.avbValue(all, "model_name") ?? "?")")
        print("firmware:        \((Cfg.avbValue(all, "firmware_version") ?? "?").split(separator: "\n").first ?? "?")")
        print("input:           \(Val.str(all[Cfg.inputNamePath]) ?? "?")  gain=\(Val.num(all[Cfg.trimPath]) ?? -1) dB  range=\(Val.str(all[Cfg.trimRangePath]) ?? "?")")
        print("muted:           \(Val.bool(all[Cfg.mutePath]) == true)")
        print("computer 1 src:  \(Val.str(all[Cfg.computerSrcPath]) ?? "?")   (want \(Cfg.groupSource))")
        print("group send:      \(Val.num(all[Cfg.sendPath]) ?? -1)   (want 1.0)")
        print("group fader:     \(Val.num(all[Cfg.groupFaderPath]) ?? -1)   (want \(Cfg.groupFaderCompensation))")
        print("group mute:      \(Val.bool(all[Cfg.groupMutePath]) == true)   (want false)")
        print("capturing apps:  \(CA.inputUsers().joined(separator: ", ").ifEmpty("none"))")
        if CommandLine.arguments.contains("--verbose") {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            let e1 = AudioObjectGetPropertyDataSize(CA.system, &a, 0, nil, &size)
            print("  process list: err=\(e1) size=\(size)")
            var procs = [AudioObjectID](repeating: 0, count: max(1, Int(size) / MemoryLayout<AudioObjectID>.size))
            let e2 = AudioObjectGetPropertyData(CA.system, &a, 0, nil, &size, &procs)
            print("  get: err=\(e2) -> \(procs.count) entries")
            for p in procs where p != 0 {
                let inFlag = CA.u32(p, kAudioProcessPropertyIsRunningInput)
                let pid = CA.u32(p, kAudioProcessPropertyPID)
                print("   obj=\(p) pid=\(pid) inputRunning=\(inFlag) bundle=\(CA.string(p, kAudioProcessPropertyBundleID) ?? "-")")
            }
        }

        guard let dev = CA.findInterface() else { print("828ES not present in CoreAudio"); return }
        print("coreaudio dev:   \(dev)   mic authorized: \(Meter.microphoneAuthorized())")
        print("measuring input \(Cfg.computerChannel + 1) of the interface for 2 s…")

        let meter = Meter()
        let sem = DispatchSemaphore(value: 0)
        var levels: [Float] = []
        meter.onLevel = { db in
            levels.append(db)
            if levels.count == 40 { sem.signal() }
        }
        if !Meter.microphoneAuthorized() { _ = await Meter.requestMicrophone() }
        meter.start(device: dev, channel: Cfg.computerChannel)
        _ = sem.wait(timeout: .now() + 4)
        meter.stop()

        if levels.isEmpty {
            print("no audio callbacks — is microphone access allowed for MicMute?")
        } else {
            let live = levels.filter { $0 > -160 }
            let peak = live.max() ?? -160
            print(String(format: "level: peak %.1f dBFS over %d windows, %d silent",
                         peak, levels.count, levels.count - live.count))
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
