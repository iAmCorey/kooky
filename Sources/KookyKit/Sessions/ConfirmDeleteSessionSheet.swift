import SwiftUI

/// Brutalist confirm sheet for deleting a session-history record. Same
/// visual language as `ConfirmRemoveWorktreeSheet` / `UpdatePromptView` —
/// `Theme.chrome*` tokens, mono kebab-case labels, `BracketButton` actions.
/// The parent owns the actual delete via the `confirm` closure; this view
/// stays a pure form that surfaces delete failures inline instead of
/// dismissing as if nothing went wrong.
struct ConfirmDeleteSessionSheet: View {
    let record: AgentSessionRecord
    /// Runs the delete off the main actor; returns success only when the
    /// backing store entry was actually removed.
    let confirm: @MainActor () async -> Bool
    let dismiss: () -> Void

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "DELETE-SESSION", bundle: .kookyResources))
                .font(Theme.mono(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Theme.chromeMuted.opacity(0.85))
                .padding(.bottom, 18)

            Text(record.title.isEmpty ? String(localized: "untitled", bundle: .kookyResources) : record.title)
                .font(Theme.display(20, weight: .medium))
                .foregroundStyle(Theme.chromeForeground)

            Text((record.cwd.path as NSString).abbreviatingWithTildeInPath)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeMuted)
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.activityFailure.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 14)
            }

            HStack(spacing: 10) {
                Spacer()
                BracketButton("cancel") { dismiss() }
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
                BracketButton(buttonLabel) { submit() }
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.4 : 1)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }

    private var buttonLabel: String {
        if isWorking {
            return String(localized: "deleting…", bundle: .kookyResources)
        }
        return String(localized: "delete session", bundle: .kookyResources)
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            let succeeded = await confirm()
            if succeeded {
                dismiss()
            } else {
                isWorking = false
                errorMessage = String(localized: "couldn't delete session", bundle: .kookyResources)
            }
        }
    }
}
