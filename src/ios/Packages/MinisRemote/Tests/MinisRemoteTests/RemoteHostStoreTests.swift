import Crypto
import XCTest
@testable import MinisRemote

@MainActor
final class RemoteHostStoreTests: XCTestCase {
    private var fileURL: URL!
    private var secrets: InMemorySecretStore!
    private var added: [String] = []

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-hosts-\(UUID().uuidString).json")
        secrets = InMemorySecretStore()
        added = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func makeStore() throws -> RemoteHostStore {
        try RemoteHostStore(fileURL: fileURL, secrets: secrets, onHostAdded: { [unowned self] key in added.append(key) })
    }

    private func host(_ name: String, keyRef: String = "key-1") -> RemoteHostConfig {
        RemoteHostConfig(name: name, address: "10.0.0.2", port: 22, user: "u", keyRef: keyRef, pinnedHostKey: nil, os: nil)
    }

    func testAddRejectsDuplicateAndInvalidName() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        XCTAssertThrowsError(try store.add(host("mini"))) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .duplicateName("mini"))
        }
        for bad in ["", "has space", "a/b", "ü", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try store.add(host(bad)), "name \(bad)") {
                XCTAssertEqual($0 as? RemoteHostStoreError, .invalidName(bad))
            }
        }
        XCTAssertNoThrow(try store.add(host(String(repeating: "a", count: 32))))
        XCTAssertNoThrow(try store.add(host("A_b-9")))
        XCTAssertEqual(store.hosts.count, 3)
    }

    func testAddReportsPermissionKey() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        XCTAssertEqual(added, ["remote-host:mini"])
    }

    func testBindingRoundTripsAcrossInstances() throws {
        let first = try makeStore()
        try first.add(host("mini"))
        let value = SessionHostBindingValue(hostName: "mini", workdir: "/home/u/my repo")
        try first.setBinding(value, sessionId: "s1")

        let second = try makeStore()
        XCTAssertEqual(second.binding(sessionId: "s1"), value)
        XCTAssertEqual(second.hosts.map(\.name), ["mini"])

        try second.setBinding(nil, sessionId: "s1")
        XCTAssertNil(try makeStore().binding(sessionId: "s1"))
    }

    func testRemovingHostClearsItsBindings() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        try store.add(host("other", keyRef: "key-2"))
        try store.setBinding(SessionHostBindingValue(hostName: "mini", workdir: "/a"), sessionId: "s1")
        try store.setBinding(SessionHostBindingValue(hostName: "other", workdir: "/b"), sessionId: "s2")
        try store.remove(name: "mini")

        let reloaded = try makeStore()
        XCTAssertNil(reloaded.binding(sessionId: "s1"))
        XCTAssertNotNil(reloaded.binding(sessionId: "s2"))
        XCTAssertEqual(reloaded.hosts.map(\.name), ["other"])
    }

    func testRemovingHostDeletesUnsharedKeyOnly() throws {
        try secrets.set(Data([1]), account: "key-1")
        let store = try makeStore()
        try store.add(host("a"))
        try store.add(host("b"))
        try store.remove(name: "a")
        XCTAssertNotNil(try secrets.get(account: "key-1"))
        try store.remove(name: "b")
        XCTAssertNil(try secrets.get(account: "key-1"))
    }

    func testPinHostKeyPersists() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        try store.pinHostKey(name: "mini", openSSHPublicKey: "ssh-ed25519 AAAA")
        XCTAssertEqual(try makeStore().hosts.first?.pinnedHostKey, "ssh-ed25519 AAAA")
        XCTAssertThrowsError(try store.pinHostKey(name: "nope", openSSHPublicKey: "x")) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .unknownHost("nope"))
        }
    }

    func testFileWrittenBeforeOSFieldDecodesWithoutOS() throws {
        let legacy = #"{"bindings":{},"hosts":[{"address":"a","keyRef":"k","name":"mini","pinnedHostKey":null,"port":22,"user":"u"}]}"#
        try Data(legacy.utf8).write(to: fileURL)
        XCTAssertEqual(
            try makeStore().hosts,
            [RemoteHostConfig(name: "mini", address: "a", port: 22, user: "u", keyRef: "k", pinnedHostKey: nil, os: nil)])
    }

    func testPinHostKeyKeepsTheOS() throws {
        let store = try makeStore()
        try store.add(RemoteHostConfig(
            name: "mini", address: "a", port: 22, user: "u", keyRef: "k", pinnedHostKey: nil, os: "Darwin"))
        try store.pinHostKey(name: "mini", openSSHPublicKey: "ssh-ed25519 AAAA")
        XCTAssertEqual(try makeStore().hosts.first?.os, "Darwin")
    }

    func testMissingFileIsEmptyAndCorruptFileThrows() throws {
        XCTAssertTrue(try makeStore().hosts.isEmpty)
        try Data("{not json".utf8).write(to: fileURL)
        XCTAssertThrowsError(try makeStore())
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("{not json".utf8))
    }

    func testFileShapeHasHostsAndBindingsKeys() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        try store.setBinding(SessionHostBindingValue(hostName: "mini", workdir: "/a"), sessionId: "s1")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(Set(object?.keys.map { $0 } ?? []), ["hosts", "bindings", "recentWorkdirs"])
        XCTAssertNotNil((object?["bindings"] as? [String: Any])?["s1"])
    }
}

