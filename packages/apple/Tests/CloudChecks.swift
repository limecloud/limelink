import Foundation
import LimeIoTKit
import LimeLinkCore

private actor CloudCheckStore: SessionStore {
    var values: [String: Data] = [:]
    func load(origin: String) -> Data? { values[origin] }
    func save(origin: String, data: Data?) { values[origin] = data }
}
func cloudConsumerChecks() async throws {
    guard let origin = ProcessInfo.processInfo.environment["LIMELINK_CLOUD_CHECK_ORIGIN"] else { return }
    func check(_ condition: Bool) throws { guard condition else { throw LinkError("cloud_consumer_check_failed") } }
    let store = CloudCheckStore(), client = try CloudLinkClient(endpoint: origin, store: store, development: true)
    _ = try await client.control.beginAuthorization(platform: "macos"); _ = try await client.control.pollAuthorization()
    let snapshot = try await client.snapshot(space: "cloud-space"), device = snapshot.devices[0]
    let fingerprint = try await client.fingerprint(device: device.id)
    do { _ = try await client.perform(space: "cloud-space", device: device, kind: "pair", payload: .object(["name": .string("Mac")])); throw LinkError("expected_response_loss") } catch is URLError {}
    let recovered = try CloudLinkClient(endpoint: origin, store: store, development: true)
    let records = try await recovered.records(); try check(records.count == 1 && records[0].attempted)
    do { _ = try await recovered.resolve(key: records[0].id); throw LinkError("expected_original_404") } catch ControlError.server(_, 404) {}
    let outcome = try await recovered.resolve(key: records[0].id); try check(outcome.result?.status == .unknown)
    _ = try await recovered.snapshot(space: "cloud-space"); try check(await recovered.fingerprint(device: device.id) == fingerprint)
    _ = try await recovered.snapshot(space: "another-space")
    do { _ = try await recovered.perform(space: "another-space", device: device, kind: "pair", payload: .object([:])); throw LinkError("expected_original_block") } catch let error as LinkError { try check(error.code == "resolve_original_request_first") }
}
