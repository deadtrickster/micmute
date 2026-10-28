import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = MicModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var pollTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    private var panelVisible: Bool { popover.isShown }

    func log(_ m: String) { FileHandle.standardError.write(Data("[micmute] \(m)\n".utf8)) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("didFinishLaunching")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: makePanel())

        model.$muted.combineLatest(model.$connected, model.$capturing)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        updateStatusItem()
        registerHotKey()
        schedulePoll(visible: false)

        if CommandLine.arguments.contains("--panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.togglePanel()
                self?.log("panel opened")
            }
        }

        Task {
            log("first refresh")
            await model.refresh()
            log("first refresh done: connected=\(model.connected) muted=\(model.muted) capturing=\(model.capturing)")
            updateStatusItem()
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private func makePanel() -> PanelView {
        PanelView(model: model,
                  onToggleMute: { Task { await self.model.toggleMute(); self.updateStatusItem() } },
                  onRestore: { Task { await self.model.restoreInterfaceRouting(); self.updateStatusItem() } },
                  onQuit: { NSApp.terminate(nil) })
    }

    // MARK: - status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let state = model.state
        let (color, muted): (NSColor, Bool) = {
            switch state {
            case .live: return (.systemRed, false)
            case .idle: return (.secondaryLabelColor, false)
            case .mutedIdle: return (.systemGreen, true)
            case .mutedInUse: return (.systemYellow, true)
            case .offline: return (.tertiaryLabelColor, true)
            }
        }()
        button.image = statusImage(color: color, muted: muted)
        button.appearsDisabled = (state == .offline)
        var tip = model.headline
        if state == .mutedInUse { tip = "Muted, but \(model.capturing.joined(separator: ", ")) is capturing" }
        if state == .live { tip = "Live: \(model.capturing.joined(separator: ", ")) is capturing input 1" }
        button.toolTip = "\(tip)\nClick for mute & gain (\(Cfg.hotkeyDescription) mutes)"
    }

    private func statusImage(color: NSColor, muted: Bool) -> NSImage? {
        let name = muted ? "mic.slash.fill" : "mic.fill"
        let conf = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: "microphone")?
            .withSymbolConfiguration(conf) else { return nil }
        let img = NSImage(size: sym.size, flipped: false) { rect in
            sym.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: - clicks

    @objc private func statusClicked() {
        let isRight = NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRight { showMenu() } else { togglePanel() }
    }

    private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController = NSHostingController(rootView: makePanel())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Task { await model.startMetering(); await model.refresh(); updateStatusItem() }
        schedulePoll(visible: true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.stopMetering()          // no audio device IO while hidden
        schedulePoll(visible: false)
    }

    private func showMenu() {
        let menu = NSMenu()
        let stateItem = NSMenuItem(title: model.headline, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: model.muted ? "Unmute input 1  \(Cfg.hotkeyDescription)"
                                           : "Mute input 1  \(Cfg.hotkeyDescription)",
                     action: #selector(hotkeyMute), keyEquivalent: "")
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = Prefs.startAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Restore interface routing…", action: #selector(restoreRouting), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MicMute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil            // back to plain clicks next time
    }

    @objc private func hotkeyMute() { Task { await model.toggleMute(); updateStatusItem() } }
    @objc private func restoreRouting() { Task { await model.restoreInterfaceRouting(); updateStatusItem() } }
    @objc private func toggleLogin() {
        Prefs.startAtLogin.toggle()
        do {
            if Prefs.startAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            model.lastError = "Login item: \(error.localizedDescription)"
        }
    }

    // MARK: - polling

    /// Cheap when hidden: one datastore read every 4 s and no audio device IO at all.
    private func schedulePoll(visible: Bool) {
        pollTimer?.invalidate()
        let interval: TimeInterval = visible ? 1.5 : 4.0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.model.refresh()
                self.updateStatusItem()
            }
        }
    }

    // MARK: - global hotkey

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                await delegate.model.toggleMute()
                delegate.updateStatusItem()
            }
            return noErr
        }, 1, &eventType, selfPtr, &hotKeyHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D49_434D), id: 1)   // 'MICM'
        RegisterEventHotKey(Cfg.hotkeyKeyCode, UInt32(controlKey | optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
