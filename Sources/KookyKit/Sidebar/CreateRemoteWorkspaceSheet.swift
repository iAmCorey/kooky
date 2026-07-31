import SwiftUI

/// Creates a transport-pinned remote workspace. The sheet emits a validated
/// value object; shell command construction remains outside the UI.
struct CreateRemoteWorkspaceSheet: View {
    let create: (WorkspaceTransport) -> Void
    let dismiss: () -> Void
    let moshEnabled: Bool

    private enum TransportChoice: String, CaseIterable, Hashable {
        case ssh = "SSH"
        case mosh = "Mosh (Beta)"
    }

    private enum UDPChoice: String, CaseIterable, Hashable {
        case automatic = "automatic"
        case port = "fixed port"
        case range = "port range"
    }

    @State private var transportChoice: TransportChoice
    @State private var destination = ""
    @State private var udpChoice: UDPChoice = .automatic
    @State private var udpPort = "60000"
    @State private var udpRangeStart = "60000"
    @State private var udpRangeEnd = "61000"
    @State private var prediction: MoshPredictionMode = .adaptive
    @State private var sshPort = ""
    @State private var identityFile = ""
    @State private var serverPath = ""
    @State private var networkTimeoutSeconds =
        MoshWorkspaceConfiguration.defaultNetworkTimeoutSeconds
    @State private var showsAdvanced = false
    @FocusState private var destinationFocused: Bool

    init(
        create: @escaping (WorkspaceTransport) -> Void,
        dismiss: @escaping () -> Void,
        moshEnabled: Bool = true
    ) {
        self.create = create
        self.dismiss = dismiss
        self.moshEnabled = moshEnabled
        _transportChoice = State(initialValue: moshEnabled ? .mosh : .ssh)
    }

    private var normalizedDestination: String? {
        WorkspaceTransport.normalizedNonEmpty(destination)
    }

    private var selectedTransport: WorkspaceTransport? {
        guard let destination = normalizedDestination else { return nil }
        switch transportChoice {
        case .ssh:
            guard let configuration = SSHWorkspaceConfiguration(destination: destination) else {
                return nil
            }
            return .ssh(configuration)
        case .mosh:
            guard let udpSelection else { return nil }
            return MoshWorkspaceConfiguration(
                destination: destination,
                udpPort: udpSelection,
                prediction: prediction,
                serverPath: serverPath,
                sshPort: parsedOptionalPort(sshPort),
                identityFile: identityFile,
                networkTimeoutSeconds: networkTimeoutSeconds
            ).map(WorkspaceTransport.mosh)
        }
    }

    private var udpSelection: MoshUDPPortSelection? {
        switch udpChoice {
        case .automatic:
            return .automatic
        case .port:
            guard let value = UInt16(udpPort), value > 0 else { return nil }
            return .port(value)
        case .range:
            guard let lower = UInt16(udpRangeStart), lower > 0,
                  let upper = UInt16(udpRangeEnd), upper > 0,
                  lower <= upper
            else {
                return nil
            }
            return .range(lower...upper)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "REMOTE-WORKSPACE", bundle: .kookyResources))
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
                .tracking(1.2)
                .padding(.bottom, 18)

            Text(String(localized: "Connect to a remote host", bundle: .kookyResources))
                .font(Theme.display(20, weight: .semibold))
                .foregroundStyle(Theme.chromeForeground)

