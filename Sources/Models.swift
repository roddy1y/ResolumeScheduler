import Foundation

enum FrameRate: Double, CaseIterable, Identifiable {
    case fps24 = 24
    case fps25 = 25
    case fps30 = 30

    var id: Double { rawValue }
    var title: String { "\(Int(rawValue)) fps" }
}

enum ClockSource: String, CaseIterable, Identifiable {
    case worldClock
    case ltc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .worldClock: return "World Clock"
        case .ltc: return "LTC"
        }
    }

    var help: String {
        switch self {
        case .worldClock:
            return "Orologio di sistema. Rinomina i clip in HHMM (es. 1430)."
        case .ltc:
            return "Timecode LTC dall’input audio. Rinomina i clip es. 00:01:01.12"
        }
    }
}

enum TriggerTarget: String, CaseIterable, Identifiable {
    case clip
    case column
    case groupColumn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clip: return "Clip"
        case .column: return "Colonna"
        case .groupColumn: return "Colonna gruppo"
        }
    }

    var help: String {
        switch self {
        case .clip:
            return "Triggera la singola clip (layer + colonna)."
        case .column:
            return "Triggera la colonna generale della composition."
        case .groupColumn:
            return "Triggera la colonna del layer group scelto (seleziona il gruppo)."
        }
    }
}

struct LayerGroupInfo: Identifiable, Equatable, Hashable {
    /// 0-based index in Resolume (OSC uses +1).
    let index: Int
    let name: String
    var id: Int { index }
    var title: String { "\(index + 1). \(name)" }
}

struct AppSettings {
    var clockSource: ClockSource
    var triggerTarget: TriggerTarget
    var frameRate: FrameRate
    var audioInputUID: String
    /// 0-based channel index on the selected input device.
    var audioChannel: Int
    /// 0-based layer group used for "Colonna gruppo".
    var targetLayerGroup: Int
    var oscHost: String
    var oscPort: Int

    static let defaults = AppSettings(
        clockSource: .worldClock,
        triggerTarget: .clip,
        frameRate: .fps25,
        audioInputUID: "",
        audioChannel: 0,
        targetLayerGroup: 0,
        oscHost: "127.0.0.1",
        oscPort: 7000
    )

    static func load() -> AppSettings {
        let d = UserDefaults.standard
        var s = AppSettings.defaults
        if let v = d.string(forKey: "clockSource"), let c = ClockSource(rawValue: v) { s.clockSource = c }
        // migrate old "timecode" key
        if d.string(forKey: "clockSource") == "timecode" { s.clockSource = .ltc }
        if let v = d.string(forKey: "triggerTarget"), let t = TriggerTarget(rawValue: v) { s.triggerTarget = t }
        let fps = d.double(forKey: "frameRate")
        if let fr = FrameRate(rawValue: fps) { s.frameRate = fr }
        s.audioInputUID = d.string(forKey: "audioInputUID") ?? ""
        s.audioChannel = max(0, d.integer(forKey: "audioChannel"))
        s.targetLayerGroup = max(0, d.integer(forKey: "targetLayerGroup"))
        s.oscHost = d.string(forKey: "oscHost") ?? "127.0.0.1"
        let port = d.integer(forKey: "oscPort")
        if (1...65535).contains(port) { s.oscPort = port }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(clockSource.rawValue, forKey: "clockSource")
        d.set(triggerTarget.rawValue, forKey: "triggerTarget")
        d.set(frameRate.rawValue, forKey: "frameRate")
        d.set(audioInputUID, forKey: "audioInputUID")
        d.set(audioChannel, forKey: "audioChannel")
        d.set(targetLayerGroup, forKey: "targetLayerGroup")
        d.set(oscHost, forKey: "oscHost")
        d.set(oscPort, forKey: "oscPort")
    }
}

struct ClipTrigger: Identifiable, Equatable {
    let id: String
    let layer: Int
    let column: Int
    /// 0-based layer group index if the layer belongs to a group.
    let layerGroup: Int?
    let timeSeconds: Double
    let defaultName: String
    let displayName: String
    let scheduleLabel: String
    var hasFired: Bool
    /// Se false, lo scheduler non invia OSC per questo trigger.
    var isEnabled: Bool

