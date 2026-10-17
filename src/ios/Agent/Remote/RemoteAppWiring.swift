import Foundation
import MinisRemote
import UIKit

private let logger = AppLogger(category: "RemoteHost")

enum RemoteWiringError: Error, Equatable {
    case storeUnreadable(path: String, detail: String)
    case storeReadable

    var userMessage: String {
        switch self {
        case .storeUnreadable(let path, let detail):
            return "Error: Remote host settings at \(path) could not be read (\(detail)). Shell and file tools are blocked so a call meant for a host never runs on this phone. Ask the user to open Settings → Remote Hosts and reset the host list (the unreadable file is kept as a backup), then retry."
        case .storeReadable:
            return "Remote host settings are readable; there is nothing to reset."
        }
    }
}

/// The package types, wired to one host store. Created once per app; tests build their own.
struct RemoteServices {
    let store: RemoteHostStore
    let secrets: RemoteSecretStore
    let pool: SSHConnectionPool
    let executor: RemoteExecutor
    let files: RemoteFileService

    @MainActor
    static func make(store: RemoteHostStore, secrets: RemoteSecretStore) -> RemoteServices {
        let pool = SSHConnectionPool(
            directory: StoreBackedHostDirectory(store: store, secrets: secrets), connectTimeout: .seconds(10))
        return RemoteServices(
            store: store, secrets: secrets, pool: pool, executor: RemoteExecutor(pool: pool),
            files: RemoteFileService(pool: pool))
    }
}

struct RemoteBoundHost: Equatable {
    let binding: SessionHostBindingValue
    /// nil until the setup checks have read it from the host.
    let os: String?
}

/// Owns the app's shared remote-host instances; the package has no singletons.
@MainActor
final class RemoteAppWiring: ObservableObject {
    static let shared = RemoteAppWiring.live()
    private static let liveFileURL = URL.applicationSupportDirectory.appendingPathComponent("remote-hosts.json")
    private static let liveSecrets = KeychainSecretStore(service: "minis.remote-host.key")

    private struct PermissionKey: Hashable {
        let permission: String
        let sessionId: String?
    }

    @Published private(set) var services: Result<RemoteServices, RemoteWiringError>
    private let permissionRequests = RequestCoalescer<PermissionKey, PermissionResult>()
    private var foregroundObserver: NSObjectProtocol?

    init(services: Result<RemoteServices, RemoteWiringError>) {
        self.services = services
    }

    private static func live() -> RemoteAppWiring {
        let wiring = RemoteAppWiring(services: loadLiveServices())
        wiring.foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak wiring] _ in
            MainActor.assumeIsolated {
                guard case .success(let services) = wiring?.services else { return }
                // iOS tears sockets down while suspended; the next call must reconnect instead of using a dead client.
                Task { await services.pool.invalidateClosed() }
            }
        }
        return wiring
    }

    private static func loadLiveServices() -> Result<RemoteServices, RemoteWiringError> {
        let fileURL = liveFileURL
        do {
            let store = try RemoteHostStore(fileURL: fileURL, secrets: liveSecrets, onHostAdded: {
                // Unset permission keys read as Bypass; a new host must ask first.
                OffloadPermissionManager.shared.setPermissionLevel(.askOnce, for: $0)
            })
            return .success(RemoteServices.make(store: store, secrets: liveSecrets))
        } catch {
            logger.error("Remote host settings unreadable at \(fileURL.path): \(error)")
            return .failure(.storeUnreadable(path: fileURL.path, detail: String(describing: error)))
        }
    }

    /// Settings' answer to `storeUnreadable`: keeps the unreadable file as a backup and starts with no hosts.
    /// Returns the backup's location so the user can recover it.
    func resetUnreadableStore() throws -> URL {
        guard case .failure = services else { throw RemoteWiringError.storeReadable }
        let backup = try RemoteHostStore.moveUnreadableFileAside(at: Self.liveFileURL, date: Date())
        logger.info("Moved unreadable remote host settings to \(backup.path)")
        services = Self.loadLiveServices()
        return backup
    }

    /// Must match the key `RemoteHostStore.add` reports to `onHostAdded`.
    static func permissionKey(host: String) -> String {
        RemotePermissionRows.permissionKeyPrefix + host
    }

    /// Where `OffloadPermissionManager` stores the level (its private `defaultsKey(for:)`); only an unset key
    /// needs it, which the manager's API cannot tell apart from Bypass.
    static func permissionDefaultsKey(host: String) -> String {
        "offloadPermission.\(permissionKey(host: host))"
    }

    /// The manager reads an unset key as Bypass. A host whose level was never written (added before the
    /// `onHostAdded` default, or after the defaults were cleared) must ask first, so it gets Ask Once here.
    static func defaultUnsetPermissionToAskOnce(host: String) {
        guard UserDefaults.standard.object(forKey: permissionDefaultsKey(host: host)) == nil else { return }
        OffloadPermissionManager.shared.setPermissionLevel(.askOnce, for: permissionKey(host: host))
    }

    /// The manager's own denial names the raw `remote-host:<name>` key and the device Permissions page, which
    /// does not list hosts.
    static func permissionDeniedMessage(host: String, level: OffloadPermissionLevel) -> String {
        let place = "Settings → Remote Hosts → \(host)"
        guard level == .notAllowed else {
            return "Permission denied: the user declined tool calls on host `\(host)` for this session, or did not answer in time. To change it, open \(place)."
        }
        return "Permission denied: tool calls on host `\(host)` are set to Not Allowed. To change it, open \(place)."
    }

    var hasConfiguredHosts: Bool {
        guard case .success(let services) = services else { return false }
        return !services.store.hosts.isEmpty
    }

    func binding(sessionId: String?) -> SessionHostBindingValue? {
        guard case .success(let services) = services, let sessionId else { return nil }
        return services.store.binding(sessionId: sessionId)
    }

    /// Pure lookup, no network: the OS comes from the host config, which the setup checks fill.
    func boundHost(sessionId: String?) -> RemoteBoundHost? {
        guard case .success(let services) = services, let binding = binding(sessionId: sessionId) else { return nil }
        let os = services.store.hosts.first { $0.name == binding.hostName }?.os
        return RemoteBoundHost(binding: binding, os: os)
    }

    func systemPromptFragment(sessionId: String?) -> String {
        guard let bound = boundHost(sessionId: sessionId) else { return "" }
        return RemoteToolOutput.systemPromptFragment(binding: bound.binding, os: bound.os)
    }

    /// `OffloadPermissionManager` holds one pending prompt; a second concurrent request would replace the first,
    /// whose continuation then never resumes. Parallel tool calls to one host therefore share a single check.
    func checkPermission(host: String, sessionId: String?, summary: String) async -> PermissionResult {
        let permission = Self.permissionKey(host: host)
        Self.defaultUnsetPermissionToAskOnce(host: host)
        let result = await permissionRequests.run(key: PermissionKey(permission: permission, sessionId: sessionId)) {
            await OffloadPermissionManager.shared.checkPermission(
                for: permission, sessionId: sessionId, fullCommand: summary)
        }
        guard case .denied = result else { return result }
        return .denied(Self.permissionDeniedMessage(
            host: host, level: OffloadPermissionManager.shared.permissionLevel(for: permission)))
    }
}
