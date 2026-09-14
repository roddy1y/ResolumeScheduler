import Foundation

/// Minimal Resolume Webserver client (group names + group-column connect fallback).
enum ResolumeREST {
    static var baseURL: URL { URL(string: "http://127.0.0.1:8080/api/v1")! }

    static func fetchLayerGroups() async -> [LayerGroupInfo] {
        do {
            let url = baseURL.appendingPathComponent("composition")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = root["layergroups"] as? [[String: Any]]
            else { return [] }

            return groups.enumerated().map { index, group in
                let name: String = {
                    if let n = group["name"] as? [String: Any], let v = n["value"] as? String, !v.isEmpty {
                        return v
                    }
                    return "Layer Group \(index + 1)"
                }()
                return LayerGroupInfo(index: index, name: name)
            }
        } catch {
            return []
        }
    }

    /// POST connect — useful fallback when OSC group-column doesn't fire.
    @discardableResult
    static func connectGroupColumn(groupOneBased: Int, columnOneBased: Int) async -> Bool {
        let path = "composition/layergroups/\(groupOneBased)/columns/\(columnOneBased)/connect"
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