    var timeLabel: String { scheduleLabel }

    func oscAddress(target: TriggerTarget, explicitLayerGroup: Int? = nil) -> String? {
        switch target {
        case .clip:
            return "/composition/layers/\(layer + 1)/clips/\(column + 1)/connect"
        case .column:
            return "/composition/columns/\(column + 1)/connect"
        case .groupColumn:
            let group = explicitLayerGroup ?? layerGroup
            guard let group else { return nil }
            return "/composition/groups/\(group + 1)/columns/\(column + 1)/connect"
        }
    }
}

enum TimeCodeFormat {
    static func parseWorldClockName(_ name: String) -> (seconds: Double, label: String)? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 4, t.allSatisfy(\.isNumber) else { return nil }
        let hh = Int(t.prefix(2)) ?? -1
        let mm = Int(t.suffix(2)) ?? -1
        guard (0...23).contains(hh), (0...59).contains(mm) else { return nil }
        return (Double(hh * 3600 + mm * 60), String(format: "%d:%02d", hh, mm))
    }

    /// Formati LTC nel nome clip:
    /// - `00:01:01.12` → HH:MM:SS.FF
    /// - `00:01:01:12` → HH:MM:SS:FF
    /// - `00:01:01` → HH:MM:SS
    /// - `000101` / `00010112` → HHMMSS / HHMMSSff
    static func parseTimecodeName(_ name: String, fps: Double = 25) -> (seconds: Double, label: String)? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fpsInt = max(1, Int(fps.rounded()))

        func make(hh: Int, mm: Int, ss: Int, ff: Int) -> (seconds: Double, label: String)? {
            guard (0...99).contains(hh), (0...59).contains(mm), (0...59).contains(ss),
                  (0..<fpsInt).contains(ff)
            else { return nil }
            let seconds = Double(hh * 3600 + mm * 60 + ss) + Double(ff) / Double(fpsInt)
            let label = String(format: "%02d:%02d:%02d.%02d", hh, mm, ss, ff)
            return (seconds, label)
        }

        if t.contains(":") || t.contains(".") {
            var normalized = t
            // 00:01:01.12 → treat '.' as frame separator
            if normalized.filter({ $0 == ":" }).count == 2,
               let dot = normalized.lastIndex(of: "."),
               normalized[normalized.index(after: dot)...].allSatisfy(\.isNumber) {
                normalized.replaceSubrange(dot...dot, with: ":")
            }
            let parts = normalized.split(separator: ":").map(String.init)
            if parts.count == 4,
               let hh = Int(parts[0]), let mm = Int(parts[1]),
               let ss = Int(parts[2]), let ff = Int(parts[3]) {
                return make(hh: hh, mm: mm, ss: ss, ff: ff)
            }
            if parts.count == 3,
               let hh = Int(parts[0]), let mm = Int(parts[1]), let ss = Int(parts[2]) {
                return make(hh: hh, mm: mm, ss: ss, ff: 0)
            }
            return nil
        }

        guard t.allSatisfy(\.isNumber) else { return nil }
        if t.count == 8 {
            let hh = Int(t.prefix(2)) ?? -1
            let mm = Int(t.dropFirst(2).prefix(2)) ?? -1
            let ss = Int(t.dropFirst(4).prefix(2)) ?? -1
            let ff = Int(t.suffix(2)) ?? -1
            return make(hh: hh, mm: mm, ss: ss, ff: ff)
        }
        if t.count == 6 {
            let hh = Int(t.prefix(2)) ?? -1
            let mm = Int(t.dropFirst(2).prefix(2)) ?? -1
            let ss = Int(t.suffix(2)) ?? -1
            return make(hh: hh, mm: mm, ss: ss, ff: 0)
        }
        return nil
    }

    static func clockHMS(from date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    static func secondsSinceMidnight(from date: Date = Date()) -> Double {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return Double(c.hour ?? 0) * 3600
            + Double(c.minute ?? 0) * 60
            + Double(c.second ?? 0)
            + Double(c.nanosecond ?? 0) / 1_000_000_000
    }
}
