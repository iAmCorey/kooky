import AppKit
import Foundation

/// We don't bundle ghostty's shell-integration assets, so we ship a small zsh
/// wrapper that:
///   1. sources the user's real `~/.zshrc` so their config still applies, then
///   2. installs a `chpwd` hook that emits OSC 7 (`\e]7;file://host/path\e\\`).
///
/// Libghostty's `GHOSTTY_ACTION_PWD` then fires whenever the shell `cd`s, which
/// is what `WorkspaceStore` listens to for cwd-tracking.
enum KookyShellIntegration {
    /// POSIX single-quote wrap (escape internal `'` by `'\''`). Safe for
    /// arbitrary file paths and argv-style values; reused by anyone that
    /// builds a shell-command string for `engine.sendInput` or PTY spawn.
    static func quote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Backslash-escape every POSIX shell metacharacter — matches the
    /// `\ ` / `\'` style Finder uses when dragging a file onto Terminal.app
    /// or ghostty.app. Picks this over `quote(_:)` for the drag-and-drop
    /// path so the user sees the same untouched-looking path they'd see in
    /// any other macOS terminal, rather than a surrounding pair of quotes.
    /// Non-ASCII bytes (Chinese / emoji / accented chars) pass through
    /// unescaped — every modern shell accepts them as raw UTF-8.
    ///
    /// Edge case: filenames with embedded newlines are legal on macOS but
    /// POSIX shells eat `\<newline>` as line-continuation, dropping both
    /// chars instead of preserving the literal newline. We fall back to
    /// `quote(_:)` for those — visible quotes are uglier than `\ `, but
    /// silent path corruption is worse.
    static func backslashEscape(_ s: String) -> String {
        if s.contains("\n") {
            return quote(s)
        }
        var result = ""
        result.reserveCapacity(s.count)
        for char in s {
            if shellMetacharacters.contains(char) { result.append("\\") }
            result.append(char)
        }
        return result
    }

    private static let shellMetacharacters: Set<Character> = [
        " ", "\t", "\n", "\\", "\"", "'", "`", "$",
        "(", ")", "|", "&", ";", "<", ">", "*", "?",
        "[", "]", "{", "}", "~", "!", "#",
    ]

    /// Filter `urls` to fileURLs, `backslashEscape` each path, join by
    /// spaces. Nil when nothing survives the filter — the caller falls
    /// through to other paste sources. Shared between Finder drag-drop
    /// (v0.11.3 `performDragOperation`) and Cmd+V on a Finder Copy
    /// (v0.18.2 paste path): both produce a multi-URL pasteboard the
    /// user expects to render as terminal argv.
    static func backslashEscapedFileURLs(_ urls: [URL]) -> String? {
        let escaped = urls.compactMap { $0.isFileURL ? backslashEscape($0.path) : nil }
        return escaped.isEmpty ? nil : escaped.joined(separator: " ")
    }

    /// Resolve pasteboard contents into a terminal-safe text payload —
    /// what Cmd+V and the right-click "Paste" entry should inject.
    ///
    /// NOTE: at the three live paste sites this is reached through
    /// `paste(from:host:deliver:)`, whose image tier intercepts raw images
    /// first — tier 2 below survives as the fallback for direct callers
    /// (and keeps its tests meaningful as the synchronous reference).
    ///
    /// Precedence:
    /// 1. **File URLs** (Finder Copy on a file — including images) →
    ///    `backslashEscape($0.path)` joined by spaces. Without this,
    ///    `pb.string(forType: .string)` for a fileURL returns just the
    ///    last path component (the filename), which agents can't open.
    ///    Warp / iTerm2 both do this; matches user expectation.
    /// 2. **Raw image data** (`Cmd+Ctrl+Shift+4` screenshot to
    ///    clipboard, Preview "Edit → Copy" on an open image) →
    ///    spilled to `~/Library/Caches/kooky/pastes/screenshot-<ts>.png`,
    ///    then `backslashEscape(file.path)`. Agents (Claude / Cursor /
    ///    Codex) take a file path as input; storing the bytes inline
    ///    would dump base64 garbage into the prompt.
    /// 3. **Plain string** → raw, no escaping (we'd corrupt `ls -la`).
    ///    `bracketed-paste` mode already isolates it from shell parsing.
    static func readTerminalPasteText(from pb: NSPasteboard) -> String? {
        readTerminalPasteText(from: pb, fileURLs: pasteboardFileURLs(pb))
    }

    /// `fileURLs` is threaded in by `paste(from:host:plainText:deliver:)` so
    /// the ladder pays the pasteboard-server IPC once, not per tier.
    private static func readTerminalPasteText(from pb: NSPasteboard, fileURLs: [URL]?) -> String? {
        if let urls = fileURLs,
           let joined = backslashEscapedFileURLs(urls)
        {
            return joined
        }
        if pb.availableType(from: [.png, .tiff]) != nil,
           let cached = writePasteboardImageToCache(pb)
        {
            return backslashEscape(cached.path)
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            return text
        }
        return nil
    }

    /// Tier 1 of the paste precedence: pasted Finder files as local URLs.
    /// Single source for the fileURL-extraction dance `readTerminalPasteText`
    /// and the remote-paste snapshot share.
    private static func pasteboardFileURLs(_ pb: NSPasteboard) -> [URL]? {
        guard pb.availableType(from: [.fileURL]) != nil,
              let urls = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.filter(\.isFileURL),
              !urls.isEmpty else { return nil }
        return urls
    }

    /// Test seam for the remote-paste subprocess (`ssh mkdir` / `scp`).
    /// `nonisolated(unsafe)`: written once from a test before any upload
    /// runs, read from the upload's GCD thread — never mutated concurrently.
    nonisolated(unsafe) static var remotePasteProcessRunnerOverride: (@Sendable (String, [String], TimeInterval) -> Bool)?

    /// One-line entry for every paste site (surface ⌘V, right-click Paste,
    /// composer). When `host` is set and the pasteboard carries a file/image
    /// payload, uploads async and hands the escaped remote path(s) to
    /// `deliver` on the main actor — fail-closed beep when the transfer
    /// fails, so a dead connection never pastes a local path the remote
    /// can't read — and returns true. False = not a remote-upload paste;
    /// the caller falls through to its local paste path.
    @discardableResult
    static func pasteViaRemoteUpload(from pb: NSPasteboard, host: String?, deliver: @escaping @MainActor (String) -> Void) -> Bool {
        guard let host, let upload = remotePasteUpload(from: pb, host: host) else { return false }
        Task { @MainActor in
            if let text = await upload(), !text.isEmpty {
                deliver(text)
            } else {
                NSSound.beep()
            }
        }
        return true
    }

    /// Serial transcode lane shared by local AND remote image pastes:
    /// back-to-back pastes deliver in order, and the decode/encode buffers
    /// of tens-of-MB screenshot TIFFs never run concurrently. (The captured
    /// raw `Data` snapshots DO coexist while queued — the serialization
    /// bounds working-set peaks, not the queued inputs.)
    private static let pasteTranscodeQueue = DispatchQueue(label: "kooky.paste-transcode", qos: .userInitiated)

    /// THE paste entry for every site (surface ⌘V, right-click Paste,
    /// composer): owns all three tiers AND each tier's sync/async decision,
    /// so no caller can re-derive the precedence or get the ordering wrong.
    /// Remote upload (SSH workspace) wins, then a clipboard image transcodes
    /// off-main, then files/plain text deliver synchronously (cheap, and an
    /// async hop would reorder them against subsequent keystrokes for no
    /// benefit). `includePlainText: false` is the composer's variant: plain
    /// text falls through to NSTextView's native paste (undo coalescing),
    /// while file paths still deliver escaped. Returns false when nothing
    /// was handled — the caller falls back (or ignores the chord).
    @MainActor
    /// How a paste site wants PLAIN text (no files on the pasteboard)
    /// handled. Required, no default, on purpose: the unsafe combination —
    /// plain clipboard text delivered straight to the PTY, bypassing
    /// `clipboard-paste-protection` — is unrepresentable, and every future
    /// paste site must name its plain-text owner to compile.
    enum PlainTextHandling {
        /// Terminal sites: route through the engine's protected paste
        /// (`pasteFromClipboardViaCore` — read cb → safety check → consent).
        case viaCore(@MainActor () -> Bool)
        /// The composer: kooky handles files/images only; plain text stays
        /// with the caller's native paste (NSTextView undo coalescing).
        case callerHandles
    }

    /// One entry for every paste site (surface ⌘V, right-click Paste,
    /// composer): remote upload for SSH workspaces, off-main transcode for
    /// clipboard images, escaped paths for files, and per-site plain-text
    /// policy via `plainText`. Returns false when nothing was handled — the
    /// caller falls back (or ignores the chord).
    @MainActor
    static func paste(
        from pb: NSPasteboard,
        host: String?,
        plainText: PlainTextHandling,
        deliver: @escaping @MainActor (String) -> Void
    ) -> Bool {
        if pasteViaRemoteUpload(from: pb, host: host, deliver: deliver) { return true }
        // One pasteboard-server IPC for the whole local ladder — the image
        // tier, the plain-text fork, and the text tier all key on it.
        let fileURLs = pasteboardFileURLs(pb)
        if pasteImageAsync(from: pb, fileURLs: fileURLs, deliver: deliver) { return true }
        if fileURLs == nil {
            // File tiers deliver kooky-constructed escaped paths; only PLAIN
            // clipboard text forks per site policy.
            switch plainText {
            case .viaCore(let core): return core()
            case .callerHandles: return false
            }
        }
        guard let text = readTerminalPasteText(from: pb, fileURLs: fileURLs), !text.isEmpty else { return false }
        deliver(text)
        return true
    }

    /// Image tier of `paste(from:host:deliver:)`: a clipboard IMAGE needs a
    /// TIFF decode + PNG encode + disk write that froze the main thread for
    /// its whole duration — hundreds of ms for a Retina screenshot. The raw
    /// bytes are snapshotted HERE (the pasteboard can change under the hop);
    /// that snapshot is itself a size-proportional pasteboard-server copy
    /// still paid on the main thread — accepted, the decode+encode is the
    /// dominant cost. A keystroke typed mid-transcode reaches the PTY first
    /// — the same accepted window the remote-upload path has, far smaller.
    /// Returns false when the pasteboard has no raw image (or has real file
    /// URLs, which outrank the image tier).
    private static func pasteImageAsync(from pb: NSPasteboard, fileURLs: [URL]?, deliver: @escaping @MainActor (String) -> Void) -> Bool {
        guard fileURLs == nil, let raw = pasteboardRawImage(pb) else { return false }
        // Snapshot the plain-text representation NOW (Codex review): the old
        // synchronous path fell through to the string tier when the image
        // couldn't be transcoded — a corrupt TIFF, unwritable cache, or full
        // disk must deliver that text (browser image copies usually carry
        // one), not drop pastable content with a beep. Delivered even for
        // the composer's includePlainText:false — on the failure path,
        // content beats undo-coalescing purity.
        let fallbackText = pb.string(forType: .string)
        pasteTranscodeQueue.async {
            let path = writePasteImageToCache(raw)?.path
            DispatchQueue.main.async {
                if let path {
                    deliver(backslashEscape(path))
                } else if let fallbackText, !fallbackText.isEmpty {
                    deliver(fallbackText)
                } else {
                    NSSound.beep()
                }
            }
        }
        return true
    }

