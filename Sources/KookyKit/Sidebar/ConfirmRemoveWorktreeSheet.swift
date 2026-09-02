import AppKit
import SwiftUI

/// Brutalist confirm sheet for closing a worktree workspace. Same visual
/// language as `CreateWorktreeSheet` / `UpdatePromptView`. Parent owns
/// the actual close (+ optional `git worktree remove`) via the `confirm`
/// closure; this view stays a pure form.
///
/// Default close is non-destructive — just drops the sidebar entry,
/// disk untouched. The checkbox opts into the v0.18.x behaviour of
/// `git worktree remove --force` + `git branch -d` (merged only).
/// Reasoning: v0.18.x's default-destructive close scared users into
/// leaving unwanted entries in the sidebar instead of clicking close.
struct ConfirmRemoveWorktreeSheet: View {
    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    let workspace: Workspace
    /// `alsoDelete` is the checkbox state: false = sidebar removal only;
    /// true = also `git worktree remove --force` + `git branch -d` (if
    /// merged). Caller still owns the close + pending-request cleanup
    /// before resolving.
    let confirm: @MainActor (_ alsoDelete: Bool) async -> Outcome
    let dismiss: () -> Void

    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var alsoDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLabel
                .padding(.bottom, 18)

            headline
            subtitle
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            alsoDeleteCheckbox

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

    private var statusLabel: some View {
        Text(String(localized: "CLOSE-WORKTREE", bundle: .kookyResources))
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(workspace.title)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
    }

    private var subtitle: some View {
        Text((worktreePath.path as NSString).abbreviatingWithTildeInPath)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
    }

    /// Toggle exposing the destructive escape hatch — when on, close
    /// also runs `git worktree remove --force` + `git branch -d`.
    private var alsoDeleteCheckbox: some View {
        KookyCheckbox(
            title: String(localized: "also delete worktree directory and branch", bundle: .kookyResources),
            isOn: $alsoDelete
        )
        .disabled(isWorking)
    }

    private var buttonLabel: String {
        if isWorking {
            return String(
                localized: String.LocalizationValue(
                    alsoDelete ? "deleting…" : "closing…"
                ),
                bundle: .kookyResources
            )
        }
        return String(
            localized: String.LocalizationValue(
                alsoDelete ? "close & delete" : "close"
            ),
            bundle: .kookyResources
        )
    }

    private var worktreePath: URL { workspace.diskPath }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            let outcome = await confirm(alsoDelete)
            switch outcome {
            case .success:
                dismiss()
            case .failure(let msg):
                isWorking = false
                errorMessage = msg
            }
        }
    }
}
