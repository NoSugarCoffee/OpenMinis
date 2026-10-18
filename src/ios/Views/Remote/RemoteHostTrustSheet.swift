import SwiftUI

/// Spec §7 / §8: a host key is stored only after the user has seen its `SHA256:` fingerprint and confirmed it.
struct RemoteHostTrustSheet: View {
    let prompt: RemoteHostKeyPrompt
    let onTrust: () -> Void
    let onCancel: () -> Void

    private var keyType: String {
        prompt.openSSHKey.split(separator: " ").first.map(String.init) ?? ""
    }

    /// The file `ssh-keygen -lf` should read on the host to show the same fingerprint.
    private var hostKeyFile: String {
        switch keyType {
        case "ssh-ed25519": return "/etc/ssh/ssh_host_ed25519_key.pub"
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": return "/etc/ssh/ssh_host_rsa_key.pub"
        case let type where type.hasPrefix("ecdsa-"): return "/etc/ssh/ssh_host_ecdsa_key.pub"
        default: return "/etc/ssh/ssh_host_*_key.pub"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if prompt.replacesPinnedKey {
                    Section {
                        Label {
                            Text(RemoteHostL10n.string("“\(prompt.host)” presented a different host key from the one you trusted. This is expected after the host was reinstalled or its SSH keys were regenerated. Otherwise someone may be intercepting the connection: do not trust the new key until you know why it changed."))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Text(prompt.fingerprint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    if !keyType.isEmpty {
                        LabeledContent(RemoteHostL10n.string("Key type"), value: keyType)
                    }
                } header: {
                    Text(RemoteHostL10n.string("Host key fingerprint"))
                } footer: {
                    Text(RemoteHostL10n.string("Compare it with the output of this command, run on the host itself:")
                        + "\nssh-keygen -lf \(hostKeyFile)")
                }

                Section {
                    Button(prompt.replacesPinnedKey ? RemoteHostL10n.string("Trust New Key") : RemoteHostL10n.string("Trust")) {
                        onTrust()
                    }
                    .foregroundStyle(prompt.replacesPinnedKey ? .red : .accentColor)
                }
            }
            .navigationTitle(prompt.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { onCancel() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
