import AVFoundation
import CoreAudio
import Foundation

/// CoreAudio queries: find the 828ES, ask who is capturing, and meter channel 1 when visible.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: CFString?
        let err = withUnsafeMutablePointer(to: &out) { p in
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, p)
        }
        guard err == noErr else { return nil }
        return out as String?
    }

    static func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = addr(sel)
        var size = UInt32(4)
        var v: UInt32 = 0
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
        return v
    }

    static func deviceCount() -> Int {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioDeviceID>.size
    }

    /// The 828ES, matched by driver UID prefix, else by name.
    static func findInterface() -> AudioDeviceID? {
        let n = deviceCount()
        guard n > 0 else { return nil }
        var a = addr(kAudioHardwarePropertyDevices)
        var size = UInt32(n * MemoryLayout<AudioDeviceID>.size)
        var devs = [AudioDeviceID](repeating: 0, count: n)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &devs) == noErr else { return nil }

        var byName: AudioDeviceID?
        for d in devs {
            let uid = string(d, kAudioDevicePropertyDeviceUID) ?? ""
            if uid.hasPrefix("com_motu_driver_proaudio_device") { return d }
            if byName == nil, let name = string(d, kAudioObjectPropertyName),
               name.uppercased().contains("828") { byName = d }
        }
        return byName
    }

    /// Names of apps currently capturing from an input, excluding ourselves.
    static func inputUsers() -> [String] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for p in processObjects() {
            guard u32(p, kAudioProcessPropertyIsRunningInput) != 0 else { continue }
            let pid = pid_t(bitPattern: u32(p, kAudioProcessPropertyPID))
            if pid == myPid { continue }   // our own metering tap doesn't count
            names.append(processName(pid, obj: p))
        }
        return Array(Set(names)).sorted()
    }

    /// Every process object the HAL knows about (one per process doing audio IO).
    static func processObjects() -> [AudioObjectID] {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &procs) == noErr else { return [] }
        return procs
    }

    /// Is this device id still present? (A cached id goes stale when the box is unplugged.)
    static func deviceExists(_ id: AudioObjectID) -> Bool {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return false }
        var devs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &devs) == noErr else { return false }
        return devs.contains(id)
    }

    /// Human name for a capturing process: the app name if it is a bundle,
    /// otherwise the executable name (a CLI tool has an empty bundle id).
    private static func processName(_ pid: pid_t, obj: AudioObjectID) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let base = (String(cString: buf) as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        if let bid = string(obj, kAudioProcessPropertyBundleID), !bid.isEmpty { return bid }
        return "pid \(pid)"
    }
}

import AppKit

/// Level meter for one channel of one input device. Runs only while the panel is visible.
final class Meter {
    private var device: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    /// Called on the main queue with the current peak in dBFS (-160 for silence).
    var onLevel: ((Float) -> Void)?

    static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in cont.resume(returning: granted) }
        }
    }

    func start(device: AudioObjectID, channel: Int) {
        stop()
        self.device = device
        var peak: Float = 0
        var callbackID: AudioDeviceIOProcID?

        let queue = DispatchQueue(label: "micmute.meter", qos: .userInitiated)
        let err = AudioDeviceCreateIOProcIDWithBlock(&callbackID, device, queue) { [weak self] _, inData, _, _, _ in
            guard self != nil else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard list.count > 0 else { return }
            var p: Float = 0
            if list.count == 1, list[0].mNumberChannels > 1 {
                // interleaved: channel 0 is every n-th sample
                let n = Int(list[0].mNumberChannels)
                if let m = list[0].mData?.assumingMemoryBound(to: Float.self) {
                    let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * n)
                    var i = 0
                    while i < frames { p = max(p, abs(m[i * n])); i += 1 }
                }
            } else if Int(channel) < list.count, let m = list[channel].mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(list[channel].mDataByteSize) / MemoryLayout<Float>.size
                var i = 0
                while i < frames { p = max(p, abs(m[i])); i += 1 }
            }
            peak = max(peak, p)
        }
        guard err == noErr, let callbackID else { return }
        procID = callbackID
        guard AudioDeviceStart(device, callbackID) == noErr else {
            AudioDeviceDestroyIOProcID(device, callbackID)
            procID = nil
            return
        }
        isRunning = true

        // Publish ~20x/second and let the bar fall back gently.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            let db = peak > 0 ? 20 * log10(peak) : -160
            peak = 0
            self.onLevel?(db)
        }
        timer.resume()
        decayTimer = timer
    }

    private var decayTimer: DispatchSourceTimer?

    func stop() {
        decayTimer?.cancel()
        decayTimer = nil
        guard let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.procID = nil
        isRunning = false
    }

    deinit { stop() }
}

/// Event-driven answer to "is an app capturing?" — no polling.
///
/// Listens to the HAL's process list and to each process's input-running flag, so the
/// callbacks only fire when something actually starts or stops capturing. Re-attaches
/// to processes as they appear and disappear.
final class UsageMonitor {
    /// Called on the main queue with the app names, only when the set changes.
    var onChange: (([String]) -> Void)?

    private let queue = DispatchQueue(label: "micmute.usage", qos: .utility)
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var processBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var running = false
    private var lastReported: [String]?

    func start() {
        guard !running else { return }
        running = true
        var a = CA.addr(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
        if AudioObjectAddPropertyListenerBlock(CA.system, &a, queue, block) == noErr {
            systemBlock = block
        }
        rescan()
    }

    func stop() {
        running = false
        if let block = systemBlock {
            var a = CA.addr(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(CA.system, &a, queue, block)
            systemBlock = nil
        }
        for (obj, block) in processBlocks {
            var a = CA.addr(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
        }
        processBlocks.removeAll()
    }

    deinit { stop() }

    /// Re-attach to processes that appeared or went away, then report if the set changed.
    private func rescan() {
        guard running else { return }
        let objs = CA.processObjects()
        let live = Set(objs)

        // collect first: removing while iterating the dictionary would be a mutation
        // during enumeration.
        let gone = processBlocks.keys.filter { !live.contains($0) }
        for obj in gone {
            if let block = processBlocks[obj] {
                var a = CA.addr(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
                processBlocks.removeValue(forKey: obj)
            }
        }
        for obj in objs where processBlocks[obj] == nil {
            var a = CA.addr(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
            if AudioObjectAddPropertyListenerBlock(obj, &a, queue, block) == noErr {
                processBlocks[obj] = block
            }
        }

        let names = CA.inputUsers()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.lastReported != names else { return }
            self.lastReported = names
            self.onChange?(names)
        }
    }
}
