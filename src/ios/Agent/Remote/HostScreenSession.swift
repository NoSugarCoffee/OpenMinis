import Foundation
import MinisRemote
import NIOPosix
import UIKit
import WebKit

private let logger = AppLogger(category: "HostScreen")

enum HostScreenError: Error, Equatable {
    case notConfigured(host: String)
    case passwordNeeded(host: String)
    case disconnected(host: String)
    case tunnel(ScreenTunnelError)
    case failed(host: String, detail: String)

    var userMessage: String {
        switch self {
        case .notConfigured(let host):
            return RemoteHostError.notConfigured(host: host).userMessage
        case .passwordNeeded(let host):
            return "The screen of \(host) needs its login. Open Settings → Remote Hosts → \(host) → Screen in Minis once and enter the Mac password; Minis keeps it in the Keychain."
        case .disconnected(let host):
            return "The screen connection to \(host) closed. Try again."
        case .tunnel(let error):
            return error.userMessage
        case .failed(let host, let detail):
            return "Could not open the screen of \(host): \(detail)"
        }
    }
}

/// One noVNC connection to a host's screen, shared by the viewer and the agent's screen tools so the app
/// knows who has control (A3 spec §4.3, D19).
@MainActor
final class HostScreenSession: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        /// `rejected` is true after the host refused a password.
        case needsPassword(rejected: Bool)
        case connected
        case failed(String)
    }

    /// Screen Sharing on macOS; a per-host port is A3 spec §3.2's later setting.
    static let vncPort = 5900
    /// noVNC's 0–9 scales; low quality keeps cellular usable (spike S3 tunes these).
    static let qualityLevel = 6
    static let compressionLevel = 2
    static let captureJPEGQuality = 0.8
    static let idleTimeout: Duration = .seconds(120)

    let host: String
    @Published private(set) var state: State = .idle
    /// The user's Control toggle in the viewer; while on, the agent's screen tools are paused.
    @Published var userControlling = false {
        didSet { applyViewOnly() }
    }

    let webView: WKWebView
    private let wiring: RemoteAppWiring
    private var bridge: ScreenBridge?
    private var pageReady = false
    private var pageReadyWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    private var awaitingCredentials = false
    private var credentialTypes: [String] = []
    private var triedSavedPassword = false
    private var pendingPassword: (value: String, save: Bool)?
    private var viewerVisible = false
    private var idleTask: Task<Void, Never>?

    init(host: String, wiring: RemoteAppWiring) {
        self.host = host
        self.wiring = wiring
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(HostScreenPageHandler(), forURLScheme: HostScreenPageHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(target: self), name: "minisScreen")
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil)
    }

    // MARK: Connection

    /// Returns once the screen is connected. A login the Keychain cannot answer throws `passwordNeeded`, so a
    /// tool call never waits on the user; the viewer shows the prompt from `state` instead.
    func ensureConnected() async throws {
        scheduleIdleClose()
        switch state {
        case .connected:
            return
        case .needsPassword:
            throw HostScreenError.passwordNeeded(host: host)
        case .connecting:
            try await waitForConnect()
        case .idle, .failed:
            try await connect()
        }
    }

    func submitPassword(_ password: String, save: Bool) {
        pendingPassword = (password, save)
        if awaitingCredentials {
            sendCredentials(password: password)
        } else {
            Task { try? await connect() }
        }
    }

    func close() {
        idleTask?.cancel()
        idleTask = nil
        userControlling = false
        awaitingCredentials = false
        Task { try? await webView.callAsyncJavaScript("minisScreen.disconnect()", contentWorld: .page) }
        stopBridge()
        if state != .idle { state = .idle }
        failConnectWaiters(HostScreenError.disconnected(host: host))
    }

    private func connect() async throws {
        state = .connecting
        triedSavedPassword = false
        do {
            let services = try readyServices()
            let started = try await ScreenBridge.start(
                host: host, port: Self.vncPort, opener: services.pool, group: MultiThreadedEventLoopGroup.singleton)
            stopBridge()
            bridge = started
            await loadPageIfNeeded()
            attachOffscreenIfNeeded()
            _ = try await webView.callAsyncJavaScript(
                "minisScreen.connect(url, quality, compression)",
                arguments: [
                    "url": started.url.absoluteString, "quality": Self.qualityLevel,
                    "compression": Self.compressionLevel,
                ],
                contentWorld: .page)
        } catch {
            let screenError = Self.screenError(error, host: host)
            state = .failed(screenError.userMessage)
            stopBridge()
            throw screenError
        }
        try await waitForConnect()
    }

    private func waitForConnect() async throws {
        try await withCheckedThrowingContinuation { connectWaiters.append($0) }
    }

    private func readyServices() throws -> RemoteServices {
        switch wiring.services {
        case .success(let services):
            guard services.store.hosts.contains(where: { $0.name == host }) else {
                throw HostScreenError.notConfigured(host: host)
            }
            return services
        case .failure(let error):
            throw HostScreenError.failed(host: host, detail: error.userMessage)
        }
    }

    private static func screenError(_ error: Error, host: String) -> HostScreenError {
        switch error {
        case let screen as HostScreenError: return screen
        case let tunnel as ScreenTunnelError: return .tunnel(tunnel)
        case let hostError as RemoteHostError: return .failed(host: host, detail: hostError.userMessage)
        default: return .failed(host: host, detail: String(describing: error))
        }
    }

    private func stopBridge() {
        guard let bridge else { return }
        self.bridge = nil
        Task { await bridge.stop() }
    }

    private func loadPageIfNeeded() async {
        guard !pageReady else { return }
        if webView.url == nil, let url = URL(string: "\(HostScreenPageHandler.scheme)://app/host-screen.html") {
            webView.load(URLRequest(url: url))
        }
        await withCheckedContinuation { pageReadyWaiters.append($0) }
    }

    // MARK: Credentials (D20)

    private var passwordAccount: String { "screen-password.\(host)" }

    private func savedPassword() -> String? {
        guard case .success(let services) = wiring.services,
              let data = try? services.secrets.get(account: passwordAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func savePassword(_ password: String) {
        guard case .success(let services) = wiring.services else { return }
        do {
            try services.secrets.set(Data(password.utf8), account: passwordAccount)
        } catch {
            logger.error("Saving the screen password of \(host) failed: \(error)")
        }
    }

    private func forgetSavedPassword() {
        guard case .success(let services) = wiring.services else { return }
        do {
            try services.secrets.delete(account: passwordAccount)
        } catch {
            logger.error("Clearing the screen password of \(host) failed: \(error)")
        }
    }

    private func handleCredentialsRequired(types: [String]) {
        awaitingCredentials = true
        credentialTypes = types
        if let pendingPassword {
            sendCredentials(password: pendingPassword.value)
        } else if !triedSavedPassword, let saved = savedPassword() {
            triedSavedPassword = true
            sendCredentials(password: saved)
        } else {
            state = .needsPassword(rejected: false)
            failConnectWaiters(HostScreenError.passwordNeeded(host: host))
        }
    }

    /// Screen Sharing's Mac-account login (type 30) asks for a user name; the SSH user is the same account.
    private func sendCredentials(password: String) {
        awaitingCredentials = false
        let username: String? = credentialTypes.contains("username") ? sshUser() : nil
        Task {
            do {
                _ = try await webView.callAsyncJavaScript(
                    "minisScreen.sendCredentials(username, password)",
                    arguments: ["username": username ?? NSNull(), "password": password], contentWorld: .page)
            } catch {
                logger.error("Sending screen credentials to \(host) failed: \(error)")
            }
        }
    }

    private func sshUser() -> String? {
        guard case .success(let services) = wiring.services else { return nil }
        return services.store.hosts.first { $0.name == host }?.user
    }

    // MARK: Page events

    fileprivate func handlePageMessage(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            pageReadyWaiters.forEach { $0.resume() }
            pageReadyWaiters = []
        case "connect":
            if let pendingPassword, pendingPassword.save { savePassword(pendingPassword.value) }
            pendingPassword = nil
            state = .connected
            applyViewOnly()
            connectWaiters.forEach { $0.resume() }
            connectWaiters = []
        case "credentialsrequired":
            handleCredentialsRequired(types: message["types"] as? [String] ?? [])
        case "securityfailure":
            if pendingPassword == nil, triedSavedPassword { forgetSavedPassword() }
            pendingPassword = nil
            awaitingCredentials = false
            state = .needsPassword(rejected: true)
            stopBridge()
            failConnectWaiters(HostScreenError.passwordNeeded(host: host))
        case "disconnect":
            awaitingCredentials = false
            userControlling = false
            if state == .connected || state == .connecting {
                state = .failed(HostScreenError.disconnected(host: host).userMessage)
            }
            stopBridge()
            failConnectWaiters(HostScreenError.disconnected(host: host))
        default:
            logger.error("Unknown screen page message \(type)")
        }
    }

    private func failConnectWaiters(_ error: HostScreenError) {
        connectWaiters.forEach { $0.resume(throwing: error) }
        connectWaiters = []
    }

    private func applyViewOnly() {
        guard state == .connected else { return }
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "minisScreen.setViewOnly(viewOnly)", arguments: ["viewOnly": !userControlling], contentWorld: .page)
        }
    }

    // MARK: Agent tools

    func capture() async throws -> (jpeg: Data, scale: ScreenScale) {
        try await ensureConnected()
        let scale = ScreenScale(framebuffer: try await framebufferSize())
        let reply = try await webView.callAsyncJavaScript(
            "return await minisScreen.capture(width, height, quality)",
            arguments: [
                "width": scale.capture.width, "height": scale.capture.height, "quality": Self.captureJPEGQuality,
            ],
            contentWorld: .page)
        guard let object = reply as? [String: Any], let base64 = object["jpeg"] as? String,
              let jpeg = Data(base64Encoded: base64) else {
            throw HostScreenError.failed(host: host, detail: "the page returned no image")
        }
        return (jpeg, scale)
    }

    func framebufferSize() async throws -> ScreenSize {
        try await ensureConnected()
        let reply = try await webView.callAsyncJavaScript(
            "return minisScreen.framebufferSize()", contentWorld: .page)
        guard let object = reply as? [String: Any], let width = object["width"] as? Int,
              let height = object["height"] as? Int, width > 0, height > 0 else {
            throw HostScreenError.failed(host: host, detail: "the screen size is not known yet")
        }
        return ScreenSize(width: width, height: height)
    }

    func send(_ events: [RFBInputEvent]) async throws {
        try await ensureConnected()
        let payload: [[String: Any]] = events.map { event in
            switch event {
            case .pointer(let x, let y, let mask):
                return ["kind": "pointer", "x": x, "y": y, "mask": Int(mask)]
            case .key(let keysym, let down):
                return ["kind": "key", "keysym": Int(keysym), "down": down]
            }
        }
        _ = try await webView.callAsyncJavaScript(
            "minisScreen.input(events)", arguments: ["events": payload], contentWorld: .page)
    }

    // MARK: Lifecycle

    /// A WKWebView outside a window stops running JavaScript, so without the viewer it waits in the key
    /// window at 1×1 (spike S4).
    func attachOffscreenIfNeeded() {
        guard !viewerVisible, webView.window == nil, let window = Self.keyWindow() else { return }
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        window.addSubview(webView)
    }

    func viewerDidAppear() {
        viewerVisible = true
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
    }

    func viewerDidDisappear() {
        viewerVisible = false
        userControlling = false
        attachOffscreenIfNeeded()
        scheduleIdleClose()
    }

    private func scheduleIdleClose() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self, !self.viewerVisible else { return }
            self.close()
        }
    }

    @objc private func appDidEnterBackground() {
        close()
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

/// One session per host for the app's lifetime.
@MainActor
final class HostScreenSessions {
    static let shared = HostScreenSessions()

    private var sessions: [String: HostScreenSession] = [:]

    func session(host: String) -> HostScreenSession {
        if let existing = sessions[host] { return existing }
        let created = HostScreenSession(host: host, wiring: RemoteAppWiring.shared)
        sessions[host] = created
        return created
    }

    func existingSession(host: String) -> HostScreenSession? {
        sessions[host]
    }
}

/// WKUserContentController keeps its handlers alive, which would keep the session alive with it.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: HostScreenSession?

    init(target: HostScreenSession) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.handlePageMessage(body) }
    }
}

/// Serves the viewer page from the app bundle. A custom scheme, not file://, because WebKit refuses ES module
/// imports from file URLs.
final class HostScreenPageHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "minis-screen"

    private static let files: [String: String] = [
        "host-screen.html": "text/html",
        "host-screen.js": "text/javascript",
        "novnc-rfb.js": "text/javascript",
    ]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let name = url.lastPathComponent
        guard let mime = Self.files[name],
              let fileURL = Bundle.main.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
