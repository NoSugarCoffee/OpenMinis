import Foundation
import MinisRemote
import UIKit

private let logger = AppLogger(category: "HostEvents")

/// Opens a `pico://host-event` link (B spec §9.1). It runs from the app root, so the link works on a cold
/// start and from any screen: the session is created first and opened through the same buffered navigation
/// a notification tap uses, then the event is fetched inside it, where A1's permission prompt can show.
@MainActor
enum HostEventOpener {
    static let sessionSource = "host-event"

    struct Dependencies {
        var isConfigured: (String) -> Bool
        var waitForModelConfig: () async -> Void
        var createSession: (_ title: String) async -> String
        var markReadOnly: (_ sessionId: String) -> Void
        var navigate: (_ sessionId: String) -> Void
        var checkPermission: (_ host: String, _ sessionId: String) async -> PermissionResult
        var fetch: (HostEventLink) async throws -> [HostEvent]
        var setTitle: (_ sessionId: String, _ title: String) -> Void
        var submit: (_ sessionId: String, _ prompt: String) -> ProgrammaticSubmitOutcome
        var ack: (_ host: String, _ ids: [String]) async throws -> Void
        var showError: (String) -> Void
        var makeNonce: () -> String
    }

    /// Links being opened right now. iOS hands one tap to both SwiftUI's `onOpenURL` and the scene
    /// delegate's `openURLContexts`, and each copy would otherwise create its own session and turn.
    private static var opening: Set<HostEventLink> = []

    static func open(_ url: URL) {
        guard let link = HostEventLinks.parse(url) else {
            logger.warning("[HostEvents] ignored malformed link \(url.absoluteString)")
            return
        }
        Task { await open(link, using: .live) }
    }

    static func open(_ link: HostEventLink, using deps: Dependencies) async {
        guard opening.insert(link).inserted else {
            logger.info("[HostEvents] ignored a second delivery of a link already opening")
            return
        }
        defer { opening.remove(link) }
        await run(link, using: deps)
    }

    private static func run(_ link: HostEventLink, using deps: Dependencies) async {
        let host = link.host
        guard deps.isConfigured(host) else {
            deps.showError(RemoteHostL10n.string("“\(host)” is not configured. Add it in Settings → Remote Hosts."))
            return
        }
        // On a cold start the provider config is still loading; a session made now would lose its model.
        await deps.waitForModelConfig()
        let sessionId = await deps.createSession(RemoteHostL10n.string("Read-only · event from \(host)"))
        // Before anything reaches the model: the first turn must already run with the read-only tool set.
        deps.markReadOnly(sessionId)
        deps.navigate(sessionId)

        if case .denied(let reason) = await deps.checkPermission(host, sessionId) {
            fail(sessionId: sessionId, host: host, message: reason, deps: deps)
            return
        }
        let events: [HostEvent]
        do {
            events = try await deps.fetch(link)
        } catch {
            fail(sessionId: sessionId, host: host, message: describe(error), deps: deps)
            return
        }
        guard !events.isEmpty else {
            fail(sessionId: sessionId, host: host, message: RemoteHostL10n.string("The batch on \(host) holds no events."), deps: deps)
            return
        }
        deps.setTitle(sessionId, HostEventPrompt.sessionTitle(events: events, host: host))
        let prompt = HostEventPrompt.text(host: host, events: events, nonce: deps.makeNonce())
        if case .rejected(let reason) = deps.submit(sessionId, prompt) {
            fail(sessionId: sessionId, host: host, message: reason, deps: deps)
            return
        }
        do {
            try await deps.ack(host, events.map(\.id))
        } catch {
            // The summary is already on screen; a failed ack only leaves the event unread on the host.
            logger.error("[HostEvents] ack on \(host) failed: \(error)")
        }
    }

    private static func fail(sessionId: String, host: String, message: String, deps: Dependencies) {
        deps.setTitle(sessionId, RemoteHostL10n.string("Read-only · could not load event from \(host)"))
        deps.showError(message)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let error as HostEventError: return error.userMessage
        case let error as RemoteHostError: return error.userMessage
        default: return String(describing: error)
        }
    }
}

extension HostEventOpener.Dependencies {
    @MainActor
    static var live: Self {
        Self(
            isConfigured: { host in
                guard case .success(let services) = RemoteAppWiring.shared.services else { return false }
                return services.store.hosts.contains { $0.name == host }
            },
            waitForModelConfig: { await ProviderConfigStore.shared.waitForAuthoritativeConfig() },
            createSession: { title in
                let vm = ViewModelCache.shared.createDraft()
                vm.sessionSource = HostEventOpener.sessionSource
                let sessionId = await vm.ensureSessionReturningId()
                await ChatStore.shared.updateSessionTitle(sessionId, title: title)
                return sessionId
            },
            markReadOnly: { SessionToolPolicy.shared.markReadOnly(sessionId: $0) },
            navigate: { sessionId in
                NotificationNavigationStore.shared.setPending(sessionId)
                NotificationCenter.default.post(name: .openSessionFromIntent, object: nil, userInfo: ["sessionId": sessionId])
            },
            checkPermission: { host, sessionId in
                await RemoteAppWiring.shared.checkPermission(
                    host: host, sessionId: sessionId, summary: "Read a notification event from \(host)")
            },
            fetch: { link in
                guard case .success(let services) = RemoteAppWiring.shared.services else {
                    throw HostEventError.unexpectedExit(host: link.host, status: -1, stderr: "remote host list unreadable")
                }
                let client = HostEventClient(runner: services.executor)
                switch link {
                case .event(let host, let id): return [try await client.event(host: host, id: id)]
                case .batch(let host, let id): return try await client.batch(host: host, id: id).events
                }
            },
            setTitle: { sessionId, title in
                Task { await ChatStore.shared.updateSessionTitle(sessionId, title: title) }
            },
            submit: { sessionId, prompt in
                let (vm, _) = ViewModelCache.shared.getOrCreate(for: sessionId)
                return vm.submitProgrammaticPrompt(prompt, origin: .hostEvent, silent: true)
            },
            ack: { host, ids in
                guard case .success(let services) = RemoteAppWiring.shared.services else { return }
                _ = try await HostEventClient(runner: services.executor).ack(host: host, ids: ids)
            },
            showError: { message in
                guard let top = topViewController() else {
                    logger.error("[HostEvents] no window to show: \(message)")
                    return
                }
                let alert = UIAlertController(
                    title: RemoteHostL10n.string("Could not open the event"), message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: AppLocalized("OK"), style: .default))
                top.present(alert, animated: true)
            },
            makeNonce: HostEventPrompt.makeNonce)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
