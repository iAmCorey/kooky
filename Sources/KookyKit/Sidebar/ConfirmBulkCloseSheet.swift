import AppKit
import SwiftUI

/// Brutalist bulk-close confirm — used by both "Close Other Workspaces"
/// and "close source workspace that has worktrees". The two flows share
/// the same shape: a list of worktrees about to lose their directories
/// plus cancel/close buttons.
/// Caller supplies the labels so the sheet stays content-agnostic.
struct ConfirmBulkCloseSheet: View {
    enum Outcome: Equatable {
        case success
        case failure(String)
    }

    let statusLabel: String
    let headlineText: String
    let subtitleText: String
    let worktreesAmong: [Workspace]
    /// `alsoDelete` is the checkbox state: false = close workspaces from
    /// sidebar only; true = also `git worktree remove --force` + delete
    /// merged branches for each listed worktree. v0.19.0 makes destructive
    /// disk removal opt-in, mirroring `ConfirmRemoveWorktreeSheet`.
    let confirm: @MainActor (_ alsoDelete: Bool) async -> Outcome
    let dismiss: () -> Void

    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var alsoDelete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBadge
                .padding(.bottom, 18)

            headline
            subtitle
                .padding(.top, 6)

            Rectangle()
                .fill(Theme.chromeHairline)
                .frame(width: 32, height: 1)
                .padding(.vertical, 22)

            worktreeList
                .padding(.bottom, 14)

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
        .frame(width: 480, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
    }

    private var statusBadge: some View {
        Text(verbatim: statusLabel)
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(verbatim: headlineText)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
    }

    private var subtitle: some View {
        Text(verbatim: subtitleText)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
    }

    private var worktreeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(worktreesAmong) { worktree in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.chromeMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(worktree.title)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.chromeForeground)
                        Text((worktreePath(for: worktree).path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.chromeMuted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
    }

    private var alsoDeleteCheckbox: some View {
        KookyCheckbox(
            title: String(localized: "also delete worktree directories and branches", bundle: .kookyResources),
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

    private func worktreePath(for workspace: Workspace) -> URL { workspace.diskPath }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            let outcome = await confirm(alsoDelete)
            switch outcome {
            case .success:
                dismiss()
            case .failure(let message):
                isWorking = false
                errorMessage = message
            }
        }
    }
}
