import AppKit
import SwiftUI

// MARK: - Fuzzy matcher

/// Subsequence-based fuzzy match — query characters must appear in target
/// in order. Case-insensitive. Higher score = better match; nil = no match.
/// Bonuses: prefix (+10), word-boundary (+5), consecutive (+3). The
/// boundary set covers the separators kooky labels actually use: space,
/// `-`, `_`, `/`, `.` (path-like titles, hyphenated slugs, camelCase via
/// `.`).
enum FuzzyMatcher {
    static func score(query: String, against target: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let t = Array(target.lowercased())
        guard q.count <= t.count else { return nil }

        var qi = 0
        var score = 0
        var prevMatchedAt = -2
        var prevIsBoundary = true

        for ti in 0..<t.count {
            let ch = t[ti]
            if qi < q.count, ch == q[qi] {
                var bonus = 1
                if ti == 0 {
                    bonus += 10
                } else if prevIsBoundary {
                    bonus += 5
                }
                if ti == prevMatchedAt + 1 { bonus += 3 }
                score += bonus
                qi += 1
                prevMatchedAt = ti
                // No need to scan the tail once the whole query has matched.
                if qi == q.count { break }
            }
            prevIsBoundary = (ch == " " || ch == "-" || ch == "_" || ch == "/" || ch == ".")
        }

        return qi == q.count ? score : nil
    }
}

// MARK: - Index

/// What a palette row represents. Carries enough id information for the
/// activate path to find the target without re-walking the entire window
/// set later.
enum PaletteItemKind: Hashable, Sendable {
    case workspace(workspaceId: UUID, windowId: UUID)
    case tab(sessionId: UUID, workspaceId: UUID, windowId: UUID)
    case createWorktree(workspaceId: UUID, windowId: UUID)
    /// Spawn a new tab with this agent / preset in the active workspace.
    case agent(templateId: String)
    /// Open the SSH-workspace destination sheet in the active window.
    case createSSHWorkspace
    /// Open a recently used project folder as a new workspace in the
    /// active window (issue #28 — "pick from my projects" without ⌘O).
    case openRecentFolder(path: String)
}

struct PaletteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let kind: PaletteItemKind
    let symbol: String
    let iconAsset: String?
}

@MainActor
enum PaletteIndex {
    /// Build the live index from every open window + the settings model's
    /// visible templates. Rebuilt fresh on every palette open so additions
    /// / closures / renames all show up without cache invalidation.
    static func build(
        controllers: [KookyWindowController],
        model: KookySettingsModel,
        recentFolders: [URL] = [],
        bundle: Bundle = .kookyResources
    ) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let multiWindow = controllers.count > 1
        for (idx, controller) in controllers.enumerated() {
            let winLabel = multiWindow
                ? String.localizedStringWithFormat(
                    String(localized: " · window %d", bundle: bundle),
                    idx + 1
                )
                : ""
            for ws in controller.store.workspaces {
                items.append(PaletteItem(
                    id: "ws-\(ws.id.uuidString)",
                    title: ws.title,
                    subtitle: String(localized: "workspace", bundle: bundle) + winLabel,
                    kind: .workspace(workspaceId: ws.id, windowId: controller.windowId),
                    symbol: "folder",
                    iconAsset: nil
                ))
                if ws.worktreeParentId == nil, GitWatcher.findGitDir(near: ws.workingDirectory) != nil {
                    items.append(PaletteItem(
                        id: "create-worktree-\(ws.id.uuidString)",
                        title: String.localizedStringWithFormat(
                            String(localized: "Create Worktree for %@", bundle: bundle),
                            ws.title
                        ),
                        subtitle: String(localized: "worktree", bundle: bundle) + winLabel,
                        kind: .createWorktree(workspaceId: ws.id, windowId: controller.windowId),
                        symbol: "arrow.triangle.branch",
                        iconAsset: nil
                    ))
                }
                for pane in ws.root.allPanes {
                    for tab in pane.tabs {
                        items.append(PaletteItem(
                            id: "tab-\(tab.id.uuidString)",
                            title: tab.title,
                            subtitle: String.localizedStringWithFormat(
                                String(localized: "tab in %@", bundle: bundle),
                                ws.title
                            ) + winLabel,
                            kind: .tab(sessionId: tab.id, workspaceId: ws.id, windowId: controller.windowId),
                            symbol: tab.displayAgent.symbol,
                            iconAsset: tab.displayAgent.iconAsset
                        ))
                    }
                }
            }
        }
        for template in AgentTemplate.visibleOrdered(model: model) {
            items.append(PaletteItem(
                id: "agent-\(template.id)",
                title: String.localizedStringWithFormat(
                    String(localized: "Open %@", bundle: bundle),
                    template.title
                ),
                subtitle: String(
                    localized: String.LocalizationValue(
                        template.isShell ? "shell" : "agent"
                    ),
                    bundle: bundle
                ),
                kind: .agent(templateId: template.id),
                symbol: template.symbol,
                iconAsset: template.iconAsset
            ))
        }
        items.append(PaletteItem(
            id: "create-ssh-workspace",
            title: String(localized: "New Remote Workspace…", bundle: bundle),
            subtitle: String(localized: "workspace on a remote host", bundle: bundle),
            kind: .createSSHWorkspace,
            symbol: "network",
            iconAsset: nil
        ))
        // Recent project folders — skip ones already open as a workspace
        // (their workspace entry above is the better jump target).
        let openPaths = Set(controllers.flatMap { controller in
            controller.store.workspaces.map { $0.workingDirectory.standardizedFileURL.path }
        })
        for url in recentFolders where !openPaths.contains(url.standardizedFileURL.path) {
            items.append(PaletteItem(
                id: "recent-\(url.path)",
                title: url.lastPathComponent,
                subtitle: String(localized: "recent", bundle: bundle)
                    + " · "
                    + (url.path as NSString).abbreviatingWithTildeInPath,
                kind: .openRecentFolder(path: url.path),
                symbol: "clock.arrow.circlepath",
                iconAsset: nil
            ))
        }
        return items
    }

    /// Rank items by fuzzy score against `query`. Empty query returns the
    /// items in their natural enumeration order (workspaces, tabs, then
    /// templates) capped at `limit` so the panel always has *something* to
    /// show on first open. Pure; `nonisolated` so tests can call it without
    /// hopping to the main actor.
    nonisolated static func match(query: String, in items: [PaletteItem], limit: Int = 20) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Array(items.prefix(limit))
        }
        // Match against title first; fall back to subtitle at half score so a
        // user searching "tab" or "agent" still surfaces those rows by kind.
        let scored: [(PaletteItem, Int)] = items.compactMap { item in
            if let s = FuzzyMatcher.score(query: trimmed, against: item.title) {
                return (item, s)
            }
            if let s = FuzzyMatcher.score(query: trimmed, against: item.subtitle) {
                return (item, s / 2)
            }
            return nil
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
}