            Text(description)
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 14) {
                labeled("transport") {
                    Picker("transport", selection: $transportChoice) {
                        ForEach(availableTransports, id: \.self) {
                            Text(LocalizedStringKey($0.rawValue), bundle: .kookyResources).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                labeled("destination") {
                    TextField("user@host", text: $destination)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .bracketBorder()
                        .focused($destinationFocused)
                        .onSubmit(submit)
                }

                if transportChoice == .mosh {
                    moshFields
                    if LocalMoshAvailability.executablePath() == nil {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.activityAttention)
                            Text(String(localized: "mosh was not found in the app PATH or common install locations. Kooky will check the login-shell PATH again at launch.", bundle: .kookyResources))
                                .font(Theme.display(11.5))
                                .foregroundStyle(Theme.chromeMuted)
                                .fixedSize(horizontal: false, vertical: true)
                            Link(
                                String(localized: "installation help", bundle: .kookyResources),
                                destination: URL(string: "https://mosh.org/#getting")!
                            )
                            .font(Theme.mono(10.5, weight: .semibold))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                BracketButton("cancel") { dismiss() }
                BracketButton("create") { submit() }
                    .disabled(selectedTransport == nil)
                    .opacity(selectedTransport == nil ? 0.4 : 1)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .onAppear { destinationFocused = true }
    }

    private var availableTransports: [TransportChoice] {
        moshEnabled ? TransportChoice.allCases : [.ssh]
    }

    private var description: String {
        switch transportChoice {
        case .ssh:
            String(localized: "Every tab opens an SSH session to this destination.", bundle: .kookyResources)
        case .mosh:
            String(localized: "Mosh keeps the terminal responsive across latency, sleep, roaming, and short network outages. SSH remains the control and upload channel.", bundle: .kookyResources)
        }
    }

    @ViewBuilder
    private var moshFields: some View {
        labeled("udp") {
            Picker("udp", selection: $udpChoice) {
                ForEach(UDPChoice.allCases, id: \.self) {
                    Text(LocalizedStringKey($0.rawValue), bundle: .kookyResources).tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            switch udpChoice {
            case .automatic:
                EmptyView()
            case .port:
                compactField("60000", text: $udpPort)
                Text(String(localized: "One fixed UDP port can host only one live tab. Use automatic or a range if you plan to open tabs or splits.", bundle: .kookyResources))
                    .font(Theme.display(10.5))
                    .foregroundStyle(Theme.activityAttention)
                    .fixedSize(horizontal: false, vertical: true)
            case .range:
                HStack(spacing: 8) {
                    compactField("60000", text: $udpRangeStart)
                    Text("…").foregroundStyle(Theme.chromeMuted)
                    compactField("61000", text: $udpRangeEnd)
                }
            }
        }

        labeled("prediction") {
            Picker("prediction", selection: $prediction) {
                ForEach(MoshPredictionMode.allCases, id: \.self) {
                    Text(LocalizedStringKey($0.rawValue), bundle: .kookyResources).tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }

        Button {
            showsAdvanced.toggle()
        } label: {
            Text(showsAdvanced
                ? String(localized: "[-] advanced", bundle: .kookyResources)
                : String(localized: "[+] advanced", bundle: .kookyResources))
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
        }
        .buttonStyle(.plain)

        if showsAdvanced {
            labeled("ssh port") {
                compactField("from ~/.ssh/config", text: $sshPort)
            }
            labeled("identity file") {
                compactField("from ~/.ssh/config", text: $identityFile)
            }
            labeled("mosh-server") {
                compactField("auto", text: $serverPath)
            }
            labeled("orphan timeout") {
                Picker("orphan timeout", selection: $networkTimeoutSeconds) {
                    Text(String(localized: "24 hours", bundle: .kookyResources)).tag(86_400)
                    Text(String(localized: "48 hours", bundle: .kookyResources)).tag(172_800)
                    Text(String(localized: "7 days", bundle: .kookyResources)).tag(604_800)
                    Text(String(localized: "30 days", bundle: .kookyResources)).tag(2_592_000)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private func parsedOptionalPort(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    @ViewBuilder
    private func labeled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey(title), bundle: .kookyResources)
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
            content()
        }
    }

    private func compactField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(
            String(localized: String.LocalizationValue(placeholder), bundle: .kookyResources),
            text: text
        )
            .textFieldStyle(.plain)
            .font(Theme.mono(11.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .bracketBorder()
    }

    private func submit() {
        guard let transport = selectedTransport else { return }
        create(transport)
    }
}
