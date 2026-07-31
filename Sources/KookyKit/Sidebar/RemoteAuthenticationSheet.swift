import SwiftUI

/// A real PTY for OpenSSH's own interactive prompts. Kooky never receives or
/// parses passwords, passphrases, OTPs, host-key answers, or security-key
/// interaction; it only learns whether the one-shot `ssh ... true` exited 0.
struct RemoteAuthenticationSheet: View {
    let session: Session
    let authenticated: () -> Void
    let dismiss: () -> Void

    @State private var engine = LibghosttyEngine()
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SSH-AUTHENTICATION")
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
                .tracking(1.2)

            Text("Authenticate to \(session.remoteRuntime?.destination ?? "remote host")")
                .font(Theme.display(18, weight: .semibold))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.top, 12)

            Text("Prompts below come directly from OpenSSH. Kooky does not read or store your credentials.")
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.top, 5)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(height: 1)
                .padding(.vertical, 14)

            TerminalView(engine: engine)
                .frame(minWidth: 620, minHeight: 300)
                .padding(8)
                .background(Color(nsColor: engine.backgroundColor))
                .bracketBorder()

            HStack {
                Spacer()
                BracketButton("cancel") { dismiss() }
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 700)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .onAppear(perform: start)
        .onDisappear { engine.terminate() }
    }

    private func start() {
        guard !started,
              let runtime = session.remoteRuntime,
              case .mosh(let configuration) = session.workspaceTransport
        else { return }
        started = true
        let control = RemoteControlChannelConfiguration(
            destination: runtime.destination,
            runtimeToken: runtime.token,
            sshPort: configuration.sshPort.flatMap(UInt16.init(exactly:)),
            identityFile: configuration.identityFile
        )
        engine.onProcessExitedCleanly = {
            authenticated()
        }
        engine.start(config: TerminalSessionConfig(
            command: control.executableURL.path,
            arguments: RemoteControlChannel.authenticationArguments(for: control),
            workingDirectory: nil,
            environment: [:]
        ))
    }
}
