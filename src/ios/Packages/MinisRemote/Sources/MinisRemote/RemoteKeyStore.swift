@preconcurrency import Citadel
import Crypto
import Foundation
import NIOSSH
import Security

public protocol RemoteSecretStore: Sendable {
    func set(_ data: Data, account: String) throws
    func get(account: String) throws -> Data?
    func delete(account: String) throws
}

public enum RemoteSecretStoreError: Error, Equatable {
    case keychain(operation: String, status: Int32)
}

/// Verified in-app only: unsigned `swift test` binaries lack keychain entitlements (errSecMissingEntitlement).
public struct KeychainSecretStore: RemoteSecretStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func set(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemoteSecretStoreError.keychain(operation: "update", status: updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RemoteSecretStoreError.keychain(operation: "add", status: addStatus)
        }
    }

    public func get(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw RemoteSecretStoreError.keychain(operation: "get", status: status)
        }
        return result as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteSecretStoreError.keychain(operation: "delete", status: status)
        }
    }
}

public final class InMemorySecretStore: RemoteSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func set(_ data: Data, account: String) throws {
        lock.withLock { items[account] = data }
    }

    public func get(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    public func delete(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

public enum RemoteKeyStoreError: Error, Equatable {
    case keyNotFound(account: String)
    case corruptStoredKey(account: String)
    /// The decoder's description (wrong passphrase, unsupported type or malformed text); the app words the rest.
    case invalidPrivateKey(String)
    case unsupportedKeyEncryption(String)
}

public enum RemoteKeyStore {
    public static func generateEd25519(store: RemoteSecretStore, account: String, comment: String) throws -> String {
        let key = Curve25519.Signing.PrivateKey()
        try store.set(key.rawRepresentation, account: account)
        return publicKeyLine(of: key, comment: comment)
    }

    public static func importOpenSSHPrivateKey(
        store: RemoteSecretStore, _ pem: String, passphrase: String?, account: String, comment: String
    ) throws -> String {
        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: passphrase.map { Data($0.utf8) })
        } catch let error as InvalidOpenSSHKey where String(describing: error).contains("invalidOrUnsupportedBCryptConfig") {
            // Citadel's `reason` is internal, so the description is the only way to recognise its bcrypt rounds >= 18 rejection.
            throw RemoteKeyStoreError.unsupportedKeyEncryption(
                "This key's passphrase encryption uses more bcrypt rounds than Citadel supports (current ssh-keygen defaults to 24, the limit is 17). Re-encrypt a copy with fewer rounds: ssh-keygen -p -a 16 -f <key>, then import it again.")
        } catch {
            throw RemoteKeyStoreError.invalidPrivateKey(String(describing: error))
        }
        try store.set(key.rawRepresentation, account: account)
        return publicKeyLine(of: key, comment: comment)
    }

    public static func privateKey(store: RemoteSecretStore, account: String) throws -> Curve25519.Signing.PrivateKey {
        guard let raw = try store.get(account: account) else {
            throw RemoteKeyStoreError.keyNotFound(account: account)
        }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        } catch {
            throw RemoteKeyStoreError.corruptStoredKey(account: account)
        }
    }

    public static func publicKeyLine(of key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        let line = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        return line + " " + comment
    }
}