@MainActor
extension RemoteHostStoreTests {
    func testSetOSPersistsAndKeepsTheRest() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        try store.pinHostKey(name: "mini", openSSHPublicKey: "ssh-ed25519 AAAA")
        try store.setOS(name: "mini", os: "Linux")

        let reloaded = try XCTUnwrap(try makeStore().hosts.first)
        XCTAssertEqual(reloaded.os, "Linux")
        XCTAssertEqual(reloaded.pinnedHostKey, "ssh-ed25519 AAAA")
        XCTAssertThrowsError(try store.setOS(name: "nope", os: "Linux")) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .unknownHost("nope"))
        }
    }

    func testUpdateToNewEndpointClearsTrustAndOS() throws {
        let store = try makeStore()
        try store.add(RemoteHostConfig(
            name: "mini", address: "a", port: 22, user: "u", keyRef: "k", pinnedHostKey: "ssh-ed25519 AAAA", os: "Darwin"))
        try store.update(name: "mini", address: "b", port: 2222, user: "v")

        XCTAssertEqual(
            try makeStore().hosts,
            [RemoteHostConfig(name: "mini", address: "b", port: 2222, user: "v", keyRef: "k", pinnedHostKey: nil, os: nil)])
    }

    func testUpdateOfUserOnlyKeepsTrustAndOS() throws {
        let store = try makeStore()
        try store.add(RemoteHostConfig(
            name: "mini", address: "a", port: 22, user: "u", keyRef: "k", pinnedHostKey: "ssh-ed25519 AAAA", os: "Darwin"))
        try store.update(name: "mini", address: "a", port: 22, user: "v")

        XCTAssertEqual(
            store.hosts,
            [RemoteHostConfig(name: "mini", address: "a", port: 22, user: "v", keyRef: "k", pinnedHostKey: "ssh-ed25519 AAAA", os: "Darwin")])
    }

    func testAddAndUpdateRejectInvalidConnectionFields() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.add(RemoteHostConfig(
            name: "mini", address: "a", port: 0, user: "u", keyRef: "k", pinnedHostKey: nil, os: nil))) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .invalidPort(0))
        }
        try store.add(host("mini"))
        XCTAssertThrowsError(try store.update(name: "mini", address: " ", port: 22, user: "u")) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .missingField("address"))
        }
        XCTAssertThrowsError(try store.update(name: "mini", address: "a", port: 65536, user: "u")) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .invalidPort(65536))
        }
        XCTAssertThrowsError(try store.update(name: "mini", address: "a", port: 22, user: "")) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .missingField("user"))
        }
        XCTAssertThrowsError(try store.update(name: "nope", address: "a", port: 22, user: "u")) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .unknownHost("nope"))
        }
    }

    func testBindingRecordsRecentWorkdirsMostRecentFirst() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        for (session, dir) in [("s1", "/a"), ("s2", "/b"), ("s3", "/a")] {
            try store.setBinding(SessionHostBindingValue(hostName: "mini", workdir: dir), sessionId: session)
        }
        try store.setBinding(nil, sessionId: "s1")

        XCTAssertEqual(try makeStore().recentWorkdirs(host: "mini"), ["/a", "/b"])
        XCTAssertEqual(store.recentWorkdirs(host: "other"), [])
    }

    func testRecentWorkdirsAreCapped() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        for index in 0..<(RemoteHostStore.maxRecentWorkdirs + 3) {
            try store.setBinding(SessionHostBindingValue(hostName: "mini", workdir: "/d\(index)"), sessionId: "s")
        }
        let recent = store.recentWorkdirs(host: "mini")
        XCTAssertEqual(recent.count, RemoteHostStore.maxRecentWorkdirs)
        XCTAssertEqual(recent.first, "/d\(RemoteHostStore.maxRecentWorkdirs + 2)")
    }

    func testRemovingHostForgetsItsRecentWorkdirs() throws {
        let store = try makeStore()
        try store.add(host("mini"))
        try store.setBinding(SessionHostBindingValue(hostName: "mini", workdir: "/a"), sessionId: "s1")
        try store.remove(name: "mini")
        try store.add(host("mini"))
        XCTAssertEqual(store.recentWorkdirs(host: "mini"), [])
    }

    func testUnreadableFileIsMovedAsideForAFreshStart() throws {
        try Data("{not json".utf8).write(to: fileURL)
        let date = Date(timeIntervalSince1970: 1_760_000_000)

        let backup = try RemoteHostStore.moveUnreadableFileAside(at: fileURL, date: date)
        addTeardownBlock { try? FileManager.default.removeItem(at: backup) }

        XCTAssertEqual(backup.deletingLastPathComponent(), fileURL.deletingLastPathComponent())
        XCTAssertTrue(backup.lastPathComponent.hasPrefix(fileURL.lastPathComponent + ".unreadable-"), backup.path)
        XCTAssertEqual(try Data(contentsOf: backup), Data("{not json".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try makeStore().hosts.isEmpty)
    }
}

