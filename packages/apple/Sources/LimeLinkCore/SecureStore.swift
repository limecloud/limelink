import Foundation
import Security
import CryptoKit
import LimeIoTKit

public actor SecureStore: SessionStore {
    private let service: String
    public init(service: String = "run.limeai.limelink") { self.service = service }
    public func load(origin: String) throws -> Data? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:origin,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LinkError("secure_storage_unavailable") }
        return data
    }
    public func save(origin: String, data: Data?) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:origin]
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard [errSecSuccess,errSecItemNotFound].contains(status) else { throw LinkError("secure_storage_unavailable") }
            return
        }
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary,nil) == errSecSuccess else { throw LinkError("secure_storage_unavailable") }
        } else if status != errSecSuccess { throw LinkError("secure_storage_unavailable") }
    }
}
public struct LinkError: LocalizedError, Sendable {
    public let code: String
    public init(_ code: String) { self.code=code }
    public var errorDescription: String? { code }
}
public struct LinkIdentity: Codable, Sendable {
    public let id: String
    public let key: Data
    public init() { id=UUID().uuidString.lowercased();key=P256.Signing.PrivateKey().rawRepresentation }
    public var publicKey: String { get throws { try P256.Signing.PrivateKey(rawRepresentation:key).publicKey.x963Representation.hex } }
    public var fingerprint: String { get throws { Data(SHA256.hash(data:Data(try publicKey.utf8))).hex } }
    public func exchange(space:String,device:String,revision:String,kind:String,payload:String,now:Date = .now,nonce:String = UUID().uuidString.lowercased()) throws -> JSONValue {
        guard payload.utf8.count <= 4096 else { throw LinkError("payload_too_large") }
        let expires=Int(now.timeIntervalSince1970)+20
        let hash=Data(SHA256.hash(data:Data(payload.utf8))).hex
        let message="limelink.exchange/v1\n\(space)\n\(device)\n\(revision)\n\(id)\n\(kind)\n\(nonce)\n\(expires)\n\(hash)"
        let signature=try P256.Signing.PrivateKey(rawRepresentation:key).signature(for:Data(message.utf8)).derRepresentation.hex
        return .object(["client_id":.string(id),"public_key":.string(try publicKey),"kind":.string(kind),"nonce":.string(nonce),"expires_at":.integer(expires),"payload":.string(payload),"signature":.string(signature)])
    }
}
extension Data { var hex: String { map { String(format:"%02x",$0) }.joined() } }
