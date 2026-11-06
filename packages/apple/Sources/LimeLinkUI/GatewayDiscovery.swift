import Foundation
import Combine
import LimeLinkCore

/// 只浏览明确的 DNS-SD 服务类型，不扫描局域网端口，不向候选地址发送凭据。
@MainActor public final class GatewayDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    public static let serviceType = "_limeiot._tcp."
    @Published public private(set) var gateways: [GatewayCandidate] = []
    @Published public private(set) var message = "正在查找网关…"
    @Published public private(set) var searching = false
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var candidates: [String: GatewayCandidate] = [:]
    private var timeout: Task<Void, Never>?

    public override init() { super.init() }
    public func start() {
        guard browser == nil else { return }
        searching = true; message = "正在查找网关…"
        let next = NetServiceBrowser(); next.delegate = self; browser = next
        next.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.browser != nil else { return }
            self.searching = false
            self.message = self.gateways.isEmpty ? "未发现网关，请确认已连接同一 Wi-Fi。" : "附近的网关"
        }
    }
    public func stop() {
        timeout?.cancel(); timeout = nil
        browser?.delegate = nil; browser?.stop(); browser = nil
        for service in services.values { service.delegate = nil; service.stopMonitoring(); service.stop() }
        services.removeAll(); candidates.removeAll(); gateways = []; searching = false
    }
    public func restart() { stop(); start() }
    private func key(_ service: NetService) -> String { service.domain + "|" + service.type + "|" + service.name }
    private func publish() {
        gateways = Dictionary(grouping: candidates.values, by: \.origin).compactMap { $0.value.sorted { $0.name < $1.name }.first }.sorted { $0.origin < $1.origin }
        if !gateways.isEmpty { searching = false; message = "附近的网关" }
        else if !searching { message = "未发现网关，请确认已连接同一 Wi-Fi。" }
    }
    private func read(_ service: NetService, data: Data?) {
        let id = key(service)
        guard services[id] === service else { return }
        if let data, data.count <= 1300, let candidate = GatewayCandidate(name: service.name, attributes: NetService.dictionary(fromTXTRecord: data)) { candidates[id] = candidate }
        else { candidates[id] = nil }
        publish()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        let id = key(service)
        if let old = services[id] { old.delegate = nil; old.stopMonitoring(); old.stop() }
        services[id] = service; service.delegate = self
        service.resolve(withTimeout: 5)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard self.browser === browser else { return }
        let id = key(service)
        if let old = services.removeValue(forKey: id) { old.delegate = nil; old.stopMonitoring(); old.stop() }
        candidates[id] = nil; publish()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard self.browser === browser else { return }
        stop(); message = "无法发现网关，请检查本地网络权限。"
    }
    public func netServiceDidResolveAddress(_ sender: NetService) { read(sender, data: sender.txtRecordData()); sender.startMonitoring() }
    public func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { read(sender, data: data) }
}
