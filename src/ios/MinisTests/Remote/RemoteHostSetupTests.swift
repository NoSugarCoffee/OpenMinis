import Foundation
import MinisRemote
import XCTest
@testable import Minis

/// Settings → Remote Hosts glue. Nothing here reaches a host: the one check run targets a host name the
/// directory does not know, which fails before any connect.
@MainActor
final class RemoteHostSetupTests: XCTestCase {
    private final class RecordingSecretStore: RemoteSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]

        var accounts: [String] { lock.withLock { items.keys.sorted() } }

        func set(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
        func get(account: String) throws -> Data? { lock.withLock { items[account] } }
        func delete(account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHostSetupTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeServices(secrets: RecordingSecretStore) throws -> RemoteServices {
        let store = try RemoteHostStore(
            fileURL: directory.appendingPathComponent("remote-hosts.json"), secrets: secrets, onHostAdded: { _ in })
        return RemoteServices.make(store: store, secrets: secrets)
    }

    func testAddHostStoresAKeyWhosePublicLineCarriesTheDeviceComment() throws {
        let secrets = RecordingSecretStore()
        let services = try makeServices(secrets: secrets)

        try RemoteHostSetup.addHost(
            name: "mini", address: "192.0.2.1", port: 22, user: "dev", key: .generate, services: services)

        let host = try XCTUnwrap(services.store.hosts.first)
        XCTAssertEqual(secrets.accounts, [host.keyRef])
        let line = try RemoteHostSetup.publicKeyLine(host: host, services: services)
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 "), line)
        XCTAssertTrue(line.hasSuffix(" " + RemoteHostSetup.publicKeyComment()), line)
        XCTAssertTrue(RemoteHostSetup.publicKeyComment().hasPrefix("minis@"))
    }

    func testRejectedHostLeavesNoKeyBehind() throws {
        let secrets = RecordingSecretStore()
        let services = try makeServices(secrets: secrets)
        try RemoteHostSetup.addHost(
            name: "mini", address: "192.0.2.1", port: 22, user: "dev", key: .generate, services: services)

        XCTAssertThrowsError(try RemoteHostSetup.addHost(
            name: "mini", address: "192.0.2.2", port: 22, user: "dev", key: .generate, services: services)) {
            XCTAssertEqual($0 as? RemoteHostStoreError, .duplicateName("mini"))
        }
        XCTAssertEqual(secrets.accounts.count, 1)
    }

    func testImportOfGarbageExplainsAndStoresNothing() throws {
        let secrets = RecordingSecretStore()
        let services = try makeServices(secrets: secrets)

        XCTAssertThrowsError(try RemoteHostSetup.addHost(
            name: "mini", address: "192.0.2.1", port: 22, user: "dev",
            key: .importOpenSSH(pem: "garbage", passphrase: nil), services: services)) {
            XCTAssertTrue(RemoteHostSetup.message(for: $0).contains("OpenSSH Ed25519"), RemoteHostSetup.message(for: $0))
        }
        XCTAssertEqual(secrets.accounts, [])
        XCTAssertEqual(services.store.hosts, [])
    }

    func testBcryptRoundsRemedyNamesTheReencryptCommand() {
        let message = RemoteHostSetup.message(for: RemoteKeyStoreError.unsupportedKeyEncryption("package wording"))
        XCTAssertTrue(message.contains("ssh-keygen -p -a 16"), message)
    }

    func testMissingFieldsAreWholeSentences() {
        XCTAssertEqual(RemoteHostSetup.message(for: RemoteHostStoreError.missingField("address")), "Enter the host's address.")
        XCTAssertEqual(RemoteHostSetup.message(for: RemoteHostStoreError.missingField("user")), "Enter the host's user name.")
    }

    func testKeychainFailureNamesTheOperationInAWholeSentence() {
        XCTAssertEqual(
            RemoteHostSetup.message(for: RemoteSecretStoreError.keychain(operation: "update", status: -25308)),
            "The Keychain refused to save the key (OSStatus -25308). Unlock the device and try again.")
    }

    func testCheckFindingsAreWordedForSettings() {
        XCTAssertEqual(RemoteHostSetup.checkLabel(.loginShell), "Login shell")
        XCTAssertEqual(
            RemoteHostSetup.checkDetail(.loginShellNotPosix(shell: "/usr/bin/fish", execShell: "/bin/sh")),
            "/usr/bin/fish is not a POSIX shell; commands run with /bin/sh -l instead.")
    }

    func testChecksOnUnknownHostFailWithTheNextStep() async throws {
        let services = try makeServices(secrets: RecordingSecretStore())
        let outcome = await RemoteHostSetup.runChecks(host: "gone", services: services)
        XCTAssertEqual(outcome, .failed("“gone” is not configured. Add it in Settings → Remote Hosts."))
    }

    func testTrustPinsExactlyThePresentedKey() async throws {
        let services = try makeServices(secrets: RecordingSecretStore())
        try RemoteHostSetup.addHost(
            name: "mini", address: "192.0.2.1", port: 22, user: "dev", key: .generate, services: services)
        let prompt = RemoteHostKeyPrompt(
            host: "mini", address: "192.0.2.1", port: 22, fingerprint: "SHA256:x",
            openSSHKey: "ssh-ed25519 AAAAC3Nza", replacesPinnedKey: false)

        try await RemoteHostSetup.trust(prompt, services: services)

        XCTAssertEqual(services.store.hosts.first?.pinnedHostKey, "ssh-ed25519 AAAAC3Nza")
    }

    func testTrustRefusesAKeyFromTheHostsPreviousEndpoint() async throws {
        let services = try makeServices(secrets: RecordingSecretStore())
        try RemoteHostSetup.addHost(
            name: "mini", address: "192.0.2.1", port: 22, user: "dev", key: .generate, services: services)
        let prompt = RemoteHostKeyPrompt(
            host: "mini", address: "192.0.2.1", port: 22, fingerprint: "SHA256:x",
            openSSHKey: "ssh-ed25519 AAAAC3Nza", replacesPinnedKey: false)
        try await RemoteHostSetup.updateHost(
            name: "mini", address: "192.0.2.9", port: 22, user: "dev", services: services)

        do {
            try await RemoteHostSetup.trust(prompt, services: services)
            XCTFail("Expected the stale prompt to be refused")
        } catch {
            XCTAssertTrue(error is RemoteHostSetupFailure, "\(error)")
        }
        XCTAssertNil(services.store.hosts.first?.pinnedHostKey)
    }

    func testInstallCommandQuotesThePublicKeyLine() {
        XCTAssertEqual(
            RemoteHostSetup.authorizedKeysCommand(publicKeyLine: "ssh-ed25519 AAAA minis@Dai's iPhone"),
            #"echo 'ssh-ed25519 AAAA minis@Dai'\''s iPhone' >> ~/.ssh/authorized_keys"#)
    }

    func testCorruptStoreMessagePointsToSettings() {
        let message = RemoteWiringError.storeUnreadable(path: "/x/remote-hosts.json", detail: "bad").userMessage
        XCTAssertTrue(message.contains("Settings → Remote Hosts"), message)
    }
}
