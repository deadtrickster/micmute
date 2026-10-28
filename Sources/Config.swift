import Foundation

/// Everything specific to this install: MOTU 828ES, mic on input 1, Computer channel 1.
///
/// The mute is done in the 828ES's own DSP, not in macOS, so no app can undo it:
///   Mic Inst 1 -> mixer channel 0 -> Mix Group 1 L -> Computer 1
/// Muting mixer channel 0 therefore silences what every app records, while the
/// user's monitoring (Mix Main) keeps its level and pan.
enum Cfg {
    // 828ES datastore paths
    static let inputBank = 2          // ext/ibank/2 = "Mic Inst"
    static let inputChannel = 0       // "Mic Inst 1" = the mic on input 1
    static let mixerChannel = 0
    static let groupBus = 0
    static let computerChannel = 0    // Computer 1 = macOS input 1

    /// Mixer fader values are linear gain. A mono channel loses 2.5 dB going into a
    /// stereo bus, so the group bus that feeds Computer 1 is lifted by exactly that
    /// to make the path level-transparent (measured: 0.00 dB).
    static let groupFaderCompensation = 1.3335
    /// Source of Mix Group bus 1 (ibank 14 = "Mix Group") channel 0.
    static let groupSource = "14:0"
    /// What the device does out of the box: Computer 1 <- Mic Inst 1, direct.
    static let directSource = "2:0"

    static var trimPath: String { "ext/ibank/\(inputBank)/ch/\(inputChannel)/trim" }
    static var trimRangePath: String { "ext/ibank/\(inputBank)/ch/\(inputChannel)/trimRange" }
    static var inputNamePath: String { "ext/ibank/\(inputBank)/ch/\(inputChannel)/defaultName" }
    static var padPath: String { "ext/ibank/\(inputBank)/ch/\(inputChannel)/pad" }
    static var mutePath: String { "mix/chan/\(mixerChannel)/matrix/mute" }
    static var channelFaderPath: String { "mix/chan/\(mixerChannel)/matrix/fader" }
    static var sendPath: String { "mix/chan/\(mixerChannel)/matrix/group/\(groupBus)/send" }
    static var groupFaderPath: String { "mix/group/\(groupBus)/matrix/fader" }
    static var groupMutePath: String { "mix/group/\(groupBus)/matrix/mute" }
    static var computerSrcPath: String { "ext/obank/7/ch/\(computerChannel)/src" }
    /// The device publishes its model name and firmware under `avb/<its own EUI-64>/`,
    /// so look the entry up rather than hardcoding one machine's identifier.
    static func avbValue(_ all: [String: Any], _ suffix: String) -> String? {
        for (key, value) in all where key.hasPrefix("avb/") && key.hasSuffix("/" + suffix) {
            if let s = value as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// Host names tried in order; the first that answers the datastore wins.
    /// The 828ES answers to its mDNS name, which survives a DHCP lease change.
    static let hosts = ["828es.local", "828ES.local"]

    static let hotkeyKeyCode: UInt32 = 46       // M
    static let hotkeyDescription = "⌃⌥M"
}

enum Prefs {
    private static let d = UserDefaults.standard
    static var host: String? {
        get { d.string(forKey: "host") }
        set { d.set(newValue, forKey: "host") }
    }
    static var startAtLogin: Bool {
        get { d.bool(forKey: "startAtLogin") }
        set { d.set(newValue, forKey: "startAtLogin") }
    }
}
