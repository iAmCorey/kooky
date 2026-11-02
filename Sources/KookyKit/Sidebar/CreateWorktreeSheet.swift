import AppKit
import SwiftUI

/// Brutalist sheet for creating a git worktree in a project's repository.
/// Same visual language as `UpdatePromptView` / Settings — `Theme.chrome*`
/// tokens, mono kebab-case labels, sharp corners, 1pt hairlines, bracket
/// buttons. Form-only: the parent owns the actual git + workspace
/// materialization via the `create` closure and dismisses on success.
struct CreateWorktreeSheet: View {
    /// Parent passes this back from `create` so the sheet can surface
    /// failure inline (user fixes the branch name / path and retries)
    /// instead of dismissing.
    enum CreateOutcome: Equatable {
        case success
        case failure(String)
    }

    /// Bundle of form output handed to `create`. `kind` distinguishes
    /// "spawn a new worktree via git" from "adopt existing on-disk
    /// worktrees into the sidebar" — the latter touches no git state,
    /// just creates kooky workspaces for each picked path.
    struct Request {
        enum Kind {
            /// User picked new branch or existing branch — runs `git
            /// worktree add` then materializes a workspace.
            case create(mode: WorktreeManager.BranchMode, path: URL, branchForDisplay: String)
            /// User picked existing on-disk worktrees to surface in
            /// the sidebar. No git commands run; one workspace per
            /// picked entry.
            case adopt(worktrees: [WorktreeManager.Info])
        }
        let kind: Kind
        let template: AgentTemplate
    }

    let project: Project
    let launchTemplates: [AgentTemplate]
    let defaultLaunchTemplate: AgentTemplate
    /// Standardized disk paths of worktrees already on the sidebar —
    /// filtered out of the adopt picker so the user can't add the
    /// same one twice.
    let alreadyAdoptedPaths: Set<String>
    let create: @MainActor (Request) async -> CreateOutcome
    let dismiss: () -> Void

    private enum BranchModeUI: Hashable { case newBranch, existing, adopt }
    private enum StartFromChoice: Hashable {
        case head
        case branch(String)
        case custom
    }

    @State private var branchMode: BranchModeUI = .newBranch
    @State private var newBranchName: String = ""
    @State private var startFromChoice: StartFromChoice = .head
    @State private var customStartRef: String = ""
    @State private var existingBranch: String = ""
    /// Loaded off-thread via `.task` on first sheet appear so the main
    /// thread doesn't block on `git for-each-ref` while the user is
    /// typing. Empty until the subprocess returns.
    @State private var availableBranches: [String] = []
    @State private var checkedOutBranches: Set<String> = []
    @State private var branchesLoaded: Bool = false
    /// Full `git worktree list --porcelain` output — kept so the adopt
    /// picker can list paths not yet on the sidebar without re-running
    /// the subprocess.
    @State private var diskWorktrees: [WorktreeManager.Info] = []
    /// Pre-filtered adopt rows: disk worktrees minus the source root
    /// and minus everything already on the sidebar, each paired with
    /// its standardized-path key. Caching avoids re-standardizing the
    /// URL on every body re-eval (SwiftUI re-runs `adoptList`'s ForEach
    /// closure each keystroke; without caching that's
    /// `O(rows × ~8µs URL standardize)` per stroke).
    @State private var adoptableRows: [AdoptRow] = []
    /// Standardized paths the user has selected to adopt. Multi-select.
    @State private var selectedAdoptPaths: Set<String> = []

    fileprivate struct AdoptRow {
        let info: WorktreeManager.Info
        let key: String
    }
    /// Stable git root for the project. The project's root is immutable, but
    /// it may be a subfolder of the repo, so the real root is still resolved.
    @State private var sourceRoot: URL?
    /// User override for the auto-computed `<repo>-<branch>` sibling path.
    /// Empty = use the computed default at submit time. Lives only in
    /// the options section.
    @State private var worktreePathOverride: String = ""
    @State private var selectedTemplate: AgentTemplate?
    @State private var isOptionsExpanded: Bool = false
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?

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

