import MinisRemote
import SwiftUI
import UniformTypeIdentifiers

/// The Settings row, kept here so ContentView only gains one line.
struct RemoteHostsSettingsLink: View {
    var body: some View {
        NavigationLink {
            RemoteHostsSettingsView()
        } label: {
            Label {
                Text(RemoteHostL10n.string("Remote Hosts"))
            } icon: {
                Image(systemName: "server.rack")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(.teal, in: Circle())
            }
        }
    }
}

struct RemoteHostsSettingsView: View {
    @ObservedObject private var wiring = RemoteAppWiring.shared

    var body: some View {
        switch wiring.services {
        case .success(let services):
            RemoteHostListView(services: services, store: services.store)
        case .failure(let error):
            UnreadableRemoteHostsView(error: error, wiring: wiring)
        }
    }
}

// MARK: - Unreadable settings file

private struct UnreadableRemoteHostsView: View {
    let error: RemoteWiringError
    let wiring: RemoteAppWiring
    @State private var confirmReset = false
    @State private var resetFailure: String?

    var body: some View {
        List {
            Section {
                Label {
                    Text(RemoteHostL10n.string("The remote host list could not be read, so shell and file tools are blocked until it is fixed. Reset keeps the unreadable file as a backup and starts with no hosts; keys stay in the Keychain but hosts must be added again."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if case .storeUnreadable(let path, let detail) = error {
                    LabeledContent(AppLocalized("File"), value: path)
                        .font(.caption)
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                Button(RemoteHostL10n.string("Reset Remote Hosts"), role: .destructive) { confirmReset = true }
            } footer: {
                if let resetFailure {
                    Text(resetFailure).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(RemoteHostL10n.string("Remote Hosts"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            RemoteHostL10n.string("Reset the remote host list?"), isPresented: $confirmReset, titleVisibility: .visible
        ) {
            Button(AppLocalized("Reset"), role: .destructive) {
                do {
                    _ = try wiring.resetUnreadableStore()
                } catch {
                    resetFailure = RemoteHostL10n.string("Reset failed: \(String(describing: error))")
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Host list

private struct RemoteHostListView: View {
    let services: RemoteServices
    @ObservedObject var store: RemoteHostStore
    @State private var addHost: AddHostSheet?

    private enum AddHostSheet: String, Identifiable {
        case pair
        case manual

        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                ForEach(store.hosts, id: \.name) { host in
                    NavigationLink {
                        RemoteHostDetailView(services: services, store: store, hostName: host.name)
                    } label: {
                        RemoteHostRowLabel(host: host)
                    }
                }
                Button {
                    addHost = .pair
                } label: {
                    Label(RemoteHostL10n.string("Add Host"), systemImage: "plus")
                }
            } footer: {
                Text(RemoteHostL10n.string("A chat bound to a host runs its shell and file tools there over SSH, for example a Mac or a Linux machine on your Tailscale network."))
            }

            if !store.hosts.isEmpty {
                Section {
                    ForEach(store.hosts, id: \.name) { host in
                        RemoteHostPermissionRow(hostName: host.name)
                    }
                } header: {
                    Text(AppLocalized("Permissions"))
                } footer: {
                    Text(RemoteHostL10n.string("Ask Once asks the first time a chat uses the host. Bypass runs without asking. Not Allowed blocks every call to the host."))
                }
            }
        }
        .navigationTitle(RemoteHostL10n.string("Remote Hosts"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $addHost) { sheet in
            switch sheet {
            case .pair:
                RemoteHostPairView(services: services, onManualEntry: { addHost = .manual })
            case .manual:
                RemoteHostEditorView(mode: .add, services: services)
            }
        }
    }
}

private struct RemoteHostRowLabel: View {
    let host: RemoteHostConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(host.name)
                if host.pinnedHostKey == nil {
                    Text(RemoteHostL10n.string("Not trusted"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Text(RemoteHostRowLabel.endpoint(host))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func endpoint(_ host: RemoteHostConfig) -> String {
        host.port == 22 ? "\(host.user)@\(host.address)" : "\(host.user)@\(host.address):\(host.port)"
    }
}

/// Mirrors CommandPermissionRow in OffloadPermissionSettingsView (private there) for a `remote-host:<name>` key.
private struct RemoteHostPermissionRow: View {
    let hostName: String
    @State private var level: OffloadPermissionLevel

    init(hostName: String) {
        self.hostName = hostName
        RemoteAppWiring.defaultUnsetPermissionToAskOnce(host: hostName)
        _level = State(initialValue: OffloadPermissionManager.shared.permissionLevel(
            for: RemoteAppWiring.permissionKey(host: hostName)))
    }

    var body: some View {
        Picker(hostName, selection: $level) {
            ForEach(OffloadPermissionLevel.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.menu)
        .onChange(of: level) { newValue in
            OffloadPermissionManager.shared.setPermissionLevel(newValue, for: RemoteAppWiring.permissionKey(host: hostName))
        }
    }
}

// MARK: - Host detail

private struct RemoteHostDetailView: View {
    let services: RemoteServices
    @ObservedObject var store: RemoteHostStore
    let hostName: String

    @Environment(\.dismiss) private var dismiss
    @State private var publicKey: Result<String, RemoteHostSetupFailure>?
    @State private var checkOutcome: RemoteHostCheckOutcome?
    @State private var isChecking = false
    @State private var trustPrompt: RemoteHostKeyPrompt?
    @State private var showEditor = false
    @State private var showReplaceKey = false
    @State private var confirmRemove = false
    @State private var actionFailure: String?
    @State private var copiedNotice: String?
    @State private var showScreen = false

    private var host: RemoteHostConfig? {
        store.hosts.first { $0.name == hostName }
    }

    var body: some View {
        List {
            if let host {
                connectionSection(host)
                publicKeySection(host)
                hostKeySection(host)
                checksSection(host)
                Section {
                    NavigationLink(RemoteHostL10n.string("Notifications")) {
                        HostNotificationsView(services: services, hostName: hostName)
                    }
                } footer: {
                    Text(RemoteHostL10n.string("Push notifications for mail and GitHub, sent by minis-hostd running on the host."))
                }
                Section {
                    Button(RemoteHostL10n.string("Screen")) { showScreen = true }
                } footer: {
                    Text(RemoteHostL10n.string("See and control the host's screen over this SSH connection. On a Mac, turn on Screen Sharing; on Linux, run a VNC server on 127.0.0.1:5900."))
                }
                Section {
                    Button(RemoteHostL10n.string("Remove Host"), role: .destructive) { confirmRemove = true }
                }
            } else {
                Text(RemoteHostL10n.string("This host was removed."))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(hostName)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScreen) {
            HostScreenView(session: HostScreenSessions.shared.session(host: hostName), onDone: { showScreen = false })
        }
        .task(id: host?.keyRef) { loadPublicKey() }
        .onChange(of: host.map { "\($0.address):\($0.port)" }) { _ in
            // Results and a pending host key belong to the endpoint they came from.
            checkOutcome = nil
            trustPrompt = nil
        }
        .sheet(isPresented: $showEditor) {
            if let host {
                RemoteHostEditorView(mode: .edit(host), services: services)
            }
        }
        .sheet(isPresented: $showReplaceKey, onDismiss: loadPublicKey) {
            if let host {
                RemoteKeyReplaceView(host: host, services: services)
            }
        }
        .sheet(item: $trustPrompt) { prompt in
            RemoteHostTrustSheet(prompt: prompt, onTrust: {
                trustPrompt = nil
                Task {
                    do {
                        try await RemoteHostSetup.trust(prompt, services: services)
                        await runChecks()
                    } catch {
                        actionFailure = RemoteHostSetup.message(for: error)
                    }
                }
            }, onCancel: { trustPrompt = nil })
        }
        .confirmationDialog(
            RemoteHostL10n.string("Remove “\(hostName)”?"), isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button(RemoteHostL10n.string("Remove Host"), role: .destructive) {
                Task {
                    do {
                        try await RemoteHostSetup.removeHost(name: hostName, services: services)
                        dismiss()
                    } catch {
                        actionFailure = RemoteHostSetup.message(for: error)
                    }
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(RemoteHostL10n.string("Chats bound to this host go back to running tools on this iPhone, and its private key is deleted from the Keychain."))
        }
        .alert(
            RemoteHostL10n.string("Something went wrong"),
            isPresented: Binding(get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } })
        ) {
            Button(AppLocalized("OK"), role: .cancel) {}
        } message: {
            Text(actionFailure ?? "")
        }
    }

    private func connectionSection(_ host: RemoteHostConfig) -> some View {
        Section {
            LabeledContent(RemoteHostL10n.string("Address"), value: host.address)
            LabeledContent(RemoteHostL10n.string("Port"), value: String(host.port))
            LabeledContent(RemoteHostL10n.string("User"), value: host.user)
            if let os = host.os {
                LabeledContent(RemoteHostL10n.string("Operating system"), value: os)
            }
            Button(AppLocalized("Edit")) { showEditor = true }
        } header: {
            Text(AppLocalized("Connection"))
        }
    }

    private func publicKeySection(_ host: RemoteHostConfig) -> some View {
        Section {
            switch publicKey {
            case .success(let line):
                Text(line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button(RemoteHostL10n.string("Copy Public Key")) { copy(line, notice: RemoteHostL10n.string("Public key copied")) }
                Button(RemoteHostL10n.string("Copy Install Command")) {
                    copy(RemoteHostSetup.authorizedKeysCommand(publicKeyLine: line),
                         notice: RemoteHostL10n.string("Install command copied"))
                }
            case .failure(let failure):
                Text(failure.message).foregroundStyle(.red)
            case nil:
                ProgressView()
            }
            Button(RemoteHostL10n.string("Replace Key…")) { showReplaceKey = true }
        } header: {
            Text(RemoteHostL10n.string("Public Key"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(RemoteHostL10n.string("Add this key to ~/.ssh/authorized_keys on the host, for example by running the copied install command there. The private key stays in this device's Keychain and is not synced."))
                if let copiedNotice {
                    Text(copiedNotice).foregroundStyle(.green)
                }
            }
        }
    }

    private func hostKeySection(_ host: RemoteHostConfig) -> some View {
        Section {
            if let pinned = host.pinnedHostKey {
                Text(Self.fingerprintText(pinned))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                Text(RemoteHostL10n.string("Not trusted yet. Test the connection to see the host's fingerprint and trust it."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(RemoteHostL10n.string("Host Key"))
        }
    }

    private func checksSection(_ host: RemoteHostConfig) -> some View {
        Section {
            Button {
                Task { await runChecks() }
            } label: {
                HStack {
                    Text(AppLocalized("Test Connection"))
                    if isChecking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isChecking)
            switch checkOutcome {
            case .checked(let results):
                ForEach(results, id: \.check) { result in
                    RemoteHostCheckRow(result: result)
                }
            case .failed(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case .untrusted(let prompt):
                Button(RemoteHostL10n.string("Review Host Key…")) { trustPrompt = prompt }
            case nil:
                EmptyView()
            }
        } header: {
            Text(RemoteHostL10n.string("Checks"))
        } footer: {
            Text(RemoteHostL10n.string("Connects, then checks the OS, the login shell, that git is on the login shell's PATH, and that ~/.minis is writable."))
        }
    }

    private func runChecks() async {
        isChecking = true
        defer { isChecking = false }
        let outcome = await RemoteHostSetup.runChecks(host: hostName, services: services)
        checkOutcome = outcome
        if case .untrusted(let prompt) = outcome {
            trustPrompt = prompt
        }
    }

    private func loadPublicKey() {
        guard let host else { return }
        do {
            publicKey = .success(try RemoteHostSetup.publicKeyLine(host: host, services: services))
        } catch {
            publicKey = .failure(RemoteHostSetupFailure(message: RemoteHostSetup.message(for: error)))
        }
    }

    private func copy(_ text: String, notice: String) {
        UIPasteboard.general.string = text
        copiedNotice = notice
    }

    private static func fingerprintText(_ pinnedKey: String) -> String {
        do {
            return try HostKeyFingerprint.sha256(openSSHPublicKey: pinnedKey)
        } catch {
            return String(describing: error)
        }
    }
}

struct RemoteHostCheckRow: View {
    let result: RemoteHostChecks.Result

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(RemoteHostSetup.checkLabel(result.check))
                Text(RemoteHostSetup.checkDetail(result.finding))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(result.ok ? .green : .red)
        }
    }
}

// MARK: - Add / edit

private struct RemoteHostEditorView: View {
    enum Mode {
        case add
        case edit(RemoteHostConfig)
    }

    let mode: Mode
    let services: RemoteServices

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var port: String
    @State private var user: String
    @State private var key = RemoteKeyInput()
    @State private var failure: String?
    @State private var isSaving = false

    init(mode: Mode, services: RemoteServices) {
        self.mode = mode
        self.services = services
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _address = State(initialValue: "")
            _port = State(initialValue: "22")
            _user = State(initialValue: "")
        case .edit(let host):
            _name = State(initialValue: host.name)
            _address = State(initialValue: host.address)
            _port = State(initialValue: String(host.port))
            _user = State(initialValue: host.user)
        }
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(RemoteHostL10n.string("Name, for example mini"), text: $name)
                        .disabled(!isAdding)
                    TextField(RemoteHostL10n.string("Address, for example mini or 100.64.0.2"), text: $address)
                        .keyboardType(.URL)
                    TextField(RemoteHostL10n.string("Port"), text: $port)
                        .keyboardType(.numberPad)
                    TextField(RemoteHostL10n.string("User"), text: $user)
                } header: {
                    Text(RemoteHostL10n.string("Host"))
                } footer: {
                    if isAdding {
                        Text(RemoteHostL10n.string("The name is how the agent and the chat refer to the host: 1–32 letters, digits, “-” or “_”. It cannot be changed later."))
                    } else {
                        Text(RemoteHostL10n.string("Changing the address or port clears the trusted host key, so the next connection asks you to trust it again."))
                    }
                }
                if isAdding {
                    RemoteKeyInputSections(input: $key)
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(isAdding ? RemoteHostL10n.string("Add Host") : RemoteHostL10n.string("Edit Host"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Save")) { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func save() async {
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else {
            failure = RemoteHostL10n.string("The port must be a number, usually 22.")
            return
        }
        isSaving = true
        defer { isSaving = false }
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        do {
            switch mode {
            case .add:
                try RemoteHostSetup.addHost(
                    name: name.trimmingCharacters(in: .whitespaces), address: trimmedAddress, port: portNumber,
                    user: trimmedUser, key: try key.source(), services: services)
            case .edit(let host):
                try await RemoteHostSetup.updateHost(
                    name: host.name, address: trimmedAddress, port: portNumber, user: trimmedUser, services: services)
            }
            dismiss()
        } catch {
            failure = RemoteHostSetup.message(for: error)
        }
    }
}

private struct RemoteKeyReplaceView: View {
    let host: RemoteHostConfig
    let services: RemoteServices

    @Environment(\.dismiss) private var dismiss
    @State private var key = RemoteKeyInput()
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                RemoteKeyInputSections(input: $key)
                Section {
                    Text(RemoteHostL10n.string("The host rejects this device until the new public key is in its ~/.ssh/authorized_keys."))
                        .foregroundStyle(.secondary)
                    if let failure {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(RemoteHostL10n.string("Replace Key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Replace")) {
                        Task {
                            do {
                                try await RemoteHostSetup.replaceKey(host: host, with: try key.source(), services: services)
                                dismiss()
                            } catch {
                                failure = RemoteHostSetup.message(for: error)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Key input

private struct RemoteKeyInput {
    enum Choice: Hashable {
        case generate
        case importExisting
    }

    struct LoadedFile {
        let name: String
        let contents: String
    }

    var choice: Choice = .generate
    var pem = ""
    /// A chosen file's key text, kept out of the visible editor.
    var loadedFile: LoadedFile?
    var passphrase = ""

    func source() throws -> RemoteKeySource {
        switch choice {
        case .generate:
            return .generate
        case .importExisting:
            let trimmed = (loadedFile?.contents ?? pem).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw RemoteHostSetupFailure(message: RemoteHostL10n.string("Paste or choose an OpenSSH Ed25519 private key to import."))
            }
            return .importOpenSSH(pem: trimmed + "\n", passphrase: passphrase.isEmpty ? nil : passphrase)
        }
    }
}

private struct RemoteKeyInputSections: View {
    @Binding var input: RemoteKeyInput
    @State private var showFileImporter = false
    @State private var fileFailure: String?

    var body: some View {
        Section {
            Picker(RemoteHostL10n.string("Key"), selection: $input.choice) {
                Text(RemoteHostL10n.string("Generate New Key")).tag(RemoteKeyInput.Choice.generate)
                Text(RemoteHostL10n.string("Import Private Key")).tag(RemoteKeyInput.Choice.importExisting)
            }
            .pickerStyle(.segmented)
        } header: {
            Text(RemoteHostL10n.string("SSH Key"))
        } footer: {
            if input.choice == .generate {
                Text(RemoteHostL10n.string("Creates an Ed25519 key that never leaves this device. Its public key is shown after saving, ready to add to the host."))
            }
        }
        if input.choice == .importExisting {
            Section {
                if let loadedFile = input.loadedFile {
                    HStack {
                        Label(RemoteHostL10n.string("Loaded \(loadedFile.name)"), systemImage: "doc.badge.lock")
                        Spacer()
                        Button(AppLocalized("Clear")) { input.loadedFile = nil }
                    }
                } else {
                    TextEditor(text: $input.pem)
                        .font(.caption.monospaced())
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(AppLocalized("Choose File…")) { showFileImporter = true }
                }
                SecureField(RemoteHostL10n.string("Passphrase (if the key has one)"), text: $input.passphrase)
                if let fileFailure {
                    Text(fileFailure).foregroundStyle(.red)
                }
            } footer: {
                Text(RemoteHostL10n.string("Paste an OpenSSH Ed25519 private key (BEGIN OPENSSH PRIVATE KEY). A passphrase-protected key from a current ssh-keygen uses 24 bcrypt rounds, more than Minis can read (17 at most): re-encrypt a copy with fewer rounds first, using ssh-keygen -p -a 16 -f <copy of the key>."))
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data, .text]) { result in
                switch result {
                case .success(let url):
                    readKeyFile(url)
                case .failure(let error):
                    fileFailure = String(describing: error)
                }
            }
        }
    }

    private func readKeyFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            input.loadedFile = RemoteKeyInput.LoadedFile(
                name: url.lastPathComponent, contents: try String(contentsOf: url, encoding: .utf8))
            input.pem = ""
            fileFailure = nil
        } catch {
            fileFailure = RemoteHostL10n.string("Could not read the file as text: \(String(describing: error))")
        }
    }
}