// MARK: - SwiftUI view

struct CommandPaletteView: View {
    let items: [PaletteItem]
    let onActivate: (PaletteItem) -> Void
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selected: Int = 0
    @State private var results: [PaletteItem] = []
    @FocusState private var focusField: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Theme.chromeHairline).frame(height: 1)
            resultsList
        }
        // NSHostingController sizes the host panel to the view's
        // intrinsic frame — without this, the panel shrinks to the
        // narrowest the rows can wrap to and ignores the NSPanel
        // contentRect width entirely.
        .frame(width: 720)
        .glassWindowBackground(fallback: Theme.chromeBackground)
        .preferredColorScheme(Theme.chromeColorScheme)
        .onAppear {
            focusField = true
            results = PaletteIndex.match(query: query, in: items)
        }
        // Recompute ranks only when the query actually changes — bodies
        // re-evaluate on every keystroke and every selection step, and
        // a computed `results` would re-rank N items per access (6× per
        // keystroke in the worst case).
        .onChange(of: query) { _, newValue in
            selected = 0
            results = PaletteIndex.match(query: newValue, in: items)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.chromeMuted)
            TextField(String(localized: "Search a workspace, tab, worktree, agent, or preset…", bundle: .kookyResources), text: $query)
                .textFieldStyle(.plain)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.chromeForeground)
                .focused($focusField)
                .onSubmit { activateSelected() }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    selected = min(results.count - 1, selected + 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selected = max(0, selected - 1)
                    return .handled
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { idx, item in
                        CommandPaletteRow(item: item, isSelected: idx == selected)
                            .id(item.id)
                            .onTapGesture { onActivate(item) }
                    }
                    if results.isEmpty {
                        emptyState
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: selected) { _, newIdx in
                guard results.indices.contains(newIdx) else { return }
                proxy.scrollTo(results[newIdx].id, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        Text(String(localized: "No matches.", bundle: .kookyResources))
            .font(Theme.mono(12))
            .foregroundStyle(Theme.chromeMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 32)
    }

    private func activateSelected() {
        guard results.indices.contains(selected) else { return }
        onActivate(results[selected])
    }
}

private struct CommandPaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            AgentIconView(asset: item.iconAsset, fallbackSymbol: item.symbol, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.mono(12.5))
                    .foregroundStyle(Theme.chromeForeground)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.chromeMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        // Hover ≠ selection on purpose. Keyboard ↑↓ drives the strong
        // `chromeActive` highlight; mouse hover gives a subtle wash so
        // the row reads as clickable. Decoupling them avoids: (a) the
        // mouse stealing selection mid-keyboard-nav, and (b) the scroll-
        // to-center fire that an onChange(of:selected) would otherwise
        // do on every cursor twitch.
        .background(isSelected ? Theme.chromeActive
                  : isHovered  ? Theme.chromeHover
                  : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Floating panel host

/// Floating-panel controllers ⌘W can dismiss (`AppDelegate.handleCloseTab`
/// dispatches off the key window's `windowController`). Keeps the
/// "how does this panel close" knowledge on the panel — a new floating
/// panel opts in by conforming, no AppDelegate branch needed.
@MainActor
protocol DismissablePanel: AnyObject {
    func dismiss()
}

/// Singleton NSPanel host. Reusing one panel across opens preserves the
/// last frame and avoids the alloc churn of rebuilding `NSWindow` infra
/// every ⌘P. Anchors to the active window's top-third so the palette
/// reads as window-scoped, not system-scoped (Spotlight-style positioning
/// is the convention for app-internal "go to anything" panels).
@MainActor
final class CommandPaletteWindowController: NSWindowController, DismissablePanel {
    static let shared = CommandPaletteWindowController()

    private static let panelSize = NSSize(width: 720, height: 440)

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        // hidesOnDeactivate only fires when the *app* deactivates. For
        // "click anywhere outside the palette" → dismiss, we need to also
        // listen for didResignKey (any sibling window becomes key).
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.appearance = Theme.windowAppearance
        panel.applyGlassBacking()
        self.init(window: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey(_:)),
            name: NSWindow.didResignKeyNotification, object: panel
        )
    }

    @objc private func panelResignedKey(_ note: Notification) {
        // Fires on any background click that hands key to another window.
        // Dismiss instead of leaving a ghost panel floating with stale
        // focus.
        dismiss()
    }

    func show(items: [PaletteItem], anchor: NSWindow?, onActivate: @escaping (PaletteItem) -> Void) {
        guard let panel = window else { return }
        let view = CommandPaletteView(
            items: items,
            onActivate: { [weak self] item in
                self?.dismiss()
                onActivate(item)
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        // Always build a fresh `NSHostingController`. Just swapping
        // `rootView` keeps SwiftUI's view identity stable across opens
        // so `@State` (query, selected, results) survives `orderOut` —
        // user would reopen the palette to last session's query and
        // stale results. The panel auto-releases the previous host.
        panel.contentViewController = NSHostingController(rootView: view)
        positionAtTop(of: anchor)
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle(items: () -> [PaletteItem], anchor: NSWindow?, onActivate: @escaping (PaletteItem) -> Void) {
        if window?.isVisible == true {
            dismiss()
        } else {
            show(items: items(), anchor: anchor, onActivate: onActivate)
        }
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    /// Centred horizontally over `anchor`, parked ~120pt below its top
    /// edge (Spotlight-style sweet spot). Uses the explicit `panelSize`
    /// constant for centering rather than `panel.frame.size` because the
    /// frame hasn't settled when we measure it right after swapping the
    /// hostingController — reading observed size off-centers the panel.
    private func positionAtTop(of anchor: NSWindow?) {
        guard let panel = window else { return }
        panel.setContentSize(Self.panelSize)
        let referenceFrame = anchor?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = referenceFrame.midX - Self.panelSize.width / 2
        let y = referenceFrame.maxY - 120 - Self.panelSize.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Top-chrome trigger pill

/// Clicks the floating palette open — same target as ⌘P. Rendered as
/// an overlay on `WindowDragHandle` (scoped to the area right of the
/// sidebar toggle) so the pill consumes its own clicks while drags on
/// the surrounding empty area still move the window. The ordered
/// `ViewThatFits` presentations retain a useful trigger while progressively
/// condensing from full to truncated to icon + shortcut to icon-only; only
/// the final fallback disappears. Visually minimal — just a faint white wash
/// that brightens on hover.
struct SearchTriggerPill: View {
    /// 28pt icon-only pill plus the 15pt safety gap on each side.
    static let minimumContainerWidth: CGFloat = 58

    let onOpen: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            candidate(width: 280, showsLabel: true)
            candidate(width: 180, showsLabel: true)
            candidate(width: 52, showsLabel: false)
            candidate(width: 28, showsLabel: false, showsShortcut: false)
            EmptyView()
        }
    }

    /// Keep the safety gap inside each `ViewThatFits` candidate so its width
    /// participates in the fit decision instead of being compressed after a
    /// presentation has already been selected.
    private func candidate(
        width: CGFloat,
        showsLabel: Bool,
        showsShortcut: Bool = true
    ) -> some View {
        pill(width: width, showsLabel: showsLabel, showsShortcut: showsShortcut)
            .padding(.horizontal, 15)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func pill(width: CGFloat, showsLabel: Bool, showsShortcut: Bool = true) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.chromeMuted)
            if showsLabel {
                Text(String(localized: "search workspace, tab, agent…", bundle: .kookyResources))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.chromeMuted)
                    .lineLimit(1)
                Spacer(minLength: 14)
            }
            if showsShortcut {
                Text("⌘P")
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.chromeMuted.opacity(0.55))
            }
        }
        .padding(.horizontal, showsLabel ? 10 : 6)
        .padding(.vertical, 4)
        .frame(width: width, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Theme.chromeActive : Theme.chromeHover)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.vertical, 5)
        .onHover { isHovered = $0 }
        .onTapGesture { onOpen() }
    }
}
