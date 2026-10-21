import MinisRemote
import SwiftUI
import VisionKit

/// Add Host by scanning the code `minis-hostd pair` prints (pairing spec §4). Manual entry stays one tap away
/// for hosts without minis-hostd.
struct RemoteHostPairView: View {
    let services: RemoteServices
    let onManualEntry: () -> Void

    private enum Step: Equatable {
        case scanning
        case confirming(PairingPayload)
        case pairing
        case checking
        case done(RemoteHostCheckOutcome)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .scanning
    @State private var name = ""
    @State private var failure: String?
    @State private var copied = false

    private static var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .scanning:
                    instructionsSection
                    if Self.canScan {
                        Section {
                            PairingCodeScanner(onCode: scanned, onFailure: { failure = $0 })
                                .frame(height: 300)
                                .listRowInsets(EdgeInsets())
                        }
                    } else {
                        Section {
                            Text(RemoteHostL10n.string("This iPhone cannot scan codes right now. Allow camera access for Minis in Settings, or enter the details manually."))
                        }
                    }
                case .confirming(let payload):
                    confirmSection(payload)
                case .pairing:
                    progressSection(RemoteHostL10n.string("Pairing…"))
                case .checking:
                    progressSection(RemoteHostL10n.string("Checking the host…"))
                case .done(let outcome):
                    doneSection(outcome)
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                if step == .scanning {
                    Section {
                        Button(RemoteHostL10n.string("Enter Details Manually"), action: onManualEntry)
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(RemoteHostL10n.string("Add Host"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .done = step {
                        EmptyView()
                    } else {
                        Button(AppLocalized("Cancel")) { dismiss() }
                            .disabled(step == .pairing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .done = step {
                        Button(AppLocalized("Done")) { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(step == .pairing || step == .checking)
    }

    private var instructionsSection: some View {
        Section {
            Text(RemoteHostL10n.string("On the computer, open Terminal and run the command below, then point the camera at the code it prints."))
            Text(RemoteHostSetup.pairCommand())
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button(copied ? RemoteHostL10n.string("Copied") : RemoteHostL10n.string("Copy Command")) {
                UIPasteboard.general.string = RemoteHostSetup.pairCommand()
                copied = true
            }
        } footer: {
            Text(RemoteHostL10n.string("The command installs minis-hostd for the current user. If it is installed already, ~/.minis/bin/minis-hostd pair is enough. The computer needs Remote Login (SSH) turned on."))
        }
    }

    private func confirmSection(_ payload: PairingPayload) -> some View {
        Section {
            TextField(RemoteHostL10n.string("Name, for example mini"), text: $name)
            LabeledContent(RemoteHostL10n.string("User"), value: payload.user)
            LabeledContent(RemoteHostL10n.string("Address"), value: payload.addresses.joined(separator: ", "))
            Button(RemoteHostL10n.string("Add")) { Task { await pair(payload) } }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(RemoteHostL10n.string("Scan Again")) {
                failure = nil
                step = .scanning
            }
        } header: {
            Text(RemoteHostL10n.string("Host"))
        } footer: {
            Text(RemoteHostL10n.string("The name is how the agent and the chat refer to the host: 1–32 letters, digits, “-” or “_”. It cannot be changed later."))
        }
    }

    private func progressSection(_ label: String) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(label)
            }
        }
    }

    @ViewBuilder
    private func doneSection(_ outcome: RemoteHostCheckOutcome) -> some View {
        Section {
            Label(RemoteHostL10n.string("Added \(name)."), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        switch outcome {
        case .checked(let results):
            Section {
                ForEach(results, id: \.check) { RemoteHostCheckRow(result: $0) }
            } header: {
                Text(RemoteHostL10n.string("Checks"))
            }
        case .failed(let message):
            Section {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            } footer: {
                Text(RemoteHostL10n.string("The host is saved. Test the connection again from its settings once this is fixed."))
            }
        case .untrusted:
            Section {
                Text(RemoteHostL10n.string("The host presented a different key from the one in the code. Open the host's settings to check it before using it."))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func scanned(_ text: String) {
        guard step == .scanning else { return }
        do {
            let payload = try PairingPayload.parse(text)
            failure = nil
            name = services.store.hosts.contains(where: { $0.name == payload.name }) ? "" : payload.name
            step = .confirming(payload)
        } catch {
            failure = RemoteHostSetup.message(for: error)
        }
    }

    private func pair(_ payload: PairingPayload) async {
        let hostName = name.trimmingCharacters(in: .whitespaces)
        failure = nil
        step = .pairing
        do {
            try await RemoteHostSetup.pair(
                payload, name: hostName, client: PairingClient(transport: NetworkPairingTransport()), services: services)
        } catch {
            failure = RemoteHostSetup.message(for: error)
            step = .confirming(payload)
            return
        }
        step = .checking
        step = .done(await RemoteHostSetup.runChecks(host: hostName, services: services))
    }
}

/// VisionKit's scanner limited to QR codes; reports each payload string it recognises.
private struct PairingCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            onFailure(RemoteHostL10n.string("The camera could not start: \(error.localizedDescription)"))
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            for case .barcode(let barcode) in addedItems {
                if let text = barcode.payloadStringValue { onCode(text) }
            }
        }
    }
}
