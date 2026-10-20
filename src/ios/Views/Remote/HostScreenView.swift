import MinisRemote
import SwiftUI
import WebKit

/// The host's screen (A3 spec §4.2). Opens view-only; Control lets the user click and type on the host, and
/// pauses the agent's screen tools until it is turned off again.
struct HostScreenView: View {
    @ObservedObject var session: HostScreenSession
    let onDone: () -> Void

    @State private var password = ""
    @State private var savePassword = true
    @State private var typedText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                HostScreenWebView(session: session).ignoresSafeArea(edges: .bottom)
                stateOverlay
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if session.userControlling {
                    Text(RemoteHostL10n.string("You are controlling \(session.host)"))
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.orange)
                        .foregroundStyle(.black)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.userControlling, session.state == .connected {
                    keyboardBar
                }
            }
            .navigationTitle(session.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Done")) { onDone() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker(RemoteHostL10n.string("Mode"), selection: $session.userControlling) {
                        Text(RemoteHostL10n.string("View")).tag(false)
                        Text(RemoteHostL10n.string("Control")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.state != .connected)
                }
            }
        }
        .task { try? await session.ensureConnected() }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch session.state {
        case .idle, .connecting:
            ProgressView(RemoteHostL10n.string("Connecting to \(session.host)…"))
                .tint(.white)
                .foregroundStyle(.white)
        case .needsPassword(let rejected):
            passwordCard(rejected: rejected)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).multilineTextAlignment(.center).textSelection(.enabled)
                Button(AppLocalized("Retry")) { Task { try? await session.ensureConnected() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        case .connected:
            EmptyView()
        }
    }

    private func passwordCard(rejected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteHostL10n.string("Screen Sharing on \(session.host) asks for the Mac password."))
            if rejected {
                Text(RemoteHostL10n.string("\(session.host) refused the password."))
                    .foregroundStyle(.red)
            }
            SecureField(RemoteHostL10n.string("Password"), text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            Toggle(RemoteHostL10n.string("Keep in the Keychain"), isOn: $savePassword)
            Button(RemoteHostL10n.string("Connect")) {
                session.submitPassword(password, save: savePassword)
                password = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)
        }
        .padding()
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    /// The page has no on-screen keyboard of its own, so typing goes through the same input path as the agent's.
    private var keyboardBar: some View {
        HStack(spacing: 8) {
            TextField(RemoteHostL10n.string("Type on \(session.host)"), text: $typedText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(sendTypedText)
            Button(RemoteHostL10n.string("Send"), action: sendTypedText)
                .disabled(typedText.isEmpty)
            keyButton("⏎", combo: "return")
            keyButton("⇥", combo: "tab")
            keyButton("esc", combo: "escape")
        }
        .padding(8)
        .background(.regularMaterial)
    }

    private func keyButton(_ label: String, combo: String) -> some View {
        Button(label) {
            guard let key = try? ScreenToolLogic.keyCombo(combo, index: 0) else { return }
            send([.key(key)])
        }
        .buttonStyle(.bordered)
    }

    private func sendTypedText() {
        guard !typedText.isEmpty else { return }
        send([.type(text: typedText)])
        typedText = ""
    }

    private func send(_ actions: [ScreenAction]) {
        Task { try? await session.send(ScreenInputPlan.events(for: actions)) }
    }
}

/// Hosts the session's web view while the viewer is open; the session keeps it alive offscreen otherwise.
private struct HostScreenWebView: UIViewRepresentable {
    let session: HostScreenSession

    func makeCoordinator() -> HostScreenSession { session }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let webView = session.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        container.addSubview(webView)
        session.viewerDidAppear()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: HostScreenSession) {
        coordinator.webView.removeFromSuperview()
        coordinator.viewerDidDisappear()
    }
}
