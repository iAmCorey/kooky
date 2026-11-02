import SwiftUI

/// Brutalist sheet for creating an SSH workspace — the ssh destination and an
/// optional port. Same visual language as `CreateWorktreeSheet` (`Theme.chrome*`
/// tokens, mono kebab-case labels, bracket buttons). Purely presentational:
/// the parent owns workspace creation via the `create` closure.
struct CreateSSHWorkspaceSheet: View {
    let create: (String, Int?) -> Void
    let dismiss: () -> Void

    @State private var destination = ""
    @State private var port = ""
    @FocusState private var fieldFocused: Bool

    /// Same blank-collapses-to-nil rule the store's `normalizedSSHHost`
    /// applies at ingress, so the submit gate and the model gate can't drift.
    private var normalizedDestination: String? { normalizedTitle(destination) }

    /// Blank means "let ssh decide" (`~/.ssh/config`'s `Port`, else 22) — the
    /// common case, so an empty field is not an error. Anything else has to
    /// survive the store's `normalizedSSHPort` gate, so the sheet can't submit
    /// a port the spawn step would silently drop.
    private var normalizedPort: Int? { WorkspaceStore.sshPort(fromField: port) }

    private var portIsAcceptable: Bool {
        normalizedPort != nil || port.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSubmit: Bool { normalizedDestination != nil && portIsAcceptable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "SSH-WORKSPACE", bundle: .kookyResources))
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
                .tracking(1.2)
                .padding(.bottom, 18)

            Text(String(localized: "Connect to a remote host", bundle: .kookyResources))
                .font(Theme.display(20, weight: .semibold))
                .foregroundStyle(Theme.chromeForeground)

            Text(String(localized: "Every new tab in this workspace opens an SSH session to the same destination; agent tabs launch their agent on the remote.", bundle: .kookyResources))
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "destination", bundle: .kookyResources))
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.chromeMuted)
                TextField("user@host", text: $destination)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .bracketBorder()
                    .focused($fieldFocused)
                    .onSubmit(submit)
                Text(String(localized: "anything your `ssh` accepts — host aliases from ~/.ssh/config work", bundle: .kookyResources))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.8))
            }
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "port", bundle: .kookyResources))
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.chromeMuted)
                TextField("22", text: $port)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(width: 96)
                    .bracketBorder()
                    .onSubmit(submit)
                Text(String(localized: "leave empty for the port ssh would pick (22, or ~/.ssh/config's Port)", bundle: .kookyResources))
                    .font(Theme.mono(10.5))
                    .foregroundStyle(portIsAcceptable ? Theme.chromeMuted.opacity(0.8) : Theme.chromeForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer()
                BracketButton("cancel") { dismiss() }
                BracketButton("create") { submit() }
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.4)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 420, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard let host = normalizedDestination, portIsAcceptable else { return }
        create(host, normalizedPort)
    }
}
