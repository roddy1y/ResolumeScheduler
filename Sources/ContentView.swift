import SwiftUI

@main
struct ResolumeSchedulerApp: App {
    @StateObject private var engine = SchedulerEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Impostazioni…") {
                    engine.showSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: SchedulerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            Divider()
            header
            Divider()
            triggerList
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 500)
        .onAppear { engine.check() }
        .sheet(isPresented: $engine.showSettings) {
            SettingsView()
                .environmentObject(engine)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                labeledPicker("Orologio", selection: Binding(
                    get: { engine.settings.clockSource },
                    set: { engine.settings.clockSource = $0 }
                )) {
                    ForEach(ClockSource.allCases) { Text($0.title).tag($0) }
                }
                labeledPicker("Trigger", selection: Binding(
                    get: { engine.settings.triggerTarget },
                    set: { engine.settings.triggerTarget = $0 }
                )) {
                    ForEach(TriggerTarget.allCases) { Text($0.title).tag($0) }
                }
                if engine.settings.triggerTarget == .groupColumn {
                    labeledPicker("Layer group", selection: Binding(
                        get: { engine.settings.targetLayerGroup },
                        set: { engine.settings.targetLayerGroup = $0 }
                    )) {
                        if engine.layerGroups.isEmpty {
                            Text("Group 1").tag(0)
                        } else {
                            ForEach(engine.layerGroups) { g in
                                Text(g.title).tag(g.index)
                            }
                        }
                    }
                }
                Spacer()
                Button("Impostazioni") { engine.showSettings = true }
                Button("Check") { engine.check() }
                    .keyboardShortcut("r", modifiers: [.command])
            }

            Text(engine.settings.clockSource.help)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(engine.settings.triggerTarget.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func labeledPicker<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 120, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.compositionName)
                    .font(.headline)
                Text(engine.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let err = engine.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(engine.clockLabel)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                if engine.settings.clockSource == .ltc {
                    Text(engine.ltcLock
                         ? "LTC LOCK · ch\(engine.settings.audioChannel + 1) · \(Int(engine.settings.frameRate.rawValue)) fps"
                         : "LTC waiting… peak \(String(format: "%.0f", min(1, engine.ltcPeak) * 100))%")
                        .font(.caption2)
                        .foregroundStyle(engine.ltcLock ? Color.green : Color.orange)
                    if !engine.ltcStatus.isEmpty, !engine.ltcLock {
                        Text(engine.ltcStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text("OSC → \(engine.settings.oscHost):\(engine.settings.oscPort)")
                    .font(.caption2)
                    .foregroundStyle(engine.oscOK ? Color.secondary : Color.red)
            }
        }
    }

    private var triggerList: some View {
        Group {
            if engine.triggers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nessun trigger")
                        .font(.title3)
                    Text(emptyHelp)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Trigger")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Tutti on") { engine.setAllTriggersEnabled(true) }
                            .font(.caption)
                        Button("Tutti off") { engine.setAllTriggersEnabled(false) }
                            .font(.caption)
                    }
                    List {
                        ForEach(engine.triggers) { trigger in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: {
                                        engine.triggers.first(where: { $0.id == trigger.id })?.isEnabled ?? true
                                    },
                                    set: { engine.setTriggerEnabled(id: trigger.id, enabled: $0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.checkbox)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trigger.displayName)
                                        .lineLimit(1)
                                        .foregroundStyle(trigger.isEnabled ? Color.primary : Color.secondary)
                                    Text(targetSubtitle(trigger))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(trigger.timeLabel)
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(
                                        !trigger.isEnabled ? Color.secondary
                                        : trigger.hasFired ? Color.green : Color.red
                                    )
                            }
                            .padding(.vertical, 2)
                            .opacity(trigger.isEnabled ? 1 : 0.55)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private var emptyHelp: String {
        switch engine.settings.clockSource {
        case .worldClock:
            return "Rinomina un clip in HHMM (es. 1430), salva la composition, premi Check.\nOSC verso la porta impostata (default 7000)."
        case .ltc:
            return "In Impostazioni scegli input audio + fps (24/25/30).\nRinomina i clip es. 00:01:01.12 (HH:MM:SS.FF), salva, Check.\nServe segnale LTC sull’input e OSC verso Resolume."
        }
    }

    private func targetSubtitle(_ trigger: ClipTrigger) -> String {
        switch engine.settings.triggerTarget {
        case .clip:
            return "Clip · L\(trigger.layer + 1) · C\(trigger.column + 1)"
        case .column:
            return "Colonna \(trigger.column + 1) (da L\(trigger.layer + 1))"
        case .groupColumn:
            let g = engine.settings.targetLayerGroup + 1
            let gName = engine.layerGroups.first(where: { $0.index == engine.settings.targetLayerGroup })?.name
            let prefix = gName.map { "\($0) · " } ?? "Gruppo \(g) · "
            return "\(prefix)Colonna \(trigger.column + 1)"
        }
    }

    private var footer: some View {
        HStack {
            if !engine.compositionPath.isEmpty {
                Text(engine.compositionPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(engine.triggers.filter(\.isEnabled).count) attivi · \(engine.triggers.filter(\.hasFired).count)/\(engine.triggers.count) fatti")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var engine: SchedulerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var oscHost: String = ""
    @State private var oscPortText: String = "7000"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Impostazioni")
                .font(.title2.weight(.semibold))

            GroupBox("LTC / Audio") {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("Frame rate") {
                        Picker("", selection: Binding(
                            get: { engine.settings.frameRate },
                            set: { engine.settings.frameRate = $0 }
                        )) {
                            ForEach(FrameRate.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    labeled("Input audio") {
                        HStack {
                            Picker("", selection: Binding(
                                get: { engine.settings.audioInputUID },
                                set: { uid in
                                    engine.settings.audioInputUID = uid
                                    let n = AudioDeviceList.inputChannelCount(forUID: uid.isEmpty ? nil : uid)
                                    if engine.settings.audioChannel >= n {
                                        engine.settings.audioChannel = 0
                                    }
                                }
                            )) {
                                Text("Default di sistema").tag("")
                                ForEach(engine.audioDevices) { dev in
                                    Text("\(dev.name) (\(dev.inputChannels) ch)").tag(dev.uid)
                                }
                            }
                            .labelsHidden()
                            Button("Aggiorna") { engine.refreshAudioDevices() }
                        }
                    }

                    labeled("Canale LTC") {
                        let channelCount = max(1, AudioDeviceList.inputChannelCount(
                            forUID: engine.settings.audioInputUID.isEmpty ? nil : engine.settings.audioInputUID
                        ))
                        Picker("", selection: Binding(
                            get: { min(engine.settings.audioChannel, channelCount - 1) },
                            set: { engine.settings.audioChannel = $0 }
                        )) {
                            ForEach(0..<channelCount, id: \.self) { ch in
                                Text("Canale \(ch + 1)").tag(ch)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180, alignment: .leading)
                    }
                }
                .padding(6)
            }

            GroupBox("OSC output (verso Resolume)") {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("Host") {
                        TextField("127.0.0.1", text: $oscHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    labeled("Porta") {
                        TextField("7000", text: $oscPortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                    }
                    Text("In Resolume: Preferences → OSC → Input Enabled sulla stessa porta.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salva") {
                    applyAndClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onAppear {
            engine.refreshAudioDevices()
            oscHost = engine.settings.oscHost
            oscPortText = String(engine.settings.oscPort)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func applyAndClose() {
        var s = engine.settings
        s.oscHost = oscHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.oscHost.isEmpty { s.oscHost = "127.0.0.1" }
        s.oscPort = Int(oscPortText) ?? 7000
        s.oscPort = max(1, min(65535, s.oscPort))
        engine.settings = s
        engine.applyTransportSettings()
        dismiss()
    }
}