            form

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
                BracketButton(submitButtonLabel) {
                    submit()
                }
                .disabled(isWorking || !canSubmit)
                .opacity(canSubmit && !isWorking ? 1 : 0.4)
            }
            .padding(.top, 22)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 28)
        .frame(width: 480, alignment: .topLeading)
        .background(Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .onAppear(perform: prefill)
        .task {
            // First render: kick off branch enumeration off the main
            // thread. The picker stays empty until this returns; the
            // sheet starts on `.newBranch` mode so most users never
            // wait on this.
            guard !branchesLoaded else { return }
            let cwd = project.rootPath
            // `repoRoot` is the gate; `list` and `localBranches` are
            // independent once it resolves, so kick them off in parallel
            // child tasks. Cuts sheet-open time from ~150-450ms to the
            // max of the two (~100-300ms) on a cold git cache.
            let loaded = await Task.detached(priority: .userInitiated) {
                let root = WorktreeManager.repoRoot(near: cwd)
                let queryCwd = root ?? cwd
                async let infos: [WorktreeManager.Info] = {
                    guard let root,
                          case .success(let result) = WorktreeManager.list(repoPath: root)
                    else { return [] }
                    return result
                }()
                async let branches = GitBranchInventory.localBranches(cwd: queryCwd)
                let resolvedInfos = await infos
                return (
                    root: root,
                    branches: await branches,
                    infos: resolvedInfos,
                    checkedOut: WorktreeManager.checkedOutBranches(in: resolvedInfos)
                )
            }.value
            sourceRoot = loaded.root
            let branches = loaded.branches
            availableBranches = branches
            checkedOutBranches = loaded.checkedOut
            diskWorktrees = loaded.infos
            // Precompute adopt rows: standardize each disk path once, drop
            // the source root and anything already on sidebar. Cached so
            // SwiftUI body re-evals (on every keystroke) don't re-walk.
            let sourceRootKey = (loaded.root ?? project.rootPath).standardizedFileURL.path
            adoptableRows = loaded.infos.compactMap { info in
                let key = info.path.standardizedFileURL.path
                if key == sourceRootKey || alreadyAdoptedPaths.contains(key) { return nil }
                return AdoptRow(info: info, key: key)
            }
            if existingBranch.isEmpty || loaded.checkedOut.contains(existingBranch) {
                existingBranch = branches.first { !loaded.checkedOut.contains($0) } ?? ""
            }
            branchesLoaded = true
            // No usable existing-branch target → fall back to new branch
            // (mode picker hides itself in this state; leaving branchMode
            // on `.existing` would strand the form on an empty picker).
            if existingBranch.isEmpty, branchMode == .existing {
                branchMode = .newBranch
            }
        }
    }

    // MARK: Sections

    private var statusLabel: some View {
        Text(String(localized: "CREATE-WORKTREE", bundle: .kookyResources))
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    private var headline: some View {
        Text(project.title)
            .font(Theme.display(20, weight: .medium))
            .foregroundStyle(Theme.chromeForeground)
    }

    private var subtitle: some View {
        Text((sourcePathForDisplay.path as NSString).abbreviatingWithTildeInPath)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.chromeMuted)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            modePicker
            switch branchMode {
            case .newBranch, .existing:
                branchField
                if !isOptionsExpanded {
                    pathPreview
                }
                optionsToggle
                if isOptionsExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        editRow(label: "worktree-path", text: $worktreePathOverride, placeholder: defaultPath)
                        if branchMode == .newBranch {
                            startFromControl
                        }
                        launchPicker
                    }
                }
            case .adopt:
                adoptForm
            }
        }
    }

    /// Adopt mode body — multi-select of disk worktrees not currently in
    /// the sidebar. The launch-template picker stays inside the options
    /// disclosure for consistency with create mode.
    @ViewBuilder
    private var adoptForm: some View {
        if !branchesLoaded {
            inlineStatus("loading worktrees…")
        } else if adoptableRows.isEmpty {
            // The mode picker hides `adopt` when this pool is empty, but
            // a race (user toggles mode → CLI removes worktree → toggle
            // resolves) could land here. Defensive fallback.
            inlineStatus("no unmanaged worktrees on disk")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("worktrees")
                adoptList
            }
            optionsToggle
            if isOptionsExpanded {
                launchPicker
            }
        }
    }

    private var adoptList: some View {
        // Cap height so a repo with 20+ worktrees doesn't push the sheet
        // off-screen. ScrollView only kicks in once the pile exceeds the
        // cap; smaller pools render inline at natural height.
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(adoptableRows, id: \.key) { row in
                    Toggle(isOn: Binding(
                        get: { selectedAdoptPaths.contains(row.key) },
                        set: { isOn in
                            if isOn { selectedAdoptPaths.insert(row.key) }
                            else { selectedAdoptPaths.remove(row.key) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.info.branch ?? "<detached>")
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.chromeForeground)
                            Text((row.info.path.path as NSString).abbreviatingWithTildeInPath)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.chromeMuted)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private var launchPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("launch")
            Picker("", selection: Binding(
                get: { selectedTemplate ?? defaultLaunchTemplate },
                set: { selectedTemplate = $0 }
            )) {
                ForEach(launchTemplates) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var modePicker: some View {
        // Stay hidden until branches load so segments don't flash in then
        // disappear when we learn there's nothing to pick. Each segment
        // has its own enable condition — "new" is always available;
        // "existing" only when there are unchecked-out branches; "adopt"
        // only when disk has worktrees not yet on the sidebar.
        if branchesLoaded && (hasSelectableExistingBranches || hasAdoptablePool) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("mode")
                Picker("", selection: $branchMode) {
                    Text(String(localized: "new", bundle: .kookyResources)).tag(BranchModeUI.newBranch)
                    if hasSelectableExistingBranches {
                        Text(String(localized: "existing", bundle: .kookyResources)).tag(BranchModeUI.existing)
                    }
                    if hasAdoptablePool {
                        Text(String(localized: "adopt", bundle: .kookyResources)).tag(BranchModeUI.adopt)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var hasSelectableExistingBranches: Bool {
        !selectableExistingBranches.isEmpty
    }

    private var hasAdoptablePool: Bool {
        !adoptableRows.isEmpty
    }

    @ViewBuilder
    private var branchField: some View {
        // Only rendered for `.newBranch` / `.existing` — `form` dispatches
        // `.adopt` to `adoptForm`. `if/else if` over the relevant cases
        // keeps the switch out of dead-arm territory.
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(branchMode == .newBranch ? "new-branch" : "existing-branch")
            if branchMode == .newBranch {
                TextField("feat-x", text: $newBranchName)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .bracketBorder()
                if newBranchAlreadyExists {
                    newBranchConflictRow
                }
            } else if branchMode == .existing {
                existingBranchMenu
            }
        }
    }

    private var newBranchConflictRow: some View {
        HStack(spacing: 8) {
            inlineStatus(newBranchConflictMessage, color: Theme.activityFailure.opacity(0.85))
            if !newBranchIsCheckedOut {
                Button(String(localized: "use existing", bundle: .kookyResources)) {
                    existingBranch = normalizedNewBranchName
                    branchMode = .existing
                }
                .buttonStyle(.plain)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.chromeForeground)
            }
        }
    }

    @ViewBuilder
    private var existingBranchMenu: some View {
        if !branchesLoaded {
            inlineStatus("loading branches…")
        } else if availableBranches.isEmpty {
            inlineStatus("no local branches found")
        } else if selectableExistingBranches.isEmpty {
            inlineStatus("all local branches are already checked out")
        } else {
            Picker("", selection: $existingBranch) {
                ForEach(selectableExistingBranches, id: \.self) { branch in
                    Text(branch).tag(branch)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var startFromControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("start-from")
            Picker("", selection: $startFromChoice) {
                Text("HEAD").tag(StartFromChoice.head)
                ForEach(availableBranches, id: \.self) { branch in
                    Text(branch).tag(StartFromChoice.branch(branch))
                }
                Text(String(localized: "custom ref…", bundle: .kookyResources)).tag(StartFromChoice.custom)
            }
            .pickerStyle(.menu)
            .labelsHidden()

            if startFromChoice == .custom {
                TextField("origin/main, tag, or SHA", text: $customStartRef)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.chromeForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .bracketBorder()
                if customStartRefIsMissing {
                    inlineStatus("enter a ref")
                }
            }
        }
    }

    private var pathPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel("worktree-path")
            Text(effectivePathDisplay)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.chromeMuted)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .bracketBorder()
        }
    }

    private func inlineStatus(_ text: String, color: Color = Theme.chromeMuted) -> some View {
        Text(LocalizedStringKey(text), bundle: .kookyResources)
            .font(Theme.mono(11.5))
            .foregroundStyle(color)
    }

    private var optionsToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                isOptionsExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOptionsExpanded ? 90 : 0))
                Text(String(localized: "options", bundle: .kookyResources))
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1.2)
            }
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .kookyResources)
            .font(Theme.mono(10, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Theme.chromeMuted.opacity(0.85))
    }

    @ViewBuilder
    private func editRow(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            TextField(
                String(
                    localized: String.LocalizationValue(placeholder),
                    bundle: .kookyResources
                ),
                text: text
            )
                .textFieldStyle(.plain)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.chromeForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .bracketBorder()
        }
    }

    // MARK: Logic

    private var canSubmit: Bool {
        switch branchMode {
        case .newBranch:
            return !normalizedNewBranchName.isEmpty
                && !newBranchAlreadyExists
                && !customStartRefIsMissing
        case .existing:
            // Block submit until branches finish loading so a quick toggle
            // doesn't fire `create` with `existingBranch = ""`.
            return branchesLoaded
                && !existingBranch.isEmpty
                && !checkedOutBranches.contains(existingBranch)
        case .adopt:
            return branchesLoaded && !selectedAdoptPaths.isEmpty
        }
    }

    private var normalizedNewBranchName: String {
        newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var newBranchAlreadyExists: Bool {
        branchesLoaded && availableBranches.contains(normalizedNewBranchName)
    }

    private var newBranchIsCheckedOut: Bool {
        checkedOutBranches.contains(normalizedNewBranchName)
    }

    private var newBranchConflictMessage: String {
        String(
            localized: String.LocalizationValue(
                newBranchIsCheckedOut
                    ? "branch is already checked out"
                    : "branch exists locally"
            ),
            bundle: .kookyResources
        )
    }

    private var customStartRefIsMissing: Bool {
        startFromChoice == .custom
            && customStartRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedStartRef: String? {
        switch startFromChoice {
        case .head:
            return nil
        case .branch(let branch):
            return branch
        case .custom:
            let trimmed = customStartRef.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func prefill() {
        if selectedTemplate == nil {
            selectedTemplate = defaultLaunchTemplate
        }
    }

    /// Branch the user is about to act on (new or existing). Drives the
    /// auto-computed `worktree-path` placeholder so it always reads as a
    /// finished proposal, not a half-filled `<repo>-` stub.
    private var currentBranchName: String {
        switch branchMode {
        case .newBranch: return normalizedNewBranchName
        case .existing: return existingBranch
        case .adopt: return ""  // adopt mode doesn't drive path preview
        }
    }

    private var selectableExistingBranches: [String] {
        availableBranches.filter { !checkedOutBranches.contains($0) }
    }

    /// Sibling of the source repo: `<parent>/<repo-name>-<branch>`.
    /// Falls back to `<repo-name>-` when no branch has been typed yet so
    /// the placeholder still hints at the path's shape.
    private var defaultPath: String {
        let root = sourceRoot ?? project.rootPath
        let parentDir = root.deletingLastPathComponent()
        let base = root.lastPathComponent
        let name = WorktreeManager.defaultDirectoryName(sourceName: base, branch: currentBranchName)
        let candidate = parentDir.appendingPathComponent(name).path
        return (candidate as NSString).abbreviatingWithTildeInPath
    }

    private var effectivePathDisplay: String {
        let override = worktreePathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? defaultPath : (override as NSString).abbreviatingWithTildeInPath
    }

    private var sourcePathForDisplay: URL {
        sourceRoot ?? project.rootPath
    }

    private var submitButtonLabel: String {
        if isWorking {
            return String(
                localized: String.LocalizationValue(
                    branchMode == .adopt ? "adopting…" : "creating…"
                ),
                bundle: .kookyResources
            )
        }
        switch branchMode {
        case .newBranch, .existing: return String(localized: "create worktree", bundle: .kookyResources)
        case .adopt: return String(localized: "adopt", bundle: .kookyResources)
        }
    }

    private func submit() {
        let template = selectedTemplate ?? defaultLaunchTemplate
        let kind: Request.Kind
        switch branchMode {
        case .newBranch, .existing:
            // worktree-path falls back to the auto-computed default when
            // the user didn't expand options (or left it blank). The
            // override wins only when non-empty.
            let override = worktreePathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectivePath = override.isEmpty ? defaultPath : override
            let expanded = (effectivePath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let mode: WorktreeManager.BranchMode
            let branchForDisplay: String
            if branchMode == .newBranch {
                let name = normalizedNewBranchName
                mode = .newBranch(name: name, base: selectedStartRef)
                branchForDisplay = name
            } else {
                mode = .existing(branch: existingBranch)
                branchForDisplay = existingBranch
            }
            kind = .create(mode: mode, path: url, branchForDisplay: branchForDisplay)
        case .adopt:
            // Pick in display order so adoptions land in the sidebar in
            // the same order the user saw them in the picker.
            let picked = adoptableRows.compactMap {
                selectedAdoptPaths.contains($0.key) ? $0.info : nil
            }
            kind = .adopt(worktrees: picked)
        }

        let request = Request(kind: kind, template: template)
        isWorking = true
        errorMessage = nil
        Task {
            let outcome = await create(request)
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
