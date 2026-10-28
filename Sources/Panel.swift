import SwiftUI

struct PanelView: View {
    @ObservedObject var model: MicModel
    var onToggleMute: () -> Void
    var onRestore: () -> Void
    var onQuit: () -> Void

    private var stateColor: Color {
        switch model.state {
        case .live: return .red
        case .idle: return .secondary
        case .mutedIdle: return .green
        case .mutedInUse: return .yellow
        case .offline: return .gray
        }
    }

    /// dBFS -> 0...1 across a 60 dB window; a quiet mic still shows a little life.
    private var meterFraction: Double {
        guard model.levelDb > -160 else { return 0 }
        return min(1, max(0, (Double(model.levelDb) + 60) / 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Circle().fill(stateColor).frame(width: 9, height: 9)
                Text(model.headline).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(model.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            meter

            HStack(spacing: 8) {
                Image(systemName: "dial.medium").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.gainDb }, set: { model.setGain($0.rounded()) }),
                       in: model.gainRange)
                    .controlSize(.small)
                Text("\(Int(model.gainDb)) dB")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
            }
            .help("Mic preamp gain on input 1")

            Button(action: onToggleMute) {
                HStack(spacing: 6) {
                    Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                    Text(model.muted ? "Unmute input 1" : "Mute input 1")
                    Spacer()
                    Text(Cfg.hotkeyDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(model.muted ? Color.green : Color.red)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Divider()

            HStack(spacing: 10) {
                Text("\(model.deviceName) · \(model.inputName)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if model.lastError != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .help(model.lastError ?? "")
                }
                Spacer()
                Button("Restore & quit") { onRestore() }
                    .buttonStyle(.link).font(.system(size: 10))
                    .help("Put Computer 1 back on the direct input path and quit")
                Button("Quit") { onQuit() }
                    .buttonStyle(.link).font(.system(size: 10))
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var meter: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(meterFraction > 0.95 ? Color.orange : Color.green)
                        .frame(width: max(0, geo.size.width * meterFraction))
                        .animation(.linear(duration: 0.05), value: meterFraction)
                }
            }
            .frame(height: 8)
            HStack(spacing: 6) {
                if model.micDenied {
                    Text("level needs microphone access (System Settings → Privacy → Microphone)")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                } else {
                    Text(model.muted && meterFraction < 0.02 ? "silent — the mute is in the hardware" : "input 1 level")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
