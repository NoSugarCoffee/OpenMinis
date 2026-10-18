import MinisRemote
import SwiftUI

/// Binds a chat to a host and a working directory (spec §7 step 4). The binding is keyed by the chat's own id;
/// sub-agents follow their parent's binding on their own.
struct SessionRemoteHostView: View {
    let sessionId: String?
    let ensureSessionId: () async -> String
    @ObservedObject private var wiring = RemoteAppWiring.shared
    @Environment(\.dismiss) private var dismiss

    /// The chat menu row: the bound host's name, or a generic title when the chat runs tools locally. A chat
    /// opened from a host event shows its read-only state here, the one chat-level entry the fork owns.
    @MainActor
    static func menuTitle(sessionId: String?) -> String {
        if SessionToolPolicy.shared.isReadOnly(sessionId: sessionId) {
            return RemoteHostL10n.string("Read-only Event")
        }
        return RemoteAppWiring.shared.binding(sessionId: sessionId)?.hostName ?? RemoteHostL10n.string("Remote Host")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let sessionId, SessionToolPolicy.shared.isReadOnly(sessionId: sessionId) {
                    ReadOnlyEventSection(sessionId: sessionId, onDone: { dismiss() })
                } else {
                    switch wiring.services {
                    case .success(let services):
                        SessionHostList(
                            services: services, store: services.store, sessionId: sessionId,
                            ensureSessionId: ensureSessionId, onDone: { dismiss() })
                    case .failure:
                        List {
                            Text(RemoteHostL10n.string("The remote host list could not be read, so shell and file tools are blocked. Open Settings → Remote Hosts to reset it."))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle(RemoteHostL10n.string("Run Tools On"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Done")) { dismiss() }
                }
            }
        }
    }
}

private struct SessionHostList: View {
    let services: RemoteServices
    @ObservedObject var store: RemoteHostStore
    let sessionId: String?
    let ensureSessionId: () async -> String
    let onDone: () -> Void

    @State private var resolvedSessionId: String?
    @State private var failure: String?

    init(
        services: RemoteServices, store: RemoteHostStore, sessionId: String?,
        ensureSessionId: @escaping () async -> String, onDone: @escaping () -> Void
    ) {
        self.services = services
        self.store = store
        self.sessionId = sessionId
        self.ensureSessionId = ensureSessionId
        self.onDone = onDone
        _resolvedSessionId = State(initialValue: sessionId)
    }

    private var binding: SessionHostBindingValue? {
        resolvedSessionId.flatMap { store.binding(sessionId: $0) }
    }

    var body: some View {
        List {
            Section {
                Button {
                    setBinding(nil)
                } label: {
                    selectableRow(title: RemoteHostL10n.string("This iPhone"), subtitle: nil, selected: binding == nil)
                }
                .foregroundStyle(.primary)
                ForEach(store.hosts, id: \.name) { host in
                    NavigationLink {
                        RemoteDirectoryPicker(
                            services: services, store: store, hostName: host.name,
                            startPath: binding?.hostName == host.name ? binding?.workdir : nil,
                            onPick: { directory in
                                setBinding(SessionHostBindingValue(hostName: host.name, workdir: directory))
                            })
                    } label: {
                        selectableRow(
                            title: host.name,
                            subtitle: binding?.hostName == host.name ? binding?.workdir : "\(host.user)@\(host.address)",
                            selected: binding?.hostName == host.name)
                    }
                }
            } footer: {
                if store.hosts.isEmpty {
                    Text(RemoteHostL10n.string("No remote hosts yet. Add one in Settings → Remote Hosts."))
                } else {
                    Text(RemoteHostL10n.string("When a host is picked, shell and file tools in this chat run on that host in the chosen directory. Device commands such as apple-calendar keep running on this iPhone."))
                }
            }
            if let failure {
                Section {
                    Text(failure).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }

    private func selectableRow(title: String, subtitle: String?, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
    }

    private func setBinding(_ value: SessionHostBindingValue?) {
        // A draft chat is unbound already; creating its session just to store "local" would be a side effect.
        guard value != nil || resolvedSessionId != nil else { return onDone() }
        Task {
            let id: String
            if let resolvedSessionId {
                id = resolvedSessionId
            } else {
                id = await ensureSessionId()
                resolvedSessionId = id
            }
            do {
                try store.setBinding(value, sessionId: id)
                onDone()
            } catch {
                failure = RemoteHostSetup.message(for: error)
            }
        }
    }
}

/// Browses directories over SFTP, starting at the current working directory or the host's $HOME.
private struct RemoteDirectoryPicker: View {
    let services: RemoteServices
    @ObservedObject var store: RemoteHostStore
    let hostName: String
    let startPath: String?
    let onPick: (String) -> Void

    @State private var path: String?
    @State private var listing: Result<[String], RemoteHostSetupFailure>?
    @State private var typedPath = ""

    var body: some View {
        List {
            let recent = store.recentWorkdirs(host: hostName)
            if !recent.isEmpty {
                Section {
                    ForEach(recent, id: \.self) { directory in
                        Button(directory) { onPick(directory) }
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                } header: {
                    Text(AppLocalized("Recent"))
                }
            }

            Section {
                if let path, case .success = listing {
                    Text(path)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Button(RemoteHostL10n.string("Use This Directory")) { onPick(path) }
                        .bold()
                }
                HStack {
                    TextField(RemoteHostL10n.string("Go to path"), text: $typedPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(goToTypedPath)
                    Button(AppLocalized("Go"), action: goToTypedPath)
                        .disabled(!typedPath.hasPrefix("/"))
                }
            } header: {
                Text(RemoteHostL10n.string("Working Directory"))
            }

            Section {
                switch listing {
                case nil:
                    ProgressView()
                case .failure(let failure):
                    Text(failure.message)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button(AppLocalized("Retry")) { Task { await load(path) } }
                case .success(let names):
                    if let path, path != "/" {
                        Button("..") { Task { await load(Self.parent(of: path)) } }
                    }
                    if names.isEmpty {
                        Text(RemoteHostL10n.string("No subdirectories"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(names, id: \.self) { name in
                        Button {
                            Task { await load(Self.child(name, of: path ?? "/")) }
                        } label: {
                            Label(name, systemImage: "folder")
                        }
                    }
                }
            } header: {
                Text(AppLocalized("Folders"))
            }
        }
        .navigationTitle(hostName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(startPath) }
    }

    private func goToTypedPath() {
        let target = typedPath.trimmingCharacters(in: .whitespaces)
        guard target.hasPrefix("/") else { return }
        Task { await load(target) }
    }

    /// `nil` means the host's home directory, which costs one exec to learn.
    private func load(_ requested: String?) async {
        listing = nil
        do {
            let directory: String
            if let requested {
                directory = requested
            } else {
                directory = try await services.executor.homeDirectory(host: hostName)
            }
            let names = try await services.files.listDirectories(host: hostName, path: directory)
            path = directory
            listing = .success(names)
        } catch {
            path = requested ?? path
            listing = .failure(RemoteHostSetupFailure(message: RemoteHostSetup.message(for: error)))
        }
    }

    static func child(_ name: String, of directory: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(of directory: String) -> String {
        guard let slash = directory.dropLast(directory.hasSuffix("/") ? 1 : 0).lastIndex(of: "/") else { return "/" }
        let parent = String(directory[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

/// Turning tools on is the user's call: the event's text may then steer shell and file tools (B spec §9.2).
private struct ReadOnlyEventSection: View {
    let sessionId: String
    let onDone: () -> Void
    @State private var confirming = false

    var body: some View {
        List {
            Section {
                Text(RemoteHostL10n.string("This chat was opened from a mail or GitHub notification on your host. Its content is untrusted, so shell, file writes, the browser and memory writes are off."))
                Button(RemoteHostL10n.string("Turn Tools On")) { confirming = true }
            }
        }
        .confirmationDialog(
            RemoteHostL10n.string("Content from this email or notification can then steer tools."),
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button(RemoteHostL10n.string("Turn Tools On"), role: .destructive) {
                SessionToolPolicy.shared.turnToolsOn(sessionId: sessionId)
                onDone()
            }
        }
    }
}