    /// SSH-workspace paste: pasted files / clipboard images must land on the
    /// REMOTE before a path gets injected — an agent over ssh can't open
    /// `/Users/...`. Returns nil when the pasteboard has no file or image
    /// payload. The payload is snapshotted synchronously — the pasteboard
    /// can change under an async hop — but only as URLs / raw bytes; the
    /// returned closure does everything slow off the main thread: a TIFF
    /// screenshot's PNG re-encode, then `ssh mkdir -p` + one `scp` per file
    /// into a fresh `/tmp/kooky-pastes-*` dir, resolving to the space-joined
    /// escaped remote paths (nil on any failure).
    static func remotePasteUpload(from pb: NSPasteboard, host: String) -> (@Sendable () async -> String?)? {
        let remoteDir = "/tmp/kooky-pastes-\(pasteFilenameTimestamp.string(from: Date()))-\(UUID().uuidString.prefix(8))"
        let work: @Sendable () -> String?
        if let urls = pasteboardFileURLs(pb) {
            let files = remotePasteDestinations(for: urls, remoteDir: remoteDir)
            work = { performRemotePasteUpload(files, to: host, remoteDir: remoteDir) }
        } else if let raw = pasteboardRawImage(pb) {
            work = {
                // Transcode rides the same serial lane as local pastes —
                // without it a burst of SSH screenshot pastes decodes
                // concurrently while local ones queue. The scp stays on the
                // caller's GCD thread (it blocks on waitUntilExit).
                guard let cached = pasteTranscodeQueue.sync(execute: { writePasteImageToCache(raw) })
                else { return nil }
                let files = remotePasteDestinations(for: [cached], remoteDir: remoteDir)
                return performRemotePasteUpload(files, to: host, remoteDir: remoteDir)
            }
        } else {
            return nil
        }
        return {
            await withCheckedContinuation { continuation in
                // GCD, not the cooperative pool — `waitUntilExit` blocks its
                // thread for up to the scp timeout.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: work())
                }
            }
        }
    }

    /// Connection-multiplex options shared by the kooky-ssh MAIN connection
    /// (see `sshWrapperScript`) and the paste upload's ssh/scp below. The
    /// SAME ControlPath template on both sides is load-bearing: the
    /// workspace's interactively authenticated connection becomes the master
    /// the background upload rides — a headless scp can never prompt, so
    /// without this reuse a password / interactive-passphrase workspace
    /// could never paste files at all. Repeat pastes within 30s also reuse
    /// the master (one TCP+auth handshake per paste burst, not per file).
    /// /tmp keeps the socket path well under the 104-byte sun_path limit;
    /// %C hashes host+port+user.
    static let sshMultiplexOptions = [
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=/tmp/kooky-ssh-%C",
        "-o", "ControlPersist=30",
    ]

    private static let remotePasteSSHOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
    ] + sshMultiplexOptions

    /// mkdir for this paste plus a piggybacked expiry sweep: kooky-pastes
    /// dirs older than an hour are removed on the way (ample time for any
    /// agent to consume the pasted path). `;` — not `&&` — so a sweep
    /// failure (another user's dir, say) can't fail the mkdir; errors muted.
    private static func remotePasteMkdirCommand(_ remoteDir: String) -> String {
        "find /tmp -maxdepth 1 -name 'kooky-pastes-*' -type d -mmin +60 -exec rm -rf {} + 2>/dev/null; mkdir -p -- \(quote(remoteDir))"
    }

    private static func performRemotePasteUpload(_ files: [(local: URL, remotePath: String)], to host: String, remoteDir: String) -> String? {
        guard runRemotePasteProcess(
            "/usr/bin/ssh",
            remotePasteSSHOptions + [host, remotePasteMkdirCommand(remoteDir)],
            timeout: 20
        ) else { return nil }
        for file in files {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: file.local.path, isDirectory: &isDirectory)
            var args = remotePasteSSHOptions
            if isDirectory.boolValue { args.append("-r") }
            args.append(contentsOf: [file.local.path, "\(host):\(file.remotePath)"])
            guard runRemotePasteProcess("/usr/bin/scp", args, timeout: 60) else { return nil }
        }
        return files.map { backslashEscape($0.remotePath) }.joined(separator: " ")
    }

    /// Runs ssh/scp to completion on the calling (GCD) thread with a
    /// watchdog kill at `timeout`. All stdio goes to /dev/null — BatchMode
    /// never prompts, and an unread pipe on a chatty connection is the same
    /// fill-the-buffer deadlock class `runGit` hit (v0.33.0).
    private static func runRemotePasteProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Bool {
        if let runner = remotePasteProcessRunnerOverride {
            return runner(executable, arguments, timeout)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("kooky: remote paste could not launch %@: %@", executable, error.localizedDescription)
            return false
        }
        let watchdog = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            NSLog("kooky: remote paste %@ exited %d", executable, process.terminationStatus)
            return false
        }
        return true
    }

    /// Maps each local URL to its remote destination path, deduping
    /// same-named files with a `-2` / `-3` stem suffix.
    private static func remotePasteDestinations(for urls: [URL], remoteDir: String) -> [(local: URL, remotePath: String)] {
        var counts: [String: Int] = [:]
        return urls.map { url in
            let base = sanitizedRemotePasteFilename(url.lastPathComponent)
            let seen = counts[base, default: 0] + 1
            counts[base] = seen
            let name: String
            if seen == 1 {
                name = base
            } else {
                let ns = base as NSString
                let ext = ns.pathExtension
                name = ext.isEmpty ? "\(base)-\(seen)" : "\(ns.deletingPathExtension)-\(seen).\(ext)"
            }
            return (local: url, remotePath: "\(remoteDir)/\(name)")
        }
    }

    /// Remote-safe filename: keep `A-Za-z0-9 . _ -`, everything else `_`.
    /// The remote path lands in an `scp` destination, which the REMOTE shell
    /// word-splits and glob-expands — the conservative set sidesteps that
    /// quoting problem entirely.
    private static func sanitizedRemotePasteFilename(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-":
                out.unicodeScalars.append(scalar)
            default:
                out.append("_")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return trimmed.isEmpty ? "paste" : trimmed
    }

    /// Cheap probe used by the right-click "Paste" menu's enabled gate.
    /// Mirrors `readTerminalPasteText`'s precedence but skips the
    /// image-to-disk write so a menu open never spills cache files.
    /// `availableType(...)` is preferred over `pb.string(...)` for the
    /// string check — `pb.string` materialises the full pasted bytes
    /// into a Swift heap copy (~100ms for a 10MB clipboard) just for
    /// an emptiness check; `availableType` is constant-time.
    static func pasteboardHasTerminalPasteContent(_ pb: NSPasteboard) -> Bool {
        if pb.availableType(from: [.fileURL]) != nil,
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.contains(where: { $0.isFileURL })
        {
            return true
        }
        if pb.availableType(from: [.png, .tiff, .string]) != nil {
            return true
        }
        return false
    }

    /// Spill a pasteboard image to a kooky-owned cache file. Returns
    /// the resulting URL on success. Prefers `.png` bytes verbatim;
    /// re-encodes `.tiff` to PNG via `NSBitmapImageRep` when only TIFF
    /// is offered (Cmd+Shift+3 screenshots land as TIFF, not PNG) —
    /// agents accept PNG universally, TIFF support is uneven.
    private static func writePasteboardImageToCache(_ pb: NSPasteboard) -> URL? {
        guard let raw = pasteboardRawImage(pb) else { return nil }
        return writePasteImageToCache(raw)
    }

    /// Image bytes exactly as the pasteboard offers them (PNG preferred).
    /// The potentially slow TIFF→PNG re-encode is deferred to
    /// `writePasteImageToCache` so remote paste can run it off the main
    /// thread — Retina screenshot TIFFs run tens of MB.
    private struct RawPasteImage {
        let data: Data
        let isPNG: Bool
    }

    private static func pasteboardRawImage(_ pb: NSPasteboard) -> RawPasteImage? {
        if let direct = pb.data(forType: .png) { return RawPasteImage(data: direct, isPNG: true) }
        if let tiff = pb.data(forType: .tiff) { return RawPasteImage(data: tiff, isPNG: false) }
        return nil
    }

    /// Encode (TIFF → PNG when needed — Cmd+Shift+3 screenshots land as
    /// TIFF; agents accept PNG universally) and spill to the pastes cache.
    private static func writePasteImageToCache(_ raw: RawPasteImage) -> URL? {
        guard let data = encodedPNG(raw) else { return nil }
        let ts = pasteFilenameTimestamp.string(from: Date())
        let file = pastesCacheDirectory.appendingPathComponent("screenshot-\(ts).png")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    private static func encodedPNG(_ raw: RawPasteImage) -> Data? {
        if raw.isPNG { return raw.data }
        if let rep = NSBitmapImageRep(data: raw.data),
           let encoded = rep.representation(using: .png, properties: [:])
        {
            return encoded
        }
        return nil
    }

    private static let pasteFilenameTimestamp: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt
    }()

    /// Lazy-created `~/Library/Caches/kooky/pastes/`. Mirrors the
    /// `kookyBinDirectory` / `hooksDirectory` pattern: one
    /// `createDirectory` at first access, all subsequent paste-spills
    /// skip the FS check.
    private static let pastesCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("kooky/pastes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Sweep stale paste-cache files. macOS evicts Caches under disk
    /// pressure but only when free space is critical — meanwhile a
    /// daily-paste-screenshots workflow accumulates GBs. Call at app
    /// startup via `Task.detached` so it doesn't block launch. The
    /// 30-day default matches Chrome / Firefox HTTP-cache policy.
    static func prunePastesCache(olderThan: TimeInterval = 30 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: pastesCacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        for url in contents {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mod, mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static let zshPath = "/bin/zsh"
    static let bashPath = "/bin/bash"
    // fish has no canonical system path (homebrew installs it under
    // /opt/homebrew or /usr/local), so this is only a defensive fallback —
    // callers resolve the real binary from `$SHELL`.
    static let fishPath = "/opt/homebrew/bin/fish"
    static let zdotdirKey = "ZDOTDIR"

    /// `~/Library/Application Support/kooky/<subpath>` — single source for the
    /// app's private support locations. Path-only; callers create the directory
    /// when they need it (some of these are roots, not leaf dirs).
    /// Single source for paths under `~/Library/Application Support/kooky/`
    /// — internal (not private) so other subsystems (e.g. `RecentFolders`)
    /// don't grow their own spelling of the root.
    static func kookyAppSupport(_ subpath: String, isDirectory: Bool) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("kooky/\(subpath)", isDirectory: isDirectory)
    }

    /// Directory we prepend to spawned-shell `PATH` so wrapper scripts (e.g.
    /// `claude` shim) get found before the real binaries on disk.
    static let kookyBinDirectory: String = {
        let dir = kookyAppSupport("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    /// Path to the generated Claude Code hooks JSON. Passed to `claude` via
    /// `--settings <path>` by the wrapper script when `KOOKY_SURFACE_ID` is set.
    static let claudeHooksPath: String = {
        hooksDirectory.appendingPathComponent("claude.json").path
    }()

    /// Path to the kooky-managed Gemini system-defaults file. Surfaced to
    /// gemini-cli via `GEMINI_CLI_SYSTEM_SETTINGS_PATH`. Hook arrays merge
    /// with CONCAT semantics across tiers (verified in google-gemini/gemini-cli
    /// `settingsSchema.ts`), so this layers on top of user hooks instead of
    /// replacing them — non-intrusive.
    static let geminiDefaultsPath: String = {
        hooksDirectory.appendingPathComponent("gemini-defaults.json").path
    }()

    /// Path to the kooky-managed Copilot hooks file. Copilot CLI auto-loads
    /// every `~/.copilot/hooks/*.json` and merges events across files, so a
    /// dedicated `kooky.json` co-exists with anything the user has dropped
    /// in there. Pure path computation — the directory is materialised
    /// (and the file written) only when `~/.copilot/` already exists, so
    /// non-Copilot users don't get an empty kooky-owned vendor dir in their
    /// home. We don't honor `COPILOT_HOME` from the user's shell here —
    /// kooky.app runs out-of-process, can't see interactive shell env — so
    /// users who customise `COPILOT_HOME` would drop the file themselves.
    static let copilotHooksPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/kooky.json").path
    }()

    static let cursorHooksPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/hooks.json").path
    }()

    static let droidSettingsPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory/settings.json").path
    }()

    static let antigravityHooksPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/config/hooks.json").path
    }()

    /// Reasonix's global settings file. Note this is the user's WHOLE global
    /// config (providers, UI, hooks), not a hooks-only file — `REASONIX_HOME`
    /// could relocate it, but kooky must not set that: it also moves provider
    /// credentials, which would silently break the user's API keys.
    static let reasonixSettingsPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".reasonix/settings.json").path
    }()

    static let kimiConfigPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/config.toml").path
    }()

    static let ampPluginPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amp/plugins/kooky.ts").path
    }()

    /// XDG plugin directory OpenCode auto-loads at startup. Honors
    /// `XDG_CONFIG_HOME` when set (the OpenCode launch is a child of the same
    /// shell, so a user-relocated config dir routes consistently between us
    /// and OpenCode); falls back to `~/.config`.
    static let opencodePluginPath: String = {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        }
        let dir = base.appendingPathComponent("opencode/plugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kooky.ts").path
    }()

    private static let hooksDirectory: URL = {
        let dir = kookyAppSupport("hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let kiroACPRecordDirectory: URL = {
        let dir = kookyAppSupport("kiro-acp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func kiroACPRecordPath(for sessionId: UUID) -> String {
        kiroACPRecordDirectory.appendingPathComponent("\(sessionId.uuidString).jsonl").path
    }

    /// Absolute path to the `KookyHook` helper we exec for IPC. We do NOT run
    /// it in place from the bundle: macOS Gatekeeper silently SIGKILLs an
    /// adhoc-signed (unnotarized) *secondary* binary the first time its cdhash
    /// is assessed from inside an app in `/Applications`, and a helper we exec
    /// ourselves has no "Open Anyway" affordance to clear that the way the
    /// main binary does — so every build that changes KookyHook's code (new
    /// cdhash) would break manual agent detection, Claude hooks, and tool
    /// pills on first install. The exact same bytes run fine from a path
    /// outside `/Applications` (verified: a /tmp copy exits 0 where the
    /// bundled one exits 137). So copy KookyHook into Application Support — a
    /// location Gatekeeper doesn't exec-assess — on launch and run the copy.
    /// Re-copied every launch so a freshly-installed build's helper supersedes
    /// the stale copy. Falls back to the in-bundle path if the copy fails
    /// (dev `swift run` runs fine in place from `.build/<config>/` anyway).
    static let kookyHookBinaryPath: String = mirroredHelperBinaryPath(name: "KookyHook")

    /// Same Gatekeeper escape for the control CLI: external tools exec this
    /// path (`~/Library/Application Support/kooky/bin/kooky-cli`), which
    /// stays valid across app updates AND dodges the /Applications
    /// exec-assessment kill the in-bundle path is subject to. AppDelegate
    /// touches this at launch so the mirror refreshes with every build —
    /// the returned VALUE currently has no reader; the refresh side effect
    /// is the contract (the path is documented in the README for external
    /// tools, and a future Settings page may render it).
    static let kookyCLIBinaryPath: String = mirroredHelperBinaryPath(name: "kooky-cli")

    /// One name per helper, everywhere: the SPM target names ARE the shipped
    /// binary names, so dev builds and the packaged app resolve identically.
    private static func mirroredHelperBinaryPath(name: String) -> String {
        guard let exe = Bundle.main.executablePath else { return "" }
        let bundled = (exe as NSString).deletingLastPathComponent + "/" + name
        let fm = FileManager.default
        // No bundled helper next to us (e.g. the xctest runner) → return the
        // bundle path and DON'T touch the Application Support copy, so
        // running the test suite can't clobber the helper a live kooky
        // depends on.
        guard fm.fileExists(atPath: bundled) else { return bundled }
        // `kookyBinDirectory` is the App Support `kooky/bin` dir (already created).
        let dest = (kookyBinDirectory as NSString).appendingPathComponent(name)
        // Stat gate on the pre-first-frame path: `copyItem` preserves the
        // source's mtime, so equal size+mtime means the installed copy IS
        // this build's helper — no need to read ~245KB of binaries just to
        // decide "don't copy". A rebuilt helper always changes its mtime,
        // so supersede-on-upgrade still triggers. The exec bit is
        // re-asserted even on the fast path: an externally stripped +x
        // (backup restore, security tooling) must heal, or every hook goes
        // silently dead.
        if let destAttrs = try? fm.attributesOfItem(atPath: dest),
           let srcAttrs = try? fm.attributesOfItem(atPath: bundled),
           (destAttrs[.size] as? NSNumber) == (srcAttrs[.size] as? NSNumber),
           (destAttrs[.modificationDate] as? Date) == (srcAttrs[.modificationDate] as? Date) {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            return dest
        }
        do {
            try? fm.removeItem(atPath: dest)  // throws when absent — copyItem just needs a clear dest
            try fm.copyItem(atPath: bundled, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            return dest
        } catch {
            return bundled
        }
    }

    /// Per-session env vars our wrappers + hook helper read. Caller supplies
    /// the surface UUID; everything else is process-wide. PATH prepends
    /// `kookyBinDirectory` so wrapper shims resolve before the real binaries.
    /// `claudeCustomSettingsAgentId`, when set, routes `KOOKY_HOOKS_PATH` to
    /// that custom agent's per-agent Claude settings file (endpoint / key)
    /// instead of the shared `claude.json`.
    static func kookyEnvironment(
        for sessionId: UUID,
        claudeCustomSettingsAgentId: String? = nil
    ) -> [String: String] {
        let parentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        let hooksPath = claudeCustomSettingsAgentId.map(claudeCustomSettingsPath(agentId:)) ?? claudeHooksPath
        let kiroRecordPath = kiroACPRecordPath(for: sessionId)
        // A restored tab reuses its surface UUID. Start this Kiro process with
        // a clean ACP trace so an old `session/new` response cannot flash a
        // stale conversation id before the new/resumed session records itself.
        try? FileManager.default.removeItem(atPath: kiroRecordPath)
        var env: [String: String] = [
            "KOOKY_SURFACE_ID": sessionId.uuidString,
            "KOOKY_HOOKS_PATH": hooksPath,
            "KOOKY_BIN_DIR": kookyBinDirectory,
            "KOOKY_HOOK_BIN": kookyHookBinaryPath,
            "KOOKY_KIRO_ACP_RECORD_PATH": kiroRecordPath,
            // KOOKY_AGENT_MARKERS is deliberately NOT set locally: the
            // KookyHook socket is the local status channel. OSC-title markers
            // are the ssh-remote fallback (the remote bootstrap exports the
            // var there), so emitting them locally would double-report and
            // risk leaking OSC bytes into a redirected agent's stdout.
            "PATH": "\(kookyBinDirectory):\(parentPath)",
            // Gemini CLI loads this as the lowest-precedence settings tier,
            // but its hooks arrays use CONCAT-merge — so our entries fire
            // alongside whatever the user has in `~/.gemini/settings.json`,
            // not instead of. The file is ours, regenerated each launch.
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": geminiDefaultsPath,
            // libghostty defaults TERM to "xterm-ghostty"; not every system
            // ships its terminfo. Pinning to xterm-256color gives all TUIs a
            // well-known capability profile.
            "TERM": "xterm-256color",
        ]
        // Preserve the user's original ZDOTDIR (if they had one — rare, mostly
        // dotfile organizers). The wrapper rc consumes this to restore ZDOTDIR
        // after sourcing ~/.zshrc; child installer scripts then see the real
        // value (or no ZDOTDIR at all) and write PATH exports to ~/.zshrc
        // instead of our ephemeral wrapper rc.
        if let original = ProcessInfo.processInfo.environment["ZDOTDIR"], !original.isEmpty {
            env["KOOKY_ORIGINAL_ZDOTDIR"] = original
        }
        return env
    }

    /// Writes wrapper shims, hook configs, and the OpenCode plugin to disk.
    /// Idempotent — call on every app launch so each agent's hook command
    /// tracks the latest `KookyHook` location.
    static func installAgentHooks(sshRemoteAgentDetection: Bool = false) {
        writeWrapper(name: "claude", script: claudeWrapperScript)
        writeWrapper(name: "codex", script: codexWrapperScript)
        // Gemini's own lifecycle hooks (via `GEMINI_CLI_SYSTEM_SETTINGS_PATH`)
        // drive the finer running/attention/ended states, but their earliest
        // event is `BeforeAgent` (fires on the first prompt, not on launch) —
        // so a manually-typed `gemini` showed no icon until you messaged it.
        // The bracket wrapper adds the immediate launch promotion every other
        // agent gets; it coexists with the gemini hooks (same-value pings dedup).
        writeWrapper(name: "gemini", script: bracketWrapperScript(slug: "gemini"))
        writeWrapper(name: "opencode", script: bracketWrapperScript(slug: "opencode"))
        writeWrapper(name: "amp", script: bracketWrapperScript(slug: "amp"))
        writeWrapper(name: "cursor-agent", script: bracketWrapperScript(slug: "cursor-agent"))
        writeWrapper(name: "copilot", script: bracketWrapperScript(slug: "copilot"))
        writeWrapper(name: "grok", script: bracketWrapperScript(slug: "grok"))
        writeWrapper(name: "agy", script: antigravityWrapperScript)
        writeWrapper(name: "kimi", script: bracketWrapperScript(slug: "kimi"))
        writeWrapper(name: "pi", script: bracketWrapperScript(slug: "pi"))
        writeWrapper(name: "omp", script: bracketWrapperScript(slug: "omp"))
        writeWrapper(name: "reasonix", script: bracketWrapperScript(slug: "reasonix"))
        writeWrapper(name: "kiro-cli", script: kiroWrapperScript)
        writeWrapper(name: "droid", script: bracketWrapperScript(slug: "droid"))
        // Private ssh entry point for SSH workspaces — always installed,
        // unlike the public `ssh` shim below (user-setting gated because it
        // changes manually typed ssh). Same script; the filename is what
        // unlocks the `--` remote-agent protocol.
        writeWrapper(name: "kooky-ssh", script: sshWrapperScript)
        refreshSshRemoteAgentDetection(enabled: sshRemoteAgentDetection)

        let hookCmd = kookyHookBinaryPath
        writeJSON(at: claudeHooksPath, object: claudeHooksObject(hookCmd: hookCmd))
        writeJSON(at: geminiDefaultsPath, object: geminiDefaultsObject(hookCmd: hookCmd))
        installCopilotHooksIfPresent(hookCmd: hookCmd)
        installCursorHooksIfPresent(hookCmd: hookCmd)
        installDroidHooksIfPresent(hookCmd: hookCmd)
        installReasonixHooksIfPresent(hookCmd: hookCmd)
        installAntigravityHooksIfPresent(hookCmd: hookCmd)
        installKimiHooksIfPresent(hookCmd: hookCmd)
        installAmpPluginIfPresent()
        writeManagedFile(at: opencodePluginPath, contents: opencodePluginScript)
        installPiStyleExtensionIfPresent(home: ".pi", slug: "pi")
        installPiStyleExtensionIfPresent(home: ".omp", slug: "omp")
        installFishVendorConf()
        // Grok doesn't need a hook for resume: kooky assigns its UUID before
        // launch via `--session-id`, then uses `--resume` next time.
        //
        // Pi and Oh My Pi (a fork of Pi, so the same extension API) each ride
        // a kooky-managed TypeScript extension, installed only when that
        // agent's home exists — see `installPiStyleExtensionIfPresent`. Both
        // subscribe to session / turn events and ping KookyHook, same model as
        // the OpenCode plugin — so the dot also reaches `attention` (waiting
        // on you), not just the bracket wrapper's running/ended.
        //
        // Kiro's exact id comes from its per-surface ACP recording path
        // (`KIRO_ACP_RECORD_PATH`), not a user agent config. We wrap
        // `kiro-cli`, never `kiro` (the IDE launcher).
    }

    static func refreshSshRemoteAgentDetection(enabled: Bool) {
        if enabled {
            writeWrapper(name: "ssh", script: sshWrapperScript)
        } else {
            removeManagedWrapper(
                name: "ssh",
                markers: ["KOOKY_DISABLE_SSH_AGENT_MARKERS", "kooky-agent-markers"]
            )
        }
    }

    /// Writes the Copilot hooks JSON only when the user already has a
    /// `~/.copilot/` directory — i.e. they've at least run Copilot CLI once.
    /// Skips otherwise so kooky doesn't pre-stage a vendor namespace for
    /// users who may never install Copilot. Installing Copilot later then
    /// requires one kooky restart to pick up the hooks (acceptable: the
    /// bracket wrapper still gives running/ended on the first run).
    private static func installCopilotHooksIfPresent(hookCmd: String) {
        let copilotHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
        guard FileManager.default.fileExists(atPath: copilotHome.path) else { return }
        let hooksDir = copilotHome.appendingPathComponent("hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        writeManagedJSON(at: copilotHooksPath, object: copilotHooksObject(hookCmd: hookCmd))
    }

    private static let hookStdinMarker = "--hook-stdin"
    private static let managedHookEnvironmentMarker = "KOOKY_MANAGED_HOOK=1"

    private static func hookCommand(hookCmd: String, slug: String, state: HookEvent) -> String {
        hookCommand(hookCmd: hookCmd, slug: slug, token: state.rawValue)
    }

    /// `token` is what KookyHook receives as its event argument: a lifecycle
    /// state for the mapped events, or the agent's raw event name for the
    /// passthrough pair (which routes to the tool-payload parser instead).
    /// Both forms must keep `quote(hookCmd)` — hooks run through `/bin/sh -c`
    /// and break under an app path containing spaces — and `hookStdinMarker`,
    /// which is what makes KookyHook read stdin at all.
    private static func hookCommand(hookCmd: String, slug: String, token: String) -> String {
        "\(managedHookEnvironmentMarker) \(quote(hookCmd)) \(slug) \(token) \(hookStdinMarker)"
    }

    /// Replaces kooky's own previously-written entries under `hooks[event]`
    /// while preserving the user's. Returns false when the key exists with an
    /// unexpected type — the caller must then bail rather than overwrite a
    /// config we failed to understand.
    ///
    /// The `?? (… == nil ? [] : nil)` coercion carries that whole rule
    /// (absent → start empty; present-but-wrong-type → refuse), which is why
    /// it lives here instead of being hand-copied per agent.
    private static func mergeManagedEntry(
        into hooks: inout [String: Any],
        event: String,
        entry: [String: Any]
    ) -> Bool {
        guard var entries = hooks[event] as? [[String: Any]] ?? (hooks[event] == nil ? [] : nil)
        else { return false }
        entries.removeAll(where: containsManagedHook)
        entries.append(entry)
        hooks[event] = entries
        return true
    }

    /// Cursor has one mergeable user hooks file. Preserve every user entry,
    /// replacing only commands carrying kooky's process-local marker.
    static func cursorHooksObject(
        existing: [String: Any] = [:],
        hookCmd: String
    ) -> [String: Any]? {
        var object = existing
        if object["version"] == nil { object["version"] = 1 }
        guard var hooks = object["hooks"] as? [String: Any] ?? (object["hooks"] == nil ? [:] : nil)
        else { return nil }
        let events: [(String, HookEvent)] = [
            ("sessionStart", .running),
            ("beforeSubmitPrompt", .running),
            ("stop", .attention),
            ("sessionEnd", .ended),
        ]
        for (event, state) in events {
            let entry: [String: Any] = ["command": hookCommand(hookCmd: hookCmd, slug: "cursor-agent", state: state)]
            guard mergeManagedEntry(into: &hooks, event: event, entry: entry) else { return nil }
        }
        object["hooks"] = hooks
        return object
    }

    /// Reasonix keys its hooks by Claude's event names but takes a flatter
    /// entry (`{command, match, timeout}` — no `matcher` wrapper, no `type`),
    /// so it gets its own builder rather than `hooksObject`. The file is the
    /// user's whole global settings, not a hooks-only file, so every
    /// unrelated key and user hook is preserved and only kooky's own marked
    /// entries are replaced.
    ///
    /// `Notification` covers "waiting for tool approval" natively, which is
    /// why this maps it to `.attention` alongside `Stop`.
    ///
    /// `PreToolUse` and `UserPromptSubmit` are BLOCKING events: a hook that
    /// times out, or exits with status 2, stops the agent's own work. The
    /// KookyHook ping is a local unix-socket write that returns in
    /// milliseconds and exits 1 (never 2) when the socket is gone, so neither
    /// failure mode can block the user's agent — anything added here later
    /// must keep that property.
    static func reasonixHooksObject(
        existing: [String: Any] = [:],
        hookCmd: String
    ) -> [String: Any]? {
        var object = existing
        guard var hooks = object["hooks"] as? [String: Any] ?? (object["hooks"] == nil ? [:] : nil)
        else { return nil }

        // nil state = passthrough: ship the raw event name so KookyHook reads
        // the payload off stdin for the activity pill. Those are also the only
        // entries that take `match`, an anchored regex over the tool name —
        // "" and "*" both mean every tool, written explicitly so a later edit
        // can't read an absent key as "no tools".
        let events: [(name: String, state: HookEvent?)] = [
            ("SessionStart", .running),
            ("UserPromptSubmit", .running),
            ("Stop", .attention),
            // Stop's failure twin — a turn that ended badly still hands
            // control back to the user, so it reads the same on the dot.
            ("StopFailure", .attention),
            ("Notification", .attention),
            ("SessionEnd", .ended),
            ("PreToolUse", nil),
            ("PostToolUse", nil),
            // Reasonix fires this instead of PostToolUse when the tool
            // errored. `parseToolEventPayload` already forces success=false
            // for it, so the pill goes red immediately rather than waiting on
            // the `tool_response` heuristic (or the 60s stall timer).
            ("PostToolUseFailure", nil),
        ]
        for (name, state) in events {
            var entry: [String: Any] = [
                "command": hookCommand(hookCmd: hookCmd, slug: "reasonix", token: state?.rawValue ?? name),
                "timeout": reasonixHookTimeoutMilliseconds,
            ]
            if state == nil { entry["match"] = "*" }
            guard mergeManagedEntry(into: &hooks, event: name, entry: entry) else { return nil }
        }

        object["hooks"] = hooks
        return object
    }

    /// Milliseconds — see `reasonixHooksObject`. Comfortably above a local
    /// unix-socket round trip while staying under Reasonix's own 5000ms
    /// default for blocking events.
    private static let reasonixHookTimeoutMilliseconds = 3000

    /// Droid uses Claude-style matcher groups under the `hooks` key in its
    /// user settings file. Merge a dedicated no-matcher group per event while
    /// preserving every unrelated setting and user hook.
    static func droidHooksObject(
        existing: [String: Any] = [:],
        hookCmd: String
    ) -> [String: Any]? {
        var object = existing
        guard var hooks = object["hooks"] as? [String: Any] ?? (object["hooks"] == nil ? [:] : nil)
        else { return nil }
        let events: [(String, HookEvent)] = [
            ("SessionStart", .running),
            ("UserPromptSubmit", .running),
            ("Stop", .attention),
            ("Notification", .attention),
            ("SessionEnd", .ended),
        ]
        for (event, state) in events {
            let group: [String: Any] = [
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": hookCommand(hookCmd: hookCmd, slug: "droid", state: state),
                    "timeout": 5,
                ]],
            ]
            guard mergeManagedEntry(into: &hooks, event: event, entry: group) else { return nil }
        }
        object["hooks"] = hooks
        return object
    }

    /// Antigravity's hooks file is keyed by named hook collections, so one
    /// kooky-owned key composes without touching any neighboring collection.
    static func antigravityHooksObject(
        existing: [String: Any] = [:],
        hookCmd: String
    ) -> [String: Any] {
        var object = existing
        let handler: (HookEvent) -> [String: Any] = { state in
            [
                "type": "command",
                "command": hookCommand(hookCmd: hookCmd, slug: "agy", state: state),
                "timeout": 5,
            ]
        }
        object["kooky-managed-do-not-edit"] = [
            "PreInvocation": [handler(.running)],
            "PostInvocation": [handler(.attention)],
            "Stop": [handler(.attention)],
        ]
        return object
    }

    private static func installCursorHooksIfPresent(hookCmd: String) {
        installMergedJSONIfVendorPresent(
            vendorHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor"),
            path: cursorHooksPath
        ) { cursorHooksObject(existing: $0, hookCmd: hookCmd) }
    }

    private static func installDroidHooksIfPresent(hookCmd: String) {
        installMergedJSONIfVendorPresent(
            vendorHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory"),
            path: droidSettingsPath
        ) { droidHooksObject(existing: $0, hookCmd: hookCmd) }
    }

    private static func installReasonixHooksIfPresent(hookCmd: String) {
        installMergedJSONIfVendorPresent(
            vendorHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".reasonix"),
            path: reasonixSettingsPath
        ) { reasonixHooksObject(existing: $0, hookCmd: hookCmd) }
    }

    private static func installAntigravityHooksIfPresent(hookCmd: String) {
        installMergedJSONIfVendorPresent(
            vendorHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini"),
            path: antigravityHooksPath
        ) { antigravityHooksObject(existing: $0, hookCmd: hookCmd) }
    }

    private static func installMergedJSONIfVendorPresent(
        vendorHome: URL,
        path: String,
        transform: ([String: Any]) -> [String: Any]?
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vendorHome.path) else { return }
        let url = URL(fileURLWithPath: path)
        let existing: [String: Any]
        if fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }  // malformed user config: never overwrite it
            existing = parsed
        } else {
            existing = [:]
        }
        guard let merged = transform(existing) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writeJSON(at: path, object: merged)
    }

    private static func containsManagedHook(_ value: [String: Any]) -> Bool {
        containsManagedHookValue(value)
    }

    private static func containsManagedHookValue(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.contains(managedHookEnvironmentMarker)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains(where: containsManagedHookValue)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsManagedHookValue)
        }
        return false
    }

    /// Appends a clearly delimited block to Kimi's TOML. The user's bytes
    /// outside that block are preserved verbatim; malformed half-markers make
    /// us skip the write rather than guessing where their config ends.
    static func kimiConfigWithManagedHooks(existing: String, hookCmd: String) -> String? {
        let begin = "# kooky-managed-do-not-edit hooks begin"
        let end = "# kooky-managed-do-not-edit hooks end"
        let hasBegin = existing.contains(begin)
        let hasEnd = existing.contains(end)
        guard hasBegin == hasEnd else { return nil }

        var base = existing
        if hasBegin,
           let start = base.range(of: begin),
           let finish = base.range(of: end, range: start.upperBound..<base.endIndex) {
            var upper = finish.upperBound
            if upper < base.endIndex, base[upper] == "\n" {
                upper = base.index(after: upper)
            }
            base.removeSubrange(start.lowerBound..<upper)
        }

        let events: [(String, HookEvent)] = [
            ("SessionStart", .running),
            ("UserPromptSubmit", .running),
            ("Stop", .attention),
            ("SessionEnd", .ended),
        ]
        let rules = events.map { event, state in
            let command = hookCommand(hookCmd: hookCmd, slug: "kimi", state: state)
            return """
            [[hooks]]
            event = "\(event)"
            command = "\(tomlBasicString(command))"
            timeout = 5
            """
        }.joined(separator: "\n\n")
        let block = "\(begin)\n\(rules)\n\(end)\n"
        guard !base.isEmpty else { return block }
        let separator = base.hasSuffix("\n\n") ? "" : (base.hasSuffix("\n") ? "\n" : "\n\n")
        return "\(base)\(separator)\(block)"
    }

    private static func tomlBasicString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func installKimiHooksIfPresent(hookCmd: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
        guard FileManager.default.fileExists(atPath: home.path) else { return }
        let existing = (try? String(contentsOfFile: kimiConfigPath, encoding: .utf8)) ?? ""
        guard let merged = kimiConfigWithManagedHooks(existing: existing, hookCmd: hookCmd),
              merged != existing else { return }
        try? merged.write(toFile: kimiConfigPath, atomically: true, encoding: .utf8)
    }

    private static func installAmpPluginIfPresent() {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amp", isDirectory: true)
        guard FileManager.default.fileExists(atPath: home.path) else { return }
        let url = URL(fileURLWithPath: ampPluginPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writeManagedFile(at: ampPluginPath, contents: ampPluginScript)
    }

    /// Writes a Pi-family extension only when the user already has that
    /// agent's home directory — i.e. they've run it at least once. Like the
    /// Copilot hooks, this avoids pre-staging a vendor namespace for users who
    /// may never install the agent; the bracket wrapper still gives
    /// running/ended on the first run, and a kooky restart picks up the
    /// extension once the directory exists. Both agents auto-load every `*.ts`
    /// in `<home>/agent/extensions/`.
    ///
    /// `slug` is the binary name, which is also the agent id KookyHook routes
    /// on — so the same script serves `pi` and `omp` with only that token
    /// changing.
    private static func installPiStyleExtensionIfPresent(home: String, slug: String) {
        let fm = FileManager.default
        let agentHome = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(home, isDirectory: true)
        guard fm.fileExists(atPath: agentHome.path) else { return }

        // A named profile (`omp --profile work`, reachable from an agent's
        // launch options) reads extensions from its OWN agent dir and never
        // the default one, so the status dot and tool pills would go missing
        // there. Only profiles that already exist are written — same
        // don't-pre-stage-a-vendor-namespace rule as the home check above.
        let profilesRoot = agentHome.appendingPathComponent("profiles", isDirectory: true)
        let profileHomes = (try? fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { isDirectory($0) } ?? []

        for root in [agentHome] + profileHomes {
            let dir = root.appendingPathComponent("agent/extensions", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            writeManagedFile(
                at: dir.appendingPathComponent("kooky.ts").path,
                contents: piStyleExtensionScript(slug: slug)
            )
        }
    }

    /// Pi-family extension (TypeScript, auto-loaded from
    /// `<agent home>/agent/extensions/`). Subscribes to the agent's lifecycle
    /// events and pings KookyHook so the sidebar dot tracks per-session
    /// activity — running while a turn executes, attention when the turn ends
    /// and the agent waits on the user. Mirrors the OpenCode plugin: gated on
    /// `KOOKY_SURFACE_ID`, reads `KOOKY_HOOK_BIN` from the env kooky injects,
    /// and carries the managed marker so a user edit isn't clobbered.
    ///
    /// Shared verbatim by Pi and Oh My Pi — omp is a fork of pi, so the
    /// extension API (`pi.on` / `pi.exec` / `ctx.sessionManager`) and every
    /// event name below are identical across the two. Only `slug` differs; it
    /// is the agent id KookyHook attributes the ping to.
    static func piStyleExtensionScript(slug: String) -> String {
        """
    // \(managedFileMarker) — pings KookyHook on \(slug)'s session / turn / tool
    // events so the sidebar agent dot tracks per-session activity (running
    // while a turn runs, attention when it ends and waits on you), the pane
    // status bar shows the tool \(slug) is running right now (its
    // tool_execution_* events), and the session id is reported so kooky can
    // resume the conversation after a restart. Safe to delete; it is
    // regenerated next time kooky launches.
    export default function (pi) {
      const surface = process.env.KOOKY_SURFACE_ID
      const hookBin = process.env.KOOKY_HOOK_BIN
      if (!surface || !hookBin) return

      const ping = async (state) => {
        try { await pi.exec(hookBin, ["\(slug)", state]) } catch {}
      }
      const reportSession = async (ctx) => {
        try {
          const manager = ctx && ctx.sessionManager
          if (!manager || !manager.getSessionFile()) return
          const id = manager.getSessionId()
          if (id) await pi.exec(hookBin, ["\(slug)", "conversation", id])
        } catch {}
      }
      // The "what" shown in the tool-call pill. The agent's args use `path` (not
      // Claude's `file_path`) and lowercase tool names; unknown / custom tools
      // fall back to the first non-empty string arg (keys sorted for a stable
      // pick). Mirrors KookyHookKit.extractIdentifier on the Claude side.
      const toolIdentifier = (toolName, args) => {
        if (!args || typeof args !== "object") return ""
        switch (toolName) {
          case "bash": return typeof args.command === "string" ? args.command : ""
          case "read": case "edit": case "write": case "ls":
            return typeof args.path === "string" ? args.path : ""
          case "grep": case "find":
            return typeof args.pattern === "string" ? args.pattern
              : (typeof args.path === "string" ? args.path : "")
          default:
            for (const k of Object.keys(args).sort()) {
              if (typeof args[k] === "string" && args[k]) return args[k]
            }
            return ""
        }
      }

      // Report the session id on session_start only — it fires on
      // new / resume / fork (every time the session file changes); turns
      // don't move the file, so per-turn reporting would just respawn for the
      // same id.
      pi.on("session_start", async (event, ctx) => { await reportSession(ctx); await ping("running") })
      pi.on("turn_start", async () => { await ping("running") })
      pi.on("turn_end", async () => { await ping("attention") })
      pi.on("session_shutdown", async () => { await ping("ended") })

      // A pending approval blocks MID-turn, so turn_end never fires and the
      // tab would sit on "running" while the agent waits on you. Resolving
      // hands control back, hence straight back to running.
      // Only omp emits these; upstream Pi's `on()` files handlers in a map
      // with no validation, so subscribing is a harmless no-op there.
      pi.on("tool_approval_requested", async () => { await ping("attention") })
      pi.on("tool_approval_resolved", async () => { await ping("running") })

      // Tool-call activity pill. tool_execution_start carries the args, so it
      // ships the identifier; tool_execution_end has no args (just result /
      // isError), so it ships an empty identifier + ok/fail. The toolCallId
      // is stable across the pair, so kooky matches start/end by it.
      pi.on("tool_execution_start", async (event) => {
        try {
          await pi.exec(hookBin, ["\(slug)", "tool", "pre", event.toolCallId || "", event.toolName || "", toolIdentifier(event.toolName, event.args)])
        } catch {}
      })
      pi.on("tool_execution_end", async (event) => {
        try {
          await pi.exec(hookBin, ["\(slug)", "tool", "post", event.toolCallId || "", event.toolName || "", "", event.isError ? "fail" : "ok"])
        } catch {}
      })
    }
    """
    }

    /// Wired via `claude --settings <path>`. SessionStart promotes manually-typed
    /// `claude` immediately; without it the tab icon waits for the user's first
    /// prompt. PreToolUse / PostToolUse / PostToolUseFailure subscribe Claude's
    /// tool-call lifecycle so the activity strip can render pills — they pass
    /// their raw event name as `argv[2]` (not a `HookEvent` rawValue) because
    /// `main.swift` reads stdin for those events and routes through
    /// `parseToolEventPayload`, not `buildLifecyclePayload`. Without
    /// `PostToolUseFailure`, a failed tool call's Pre record sits in `.running`
    /// for 60s before flipping to `.stalled` instead of immediately showing the
    /// red failure pill.
    static func claudeHooksObject(hookCmd: String) -> [String: Any] {
        hooksObject(
            slug: "claude",
            hookCmd: hookCmd,
            events: [
                "SessionStart":      .running,
                "UserPromptSubmit":  .running,
                "Stop":              .attention,
                "Notification":      .attention,
                "SessionEnd":        .ended,
            ],
            passthroughEvents: ["PreToolUse", "PostToolUse", "PostToolUseFailure"]
        )
    }

    /// Path to a per-custom-agent Claude settings file. Same directory as
    /// `claudeHooksPath`; named `claude-<agentId>.json` (id sanitised so a
    /// hand-edited settings.json can't escape the directory). Written by
    /// `refreshClaudeCustomSettings` and passed to `claude` via `--settings`
    /// for that agent's sessions, overriding `KOOKY_HOOKS_PATH`.
    static func claudeCustomSettingsPath(agentId: String) -> String {
        let safe = String(agentId.map {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" ? $0 : "_"
        })
        return hooksDirectory.appendingPathComponent("claude-\(safe).json").path
    }

    /// A Claude `settings.json` fragment for a custom agent: the hooks
    /// `claudeHooksObject` produces, plus an `env` block carrying the
    /// agent's custom environment (endpoint / key / …). Passed to `claude`
    /// via `--settings`, so the variables apply to that Claude process
    /// only — kooky never exports them to the shell.
    static func claudeCustomSettingsObject(env: [String: String], hookCmd: String) -> [String: Any] {
        var object = claudeHooksObject(hookCmd: hookCmd)
        object["env"] = env
        return object
    }

    /// Materialises a per-agent Claude settings file for every Claude-Code-
    /// based custom agent that carries an env block, and deletes any stale
    /// `claude-<id>.json` no longer matching one (a since-deleted agent, or
    /// an env block the user cleared — the file can hold an API token).
    /// Called at launch and after every Settings save, so the on-disk files
    /// always track the current custom-agent set.
    static func refreshClaudeCustomSettings(customAgents: [CustomAgentData]) {
        let hookCmd = kookyHookBinaryPath
        var liveFiles: Set<String> = []
        for agent in customAgents where agent.baseAgentId == AgentTemplate.claudeCodeID {
            let env = AgentTemplate.parseEnv(agent.env)
            guard !env.isEmpty else { continue }
            let path = claudeCustomSettingsPath(agentId: agent.id)
            writeJSON(at: path, object: claudeCustomSettingsObject(env: env, hookCmd: hookCmd))
            liveFiles.insert((path as NSString).lastPathComponent)
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: hooksDirectory.path)
        else { return }
        for name in names
        where name.hasPrefix("claude-") && name.hasSuffix(".json") && !liveFiles.contains(name) {
            try? FileManager.default.removeItem(at: hooksDirectory.appendingPathComponent(name))
        }
    }

    /// Gemini's hook event names diverge from Claude's (BeforeAgent / AfterAgent
    /// instead of UserPromptSubmit / Stop). Hook scripts must not write to
    /// stdout — `KookyHook` only writes to its socket so this is safe.
    /// SessionStart promotes manually-typed `gemini` to `.gemini` immediately,
    /// same pattern as Claude.
    static func geminiDefaultsObject(hookCmd: String) -> [String: Any] {
        hooksObject(slug: "gemini", hookCmd: hookCmd, events: [
            "SessionStart": .running,
            "BeforeAgent":  .running,
            "AfterAgent":   .attention,
            "Notification": .attention,
            "SessionEnd":   .ended,
        ])
    }

    /// Copilot CLI's hooks schema diverges from Claude/Gemini's enough that
    /// it doesn't fit `hooksObject`: top-level `version: 1`, camelCase event
    /// names, no inner `{"hooks": [...]}` wrapper, and the command goes in
    /// a `bash` field (not `command`). Event mapping mirrors Claude's
    /// (sessionStart / userPromptSubmitted → running; agentStop / notification
    /// → attention; sessionEnd → ended). The `_kookyManaged` sentinel is the
    /// JSON-friendly equivalent of the text marker — `writeManagedJSON` reads
    /// it back to decide whether the file is ours to overwrite.
    static func copilotHooksObject(hookCmd: String) -> [String: Any] {
        let events: [(String, HookEvent)] = [
            ("sessionStart",        .running),
            ("userPromptSubmitted", .running),
            ("agentStop",           .attention),
            ("notification",        .attention),
            ("sessionEnd",          .ended),
        ]
        var hooks: [String: Any] = [:]
        for (event, state) in events {
            hooks[event] = [
                [
                    "type": "command",
                    "bash": hookCommand(hookCmd: hookCmd, slug: "copilot", state: state),
                    "timeoutSec": 5,
                ]
            ]
        }
        return ["version": 1, "_kookyManaged": managedFileMarker, "hooks": hooks]
    }

    /// Builds a `claude --settings`-style hooks object for any agent that
    /// follows the `{"hooks": {<EventName>: [{"hooks": [{"type": "command",
    /// "command": "..."}]}]}}` shape (Claude Code, Gemini CLI). Routing
    /// `HookEvent` cases through `.rawValue` keeps the wrapper-emitted strings
    /// in sync with the receiver in `HookServer`.
    /// Builds a Claude / Gemini-style hooks JSON object. `events` maps hook
    /// names → lifecycle state (running / attention / idle / ended); kooky-hook
    /// is invoked with the state's rawValue as `argv[2]`. `passthroughEvents`
    /// is for events whose handler needs the raw event name preserved (e.g.
    /// Claude's `PreToolUse` / `PostToolUse` — kooky-hook reads stdin for
    /// those and dispatches via `parseToolEventPayload`, so the raw name is
    /// what main.swift gates on, not a HookEvent rawValue).
    private static func hooksObject(
        slug: String,
        hookCmd: String,
        events: [String: HookEvent],
        passthroughEvents: [String] = []
    ) -> [String: Any] {
        // `events` and `passthroughEvents` MUST be disjoint — a collision
        // would silently overwrite the lifecycle dispatch with the passthrough
        // variant (or vice versa, depending on the loop order below). Better
        // to crash here at install time than ship a hook config that drops
        // an .attention/.running ping with no test failure. Currently disjoint
        // (Claude lifecycle = SessionStart/UserPromptSubmit/Stop/Notification/
        // SessionEnd, passthrough = PreToolUse/PostToolUse), but any new
        // caller adding richer payloads needs to pick a side per event.
        let lifecycleKeys = Set(events.keys)
        let passthroughSet = Set(passthroughEvents)
        precondition(
            lifecycleKeys.isDisjoint(with: passthroughSet),
            "hooksObject: events and passthroughEvents share key(s) \(lifecycleKeys.intersection(passthroughSet)) — collision would silently drop a hook"
        )

        var hooks: [String: Any] = [:]
        // Claude / Gemini run `command` through `/bin/sh -c`, so an unquoted
        // `KookyHook` path breaks the moment the app lives under a path with
        // spaces or shell metacharacters (e.g. `/Applications/Kooky 2.app/…`).
        for (event, state) in events {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": hookCommand(hookCmd: hookCmd, slug: slug, state: state),
                ]],
            ]]
        }
        for event in passthroughEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": hookCommand(hookCmd: hookCmd, slug: slug, token: event),
                ]],
            ]]
        }
        return ["hooks": hooks]
    }

    /// Marker we embed at the top of every kooky-generated user-config file
    /// (currently the OpenCode plugin). `writeManagedFile` reads existing
    /// files and refuses to overwrite anything that doesn't carry this tag —
    /// so a user's same-named plugin stays untouched on upgrade.
    private static let managedFileMarker = "kooky-managed-do-not-edit"

    private static func writeJSON(at path: String, object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        let url = URL(fileURLWithPath: path)
        // .sortedKeys makes serialization byte-stable, so equal bytes on
        // disk mean nothing changed — skip the atomic replace.
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Writes a file in user-config space (e.g. OpenCode plugin) only when
    /// either the path is unused or the existing content carries our marker.
    /// A user-owned file with the same name is left alone — better to skip a
    /// feature than nuke their plugin.
    private static func writeManagedFile(at path: String, contents: String) {
        let url = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            if !existing.contains(managedFileMarker) { return }
            if existing == contents { return }
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// JSON variant of `writeManagedFile` — preserves a user-authored
    /// `kooky.json` that happens to live at the same path by looking for the
    /// `_kookyManaged` sentinel field. The Copilot hooks dir is user-owned
    /// (`~/.copilot/hooks/`), so a same-named user file is plausible enough
    /// to guard against. A corrupt-or-non-JSON file at the same path is
    /// treated as ours to overwrite — same policy `writeManagedFile` uses
    /// for non-UTF-8 / marker-less text. The alternative (silently skipping)
    /// would leave the user without working hooks and no signal as to why.
    private static func writeManagedJSON(at path: String, object: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (parsed["_kookyManaged"] as? String) != managedFileMarker {
            return
        }
        writeJSON(at: path, object: object)
    }

    private static func writeWrapper(name: String, script: String) {
        let path = (kookyBinDirectory as NSString).appendingPathComponent(name)
        writeFile(at: path, contents: script, executable: true)
    }

    private static func removeManagedWrapper(name: String, markers: [String]) {
        let path = (kookyBinDirectory as NSString).appendingPathComponent(name)
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        guard markers.allSatisfy({ contents.contains($0) }) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// OSC-2 status marker, gated and tty-targeted. Fires only when
    /// `KOOKY_AGENT_MARKERS` is set — ssh remotes export it, local sessions
    /// don't (they report through the KookyHook socket), so the local bracket
    /// wrappers stay silent and never double-report. Writes to `/dev/tty`, not
    /// stdout: a redirected agent (`claude -p … > out`) must not get OSC bytes
    /// in its output, and the marker must still reach the terminal when the
    /// agent's stdout is a pipe. `2>/dev/null` comes *before* `> /dev/tty` so a
    /// missing controlling tty (`/dev/tty` won't open) has its redirection error
    /// already silenced instead of leaking onto the caller's stderr.
    private static func agentMarkerCommand(slug: String, event: HookEvent) -> String {
        "[[ -n \"$KOOKY_AGENT_MARKERS\" ]] && printf '\\033]2;\(AgentStatusMarker.title(slug: slug, event: event))\\a' 2>/dev/null > /dev/tty"
    }

    /// Binary slugs the SSH remote bootstrap installs marker-emitting shims for.
    /// Derived from `builtin` so every agent — and every future one — is covered
    /// without a second hand-maintained roster to keep in sync. `compactMap`
    /// drops Terminal (nil `initialCommand`); customs are excluded on purpose
    /// (their binary is user-defined, unknowable to a remote pre-staged shim).
    private static let remoteAgentMarkerSlugs = AgentTemplate.builtin.compactMap(\.initialCommand)

    /// Common bash header for every wrapper: locate the real binary on
    /// `$PATH` skipping our own dir, abort if missing.
    private static func wrapperPreamble(binary: String) -> String {
        """
        #!/usr/bin/env bash
        self_dir="$(cd "$(dirname "$0")" && pwd)"
        real=""
        IFS=:
        for dir in $PATH; do
            [[ "$dir" == "$self_dir" ]] && continue
            if [[ -x "$dir/\(binary)" ]]; then
                real="$dir/\(binary)"
                break
            fi
        done
        unset IFS

        if [[ -z "$real" ]]; then
            printf '\\n  \\033[33m%s is not installed.\\033[0m\\n\\n' "\(binary)" >&2
            # The new-tab path eagerly sets session.agent based on the template,
            # expecting bracket wrapper to ping `running` next. We never got
            # there — revert the icon so it doesn't lie about what's running.
            if [[ -n "$KOOKY_SURFACE_ID" || -n "$KOOKY_AGENT_MARKERS" ]]; then
                \(agentMarkerCommand(slug: binary, event: .ended))
            fi
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" \(binary) ended 2>/dev/null
            fi
            exit 127
        fi
        """
    }

    /// Pass a pipe-driven programmatic invocation (a broker spawning the agent
    /// for JSON-RPC over stdio — `codex app-server`, the `codex:review` hang)
    /// straight through, skipping instrumentation: a KookyHook ping, OSC
    /// markers, and `-c notify` / `--settings` injection would all perturb the
    /// agent it spawned. Gate on BOTH fds (not `||`) so `claude -p … | tee`
    /// (stdin still a tty) keeps its sidebar dot. Each wrapper places this after
    /// the preamble AND after any exec-safety check — antigravity must reject
    /// the IDE-launcher shim first, else a background `agy` reopens the GUI.
    private static let ttyPassthroughGuard = """
    if [[ ! -t 0 && ! -t 1 ]]; then
        exec "$real" "$@"
    fi
    """

    /// Inside a kooky session ($KOOKY_SURFACE_ID set), injects --settings so
    /// Claude Code's hooks report state back to the app via the bundled
    /// KookyHook helper. `KOOKY_AGENT_MARKERS` enables the OSC-title fallback
    /// for remote shells that can write terminal bytes but cannot reach the
    /// local unix socket. Outside both, transparent passthrough.
    static let claudeWrapperScript = """
    \(wrapperPreamble(binary: "claude"))

    \(ttyPassthroughGuard)

    if [[ -n "$KOOKY_SURFACE_ID" || -n "$KOOKY_AGENT_MARKERS" ]]; then
        \(agentMarkerCommand(slug: "claude", event: .running))
        # Claude still emits lifecycle hooks (and a session_id) for
        # --no-session-persistence runs. Mark only this wrapper invocation so
        # KookyHook can decline that non-resumable id without disabling future
        # normal Claude runs in the same terminal tab.
        unset KOOKY_CLAUDE_NO_SESSION_PERSISTENCE
        for _kooky_arg in "$@"; do
            [[ "$_kooky_arg" == "--" ]] && break
            if [[ "$_kooky_arg" == "--no-session-persistence" ]]; then
                export KOOKY_CLAUDE_NO_SESSION_PERSISTENCE=1
                break
            fi
        done
        unset _kooky_arg
        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOKS_PATH" ]]; then
            "$real" --settings "$KOOKY_HOOKS_PATH" "$@"
        else
            "$real" "$@"
        fi
        status=$?
        \(agentMarkerCommand(slug: "claude", event: .ended))
        exit $status
    fi
    exec "$real" "$@"
    """

    /// Codex doesn't expose a Claude-style hooks settings file we can override
    /// per-invocation, but it does have `notify = ["cmd", "arg", ...]` in
    /// config.toml — fired after each agent turn with a JSON payload appended
    /// as the final argv. We override `notify` inline via `-c` so user's
    /// ~/.codex/config.toml is left untouched. The single signal we get is
    /// "turn complete" which we map to `attention`.
    static let codexWrapperScript = """
    \(wrapperPreamble(binary: "codex"))

    \(ttyPassthroughGuard)

    if [[ -n "$KOOKY_SURFACE_ID" || -n "$KOOKY_AGENT_MARKERS" ]]; then
        # Codex doesn't expose SessionStart / SessionEnd lifecycle hooks
        # we can override per-invocation. Bracket the run from the wrapper:
        # send `running` before codex starts (immediate icon promotion),
        # then `ended` after exit (revert to terminal). Mid-run state
        # transitions still come from Codex's `notify` config below.
        \(agentMarkerCommand(slug: "codex", event: .running))
        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
            "$KOOKY_HOOK_BIN" codex running 2>/dev/null
            "$real" -c "notify=[\\"$KOOKY_HOOK_BIN\\",\\"codex\\",\\"attention\\"]" "$@"
        else
            "$real" "$@"
        fi
        status=$?
        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
            "$KOOKY_HOOK_BIN" codex ended 2>/dev/null
        fi
        \(agentMarkerCommand(slug: "codex", event: .ended))
        exit $status
    fi
    exec "$real" "$@"
    """

    /// SSH is the one common path where the agent runs outside kooky's local
    /// process tree. For a plain interactive `ssh host`, inject a temporary
    /// remote shell session whose PATH starts with marker-emitting wrappers.
    /// Cases where SSH is used as transport (`git`, `scp`, `ssh host cmd`,
    /// port forwards, config dumps) pass through untouched.
    static let sshWrapperScript: String = {
        let remoteCommand = "sh -lc \(quote(remoteAgentBootstrapScript))"
        return """
        \(wrapperPreamble(binary: "ssh"))

        if [[ -n "${KOOKY_DISABLE_SSH_AGENT_MARKERS:-}" || ! -t 0 || ! -t 1 ]]; then
            exec "$real" "$@"
        fi

        args=("$@")
        remote_agent_args=()
        skip_next=0
        destination_seen=0
        remote_command_seen=0
        for ((i = 0; i < ${#args[@]}; i++)); do
            arg="${args[$i]}"
            if (( skip_next )); then
                skip_next=0
                continue
            fi
            if (( ! destination_seen )); then
                if [[ "$arg" == "--" ]]; then
                    ((i++))
                    [[ $i -lt ${#args[@]} ]] || exec "$real" "$@"
                    dest="${args[$i]}"
                    destination_seen=1
                    continue
                fi
                if [[ "$arg" == -* && "$arg" != "-" ]]; then
                    # `-o RemoteCommand=…` (attached or as the next arg) means the
                    # user already supplies the remote command — pass through like
                    # `ssh host cmd` instead of clobbering it with our bootstrap.
                    o_value=""
                    if [[ "$arg" == "-o" ]]; then
                        o_value="${args[$((i + 1))]:-}"
                    elif [[ "$arg" == -o?* ]]; then
                        o_value="${arg#-o}"
                    fi
                    case "$o_value" in
                        [Rr]emote[Cc]ommand*) exec "$real" "$@" ;;
                    esac
                    # Walk the short-option group left to right. A no-remote-shell
                    # flag (N/T/V/G/Q/O/W) — even bundled, e.g. `-fN` for a port
                    # forward — means this isn't an interactive login, so pass
                    # through. Stop at the first argument-taking option: the rest
                    # of the group (or the next arg, via skip_next) is its value.
                    group="${arg#-}"
                    c=0
                    while (( c < ${#group} )); do
                        case "${group:c:1}" in
                            [NTVGQOW]) exec "$real" "$@" ;;
                            [BbcDEeFIiJLlmOopQRSWw])
                                (( c == ${#group} - 1 )) && skip_next=1
                                break
                                ;;
                        esac
                        (( c++ ))
                    done
                    continue
                fi
                dest="$arg"
                destination_seen=1
                continue
            fi
            # kooky-ssh only: `kooky-ssh <dest> -- <agent argv…>` asks the
            # remote bootstrap to launch that agent after rc replay. Gated on
            # the invoked filename so the public `ssh` shim (same script,
            # user-setting gated install) never hijacks a manually typed
            # `ssh host -- cmd` — that stays a plain remote command.
            if [[ "${0##*/}" == "kooky-ssh" && "$arg" == "--" ]]; then
                remote_agent_args=("${args[@]:$((i + 1))}")
                args=("${args[@]:0:$i}")
                break
            fi
            remote_command_seen=1
            break
        done

        if (( ! destination_seen || remote_command_seen )); then
            exec "$real" "$@"
        fi

        printf '\\033]2;\(RemoteLoginMarker.titlePrefix)%s\\a' "$dest" > /dev/tty 2>/dev/null

        remote_command=\(quote(remoteCommand))
        if (( ${#remote_agent_args[@]} )); then
            # Re-quote the agent argv into one eval-able string, then hand it
            # to the bootstrap via an env prefix. `env` (a command, not shell
            # syntax) so the REMOTE login shell parsing this line doesn't
            # need `VAR=val cmd` support (csh lacks it, fish only grew it in
            # 3.1). The bootstrap's rc tail evals it after the user's rc
            # replay, so PATH managers like nvm are already loaded.
            printf -v _kooky_remote_agent '%q ' "${remote_agent_args[@]}"
            printf -v _kooky_remote_agent_q '%q' "${_kooky_remote_agent% }"
            remote_command="env KOOKY_REMOTE_AGENT=$_kooky_remote_agent_q $remote_command"
        fi
        _kooky_mux_opts=()
        if [[ "${0##*/}" == "kooky-ssh" ]]; then
            # kooky-owned connections multiplex (ControlPath shared with the
            # paste upload's ssh/scp — `sshMultiplexOptions`): this
            # interactively authenticated connection is the master the
            # headless upload rides, which is what lets password /
            # interactive-passphrase workspaces paste files at all. The
            # public `ssh` shim never gets this — silently switching manual
            # ssh onto shared connections is not kooky's call to make.
            _kooky_mux_opts=(\(sshMultiplexOptions.joined(separator: " ")))
        fi
        # No exec: the wrapper must OUTLIVE ssh to emit the logout marker —
        # the whole-connection-lifetime signal `remoteHost` is cleared by.
        # Ignore INT/QUIT in the wrapper itself: the foreground ssh still
        # receives them (same tty process group), and bash would otherwise
        # abort the script after a Ctrl+C'd ssh and swallow the marker.
        trap '' INT QUIT
        "$real" -t "${_kooky_mux_opts[@]}" "${args[@]}" "$remote_command"
        _kooky_ssh_status=$?
        printf '\\033]2;\(RemoteLoginMarker.logoutTitle)\\a' > /dev/tty 2>/dev/null
        exit "$_kooky_ssh_status"
        """
    }()

    /// Remote-side bootstrap used only by `sshWrapperScript`. It writes wrapper
    /// binaries into a temp dir on the remote, then starts the user's shell
    /// with that dir prepended after normal rc replay. The temp dir is removed
    /// when the remote shell exits, so this does not persist files on servers.
    /// Consume-once eval of the agent command the kooky-ssh wrapper passed
    /// via the `KOOKY_REMOTE_AGENT` env prefix — interpolated into all three
    /// bootstrap shell branches (same single-source shape as the local
    /// `agentLaunchBlock`). `heredocEscaped: true` renders the `\$` form the
    /// zsh/bash rc heredocs need (the OUTER bootstrap shell must leave
    /// expansion to the rc's shell); the POSIX fallback takes the plain form.
    /// `unset` runs BEFORE the eval so nested shells the agent spawns can't
    /// relaunch it.
    private static func remoteAgentEvalBlock(heredocEscaped: Bool) -> String {
        let d = heredocEscaped ? #"\$"# : "$"
        return """
        if [ -n "\(d){KOOKY_REMOTE_AGENT:-}" ]; then
            _kooky_remote_agent="\(d)KOOKY_REMOTE_AGENT"
            unset KOOKY_REMOTE_AGENT
            eval "\(d)_kooky_remote_agent"
        fi
        """
    }

    static let remoteAgentBootstrapScript: String = {
        let slugs = remoteAgentMarkerSlugs.map(quote).joined(separator: " ")
        return #"""
        _kooky_root="${TMPDIR:-/tmp}/kooky-agent-markers-${USER:-user}-$$"
        _kooky_bin="$_kooky_root/bin"
        mkdir -p "$_kooky_bin" 2>/dev/null || {
            printf 'kooky: could not create remote marker directory\n' >&2
            "${SHELL:-/bin/sh}" -l
            exit $?
        }
        trap 'rm -rf "$_kooky_root"' EXIT
        trap 'rm -rf "$_kooky_root"; exit' HUP INT TERM

        _kooky_write_agent_wrapper() {
            _kooky_slug="$1"
            cat > "$_kooky_bin/$_kooky_slug" <<'KOOKY_AGENT_WRAPPER'
        #!/bin/sh
        _kooky_slug="${0##*/}"
        _kooky_self_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
        _kooky_real=""
        _kooky_old_ifs=$IFS
        IFS=:
        for _kooky_dir in $PATH; do
            [ "$_kooky_dir" = "$_kooky_self_dir" ] && continue
            [ -x "$_kooky_dir/$_kooky_slug" ] || continue
            _kooky_real="$_kooky_dir/$_kooky_slug"
            break
        done
        IFS=$_kooky_old_ifs

        if [ -z "$_kooky_real" ]; then
            printf '\033]2;kooky-agent:%s:ended\a' "$_kooky_slug" > /dev/tty 2>/dev/null
            printf '\n  %s is not installed.\n\n' "$_kooky_slug" >&2
            exit 127
        fi

        printf '\033]2;kooky-agent:%s:running\a' "$_kooky_slug" > /dev/tty 2>/dev/null
        "$_kooky_real" "$@"
        _kooky_status=$?
        printf '\033]2;kooky-agent:%s:ended\a' "$_kooky_slug" > /dev/tty 2>/dev/null
        exit "$_kooky_status"
        KOOKY_AGENT_WRAPPER
            chmod +x "$_kooky_bin/$_kooky_slug"
        }

        for _kooky_slug in \#(slugs); do
            _kooky_write_agent_wrapper "$_kooky_slug"
        done
        unset _kooky_slug

        case "${SHELL:-}" in
            */zsh)
                mkdir -p "$_kooky_root/zsh"
                cat > "$_kooky_root/zsh/.zshrc" <<KOOKY_ZSHRC
        if [[ -n "\${KOOKY_ORIGINAL_ZDOTDIR:-}" ]]; then
            export ZDOTDIR="\$KOOKY_ORIGINAL_ZDOTDIR"
            unset KOOKY_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi
        # /etc/zshrc (already ran under our ephemeral ZDOTDIR) may have resolved
        # HISTFILE into the temp dir we rm -rf on exit — reset before user rc so
        # remote shell history lands in \$HOME and a user override still wins.
        export HISTFILE="\$HOME/.zsh_history"
        [[ -r "\${ZDOTDIR:-\$HOME}/.zshenv" ]] && source "\${ZDOTDIR:-\$HOME}/.zshenv"
        [[ -r "\${ZDOTDIR:-\$HOME}/.zprofile" ]] && source "\${ZDOTDIR:-\$HOME}/.zprofile"
        [[ -r "\${ZDOTDIR:-\$HOME}/.zshrc" ]] && source "\${ZDOTDIR:-\$HOME}/.zshrc"
        export KOOKY_AGENT_MARKERS=1
        export PATH="$_kooky_bin:\$PATH"
        \#(remoteAgentEvalBlock(heredocEscaped: true))
        KOOKY_ZSHRC
                KOOKY_ORIGINAL_ZDOTDIR="${ZDOTDIR:-}" ZDOTDIR="$_kooky_root/zsh" zsh -l
                ;;
            */bash)
                cat > "$_kooky_root/bashrc" <<KOOKY_BASHRC
        _kooky_login_rc_loaded=
        for _kooky_rc in "\$HOME/.bash_profile" "\$HOME/.bash_login" "\$HOME/.profile"; do
            if [[ -r "\$_kooky_rc" ]]; then
                source "\$_kooky_rc"
                _kooky_login_rc_loaded=1
                break
            fi
        done
        unset _kooky_rc
        if [[ -z "\$_kooky_login_rc_loaded" && -r "\$HOME/.bashrc" ]]; then
            source "\$HOME/.bashrc"
        fi
        unset _kooky_login_rc_loaded
        export KOOKY_AGENT_MARKERS=1
        export PATH="$_kooky_bin:\$PATH"
        \#(remoteAgentEvalBlock(heredocEscaped: true))
        KOOKY_BASHRC
                bash --rcfile "$_kooky_root/bashrc" -i
                ;;
            *)
                export KOOKY_AGENT_MARKERS=1
                export PATH="$_kooky_bin:$PATH"
                # Non-zsh/bash login shells (fish, csh, …): run the agent in
                # THIS POSIX bootstrap before handing over. It won't see the
                # user's fish/csh rc PATH additions, but it starts and marks
                # correctly instead of crashing on foreign-shell syntax.
                \#(remoteAgentEvalBlock(heredocEscaped: false))
                "${SHELL:-/bin/sh}" -l
                ;;
        esac
        """#
    }()

    /// Antigravity CLI shares its binary name (`agy`) with Antigravity 2.0
    /// IDE's command-line launcher (`~/.antigravity/antigravity/bin/agy`
    /// is a symlink into `/Applications/Antigravity.app/...`). With only
    /// the IDE installed, PATH-resolution would pick up the launcher and
    /// a plain `exec agy` opens the GUI — surprising the user who picked
    /// "Antigravity CLI" from the `+` menu. Detect the IDE shim by
    /// resolving one symlink hop and matching `/Antigravity.app/`; on
    /// match, route through the same "not installed" path the preamble
    /// uses (red message + KookyHook `ended` ping so the tab icon
    /// reverts) plus surface the official CLI install command.
    static let antigravityWrapperScript = """
    \(wrapperPreamble(binary: "agy"))

    real_target="$(readlink "$real" 2>/dev/null || true)"
    case "${real_target:-$real}" in
        */Antigravity.app/*)
            printf '\\n  \\033[33mThe `agy` on PATH is the Antigravity IDE launcher, not the CLI.\\033[0m\\n' >&2
            printf '  Install the CLI:\\n' >&2
            printf '    \\033[36mcurl -fsSL https://antigravity.google/cli/install.sh | bash\\033[0m\\n\\n' >&2
            if [[ -n "$KOOKY_SURFACE_ID" || -n "$KOOKY_AGENT_MARKERS" ]]; then
                \(agentMarkerCommand(slug: "agy", event: .ended))
            fi
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" agy ended 2>/dev/null
            fi
            exit 127
            ;;
    esac

    \(bracketBody(slug: "agy"))
    """

    /// Kiro wrapper uses the generic lifecycle bracket plus one isolated ACP
    /// recording path. The variable is scoped to the real Kiro process so a
    /// user's own `KIRO_ACP_RECORD_PATH` remains untouched in their shell and
    /// in Kiro runs outside kooky.
    static let kiroWrapperScript = """
    \(wrapperPreamble(binary: "kiro-cli"))

    \(ttyPassthroughGuard)

    if [[ -n "$KOOKY_SURFACE_ID" || -n "$KOOKY_AGENT_MARKERS" ]]; then
        \(agentMarkerCommand(slug: "kiro-cli", event: .running))
        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
            "$KOOKY_HOOK_BIN" kiro-cli running 2>/dev/null
        fi
        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_KIRO_ACP_RECORD_PATH" ]]; then
            KIRO_ACP_RECORD_PATH="$KOOKY_KIRO_ACP_RECORD_PATH" "$real" "$@"
        else
            "$real" "$@"
        fi
        status=$?
        if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
            "$KOOKY_HOOK_BIN" kiro-cli ended 2>/dev/null
        fi
        \(agentMarkerCommand(slug: "kiro-cli", event: .ended))
        exit $status
    fi
    exec "$real" "$@"
    """

    /// Generic bracket wrapper for agents we can't drive mid-run state from
    /// (no hook system or no installed plugin yet). Sends `running` before
    /// exec and `ended` after exit; activity dot stays green for the whole
    /// run, then drops to idle on quit. Used for `amp` (no plugin) and
    /// `opencode` — opencode's plugin upgrades mid-run state once installed.
    static func bracketWrapperScript(slug: String) -> String {
        """
        \(wrapperPreamble(binary: slug))

        \(bracketBody(slug: slug))
        """
    }

    /// The `running` → exec → `ended` body shared by `bracketWrapperScript`
    /// and `antigravityWrapperScript`. Outside a kooky session (and without
    /// `KOOKY_AGENT_MARKERS`) the bracket is a no-op — `exec "$real"` is the
    /// only line that runs so the wrapper is transparent when the user invokes
    /// the binary from a plain Terminal.app shell.
    private static func bracketBody(slug: String) -> String {
        """
        \(ttyPassthroughGuard)

        if [[ -n "$KOOKY_SURFACE_ID" || -n "$KOOKY_AGENT_MARKERS" ]]; then
            \(agentMarkerCommand(slug: slug, event: .running))
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" \(slug) running 2>/dev/null
            fi
            "$real" "$@"
            status=$?
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" \(slug) ended 2>/dev/null
            fi
            \(agentMarkerCommand(slug: slug, event: .ended))
            exit $status
        fi
        exec "$real" "$@"
        """
    }

    /// Amp system plugin. `session.start` carries the exact thread id; agent
    /// start/end events also upgrade the generic wrapper's whole-run green
    /// state to per-turn running/attention.
    static let ampPluginScript = """
    // \(managedFileMarker) — reports Amp thread ids and lifecycle to KookyHook.
    // Safe to delete; it is regenerated next time kooky launches.
    import { spawn } from "node:child_process"
    import type { PluginAPI } from "@ampcode/plugin"

    export default function (amp: PluginAPI) {
      const surface = process.env.KOOKY_SURFACE_ID
      const hookBin = process.env.KOOKY_HOOK_BIN
      if (!surface || !hookBin) return

      const send = (args: string[]) => {
        try {
          const child = spawn(hookBin, args, { stdio: "ignore", env: process.env })
          child.unref()
        } catch {}
      }
      amp.on("session.start", async (event) => {
        const id = event?.thread?.id
        if (id) send(["amp", "conversation", id])
        send(["amp", "running"])
      })
      amp.on("agent.start", async () => { send(["amp", "running"]) })
      amp.on("agent.end", async () => { send(["amp", "attention"]) })
    }
    """

    /// OpenCode auto-loads any `.ts`/`.js` file in
    /// `$XDG_CONFIG_HOME/opencode/plugin/` (or `~/.config/opencode/plugin/`)
    /// at startup. The plugin runs in opencode's own Bun runtime, inherits
    /// KOOKY_SURFACE_ID + KOOKY_HOOK_BIN from the shell, and shells out to
    /// KookyHook on each lifecycle event. The first-line marker
    /// (`managedFileMarker`) lets `writeManagedFile` recognise the file as
    /// kooky-generated on upgrade — a user's own `kooky.ts` plugin would
    /// not carry the marker and stays untouched.
    static let opencodePluginScript = """
    // \(managedFileMarker) — pings KookyHook on prompt-submit and turn-end so
    // the sidebar agent dot tracks per-session activity. Safe to delete; will
    // be regenerated next time kooky launches.
    export const KookyPlugin = async ({ $, client, directory }) => {
      const surface = process.env.KOOKY_SURFACE_ID
      const hookBin = process.env.KOOKY_HOOK_BIN
      if (!surface || !hookBin) return {}

      const ping = async (state) => {
        try { await $`${hookBin} opencode ${state}`.quiet() } catch {}
      }
      const reportSession = async (id) => {
        if (!id) return
        try { await $`${hookBin} opencode conversation ${id}`.quiet() } catch {}
      }
      const reportRootSession = async (id) => {
        if (!id) return
        try {
          const response = await client.session.get({
            path: { id },
            query: { directory },
          })
          const info = response?.data
          if (info?.id && !info?.parentID) await reportSession(info.id)
        } catch {}
      }

      return {
        "chat.message": async ({ sessionID }) => {
          await reportRootSession(sessionID)
          await ping("running")
        },
        event: async ({ event }) => {
          if (event?.type === "session.created") {
            const info = event?.properties?.info
            // Subagents also create sessions. Only the root chat belongs to
            // this kooky tab; a child id would resume the wrong conversation.
            if (info?.id && !info?.parentID) await reportSession(info.id)
          }
          if (event?.type === "session.idle") {
            await reportRootSession(event?.properties?.sessionID)
            await ping("attention")
          }
        },
      }
    }
    """

    enum DetectedUserShell { case zsh, bash, fish, other }

    static var detectedUserShell: DetectedUserShell {
        let path = ProcessInfo.processInfo.environment["SHELL"] ?? zshPath
        if path.hasSuffix("/zsh") { return .zsh }
        if path.hasSuffix("/bash") { return .bash }
        if path.hasSuffix("/fish") { return .fish }
        return .other
    }

    private static let bashLauncherFilePath: String =
        NSTemporaryDirectory().appending("kooky-bash-launch-\(getpid()).sh")

    private static let bashRcfilePath: String =
        NSTemporaryDirectory().appending("kooky-bashrc-\(getpid())")

    private static let kookyBashrc: String = """
        # Default word-jump bindings; readline doesn't bind Ctrl/Alt+arrow on
        # macOS by default. See the matching block in zshDirectory.
        bind '"\\e[1;5D": backward-word'     # Ctrl+Left
        bind '"\\e[1;5C": forward-word'      # Ctrl+Right
        bind '"\\e[1;3D": backward-word'     # Alt+Left
        bind '"\\e[1;3C": forward-word'      # Alt+Right

        # bash is launched as interactive non-login (`--rcfile` is incompatible
        # with `-l`), so it would normally skip the login rc chain. macOS users
        # traditionally put PATH / env in ~/.bash_profile (Apple Terminal starts
        # bash as login), so without this they'd see env vars vanish. Replay
        # the first existing login rc, matching bash's own lookup order.
        _kooky_login_rc_loaded=
        for _kooky_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [[ -r "$_kooky_rc" ]]; then
                source "$_kooky_rc"
                _kooky_login_rc_loaded=1
                break
            fi
        done
        unset _kooky_rc

        # No login rc existed, so its standard `source ~/.bashrc` chain never
        # ran — fall back so the user's interactive config still loads. Skip
        # when a login rc was found: bash login shells don't auto-source
        # .bashrc, and the user's profile chain (if they want it) handles
        # that. Avoids double-load when .bash_profile already chained .bashrc
        # (NVM / oh-my-bash / PROMPT_COMMAND duplication = 150-300ms).
        if [[ -z "$_kooky_login_rc_loaded" && -r "$HOME/.bashrc" ]]; then
            source "$HOME/.bashrc"
        fi
        unset _kooky_login_rc_loaded

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOSTNAME" "$PWD"; }
        # Re-assert the cwd as the OSC title each prompt (see zsh wrapper) —
        # prepended so it runs before the user's PROMPT_COMMAND title hook.
        _kooky_title_pwd() { printf '\\e]2;%s\\a' "$PWD"; }
        \(envStatusBlock)

        # No command-line reporting here on purpose: bash gets no OSC 133 from
        # kooky (only the zsh and fish integrations emit it), so there is no
        # command RESULT for the text to label — it would cost a subshell plus
        # a hook spawn per prompt to feed a row that can never render. Giving
        # bash 133 is its own item: the `C` marker needs PS0, which stock
        # macOS bash 3.2 doesn't have, so it needs a version gate like fish's.
        PROMPT_COMMAND="_kooky_title_pwd;_kooky_osc7_pwd;_kooky_env_status${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        _kooky_osc7_pwd
        _kooky_env_status

        \(agentLaunchBlock)
        """

    private static let bashLauncherScript: String = """
        #!/bin/bash
        exec \(bashPath) --rcfile "\(bashRcfilePath)" -i

        """

    /// Path to a tiny launcher script that re-execs bash as an interactive,
    /// non-login shell with our `--rcfile`. Required because libghostty starts
    /// every `command` as a login shell (`argv[0]` prefixed with `-`), and
    /// login bash ignores `--rcfile` entirely (it reads `~/.bash_profile`
    /// instead). The launcher is a degenerate `bash` itself, so it gets the
    /// login prefix; it then `exec`s a fresh bash without the prefix.
    ///
    /// Computed, not `static let`: macOS's periodic $TMPDIR cleanup deletes
    /// files not accessed for 3 days, and these are only read when a terminal
    /// spawns — a long-lived kooky that goes days without a new bash tab loses
    /// them (issue #45). Re-ensure on every access; `writeFile`'s content gate
    /// makes the healthy path a cheap read. nil = couldn't (re)create — the
    /// caller falls back to a plain login bash so the user's own config still
    /// loads, just without kooky integration.
    static var bashLauncherPath: String? {
        let rcOk = ensureBridgeFile(at: bashRcfilePath, contents: kookyBashrc, label: "bash bridge rc")
        let launcherOk = ensureBridgeFile(
            at: bashLauncherFilePath, contents: bashLauncherScript,
            executable: true, label: "bash launcher"
        )
        return (rcOk && launcherOk) ? bashLauncherFilePath : nil
    }

    private static let zshDirectoryPath: String =
        NSTemporaryDirectory().appending("kooky-zsh-\(getpid())")

    private static let kookyZshrc: String = """
        # Default word-jump bindings. zsh ZLE only binds Alt+B/F by default;
        # most other terminals (iTerm2, ghostty, Apple Terminal) remap the
        # Ctrl/Alt+arrow sequences to ESC+B/F so users don't notice. kooky
        # binds them directly here. Placed before sourcing ~/.zshrc so user
        # rc files retain final say if they override the same sequences.
        bindkey '^[[1;5D' backward-word    # Ctrl+Left
        bindkey '^[[1;5C' forward-word     # Ctrl+Right
        bindkey '^[[1;3D' backward-word    # Alt+Left
        bindkey '^[[1;3C' forward-word     # Alt+Right

        # Restore ZDOTDIR to the user's original (almost always unset) *before*
        # replaying their rc chain. zsh has already consumed ZDOTDIR to locate
        # this wrapper rc — changing it now is safe and ensures any
        # `$ZDOTDIR/...` reference inside .zshenv / .zprofile / .zshrc
        # (compinit's `.zcompdump`, plugin caches, znap/zinit roots, HISTFILE
        # overrides) resolves to real `$HOME` instead of our ephemeral
        # kooky-zsh-<pid> dir. Also stops `curl | bash`-style installers
        # (opencode, rustup) from writing PATH exports to our ephemeral rc.
        if [[ -n "$KOOKY_ORIGINAL_ZDOTDIR" ]]; then
            export ZDOTDIR="$KOOKY_ORIGINAL_ZDOTDIR"
            unset KOOKY_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi

        # macOS `/etc/zshrc` (already ran) resolved HISTFILE against our
        # ephemeral ZDOTDIR; `cleanup()` deletes that dir on quit, taking
        # history with it. Reset to the real path *before* user rc so a user
        # HISTFILE override in any of the three files below still wins.
        export HISTFILE="$HOME/.zsh_history"

        # Re-assert the cwd as the OSC title each prompt — registered before
        # the user rc so it runs first in precmd_functions. Drops a stale
        # ssh / TUI title; a title the user's theme sets later this prompt
        # still wins (it runs after). kooky maps a cwd-shaped title to the
        # bare basename. `return $_s` keeps $? intact for the user hooks.
        autoload -Uz add-zsh-hook
        _kooky_title_pwd() { local _s=$?; printf '\\e]2;%s\\a' "$PWD"; return $_s }
        add-zsh-hook precmd _kooky_title_pwd

        # Replay the rc files zsh would have run if ZDOTDIR had pointed at the
        # user's real dir. Resolve via `${ZDOTDIR:-$HOME}` after each source —
        # so users who park their zsh config in a custom dir (e.g.
        # `~/.config/zsh` via parent-shell ZDOTDIR, or via `export ZDOTDIR=...`
        # inside .zshenv itself) get the full chain. Re-resolve after each
        # source because .zshenv / .zprofile may mutate ZDOTDIR.
        [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
        [[ -r "${ZDOTDIR:-$HOME}/.zprofile" ]] && source "${ZDOTDIR:-$HOME}/.zprofile"
        [[ -r "${ZDOTDIR:-$HOME}/.zshrc" ]] && source "${ZDOTDIR:-$HOME}/.zshrc"

        # User rc may rewrite PATH; re-prepend the kooky wrapper directory so
        # `claude` etc. resolve to our shims first.
        [[ -n "$KOOKY_BIN_DIR" ]] && export PATH="$KOOKY_BIN_DIR:$PATH"

        _kooky_osc7_pwd() { printf '\\e]7;file://%s%s\\e\\\\' "$HOST" "$PWD" }
        add-zsh-hook chpwd _kooky_osc7_pwd
        _kooky_osc7_pwd

        \(envStatusBlock)

        \(osc133Block)

        \(agentLaunchBlock)
        """

    /// Re-ensures every shell's bridge right before a surface actually spawns
    /// (`createSurfaceIfReady`) — the moment the files MUST exist. The ensure
    /// inside `makeSessionConfig` only covers config-construction time: a
    /// restored tab keeps its config in `pendingConfig` until its view first
    /// mounts, which can sit past the 3-day $TMPDIR cleanup — its cached
    /// `config.command` would then point at a deleted bash launcher (Codex
    /// review on issue #45). The launcher path is per-pid-fixed, so rewriting
    /// the files here revives the cached path. zsh gets the same guarantee
    /// from the ZDOTDIR injection at the same call site (it accesses
    /// `zshDirectory`); fish's vendor conf lives in App Support (outside the
    /// cleanup's reach) and is re-written here anyway so all three shells
    /// share one spawn-time guarantee. Content-gated writes — the healthy
    /// path costs a few small reads per surface creation.
    static func ensureSpawnBridges() {
        _ = bashLauncherPath
        installFishVendorConf()
    }

    /// Path to a per-process directory containing our wrapper `.zshrc`. Pass
    /// this as `ZDOTDIR` when spawning zsh so it loads the wrapper instead of
    /// `~/.zshrc` directly.
    ///
    /// Computed, not `static let` — same $TMPDIR-cleanup self-heal as
    /// `bashLauncherPath` (issue #45): with the wrapper rc deleted, ZDOTDIR
    /// would point zsh at an empty dir and it would load NO user rc at all (a
    /// bare shell). nil = couldn't (re)create — the caller skips the ZDOTDIR
    /// injection so zsh reads the user's real rc chain, just without kooky
    /// integration.
    static var zshDirectory: String? {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: zshDirectoryPath), withIntermediateDirectories: true
        )
        let rcPath = (zshDirectoryPath as NSString).appendingPathComponent(".zshrc")
        guard ensureBridgeFile(at: rcPath, contents: kookyZshrc, label: "zsh bridge rc") else {
            return nil
        }
        return zshDirectoryPath
    }

    /// fish integration, auto-loaded from a kooky-owned `vendor_conf.d/kooky.fish`
    /// that fish discovers via the `XDG_DATA_DIRS` we set for fish sessions
    /// (`fishVendorDataRoot`). This is the fish analogue of zsh's `ZDOTDIR`
    /// wrapper: a `-C "source …"` launcher was tried first but `-C` runs AFTER
    /// `config.fish`, so shell-wrapping autocomplete tools (Fig / Amazon Q /
    /// kiro) that re-`exec` fish from `config.fish` swallowed it. vendor_conf.d
    /// is read by every fish — including the inner fish those tools spawn (it
    /// inherits `XDG_DATA_DIRS`) — so the integration survives the hijack.
    ///
    /// vendor_conf.d runs BEFORE `config.fish`, so all real work is deferred to
    /// `fish_prompt` event handlers that fire after it: that lets us win on PATH
    /// and lets the agent launch in the fully-configured shell. Additive only —
    /// we never override the user's `fish_prompt` / `fish_title`, so themes
    /// (Tide / Starship) keep working. Two things fish gives us for free:
    /// (a) fish auto-restores `$status` around each event handler, so our hooks
    ///     can't leak a status into the user's prompt (zsh needs explicit
    ///     `return $_s` masking).
    /// (b) fish 4+ emits OSC 133 markers natively, so we only add them on fish
    ///     3.x (a version gate) to avoid double-marking. fish never emits OSC 7,
    ///     though, so cwd tracking is always ours.
    static let fishInitScript = """
    # Interactive shells only — vendor_conf.d is also read by non-interactive
    # fish (e.g. `fish -c` a tool spawns in this session, since XDG_DATA_DIRS is
    # inherited). Use `return` (stop sourcing THIS file), never `exit` (which
    # reads as "terminate the shell" — fish happens to scope it to the snippet,
    # but `return` is the correct, version-robust way to bail).
    status is-interactive; or return

    set -g __kooky_host (hostname 2>/dev/null)

    # Re-prepend the wrapper dir so `claude` etc. resolve to our shims first,
    # even if config.fish rebuilt PATH (fish_add_path / brew shellenv). Shared by
    # the prompt hook and the agent launcher so PATH is ready regardless of which
    # fires first. This is what makes a manually-typed `claude` light the dot.
    function __kooky_prepend_path
        test -n "$KOOKY_BIN_DIR"; or return
        # Force the wrapper dir to the FRONT, even when it's already present
        # somewhere — config.fish / fish_add_path / kiro routinely leave it
        # mid-PATH (e.g. behind ~/.local/bin), and the shim only wins when it's
        # first. Skip when already first (avoids per-prompt PATH churn); else
        # drop any existing copy and prepend (no duplicates).
        test "$PATH[1]" = "$KOOKY_BIN_DIR"; and return
        set -gx PATH "$KOOKY_BIN_DIR" (string match -v -- "$KOOKY_BIN_DIR" $PATH)
    end

    # PATH re-prepend + OSC 7 cwd, each prompt (fires after config.fish, so we
    # win PATH). fish never emits OSC 7 itself; new tabs inherit the reported cwd.
    function __kooky_prompt --on-event fish_prompt
        __kooky_prepend_path
        printf '\\e]7;file://%s%s\\e\\\\' "$__kooky_host" "$PWD"
    end

    # env status IPC (Python venv / Node version / proxy → pane status bar).
    # Two-layer dedup mirrors the zsh wrapper: cache `node --version` against the
    # resolved node path, and skip the IPC fork entirely when no key changed.
    function __kooky_env_status --on-event fish_prompt
        if test -z "$KOOKY_SURFACE_ID"; or test -z "$KOOKY_HOOK_BIN"; or not test -x "$KOOKY_HOOK_BIN"
            return
        end
        set -l node_path ""
        if command -q node
            set node_path (command -v node)
        end
        set -l node_key "$node_path|$NVM_BIN"
        if test "$node_key" != "$__kooky_node_key_last"
            set -g __kooky_node_version_last ""
            if test -n "$node_path"
                set -g __kooky_node_version_last ($node_path --version 2>/dev/null)
            end
            set -g __kooky_node_key_last "$node_key"
        end
        set -l https_v "$https_proxy"; test -z "$https_v"; and set https_v "$HTTPS_PROXY"
        set -l http_v "$http_proxy"; test -z "$http_v"; and set http_v "$HTTP_PROXY"
        set -l all_v "$all_proxy"; test -z "$all_v"; and set all_v "$ALL_PROXY"
        set -l env_now "$VIRTUAL_ENV|$CONDA_DEFAULT_ENV|$NVM_BIN|$NVM_DIR|$__kooky_node_version_last|$https_v|$http_v|$all_v"
        if test "$env_now" = "$__kooky_env_last"
            return
        end
        # Only advance the dedup cache when the IPC actually succeeded, so a
        # transient socket gap retries next prompt instead of freezing.
        if "$KOOKY_HOOK_BIN" env "$VIRTUAL_ENV" "$CONDA_DEFAULT_ENV" "$NVM_BIN" "$NVM_DIR" "$__kooky_node_version_last" "$https_v" "$http_v" "$all_v" 2>/dev/null
            set -g __kooky_env_last "$env_now"
        end
    end

    # The accepted command line, for the Session Info inspector. Deliberately
    # OUTSIDE the OSC 133 version gate below: fish 4 emits the prompt/command
    # boundaries natively, so this marker is what kooky needs on every fish.
    # Control characters are flattened first — a raw BEL or ESC inside the
    # command would terminate the OSC string early and let the rest of the
    # command render as terminal output.
    function __kooky_command_marker --on-event fish_preexec
        set -l _kooky_cmd (string join ' ' -- $argv | string replace -ra '[[:cntrl:]]' ' ' | string trim | string sub -l \(CommandMarker.maxLength))
        test -n "$_kooky_cmd"; or return
        printf '\\e]2;\(CommandMarker.titlePrefix)%s\\a' $_kooky_cmd
    end

    # OSC 133 prompt/command markers — fish 4+ emits these natively, so only add
    # them on fish 3.x to avoid double-marking. Gives kooky per-command exit
    # status (the failed-command red dot), duration, and jump-to-prompt.
    set -l __kooky_major (string split '.' -- $version)[1]
    if test "$__kooky_major" -lt 4 2>/dev/null
        function __kooky_133_prompt --on-event fish_prompt
            printf '\\e]133;A;cl=line\\a'
        end
        function __kooky_133_preexec --on-event fish_preexec
            printf '\\e]133;C\\a'
        end
        function __kooky_133_postexec --on-event fish_postexec
            printf '\\e]133;D;%s\\a' $status
        end
    end

    # Agent auto-launch — one-shot on the FIRST prompt (after config.fish set up
    # the real PATH/env). Self-removes so it can't re-fire, and the exported
    # guard blocks re-entry from any subshell the agent spawns.
    function __kooky_agent_launch --on-event fish_prompt
        functions -e __kooky_agent_launch
        test -n "$KOOKY_AGENT"; and test -z "$KOOKY_AGENT_LAUNCHED"; or return
        set -gx KOOKY_AGENT_LAUNCHED 1
        __kooky_prepend_path
        set -l _kooky_cmd $KOOKY_AGENT
        set -e KOOKY_AGENT
        set -l _kooky_bin (string split -m1 ' ' -- $_kooky_cmd)[1]
        # `eval` lets KOOKY_AGENT carry multi-word commands (resume flag, prompt,
        # extra options); a single-word `claude` behaves identically.
        eval $_kooky_cmd
        # The agent ran foreground, so reaching here means it exited (or a user
        # alias shadowed the PATH wrapper before its `ended` ping). Revert the
        # eagerly-promoted tab icon to a plain shell; idempotent if the wrapper
        # already pinged ended.
        if test -n "$KOOKY_SURFACE_ID"; and test -n "$KOOKY_HOOK_BIN"
            "$KOOKY_HOOK_BIN" $_kooky_bin ended 2>/dev/null
        end
    end
    """

    /// `XDG_DATA_DIRS` entry we hand fish sessions so it discovers our
    /// `fish/vendor_conf.d/kooky.fish` (see `fishInitScript`). A stable
    /// Application Support path (not per-process) — fish reads it on every shell
    /// start, including inner shells spawned by autocomplete wrappers.
    static let fishVendorDataRoot: String = {
        kookyAppSupport("share", isDirectory: true).path
    }()

    /// Absolute path to the kooky-owned fish vendor conf file.
    static let fishVendorConfPath: String = {
        (fishVendorDataRoot as NSString).appendingPathComponent("fish/vendor_conf.d/kooky.fish")
    }()

    /// Writes the fish vendor conf. Called from `installAgentHooks` so it tracks
    /// the latest `fishInitScript` on every launch.
    static func installFishVendorConf() {
        let dir = (fishVendorConfPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        writeFile(at: fishVendorConfPath, contents: fishInitScript)
    }

    /// Removes per-process temp files. Wired into `applicationWillTerminate`
    /// so wrappers don't accumulate in `NSTemporaryDirectory()` across runs.
    ///
    /// Sweeps every `kooky-<slug>-<pid>` artifact (optional extension) by
    /// pattern rather than a hardcoded name list — a new wrapper file is then
    /// cleaned up for free, with no second site to keep in sync. Matching the
    /// `-<pid>` suffix on the extension-stripped stem scopes deletion to this
    /// process: another live kooky's files (or a pid that's merely a digit
    /// prefix of ours, e.g. 234 vs 1234) stay untouched.
    static func cleanup() {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory()
        let pidSuffix = "-\(getpid())"
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries where entry.hasPrefix("kooky-") {
            guard (entry as NSString).deletingPathExtension.hasSuffix(pidSuffix) else { continue }
            try? fm.removeItem(atPath: dir.appending(entry))
        }
    }

    // MARK: - Internals

    /// Inline agent launch — invoked by both wrapper rcs to start KOOKY_AGENT
    /// before the first prompt prints. KOOKY_AGENT_LAUNCHED guards against
    /// re-entry from subshells the agent itself may spawn.
    static let agentLaunchBlock = """
        if [[ -n "$KOOKY_AGENT" && -z "$KOOKY_AGENT_LAUNCHED" ]]; then
            export KOOKY_AGENT_LAUNCHED=1
            _kooky_cmd="$KOOKY_AGENT"
            _kooky_agent_bin="${_kooky_cmd%% *}"
            unset KOOKY_AGENT
            # `eval` lets KOOKY_AGENT carry multi-word commands (e.g. an
            # editor + file path); single-word agent commands like `claude`
            # behave identically.
            eval "$_kooky_cmd"
            _kooky_status=$?
            # The agent ran in the foreground, so reaching here means it exited
            # — or never really started: a user alias (e.g. `alias pi=...`) can
            # shadow the PATH wrapper before its `ended` ping fires, stranding
            # the eagerly-promoted tab icon on the agent. Revert to a plain
            # shell. Idempotent — a wrapper that already pinged `ended` makes
            # this a no-op (`applyHookEvent` dedups same-value writes).
            if [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" ]]; then
                "$KOOKY_HOOK_BIN" "$_kooky_agent_bin" ended 2>/dev/null
            fi
            # Restore the agent's exit code — the revert ping clobbered `$?`,
            # but the first prompt (and theme hooks / `_kooky_title_pwd` that
            # read `$?`) should see the agent's real status, not our hook call's.
            ( exit $_kooky_status )
        fi
        """

    /// Two layers of memoization in this hook avoid heavy per-prompt work:
    /// (a) `node --version` is the dominant cost (~50-200ms for V8 cold-start
    ///     on every prompt). We cache its result against the resolved `node`
    ///     binary path + NVM_BIN — if neither changed, the cached version is
    ///     still valid.
    /// (b) the `kooky-hook env` IPC fork is skipped entirely when no env key
    ///     differs from the previous send. Most prompts have steady env, so
    ///     this turns the hook into a no-op the vast majority of the time.
    static let envStatusBlock = """
        _kooky_env_status() {
            [[ -n "$KOOKY_SURFACE_ID" && -n "$KOOKY_HOOK_BIN" && -x "$KOOKY_HOOK_BIN" ]] || return 0
            local _kooky_node_path=""
            command -v node >/dev/null 2>&1 && _kooky_node_path="$(command -v node)"
            local _kooky_node_key="${_kooky_node_path}|${NVM_BIN:-}"
            if [[ "$_kooky_node_key" != "$_KOOKY_NODE_KEY_LAST" ]]; then
                _KOOKY_NODE_VERSION_LAST=""
                [[ -n "$_kooky_node_path" ]] && _KOOKY_NODE_VERSION_LAST="$("$_kooky_node_path" --version 2>/dev/null)"
                _KOOKY_NODE_KEY_LAST="$_kooky_node_key"
            fi
            # Accept both lowercase and uppercase forms — curl / git / requests
            # respect lowercase; some tools (and many corp setups) export
            # uppercase only. Fall through to uppercase when lowercase is unset.
            local _kooky_https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
            local _kooky_http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
            local _kooky_all_proxy="${all_proxy:-${ALL_PROXY:-}}"
            local _kooky_env_now="${VIRTUAL_ENV:-}|${CONDA_DEFAULT_ENV:-}|${NVM_BIN:-}|${NVM_DIR:-}|$_KOOKY_NODE_VERSION_LAST|$_kooky_https_proxy|$_kooky_http_proxy|$_kooky_all_proxy"
            [[ "$_kooky_env_now" == "$_KOOKY_ENV_LAST" ]] && return 0
            # Only advance the dedup cache when the IPC actually succeeded —
            # if kooky-hook returns non-zero (kooky restarting, socket gone
            # before the hook server bound), the next prompt will retry
            # instead of staying frozen at the unsent value.
            "$KOOKY_HOOK_BIN" env "${VIRTUAL_ENV:-}" "${CONDA_DEFAULT_ENV:-}" "${NVM_BIN:-}" "${NVM_DIR:-}" "$_KOOKY_NODE_VERSION_LAST" "$_kooky_https_proxy" "$_kooky_http_proxy" "$_kooky_all_proxy" 2>/dev/null \
                && _KOOKY_ENV_LAST="$_kooky_env_now"
            # Mask our internal IPC status so user precmd hooks downstream in
            # zsh's precmd_functions chain don't see `$?=1` and bleed it into
            # their prompt rendering. The dedup logic is internal — its
            # success/failure must not leak into the rest of the shell.
            return 0
        }
        """

    /// FinalTerm / OSC 133 prompt+command boundary markers. libghostty parses
    /// these and fires `GHOSTTY_ACTION_COMMAND_FINISHED` on `D` (per-tab
    /// last-command status + duration, scroll-to-prompt jumps), and uses
    /// `A;cl=line` to anchor `cursor-click-to-move` so option-/single-click
    /// on a prompt jumps the shell cursor to that column. Re-injects the
    /// `B` marker into PROMPT on every redraw because Starship / p10k-style
    /// themes rebuild PROMPT each `precmd` and would otherwise drop our suffix.
    private static let osc133Block = #"""
        __kooky_133_first=1
        __kooky_133_precmd() {
            local last=$?
            if (( ! __kooky_133_first )); then
                printf '\e]133;D;%s\a' "$last"
            fi
            __kooky_133_first=0
            # `cl=line` is ghostty's required marker metadata — without it
            # libghostty silently ignores the prompt sentinel and features
            # that depend on it (`cursor-click-to-move`, jump-to-prompt)
            # stay dormant. `\a` (BEL) terminator matches ghostty's own
            # zsh shell-integration script exactly.
            printf '\e]133;A;cl=line\a'
            # Wrap the OSC 133 B marker in zsh's zero-width brackets (%{ ... %}).
            # Without them zsh counts every byte of the escape sequence (ESC, ],
            # `133;B`, BEL) toward the PROMPT's visible width, miscalculates the
            # wrap column by ~8 cells, and ZLE redraws the input on the wrong
            # row the moment a long input wraps — wiping the first visible line.
            [[ "$PROMPT" != *$'\e]133;B\a'* ]] && PROMPT="${PROMPT}"$'%{\e]133;B\a%}'
            _kooky_env_status
            # Same masking concern as `_kooky_env_status` itself: the kooky
            # hooks must not leak `$?` into user prompts that downstream
            # precmd hooks may sample.
            return 0
        }
        __kooky_133_preexec() {
            printf '\e]133;C\a'
            # The accepted command line, for the Session Info inspector. It
            # rides this same stream as the `D` result above precisely so it
            # can never arrive after the exit status it labels. Control
            # characters are flattened first: a raw BEL or ESC inside the
            # command would terminate the OSC string early and let the rest of
            # the command render as terminal output.
            #
            # Not `_kooky_cmd`: the agent-launch block below uses that name at
            # top level, and shadowing a global with a same-named local is a
            # trap for whoever edits either block next.
            local _kooky_preexec_cmd=${1//[[:cntrl:]]/ }
            if [[ -n "${_kooky_preexec_cmd//[[:space:]]/}" ]]; then
                printf '\e]2;\#(CommandMarker.titlePrefix)%s\a' "${_kooky_preexec_cmd:0:\#(CommandMarker.maxLength)}"
            fi
            return 0
        }
        add-zsh-hook precmd __kooky_133_precmd
        add-zsh-hook preexec __kooky_133_preexec
        """#

    /// Skips the write when the on-disk content already matches — the launch
    /// path rewrites ~30 managed files unconditionally, so a steady-state
    /// launch now pays cheap reads instead of ~30 atomic replaces (temp-file
    /// + rename each) on the pre-first-frame path. Per-spawn temp rc files
    /// always miss (fresh paths) and just pay one failed read.
    /// Internal: also the content-gated writer for other subsystems' managed
    /// files (KookySettings' sentinel themes) — same kookyAppSupport precedent.
    static func writeFile(at path: String, contents: String, executable: Bool = false) {
        if (try? String(contentsOfFile: path, encoding: .utf8)) != contents {
            try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if executable { chmod(path, 0o755) }
    }

    /// `writeFile` + existence post-check for the $TMPDIR shell-bridge files
    /// (issue #45). `writeFile` swallows write errors (`try?`), so the
    /// post-check is what turns "disk refused the write" into a false the
    /// caller can act on instead of handing zsh/bash a dead path. Logged both
    /// ways: the absent→written line is the forensic trace that TMPDIR cleanup
    /// struck (it also fires once per launch — first creation — which is cheap
    /// to tell apart by timestamp).
    private static func ensureBridgeFile(
        at path: String, contents: String, executable: Bool = false, label: String
    ) -> Bool {
        let existed = FileManager.default.fileExists(atPath: path)
        writeFile(at: path, contents: contents, executable: executable)
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("kooky: could not write \(label) at \(path) — spawning without shell integration")
            return false
        }
        if !existed {
            NSLog("kooky: \(label) was absent — wrote \(path) (first launch, or rebuilt after TMPDIR cleanup)")
        }
        return true
    }
}
