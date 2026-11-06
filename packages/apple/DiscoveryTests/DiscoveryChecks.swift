import Foundation
import LimeLinkCore
import LimeLinkUI

struct Fixture: Decodable {
    struct Row: Decodable { let name: String; let attributes: [String: String]; let valid: Bool }
    let cases: [Row]
}
@main @MainActor enum DiscoveryChecks {
    static func main() async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "contracts/fixtures/gateway-discovery.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        for row in fixture.cases {
            let candidate = GatewayCandidate(name: row.name, attributes: row.attributes.mapValues { Data($0.utf8) })
            guard (candidate != nil) == row.valid else { throw NSError(domain: "discovery_fixture_\(row.name)", code: 1) }
        }
        guard GatewayCandidate(name: "invalid", attributes: ["version": Data("1".utf8), "origin": Data([0xff])]) == nil else { fatalError("invalid_utf8") }
        guard GatewayCandidate(name: "long", attributes: ["version": Data("1".utf8), "origin": Data(("https://" + String(repeating: "a", count: 250)).utf8)]) == nil else { fatalError("oversized_txt") }
        print("discovery_contract_passed", terminator: "\n"); fflush(stdout)
        guard let origin = ProcessInfo.processInfo.environment["LIMELINK_DISCOVERY_EXPECT_ORIGIN"] else { return }
        let discovery = GatewayDiscovery(); discovery.start(); defer { discovery.stop() }
        let deadline = Date().addingTimeInterval(40)
        var step = 0
        while Date() < deadline {
            let count = discovery.gateways.filter { $0.origin == origin }.count
            guard count <= 1 else { fatalError("duplicate_origin") }
            if step == 0 && count == 1 { print("gateway_seen"); fflush(stdout); step = 1 }
            else if step == 1 && count == 0 { print("gateway_removed"); fflush(stdout); step = 2 }
            else if step == 2 && count == 1 { print("gateway_reappeared"); fflush(stdout); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "discovery_live_timeout_step_\(step)", code: 1)
    }
}