final class RemoteKeyStoreTests: XCTestCase {
    func testGenerateStoresKeyAndReturnsMatchingPublicLine() throws {
        let store = InMemorySecretStore()
        let line = try RemoteKeyStore.generateEd25519(store: store, account: "k", comment: "minis@phone")
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(line.hasSuffix(" minis@phone"))
        let key = try RemoteKeyStore.privateKey(store: store, account: "k")
        let again = RemoteKeyStore.publicKeyLine(of: key, comment: "minis@phone")
        XCTAssertEqual(line, again)
    }

    func testPrivateKeyMissingThrows() {
        XCTAssertThrowsError(try RemoteKeyStore.privateKey(store: InMemorySecretStore(), account: "none")) {
            XCTAssertEqual($0 as? RemoteKeyStoreError, .keyNotFound(account: "none"))
        }
    }

    // Generated with: ssh-keygen -t ed25519 -N '' -C minis@test
    func testImportOpenSSHKeyMatchesSshKeygenPublicKey() throws {
        let store = InMemorySecretStore()
        let line = try RemoteKeyStore.importOpenSSHPrivateKey(
            store: store, Fixtures.privatePEM, passphrase: nil, account: "imp", comment: "minis@test")
        XCTAssertEqual(line, Fixtures.publicLine)
        XCTAssertNotNil(try store.get(account: "imp"))
    }

    func testImportGarbageThrowsAndStoresNothing() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try RemoteKeyStore.importOpenSSHPrivateKey(
            store: store, "garbage", passphrase: nil, account: "x", comment: "c"))
        XCTAssertNil(try store.get(account: "x"))
    }
}

extension RemoteKeyStoreTests {
    func testImportEncryptedKeyNeedsPassphrase() throws {
        let store = InMemorySecretStore()
        let line = try RemoteKeyStore.importOpenSSHPrivateKey(
            store: store, Fixtures.encryptedPrivatePEM, passphrase: "pw", account: "enc", comment: "minis@test")
        XCTAssertEqual(line, Fixtures.encryptedPublicLine)
        XCTAssertThrowsError(try RemoteKeyStore.importOpenSSHPrivateKey(
            store: store, Fixtures.encryptedPrivatePEM, passphrase: nil, account: "enc2", comment: "c"))
        XCTAssertNil(try store.get(account: "enc2"))
    }

    /// The app wraps the decoder's own description in a sentence in the user's language.
    func testImportOfGarbageCarriesTheDecoderError() {
        var decoderError = ""
        do {
            _ = try Curve25519.Signing.PrivateKey(sshEd25519: "garbage", decryptionKey: nil)
        } catch {
            decoderError = String(describing: error)
        }
        XCTAssertThrowsError(try RemoteKeyStore.importOpenSSHPrivateKey(
            store: InMemorySecretStore(), "garbage", passphrase: nil, account: "g", comment: "c")) {
            XCTAssertEqual($0 as? RemoteKeyStoreError, .invalidPrivateKey(decoderError))
        }
    }

    func testImportDefaultRoundsEncryptedKeyExplainsRemedy() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try RemoteKeyStore.importOpenSSHPrivateKey(
            store: store, Fixtures.defaultRoundsEncryptedPrivatePEM, passphrase: "pw", account: "def", comment: "c")) {
            guard case .unsupportedKeyEncryption(let message) = $0 as? RemoteKeyStoreError else {
                return XCTFail("Expected unsupportedKeyEncryption, got \($0)")
            }
            XCTAssertTrue(message.contains("ssh-keygen -p -a 16"))
        }
        XCTAssertNil(try? store.get(account: "def"))
    }
}
