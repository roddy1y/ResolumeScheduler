import Foundation
import Combine

@MainActor
final class SchedulerEngine: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard bootstrapped else { return }
            settings.save()
            applyTransportSettings()
            check()
        }
    }

    @Published var audioDevices: [AudioInputDevice] = []
    @Published var triggers: [ClipTrigger] = []
    @Published var statusMessage = "Premi Check per leggere la composition."
    @Published var compositionName = "—"
    @Published var compositionPath = ""
    @Published var clockLabel = "--:--:--"
    @Published var ltcLock = false
    @Published var ltcStatus = ""
    @Published var ltcPeak: Float = 0
    @Published var oscOK = false
    @Published var lastError: String?
    @Published var showSettings = false

    private let osc = OSCClient()
    private let ltc = LTCReceiver()
    private var timer: Timer?
    private var lastDayOfYear = -1
    private var lastTimecodeSeconds: Double = -1
    private var latestLTC: ReceivedTimecode?
    private var bootstrapped = false

    init() {
        settings = AppSettings.load()
        refreshAudioDevices()
        if settings.audioInputUID.isEmpty,
           let def = AudioDeviceList.defaultInputUID() {
            settings.audioInputUID = def
        }

        ltc.onTimecode = { [weak self] tc in
            Task { @MainActor in
                self?.handleLTC(tc)
            }
        }
        ltc.onStatus = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.ltcStatus = message ?? ""
                if let message,
                   message.localizedCaseInsensitiveContains("negato")
                    || message.localizedCaseInsensitiveContains("impossibile")
                    || message.localizedCaseInsensitiveContains("engine")
                    || message.localizedCaseInsensitiveContains("formato")
                    || message.localizedCaseInsensitiveContains("device") {
                    self.lastError = message
                }
            }
        }

        bootstrapped = true
        applyTransportSettings()
        startClock()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        ltc.stop()
        osc.disconnect()
    }

    func refreshAudioDevices() {
        audioDevices = AudioDeviceList.inputs()
        if settings.audioInputUID.isEmpty,
           let def = AudioDeviceList.defaultInputUID() {
            settings.audioInputUID = def
        }
    }

    func applyTransportSettings() {
        osc.reconnect(host: settings.oscHost.trimmingCharacters(in: .whitespacesAndNewlines),
                      port: UInt16(clamping: max(1, min(65535, settings.oscPort))))
        oscOK = true

        switch settings.clockSource {
        case .worldClock:
            ltc.stop()
            ltcLock = false
            latestLTC = nil
        case .ltc:
            refreshAudioDevices()
            let uid = settings.audioInputUID.isEmpty ? nil : settings.audioInputUID
            let channels = AudioDeviceList.inputChannelCount(forUID: uid)
            let channel = min(max(0, settings.audioChannel), max(0, channels - 1))
            ltc.start(deviceUID: uid, channel: channel, fps: settings.frameRate.rawValue)
        }
    }

    func check() {
        let nowSeconds = currentClockSeconds() ?? TimeCodeFormat.secondsSinceMidnight()
        do {
            let result = try CompositionParser.loadTriggers(
                clockSource: settings.clockSource,
                currentSeconds: nowSeconds,
                fps: settings.frameRate.rawValue
            )
            compositionPath = result.compositionPath
            compositionName = result.compositionName
            let previousEnabled = Dictionary(uniqueKeysWithValues: triggers.map { ($0.id, $0.isEnabled) })
            let disabledSaved = Set(UserDefaults.standard.stringArray(forKey: "disabledTriggerIDs") ?? [])
            triggers = result.triggers.map { trigger in
                var t = trigger
                if let kept = previousEnabled[t.id] {
                    t.isEnabled = kept
                } else {
                    t.isEnabled = !disabledSaved.contains(t.id)
                }
                return t
            }
            persistEnabledFlags()
            lastError = nil

            if triggers.isEmpty {
                switch settings.clockSource {
                case .worldClock:
                    statusMessage = "Nessun trigger HHMM. Rinomina un clip (es. 1430), salva, Check."
                case .ltc:
                    statusMessage = "Nessun trigger LTC. Rinomina un clip (es. 00:01:01.12), salva, Check."
                }
            } else {
                let mode = settings.triggerTarget.title.lowercased()
                statusMessage = "\(triggers.count) trigger · \(settings.clockSource.title) · via \(mode)"
            }
        } catch {
            lastError = error.localizedDescription
            statusMessage = "Errore nel caricamento."
            triggers = []
        }
    }

    private func startClock() {
        lastDayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? -1
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func tick() {
        switch settings.clockSource {
        case .worldClock:
            tickWorldClock()
        case .ltc:
            tickLTC()
        }
    }

    private func tickWorldClock() {
        let now = Date()
        let cal = Calendar.current
        let day = cal.ordinality(of: .day, in: .year, for: now) ?? -1
        if day != lastDayOfYear {
            lastDayOfYear = day
            resetFired()
            statusMessage = "Nuovo giorno: trigger resettati."
        }
        clockLabel = TimeCodeFormat.clockHMS(from: now)
        fireDue(at: TimeCodeFormat.secondsSinceMidnight(from: now))
    }

    private func tickLTC() {
        ltcLock = ltc.hasLock
        ltcPeak = ltc.inputPeak
        if let tc = latestLTC {
            clockLabel = tc.smpte
            fireDue(at: tc.totalSeconds)
        } else {
            clockLabel = "--:--:--:--"
        }
    }

    private func handleLTC(_ tc: ReceivedTimecode) {
        if lastTimecodeSeconds >= 0, tc.totalSeconds + 0.75 < lastTimecodeSeconds {
            resetFired()
            statusMessage = "LTC indietro/loop: trigger resettati."
        }
        lastTimecodeSeconds = tc.totalSeconds
        latestLTC = tc
        ltcLock = true
        clockLabel = tc.smpte
        fireDue(at: tc.totalSeconds)
    }

    private func fireDue(at seconds: Double) {
        for i in triggers.indices {
            guard triggers[i].isEnabled else { continue }
            guard !triggers[i].hasFired else { continue }
            guard seconds + 0.02 >= triggers[i].timeSeconds else { continue }

            guard let address = triggers[i].oscAddress(target: settings.triggerTarget) else {
                lastError = "L\(triggers[i].layer + 1)C\(triggers[i].column + 1) non è in un layer group"
                triggers[i].hasFired = true // avoid spam
                continue
            }
            let ok = osc.sendInt(address, value: 1)
            triggers[i].hasFired = ok
            if ok {
                let via: String
                switch settings.triggerTarget {
                case .clip:
                    via = "L\(triggers[i].layer + 1)C\(triggers[i].column + 1)"
                case .column:
                    via = "Col \(triggers[i].column + 1)"
                case .groupColumn:
                    let g = (triggers[i].layerGroup ?? 0) + 1
                    via = "G\(g) Col \(triggers[i].column + 1)"
                }
                statusMessage = "Trigger \(via) @ \(triggers[i].timeLabel)"
            } else {
                lastError = osc.lastError ?? "Invio OSC fallito"
            }
        }
    }

    func setTriggerEnabled(id: String, enabled: Bool) {
        guard let i = triggers.firstIndex(where: { $0.id == id }) else { return }
        triggers[i].isEnabled = enabled
        persistEnabledFlags()
    }

    func setAllTriggersEnabled(_ enabled: Bool) {
        for i in triggers.indices {
            triggers[i].isEnabled = enabled
        }
        persistEnabledFlags()
    }

    private func persistEnabledFlags() {
        let disabled = triggers.filter { !$0.isEnabled }.map(\.id)
        UserDefaults.standard.set(disabled, forKey: "disabledTriggerIDs")
    }

    private func resetFired() {
        for i in triggers.indices {
            triggers[i].hasFired = false
        }
    }

    private func currentClockSeconds() -> Double? {
        switch settings.clockSource {
        case .worldClock:
            return TimeCodeFormat.secondsSinceMidnight()
        case .ltc:
            return latestLTC?.totalSeconds
        }
    }
}
