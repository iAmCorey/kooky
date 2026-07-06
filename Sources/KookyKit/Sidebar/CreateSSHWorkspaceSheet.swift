import SwiftUI

/// Small form for creating a workspace whose terminal tabs auto-connect to an
/// SSH destination. The parent owns the actual workspace creation so this view
/// stays purely presentational.
struct CreateSSHWorkspaceSheet: View {
    let create: (String) -> Void
    let dismiss: () -> Void

    @State private var remoteHost = ""
    @State private var errorMessage: String?
    @FocusState private var hostFocused: Bool

    private var normalizedHost: String {
        remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !normalizedHost.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SSH-WORKSPACE")
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.chromeMuted)
                .tracking(1.2)
                .padding(.bottom, 18)

            Text("Connect to a remote host")
                .font(Theme.display(20, weight: .semibold))
                .foregroundStyle(Theme.chromeForeground)

            Text("New tabs in this workspace will open SSH sessions to the same destination.")
                .font(Theme.display(12.5))
                .foregroundStyle(Theme.chromeMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            VStack(alignment: .leading, spacing: 8) {
                Text("destination")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.chromeMuted)
                TextField("user@host", text: $remoteHost)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.chromeActive.opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.chromeHairline, lineWidth: 1)
                    )
                    .focused($hostFocused)
                    .onSubmit(submit)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.activityFailure.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
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
        .onAppear { hostFocused = true }
    }

    private func submit() {
        guard canSubmit else {
            errorMessage = "enter an SSH destination"
            return
        }
        create(normalizedHost)
    }
}
