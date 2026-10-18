//
//  RemoteOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for the `minis-remote` offload (fork: remote-host). Argument
//  and path validation live in the MinisRemote package; this resolves the
//  calling session, asks permission and calls the shared file service.
//

import Foundation
import MinisRemote

private let logger = AppLogger(category: "RemoteOffload")

@objc public class RemoteOffloadBridge: NSObject {
    private static let reachabilityBudget: Duration = .seconds(9)
    private static let inFlight = InFlightCopies()

    private final class InFlightCopies: @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [UUID: Task<Void, Never>] = [:]

        func add(_ task: Task<Void, Never>, id: UUID) {
            lock.lock(); defer { lock.unlock() }
            tasks[id] = task
        }

        func remove(id: UUID) {
            lock.lock(); defer { lock.unlock() }
            tasks.removeValue(forKey: id)
        }

        func cancelAll() -> Bool {
            lock.lock(); defer { lock.unlock() }
            tasks.values.forEach { $0.cancel() }
            return !tasks.isEmpty
        }
    }

    /// Blocking helper: the offload handler runs on the iSH guest thread, never on main. The task stays
    /// cancellable through `cancelInFlight` so a guest `kill` can stop a long copy.
    private static func onMain(_ body: @escaping @MainActor () async -> NSDictionary) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        let id = UUID()
        let box = ResultBox()
        let task = Task { @MainActor in
            box.value = await body()
            sem.signal()
        }
        inFlight.add(task, id: id)
        sem.wait()
        inFlight.remove(id: id)
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: NSDictionary = [:]
    }

    /// Abort handler for a guest signal; returns whether anything was running to stop.
    @objc public static func cancelInFlight() -> Bool {
        inFlight.cancelAll()
    }

    private static func failure(_ code: String, _ message: String) -> NSDictionary {
        ["ok": false, "error": code, "message": message] as NSDictionary
    }

    private struct Caller {
        let sessionId: String
        let bindingSessionId: String
    }

    /// A sub agent's hidden session works for its parent, so binding and the Ask Once grant come from the parent.
    @MainActor
    private static func caller(fsContext: UInt64) async -> Caller? {
        guard let sid = MinisFsRouter.shared.sid(for: fsContext) else { return nil }
        let parent = await ChatStore.shared.getSession(sid)?.parentSessionId
        return Caller(sessionId: sid, bindingSessionId: parent ?? sid)
    }

    private static let unknownCaller = "Error: could not tell which chat session ran this command, so no path or permission could be checked. Run it from a chat session's shell."

    // MARK: - cp

    @objc public static func copy(positional: [String], fsContext: UInt64) -> NSDictionary {
        onMain {
            guard let caller = await caller(fsContext: fsContext) else { return failure("copy_failed", unknownCaller) }
            return await copy(positional: positional, caller: caller, wiring: .shared)
        }
    }

    @MainActor
    static func copy(positional: [String], sessionId: String, bindingSessionId: String, wiring: RemoteAppWiring) async -> NSDictionary {
        await copy(
            positional: positional, caller: Caller(sessionId: sessionId, bindingSessionId: bindingSessionId),
            wiring: wiring)
    }

    @MainActor
    private static func copy(positional: [String], caller: Caller, wiring: RemoteAppWiring) async -> NSDictionary {
        let services: RemoteServices
        switch wiring.services {
        case .success(let ready): services = ready
        case .failure(let error): return failure("remote_unavailable", error.userMessage)
        }

        let plan: RemoteCopyPlan
        let local: RemoteContainedPath
        do {
            let (src, dst) = try RemoteCopyArguments.parseCommandLine(positional: positional)
            plan = try RemoteCopyArguments.plan(src: src, dst: dst, knownHosts: services.store.hosts.map(\.name))
            local = try RemoteLocalPathGuard.contain(hostPath: plan.localHostPath, roots: copyRoots(sessionId: caller.sessionId))
        } catch let error as RemoteCopyArgumentError {
            return failure("invalid_args", error.userMessage)
        } catch {
            return failure("invalid_args", RemoteToolCall.errorMessage(error))
        }

        let permission = await wiring.checkPermission(
            host: plan.host, sessionId: caller.bindingSessionId,
            summary: "minis-remote cp \(plan.direction == .upload ? local.guestPath : "\(plan.host):\(plan.remotePath)") \(plan.direction == .upload ? "\(plan.host):\(plan.remotePath)" : local.guestPath)")
        if case .denied(let message) = permission { return failure("permission_denied", message) }

        do {
            let remotePath = try await absoluteRemotePath(plan, wiring: wiring, bindingSessionId: caller.bindingSessionId, services: services)
            let localEndpoint = RemoteCopyEndpoint.local(local.hostPath)
            let remoteEndpoint = RemoteCopyEndpoint.remote(host: plan.host, path: remotePath)
            logger.info("minis-remote cp \(plan.direction) \(plan.host)")
            let upload = plan.direction == .upload
            let bytes = try await services.files.copy(
                from: upload ? localEndpoint : remoteEndpoint, to: upload ? remoteEndpoint : localEndpoint)
            let remoteText = "\(plan.host):\(plan.remotePath)"
            return [
                "copied": NSNumber(value: bytes),
                "from": upload ? local.guestPath : remoteText,
                "to": upload ? remoteText : local.guestPath,
            ] as NSDictionary
        } catch is CancellationError {
            return failure("cancelled", "Error: copy cancelled. The destination keeps its previous contents; the transfer replaces it only when complete.")
        } catch {
            return failure("copy_failed", RemoteToolCall.errorMessage(error))
        }
    }

    /// Memory, skills, shared and mcp-servers are global; the other buckets belong to the calling session.
    /// Folders mounted from outside the app are not listed, so they are refused until added here.
    static func copyRoots(sessionId: String) -> [RemoteCopyRoot] {
        let sessionBuckets = [
            AIChatViewModel.minisOffloadsLinuxDir, AIChatViewModel.minisAttachmentsLinuxDir,
            AIChatViewModel.minisWorkspaceLinuxDir, AIChatViewModel.minisBrowserLinuxDir,
        ].compactMap { guest in
            MinisFsRouter.shared.hostURL(forGuest: guest, sid: sessionId).map {
                RemoteCopyRoot(guestPrefix: guest, hostPath: $0.path)
            }
        }
        let globals = [
            (AIChatViewModel.minisMemoryLinuxDir, AIChatViewModel.minisMemoryPersistentDir),
            (AIChatViewModel.minisSkillsLinuxDir, AIChatViewModel.minisSkillsPersistentDir),
            (AIChatViewModel.minisSharedLinuxDir, AIChatViewModel.minisSharedPersistentDir),
            (AIChatViewModel.minisMcpServersLinuxDir, AIChatViewModel.minisMcpServersPersistentDir),
        ].map { RemoteCopyRoot(guestPrefix: $0.0, hostPath: $0.1.path) }
        return sessionBuckets + globals
    }

    @MainActor
    private static func absoluteRemotePath(
        _ plan: RemoteCopyPlan, wiring: RemoteAppWiring, bindingSessionId: String, services: RemoteServices
    ) async throws -> String {
        guard RemoteToolCall.needsHome(path: plan.remotePath) else { return plan.remotePath }
        let home = try await services.executor.homeDirectory(host: plan.host)
        let workdir = RemoteToolCall.workdir(host: plan.host, binding: wiring.binding(sessionId: bindingSessionId))
        return RemoteToolCall.absolutePath(plan.remotePath, workdir: workdir, home: home)
    }

    // MARK: - hosts

    @objc public static func hosts(fsContext: UInt64) -> NSDictionary {
        onMain {
            guard let caller = await caller(fsContext: fsContext) else { return failure("hosts_failed", unknownCaller) }
            return await hosts(bindingSessionId: caller.bindingSessionId, wiring: .shared)
        }
    }

    /// Only hosts the caller may already use are contacted: an unapproved host reports `reachable: null` and
    /// why, so listing never runs a command the user has not allowed.
    @MainActor
    static func hosts(bindingSessionId: String, wiring: RemoteAppWiring) async -> NSDictionary {
        let services: RemoteServices
        switch wiring.services {
        case .success(let ready): services = ready
        case .failure(let error): return failure("remote_unavailable", error.userMessage)
        }
        let manager = OffloadPermissionManager.shared
        let configured = services.store.hosts
        var probeable: [String] = []
        var withheld: [String: String] = [:]
        for host in configured {
            let key = RemoteAppWiring.permissionKey(host: host.name)
            RemoteAppWiring.defaultUnsetPermissionToAskOnce(host: host.name)
            switch manager.permissionLevel(for: key) {
            case .bypass:
                probeable.append(host.name)
            case .askOnce where manager.hasSessionGrant(for: key, sessionId: bindingSessionId):
                probeable.append(host.name)
            case .askOnce:
                withheld[host.name] = "ask"
            case .notAllowed:
                withheld[host.name] = "not_allowed"
            }
        }
        let pool = services.pool
        let reachable = await RemoteReachability.probe(hosts: probeable, budget: reachabilityBudget) { name in
            (try? await pool.exec(host: name, script: "true", timeout: .seconds(5)))?.exitStatus == 0
        }
        let entries: [NSDictionary] = configured.map { host in
            if let permission = withheld[host.name] {
                return ["name": host.name, "address": host.address, "reachable": NSNull(), "permission": permission] as NSDictionary
            }
            return ["name": host.name, "address": host.address, "reachable": reachable[host.name] ?? false] as NSDictionary
        }
        return ["hosts": entries] as NSDictionary
    }
}
