import Foundation

/// 局域网公告仅提供候选地址，不代表已认证的网关或设备身份。
public struct GatewayCandidate: Identifiable, Equatable, Sendable {
    public let origin: String
    public let name: String
    public var id: String { origin }
    public init?(name: String, attributes: [String: Data]) {
        guard attributes["version"] == Data("1".utf8),
              let data = attributes["origin"], data.count <= 248,
              let value = String(data: data, encoding: .utf8), !value.contains("%"),
              let url = URLComponents(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || ".-:[]".utf8.contains($0) }),
              url.user == nil, url.password == nil, url.path.isEmpty,
              url.query == nil, url.fragment == nil,
              url.port == nil || (1...65535).contains(url.port!),
              url.string == value, !value.hasSuffix(":") else { return nil }
        origin = value
        let label = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80))
        self.name = label.isEmpty ? "LimeIoT 网关" : label
    }
}
