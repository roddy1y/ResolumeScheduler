import Foundation

enum CompositionParserError: LocalizedError {
    case preferencesNotFound
    case configMissing
    case compositionPathMissing
    case compositionNotFound(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .preferencesNotFound:
            return "Cartella Preferences di Resolume Arena non trovata in Documenti."
        case .configMissing:
            return "config.xml non trovato. Avvia Resolume almeno una volta."
        case .compositionPathMissing:
            return "Nessuna composition corrente in config.xml. Salva la composition in Resolume."
        case .compositionNotFound(let path):
            return "Composition non trovata:\n\(path)"
        case .parseFailed(let reason):
            return "Errore nel parsing: \(reason)"
        }
    }
}

enum CompositionParser {
    static var arenaDocuments: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Resolume Arena", isDirectory: true)
    }

    static var preferencesFolder: URL {
        arenaDocuments.appendingPathComponent("Preferences", isDirectory: true)
    }

    static var configURL: URL {
        preferencesFolder.appendingPathComponent("config.xml")
    }

    static func currentCompositionPath() throws -> String {
        guard FileManager.default.fileExists(atPath: preferencesFolder.path) else {
            throw CompositionParserError.preferencesNotFound
        }
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw CompositionParserError.configMissing
        }

        let data = try Data(contentsOf: configURL)
        let xml = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        guard let root = xml.rootElement() else {
            throw CompositionParserError.parseFailed("config.xml senza root")
        }

        if let path = findParamValue(in: root, name: "CurrentCompositionFile"), !path.isEmpty {
            return path
        }

        throw CompositionParserError.compositionPathMissing
    }

    static func loadTriggers(
        clockSource: ClockSource,
        currentSeconds: Double,
        fps: Double = 25,
        from compositionPath: String? = nil
    ) throws -> (compositionPath: String, compositionName: String, triggers: [ClipTrigger]) {
        let path = try compositionPath ?? currentCompositionPath()
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw CompositionParserError.compositionNotFound(path)
        }

        let data = try Data(contentsOf: url)
        let xml = try XMLDocument(data: data, options: [])
        guard let root = xml.rootElement() else {
            throw CompositionParserError.parseFailed("composition senza root")
        }

        let compositionName =
            root.elements(forName: "CompositionInfo").first?.attribute(forName: "name")?.stringValue
            ?? url.deletingPathExtension().lastPathComponent

        var triggers: [ClipTrigger] = []
        let layerGroups = buildLayerGroupMap(from: root)
        let columnNames = buildColumnNameMaps(from: root)

        for deck in root.elements(forName: "Deck") {
            for clip in deck.elements(forName: "Clip") {
                guard
                    let layerStr = clip.attribute(forName: "layerIndex")?.stringValue,
                    let columnStr = clip.attribute(forName: "columnIndex")?.stringValue,
                    let layer = Int(layerStr),
                    let column = Int(columnStr)
                else { continue }

                guard let nameParam = findNameParam(in: clip) else { continue }
                guard nameParam.valueName != nameParam.defaultName else { continue }

                let parsed: (seconds: Double, label: String)?
                switch clockSource {
                case .worldClock:
                    parsed = TimeCodeFormat.parseWorldClockName(nameParam.valueName)
                case .ltc:
                    parsed = TimeCodeFormat.parseTimecodeName(nameParam.valueName, fps: fps)
                }
                guard let schedule = parsed else { continue }

                let uniqueId = clip.attribute(forName: "uniqueId")?.stringValue
                    ?? "\(layer)-\(column)-\(nameParam.valueName)"

                let group = layerGroups[layer]
                let columnName = resolveColumnName(
                    column: column,
                    layerGroup: group,
                    maps: columnNames
                )

                triggers.append(
                    ClipTrigger(
                        id: uniqueId,
                        layer: layer,
                        column: column,
                        layerGroup: group,
                        timeSeconds: schedule.seconds,
                        defaultName: nameParam.defaultName.isEmpty ? nameParam.valueName : nameParam.defaultName,
                        displayName: columnName,
                        scheduleLabel: schedule.label,
                        hasFired: currentSeconds > schedule.seconds,
                        isEnabled: true
                    )
                )
            }
        }

        triggers.sort { $0.timeSeconds < $1.timeSeconds }
        return (path, compositionName, triggers)
    }

    private struct ColumnNameMaps {
        /// composition-level columns (no group)
        var composition: [Int: String] = [:]
        /// (groupIndex, columnIndex) → name
        var groups: [String: String] = [:]
    }

    private static func groupKey(_ group: Int, _ column: Int) -> String {
        "\(group):\(column)"
    }

    private static func buildColumnNameMaps(from root: XMLElement) -> ColumnNameMaps {
        var maps = ColumnNameMaps()

        func visit(_ element: XMLElement) {
            if element.name == "Column",
               let columnStr = element.attribute(forName: "columnIndex")?.stringValue,
               let column = Int(columnStr) {
                let nameValue: String? = {
                    for params in element.elements(forName: "Params") {
                        for param in params.elements(forName: "Param") {
                            guard param.attribute(forName: "name")?.stringValue == "Name" else { continue }
                            return param.attribute(forName: "value")?.stringValue
                        }
                    }
                    return nil
                }()
                let trimmed = nameValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let meaningful = !trimmed.isEmpty && trimmed != "Column #"

                if let groupStr = element.attribute(forName: "groupIndex")?.stringValue,
                   let group = Int(groupStr) {
                    let key = groupKey(group, column)
                    if meaningful {
                        maps.groups[key] = trimmed
                    } else if maps.groups[key] == nil {
                        maps.groups[key] = "Colonna \(column + 1)"
                    }
                } else {
                    if meaningful {
                        maps.composition[column] = trimmed
                    } else if maps.composition[column] == nil {
                        maps.composition[column] = "Colonna \(column + 1)"
                    }
                }
            }

            for child in element.children ?? [] {
                if let el = child as? XMLElement {
                    visit(el)
                }
            }
        }

        visit(root)
        return maps
    }

    private static func resolveColumnName(column: Int, layerGroup: Int?, maps: ColumnNameMaps) -> String {
        if let group = layerGroup {
            let key = groupKey(group, column)
            if let name = maps.groups[key], !name.isEmpty {
                return name
            }
        }
        if let name = maps.composition[column], !name.isEmpty {
            return name
        }
        return "Colonna \(column + 1)"
    }

    /// layerIndex (0-based) → layerGroup index (0-based)
    private static func buildLayerGroupMap(from root: XMLElement) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for layer in root.elements(forName: "Layer") {
            guard
                let layerStr = layer.attribute(forName: "layerIndex")?.stringValue,
                let layerIndex = Int(layerStr),
                let groupStr = layer.attribute(forName: "layerGroup")?.stringValue,
                let groupIndex = Int(groupStr)
            else { continue }
            map[layerIndex] = groupIndex
        }
        return map
    }

    // MARK: - Helpers

    private struct NameParam {
        let defaultName: String
        let valueName: String
    }

    private static func findNameParam(in clip: XMLElement) -> NameParam? {
        for params in clip.elements(forName: "Params") {
            for param in params.elements(forName: "Param") {
                guard param.attribute(forName: "name")?.stringValue == "Name" else { continue }
                let value = param.attribute(forName: "value")?.stringValue ?? ""
                let def = param.attribute(forName: "default")?.stringValue ?? ""
                return NameParam(defaultName: def, valueName: value)
            }
        }
        return nil
    }

    private static func findParamValue(in element: XMLElement, name: String) -> String? {
        if element.name == "Param",
           element.attribute(forName: "name")?.stringValue == name {
            return element.attribute(forName: "value")?.stringValue
        }
        for child in element.children ?? [] {
            if let el = child as? XMLElement,
               let value = findParamValue(in: el, name: name) {
                return value
            }
        }
        return nil
    }
}
