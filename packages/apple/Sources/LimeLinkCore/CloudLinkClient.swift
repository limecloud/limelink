import CryptoKit
import Foundation
import LimeIoTKit

public struct CloudLinkSnapshot: Sendable {
    public let space: String
    public let principal: String
    public let gateway: ControlGateway
    public let devices: [Device]
    public let models: [String: Model]
}

/// 消费 IoT 正式云合同；产品只拥有目标选择与按本地空间绑定的协同签名。
public actor CloudLinkClient {
    public nonisolated let control: ControlClient
    private let store: any SessionStore
    private var selected: CloudLinkSnapshot?
    private var busy = false
    public init(endpoint: String, store: any SessionStore = SecureStore(), transport: any HTTPTransport = URLSessionTransport(), development: Bool = false) throws {
        self.store = store
        control = try ControlClient(endpoint: endpoint, store: store, transport: transport, allowLoopbackHTTP: development)
    }
    public func snapshot(space: String) async throws -> CloudLinkSnapshot {
        let session = try await control.restoreSession()
        let gateways = try await control.gateways(space: space).filter { $0.active }
        guard gateways.count == 1 else { throw LinkError("select_single_active_gateway") }
        let gateway = gateways[0]
        guard gateway.spaceId == space, gateway.principalId == session.principal.principalId,
              gateway.scopes.contains("devices.read"), gateway.scopes.contains("commands.write") else { throw LinkError("gateway_scope_mismatch") }
        var devices: [Device] = [], cursors: Set<String> = [], after: String? = nil
        repeat {
            try Task.checkCancellation()
            let page = try await control.devices(space: space, after: after)
            guard page.bindingRevision == gateway.revision, devices.count + page.items.count <= 1024 else { throw LinkError("gateway_binding_changed") }
            devices += page.items; after = page.next
            if let after { guard cursors.count < 128, cursors.insert(after).inserted else { throw LinkError("invalid_device_cursor") } }
        } while after != nil
        guard Set(devices.map(\.id)).count == devices.count else { throw LinkError("duplicate_remote_device") }
        var models: [String: Model] = [:]
        for revision in Set(devices.map(\.modelRevision)) { models[revision] = try await control.model(space: space, revision: revision) }
        let latest = try await control.gateways(space: space).filter { $0.active }
        guard latest.count == 1, latest[0].gatewayId == gateway.gatewayId, latest[0].revision == gateway.revision,
              latest[0].localSpaceId == gateway.localSpaceId, latest[0].principalId == gateway.principalId else { throw LinkError("gateway_binding_changed") }
        let value = CloudLinkSnapshot(space: space, principal: session.principal.principalId, gateway: gateway, devices: devices, models: models)
        selected = value; return value
    }
    private func identity(_ snapshot: CloudLinkSnapshot, device: String) async throws -> LinkIdentity {
        let principal = try await control.restoreSession().principal.principalId
        guard principal == snapshot.principal else { throw LinkError("cloud_identity_changed") }
        let tuple = try JSONEncoder().encode([control.origin, principal, snapshot.space, snapshot.gateway.gatewayId, snapshot.gateway.localSpaceId, device])
        let scope = control.origin + "#limelink.cloud.identity:" + Data(SHA256.hash(data: tuple)).hex
        if let data = try await store.load(origin: scope) { return try JSONDecoder().decode(LinkIdentity.self, from: data) }
        let identity = LinkIdentity(), data = try JSONEncoder().encode(identity)
        try await store.save(origin: scope, data: data)
        guard try await store.load(origin: scope) == data else { throw LinkError("identity_not_durable") }
        return identity
    }
    public func fingerprint(device: String) async throws -> String {
        guard let selected else { throw LinkError("refresh_target_required") }
        return try await identity(selected, device: device).fingerprint
    }
    public func records() async throws -> [ControlCommandRecord] {
        try await control.commandRecords().filter { $0.reference.request.operation.type == "action.invoke" && $0.reference.request.operation.path == "link.exchange" }
    }
    public func perform(space: String, device: Device, kind: String, payload: JSONValue) async throws -> ControlCommandRecord {
        guard !busy else { throw LinkError("request_in_progress") }; busy = true; defer { busy = false }
        guard let previous = selected, previous.space == space, device.ready else { throw LinkError("refresh_target_required") }
        guard try await !records().contains(where: { $0.isPrepared || !$0.canForget }) else { throw LinkError("resolve_original_request_first") }
        let snapshot = try await snapshot(space: space)
        guard snapshot.principal == previous.principal, snapshot.gateway.gatewayId == previous.gateway.gatewayId,
              snapshot.gateway.revision == previous.gateway.revision, snapshot.gateway.localSpaceId == previous.gateway.localSpaceId else { throw LinkError("gateway_binding_changed") }
        guard let current = snapshot.devices.first(where: { $0.id == device.id && $0.ready && $0.modelRevision == device.modelRevision }) else { throw LinkError("target_changed") }
        guard snapshot.models[current.modelRevision]?.modelId == "urn:limelink:model:desktop:1" else { throw LinkError("target_capability_changed") }
        let identity = try await identity(snapshot, device: current.id)
        let input = try identity.exchange(space: snapshot.gateway.localSpaceId, device: current.id, revision: current.modelRevision, kind: kind, payload: payload.jsonText)
        let record = try await control.prepareCommand(space: space, gateway: snapshot.gateway, device: current, path: "link.exchange", value: input, type: "action.invoke")
        try Task.checkCancellation()
        return try await control.submitCommand(key: record.id)
    }
    public func resolve(key: String, reconcile: Bool = false) async throws -> ControlCommandRecord { try await control.resolveCommand(key: key, reconcile: reconcile) }
    public func forget(key: String) async throws { try await control.forgetCommand(key: key) }
    public func logout() async throws { try await control.logout(); selected = nil }
    public static func response(_ record: ControlCommandRecord) throws -> JSONValue? {
        guard record.result?.status == .confirmed, case .object(let local) = record.result?.localResult,
              case .object(let evidence) = local["evidence"], case .object(let output) = evidence["output"],
              case .string(let text) = output["response"] else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
