import AppKit
import SwiftUI

/// `MicMute --render <path>`: draw the panel offscreen to a PNG so the layout can be
/// checked without a session on the display.
@MainActor
enum Render {
    static func run(to path: String) {
        let model = MicModel()
        model.connected = true
        model.deviceName = "828ES"
        model.inputName = "Mic Inst 1"
        model.gainDb = 47
        model.levelDb = -18
        if CommandLine.arguments.contains("--muted-in-use") {
            model.muted = true
            model.capturing = ["zoom.us"]
            model.levelDb = -160
        } else if CommandLine.arguments.contains("--live") {
            model.capturing = ["zoom.us"]
        }

        let view = NSHostingView(rootView: PanelView(model: model,
                                                     onToggleMute: {},
                                                     onRestore: {},
                                                     onQuit: {}))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 240)

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        // Stand in for the popover's vibrancy material so the render is legible.
        window.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isOpaque = true
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        // let SwiftUI lay out and draw once
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        view.layoutSubtreeIfNeeded()

        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("wrote \(path) \(Int(rep.size.width))x\(Int(rep.size.height))\n".utf8))
        }
    }
}
