import AppKit

// Uninstall step, scriptable: put Computer 1 back on the direct input path and unmute.
if CommandLine.arguments.contains("--restore") {
    Task { @MainActor in
        let model = MicModel()
        await model.restoreInterfaceRouting()
        print("interface routing restored; input 1 is unmuted")
        exit(0)
    }
    RunLoop.main.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--render") {
    let path = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "/tmp/panel.png"
    MainActor.assumeIsolated { Render.run(to: path) }
    exit(0)
}

if CommandLine.arguments.contains("--probe") {
    // Debug path: report state and exit, no menu bar.
    Task {
        await Probe.run()
        exit(0)
    }
    RunLoop.main.run()
}

// Menu bar only: no dock icon, no windows. Top-level code is not main-actor
// isolated, so hand the whole lifetime of the app to the main actor.
@MainActor
func run() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate              // held for the process lifetime by `run`
    app.setActivationPolicy(.accessory)
    app.run()
}

MainActor.assumeIsolated { run() }
