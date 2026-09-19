import Foundation
import SQLite3

/// Per-agent session-store readers beyond Claude/Codex (which live next to
/// the shared helpers in AgentSessionHistory.swift). Formats verified against
/// real stores / shipped CLI sources on 2026-07-27; all parsing stays
/// defensive per the scanner's contract — no field, no record, never an
/// error. Every reader returns already-capped slices via `scanStore` (or an
/// SQL LIMIT), so `scan`'s merge cost stays bounded no matter how large a
/// store grows.
extension AgentSessionScanner {

    // MARK: Pi / Oh My Pi (~/.pi|.omp/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl)

    /// Shared by Pi and its fork Oh My Pi — same JSONL lineage. Line 1 is a
    /// header `{type:"session", id, cwd, title?, parentSession?}` (omp adds
    /// auto-generated `title`); a rename APPENDS a `session_info` record
    /// (`{type:"session_info", name}`, last one wins — Pi's analog of
    /// Claude's `custom-title`).
    static func piStyleRecords(under root: URL, agentId: String) -> [AgentSessionRecord] {
        // omp writes advisor transcripts (`__advisor*.jsonl`) beside
        // sessions; its own session lister skips them.
        let files = projectFiles(under: root) { !$0.lastPathComponent.hasPrefix("__advisor") }
        return scanStore(files: files) { file, mtime in
            piStyleRecord(file: file, mtime: mtime, agentId: agentId)
        }
    }

    private static let sessionInfoMarker = Data("session_info".utf8)

    static func piStyleRecord(file: URL, mtime: Date, agentId: String) -> AgentSessionRecord? {
        var conversationId: String?
        var cwd: String?
        var headerTitle: String?
        var renamedTitle: String?
        var firstUserText: String?
        for line in headLines(of: file) {
            // Once the header and first user text are settled, only a
            // `session_info` rename (last wins) can still change the record —
            // gate the JSON parse on its byte marker, same as the Claude and
            // Codex walks (multi-KB message lines dominate the head).
            if conversationId != nil, firstUserText != nil,
               line.range(of: sessionInfoMarker) == nil {
                continue
            }
            guard let object = jsonObject(line) else { continue }
            switch object["type"] as? String {
            case "session":
                // Forked / subagent transcripts carry `parentSession` — not a
                // conversation the user can meaningfully resume.
                if object["parentSession"] as? String != nil { return nil }
                conversationId = object["id"] as? String
                cwd = object["cwd"] as? String
                headerTitle = object["title"] as? String
            case "session_info":
                if let name = object["name"] as? String { renamedTitle = name }
            case "message":
                guard firstUserText == nil,
                      let message = object["message"] as? [String: Any],
                      message["role"] as? String == "user",
                      let text = displayableUserText(messageContent(message["content"]))
                else { break }
                firstUserText = text
            default:
                break
            }
        }
        guard let conversationId, !conversationId.isEmpty, let cwd else { return nil }
        return AgentSessionRecord(
            agentId: agentId,
            conversationId: conversationId,
            title: cleanedTitle(renamedTitle ?? headerTitle ?? firstUserText ?? ""),
            cwd: URL(fileURLWithPath: cwd),
            lastActivity: mtime,
            createdAt: creationDate(of: file),
            sourceURL: file
        )
    }

    // MARK: Kimi Code (~/.kimi-code/session_index.jsonl + per-session state.json)

    /// Kimi keeps a flat global index — one line per session with
    /// `{sessionId, sessionDir, workDir}` — plus a small `state.json` per
    /// session carrying `{title, isCustomTitle, ...}`. The full `sessionId`
    /// string (`session_<uuid>`) is exactly what `kimi --session` takes.
    static func collectKimi(root: URL) -> [AgentSessionRecord] {
        let index = root.appendingPathComponent("session_index.jsonl")
        guard let data = try? Data(contentsOf: index) else { return [] }
        let entries = data.split(separator: UInt8(ascii: "\n")).compactMap { line -> (item: (id: String, stateURL: URL, cwd: String), mtime: Date)? in
            guard let object = jsonObject(line),
                  let id = object["sessionId"] as? String, !id.isEmpty,
                  let dir = object["sessionDir"] as? String,
                  let cwd = object["workDir"] as? String, !cwd.isEmpty
            else { return nil }
            let sessionDir = dir.hasPrefix("/")
                ? URL(fileURLWithPath: dir)
                : root.appendingPathComponent(dir, isDirectory: true)
            let stateURL = sessionDir.appendingPathComponent("state.json")
            guard let mtime = try? stateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return ((id, stateURL, cwd), mtime)
        }
        return scanStore(files: entries) { entry, mtime in
            var title = ""
            if let data = try? Data(contentsOf: entry.stateURL),
               let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let raw = state["title"] as? String {
                // Kimi never auto-titles — every untouched session is the
                // literal "New Session". Blank those so the row falls back
                // to the untitled placeholder instead of a wall of
                // identical non-names.
                let isCustom = state["isCustomTitle"] as? Bool ?? false
                if isCustom || raw != "New Session" { title = raw }
            }
            return AgentSessionRecord(
                agentId: AgentTemplate.kimi.id,
                conversationId: entry.id,
                title: cleanedTitle(title),
                cwd: URL(fileURLWithPath: entry.cwd),
                lastActivity: mtime,
                createdAt: creationDate(of: entry.stateURL.deletingLastPathComponent()),
                sourceURL: entry.stateURL.deletingLastPathComponent()
            )
        }
    }

    // MARK: OpenCode (~/.local/share/opencode/opencode.db, SQLite)

    /// OpenCode's store is a WAL-mode SQLite database; the `session` table
    /// carries every field as a first-class column, so the whole scan is one
    /// read-only query (system libsqlite3 — no dependency added).
    /// `parent_id IS NULL` filters subagent children; archived sessions stay
    /// out. A schema drift (renamed table/columns) fails `prepare` and
    /// yields an empty slice — same defensive stance as the file parsers.
    static func collectOpencode(root: URL) -> [AgentSessionRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT id, directory, title, time_updated FROM session \
        WHERE parent_id IS NULL AND time_archived IS NULL \
        ORDER BY time_updated DESC LIMIT \(perAgentCap)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var records: [AgentSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let dirText = sqlite3_column_text(statement, 1)
            else { continue }
            let id = String(cString: idText)
            let directory = String(cString: dirText)
            guard !id.isEmpty, !directory.isEmpty else { continue }
            let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let updatedMs = sqlite3_column_int64(statement, 3)
            records.append(AgentSessionRecord(
                agentId: AgentTemplate.opencode.id,
                conversationId: id,
                title: cleanedTitle(title),
                cwd: URL(fileURLWithPath: directory),
                lastActivity: Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000),
                sourceURL: root
            ))
        }
        return records
    }

    // MARK: Grok Build (~/.grok/sessions/<encoded-cwd>/<uuid>/summary.json)

    /// One dir per session; `summary.json` carries `{info: {id, cwd},
    /// session_summary, ...}` and is rewritten as the session progresses, so
    /// its mtime is the last activity. `session_summary` stays empty for the
    /// first few turns — fall back to the first user line of the sibling
    /// `chat_history.jsonl` (`{type: "user", content}`).
    static func collectGrok(root: URL) -> [AgentSessionRecord] {
        let files = twoLevelFiles(under: root, named: "summary.json")
        return scanStore(files: files) { file, mtime in
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let info = object["info"] as? [String: Any],
                  let id = info["id"] as? String, !id.isEmpty,
                  let cwd = info["cwd"] as? String, !cwd.isEmpty
            else { return nil }
            var title = (object["session_summary"] as? String) ?? ""
            if title.isEmpty {
                let history = file.deletingLastPathComponent().appendingPathComponent("chat_history.jsonl")
                for line in headLines(of: history) {
                    guard let entry = jsonObject(line), entry["type"] as? String == "user" else { continue }
                    // `content` is a plain string on older sessions and
                    // `[{type:"text",text}]` blocks on current ones. The real
                    // ask is wrapped in <user_query>…</user_query> among
                    // injected <user_info>/summary blocks — unwrap it, or the
                    // shared `<`-prefix filter would reject the actual prompt.
                    let text = messageContent(entry["content"])
                    guard let usable = displayableUserText(grokUserQuery(in: text) ?? text) else { continue }
                    title = usable
                    break
                }
            }
            return AgentSessionRecord(
                agentId: AgentTemplate.grok.id,
                conversationId: id,
                title: cleanedTitle(title),
                cwd: URL(fileURLWithPath: cwd),
                lastActivity: mtime,
                // summary.json is rewritten as the session progresses, so use the
                // session dir's creation date for "when it started".
                createdAt: creationDate(of: file.deletingLastPathComponent()),
                sourceURL: file.deletingLastPathComponent()
            )
        }
    }


    private static func grokUserQuery(in text: String?) -> String? {
        guard let text,
              let open = text.range(of: "<user_query>"),
              let close = text.range(of: "</user_query>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Cursor CLI (~/.cursor/chats/<md5-of-cwd>/<chat-uuid>/meta.json)

    /// `meta.json` is a tiny flat file: `{cwd, title, updatedAtMs,
    /// hasConversation}`; the chat id is the enclosing dir name. Sessions
    /// where no conversation ever happened (`hasConversation != true`) are
    /// empty shells — resuming one lands in a blank chat, so skip them.
    static func collectCursor(root: URL) -> [AgentSessionRecord] {
        let files = twoLevelFiles(under: root, named: "meta.json")
        return scanStore(files: files) { file, mtime in
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["hasConversation"] as? Bool == true,
                  let cwd = object["cwd"] as? String, !cwd.isEmpty
            else { return nil }
            let id = file.deletingLastPathComponent().lastPathComponent
            guard !id.isEmpty else { return nil }
            let updatedMs = object["updatedAtMs"] as? Double
            return AgentSessionRecord(
                agentId: AgentTemplate.cursor.id,
                conversationId: id,
                title: cleanedTitle((object["title"] as? String) ?? ""),
                cwd: URL(fileURLWithPath: cwd),
                lastActivity: updatedMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? mtime,
                sourceURL: file.deletingLastPathComponent()
            )
        }
    }

    // MARK: Copilot CLI (~/.copilot/session-state/<session-uuid>/workspace.yaml)

    /// `workspace.yaml` is flat `key: value` lines (`id`, `cwd`, `name`,
    /// `updated_at`, ...) — a first-`": "`-split per line parses it without
    /// any YAML machinery. `name` holds the first user prompt unless the
    /// user renamed the session. The dir name is the session id `--resume=`
    /// takes.
    static func collectCopilot(root: URL) -> [AgentSessionRecord] {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        let files = sessions.compactMap { session -> (item: URL, mtime: Date)? in
            let file = session.appendingPathComponent("workspace.yaml")
            guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (file, mtime)
        }
        return scanStore(files: files) { file, mtime in
            guard let data = try? Data(contentsOf: file) else { return nil }
            var fields: [String: String] = [:]
            // A multi-line first prompt is written as a block scalar
            // (`name: |-` + indented lines). Indented lines are NEVER
            // top-level fields — treating them as such let a prompt
            // containing "cwd: …" overwrite the real cwd. The block's first
            // line stands in as the field's value (titles get flattened and
            // truncated downstream anyway).
            var pendingBlockKey: String?
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if line.first == " " || line.first == "\t" {
                    if let key = pendingBlockKey {
                        fields[key] = line.trimmingCharacters(in: .whitespaces)
                        pendingBlockKey = nil
                    }
                    continue
                }
                pendingBlockKey = nil
                guard let separator = line.range(of: ": ") else { continue }
                let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = line[separator.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if value.hasPrefix("|") || value.hasPrefix(">") {
                    pendingBlockKey = key
                } else {
                    fields[key] = value
                }
            }
            let id = file.deletingLastPathComponent().lastPathComponent
            guard !id.isEmpty, let cwd = fields["cwd"], !cwd.isEmpty else { return nil }
            return AgentSessionRecord(
                agentId: AgentTemplate.copilot.id,
                conversationId: id,
                title: cleanedTitle(fields["name"] ?? ""),
                cwd: URL(fileURLWithPath: cwd),
                lastActivity: mtime,
                // workspace.yaml is rewritten, so the session dir's creation
                // date stands in for "when the conversation started".
                createdAt: creationDate(of: file.deletingLastPathComponent()),
                sourceURL: file.deletingLastPathComponent()
            )
        }
    }

    // MARK: Kiro CLI (~/Library/Application Support/kiro-cli/data.sqlite3)

    /// Kiro's current-generation store is one SQLite table:
    /// `conversations_v2(key, conversation_id, value, created_at, updated_at)`
    /// where `key` IS the cwd (verified live 2026-07-27) and `value` is a JSON
    /// blob. The blob can run tens of KB (embedded context), so the title is
    /// extracted IN SQL via json_extract — the fallback chain is Kiro's own
    /// running summary, then the first user prompt — and the blob itself is
    /// never shipped across. Kiro has no auto-title concept beyond that.
    static func collectKiro(root: URL) -> [AgentSessionRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT key, conversation_id, \
        COALESCE(json_extract(value, '$.latest_summary'), \
                 json_extract(value, '$.history[0].user.content.Prompt.prompt'), '') , \
        updated_at, created_at FROM conversations_v2 ORDER BY updated_at DESC LIMIT \(perAgentCap)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var records: [AgentSessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cwdText = sqlite3_column_text(statement, 0),
                  let idText = sqlite3_column_text(statement, 1)
            else { continue }
            let cwd = String(cString: cwdText)
            let id = String(cString: idText)
            guard !cwd.isEmpty, !id.isEmpty else { continue }
            let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let updatedMs = sqlite3_column_int64(statement, 3)
            let createdMs = sqlite3_column_int64(statement, 4)
            records.append(AgentSessionRecord(
                agentId: AgentTemplate.kiro.id,
                conversationId: id,
                title: cleanedTitle(displayableUserText(title) ?? ""),
                cwd: URL(fileURLWithPath: cwd),
                lastActivity: Date(timeIntervalSince1970: TimeInterval(updatedMs) / 1000),
                createdAt: createdMs > 0 ? Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000) : nil,
                sourceURL: root
            ))
        }
        return records
    }

    // MARK: Gemini CLI (~/.gemini/tmp/<project>/chats/session-*.jsonl)

    /// Modern Gemini CLI keeps one dir per project under `~/.gemini/tmp`,
    /// with the real project path in a `.project_root` sidecar (the dir name
    /// alone used to be an unreversible sha256 — a project dir without the
    /// sidecar is that legacy layout, carries no recoverable cwd, and is
    /// skipped). Session files are JSONL: a header line
    /// `{sessionId, kind, ...}` then `$set` mutation records that carry
    /// `summary` and the `messages` array. Verified live 2026-07-27 against
    /// the current npm build.
    static func collectGemini(root: URL) -> [AgentSessionRecord] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [(url: URL, mtime: Date, cwd: String)] = []
        for project in projects {
            guard let marker = try? String(contentsOf: project.appendingPathComponent(".project_root"), encoding: .utf8) else {
                continue
            }
            let cwd = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty,
                  let sessions = try? fm.contentsOfDirectory(
                    at: project.appendingPathComponent("chats"),
                    includingPropertiesForKeys: [.contentModificationDateKey]
                  )
            else { continue }
            for file in sessions {
                guard file.pathExtension == "jsonl",
                      file.lastPathComponent.hasPrefix("session-"),
                      let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                files.append((file, mtime, cwd))
            }
        }
        return scanStore(files: files.map { (item: (url: $0.url, cwd: $0.cwd), mtime: $0.mtime) }) { item, mtime in
            geminiRecord(file: item.url, mtime: mtime, cwd: item.cwd)
        }
    }

    static func geminiRecord(file: URL, mtime: Date, cwd: String) -> AgentSessionRecord? {
        var sessionId: String?
        var summary: String?
        var firstUserText: String?
        for line in headLines(of: file) {
            // Same gate family as the Claude/Codex/pi walks: once the header
            // and first user text settle, only a `summary` update matters —
            // `$set` lines carry whole message-array snapshots otherwise.
            if sessionId != nil, firstUserText != nil,
               line.range(of: summaryMarker) == nil {
                continue
            }
            guard let object = jsonObject(line) else { continue }
            if let id = object["sessionId"] as? String {
                // Header line. Subagent transcripts record `kind` other than
                // "main" — not something the user can resume.
                guard object["kind"] as? String == "main" else { return nil }
                sessionId = id
            } else if let set = object["$set"] as? [String: Any] {
                if let value = set["summary"] as? String, !value.isEmpty { summary = value }
                guard firstUserText == nil, let messages = set["messages"] as? [[String: Any]] else { continue }
                for message in messages where message["type"] as? String == "user" {
                    // Gemini content blocks are bare `{text}` (no `type` key);
                    // the leading session_context injection starts with `<`
                    // and falls to the shared displayable-text filter.
                    let text = (message["content"] as? [[String: Any]])?
                        .compactMap { $0["text"] as? String }
                        .first
                    if let usable = displayableUserText(text) {
                        firstUserText = usable
                        break
                    }
                }
            }
        }
        guard let sessionId, !sessionId.isEmpty else { return nil }
        return AgentSessionRecord(
            agentId: AgentTemplate.gemini.id,
            conversationId: sessionId,
            title: cleanedTitle(summary ?? firstUserText ?? ""),
            cwd: URL(fileURLWithPath: cwd),
            lastActivity: mtime,
            createdAt: creationDate(of: file),
            sourceURL: file
        )
    }

    // MARK: Droid (~/.factory/sessions/<munged-cwd>/<sessionId>.jsonl)

    /// Format pinned from the shipped Bun bundle (v0.157.1): line 1 is a
    /// `session_start` record carrying id/title/cwd; a rename REWRITES line 1
    /// in place (and restores mtime), so a head read always sees the current
    /// title and mtime stays "last activity". Sessions live one level deep in
    /// `-`-prefixed munged-cwd dirs plus legacy flat files at the top level;
    /// `btw/` holds background forks droid itself never lists.
    static func collectDroid(root: URL) -> [AgentSessionRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return [] }
        var files: [(item: URL, mtime: Date)] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                // Project dirs are `-`-prefixed; this also excludes `btw/`.
                guard entry.lastPathComponent.hasPrefix("-"),
                      let sessions = try? fm.contentsOfDirectory(
                        at: entry, includingPropertiesForKeys: [.contentModificationDateKey]
                      )
                else { continue }
                for file in sessions {
                    guard file.pathExtension == "jsonl",
                          let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    else { continue }
                    files.append((file, mtime))
                }
            } else if entry.pathExtension == "jsonl",
                      let mtime = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                files.append((entry, mtime))
            }
        }
        return scanStore(files: files, parse: droidRecord)
    }

    static func droidRecord(file: URL, mtime: Date) -> AgentSessionRecord? {
        let lines = headLines(of: file)
        // A single-line file is a session that never got a message — droid's
        // own index skips those too.
        guard lines.count >= 2, let first = lines.first, let object = jsonObject(first),
              object["type"] as? String == "session_start",
              let id = object["id"] as? String, !id.isEmpty
        else { return nil }
        // Subagent workers and background forks carry lineage fields.
        guard object["callingSessionId"] == nil || object["callingSessionId"] is NSNull,
              object["parent"] == nil || object["parent"] is NSNull,
              object["decompSessionType"] as? String != "worker"
        else { return nil }
        guard let cwd = (object["lastCwd"] as? String) ?? (object["cwd"] as? String), !cwd.isEmpty else {
            return nil
        }
        // Droid hides archived sessions and btw forks by default; the
        // sidecar carries both markers.
        let sidecar = file.deletingPathExtension().appendingPathExtension("settings.json")
        if let data = try? Data(contentsOf: sidecar),
           let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if settings["archivedAt"] as? String != nil { return nil }
            if let tags = settings["tags"] as? [[String: Any]],
               tags.contains(where: { $0["name"] as? String == "btw-fork" }) {
                return nil
            }
        }
        let sessionTitle = (object["sessionTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = sessionTitle ?? (object["title"] as? String) ?? ""
        return AgentSessionRecord(
            agentId: AgentTemplate.droid.id,
            conversationId: id,
            title: cleanedTitle(title),
            cwd: URL(fileURLWithPath: cwd),
            lastActivity: mtime,
            createdAt: creationDate(of: file),
            sourceURL: file
        )
    }

    // MARK: Reasonix (~/.reasonix/projects/<slug>/sessions/*.jsonl + .meta sidecar)

    /// Format pinned from the v1.17.21 source (exact tag of the installed
    /// binary). The transcript itself carries NO id and NO cwd — both live in
    /// the tiny `<file>.jsonl.meta` sidecar refreshed on every autosave:
    /// `{id, custom_title, topic_title, preview, workspace_root, turns,
    /// schema_version, ...}`. `preview` is the first REAL user prompt with
    /// Reasonix's own synthetic-block filters already applied. The session id
    /// IS the filename stem, which `reasonix --resume <stem>` matches
    /// exactly and deterministically. Sessions with no sidecar (or a
    /// pre-v1 sidecar) are skipped rather than guessed at.
    static func collectReasonix(root: URL) -> [AgentSessionRecord] {
        let files = projectFiles(under: root, subdir: "sessions") { file in
            let name = file.lastPathComponent
            // The same dir holds event/conflict/guardian sidecars whose
            // names also end in .jsonl — a bare glob would resurrect event
            // logs as phantom sessions — and a cleanup-pending marker means
            // trashed/hidden.
            guard !name.hasSuffix(".events.jsonl"),
                  !name.hasSuffix(".conflicts.jsonl"),
                  !name.hasSuffix(".guardian.jsonl")
            else { return false }
            let pending = file.deletingPathExtension().appendingPathExtension("cleanup-pending.json")
            return !FileManager.default.fileExists(atPath: pending.path)
        }
        return scanStore(files: files, parse: reasonixRecord)
    }

    static func reasonixRecord(file: URL, mtime: Date) -> AgentSessionRecord? {
        let meta = file.appendingPathExtension("meta")
        guard let data = try? Data(contentsOf: meta),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["schema_version"] as? Int ?? 0) >= 1,
              let cwd = object["workspace_root"] as? String, !cwd.isEmpty
        else { return nil }
        // Zero-turn sessions are invisible to Reasonix's own picker.
        guard (object["turns"] as? Int ?? 0) > 0 else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return nil }
        let title = firstNonEmpty(object["custom_title"], object["topic_title"], object["preview"])
        return AgentSessionRecord(
            agentId: AgentTemplate.reasonix.id,
            conversationId: stem,
            title: cleanedTitle(title ?? ""),
            cwd: URL(fileURLWithPath: cwd),
            lastActivity: mtime,
            createdAt: creationDate(of: file),
            sourceURL: file
        )
    }

    private static func firstNonEmpty(_ values: Any?...) -> String? {
        for value in values {
            if let text = value as? String, !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: Shared directory walker

    /// `<root>/<group>/<session>/<name>` — the two-level per-session-dir
    /// layout Grok and Cursor share. Returns the named file per session dir
    /// with its mtime.
    private static func twoLevelFiles(under root: URL, named name: String) -> [(item: URL, mtime: Date)] {
        let fm = FileManager.default
        guard let groups = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return groups.flatMap { group -> [(item: URL, mtime: Date)] in
            guard let sessions = try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: nil) else {
                return []
            }
            return sessions.compactMap { session in
                let file = session.appendingPathComponent(name)
                guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (file, mtime)
            }
        }
    }

    /// Deletes the backing store entry for a session and its local companion
    /// files. The primary record must disappear before returning `true`.
    static func delete(_ record: AgentSessionRecord) -> Bool {
        guard record.sourceURL.path != "/dev/null" else { return false }
        switch record.agentId {
        case AgentTemplate.claudeCodeID:
            return deleteClaude(record)
        case AgentTemplate.codex.id:
            return deleteCodex(record)
        case AgentTemplate.kimi.id:
            return deleteKimi(record)
        case AgentTemplate.opencode.id:
            return deleteSQLiteRow(root: record.sourceURL, table: "session", idColumn: "id", id: record.conversationId)
        case AgentTemplate.kiro.id:
            return deleteSQLiteRow(
                root: record.sourceURL,
                table: "conversations_v2",
                idColumn: "conversation_id",
                id: record.conversationId,
                secondColumn: "key",
                secondValue: record.cwd.path
            )
        case AgentTemplate.droid.id:
            return deleteFileAndSidecars(record.sourceURL, extensions: ["settings.json"])
        case AgentTemplate.reasonix.id:
            return deleteReasonix(record.sourceURL)
        default:
            return removePrimary(record.sourceURL)
        }
    }

    private static func deleteClaude(_ record: AgentSessionRecord) -> Bool {
        guard removePrimary(record.sourceURL) else { return false }
        let project = record.sourceURL.deletingLastPathComponent()
        if let files = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(record.conversationId + ".jsonl.bak.") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        _ = removeJSONArrayEntry(at: project.appendingPathComponent("sessions-index.json"), id: record.conversationId)
        return true
    }

    private static func deleteCodex(_ record: AgentSessionRecord) -> Bool {
        guard removePrimary(record.sourceURL) else { return false }
        if let sessions = ancestor(named: "sessions", from: record.sourceURL) {
            _ = removeJSONLLine(at: sessions.deletingLastPathComponent().appendingPathComponent("history.jsonl"), id: record.conversationId)
        }
        return true
    }

    private static func deleteKimi(_ record: AgentSessionRecord) -> Bool {
        guard removePrimary(record.sourceURL) else { return false }
        if let root = ancestor(containing: "session_index.jsonl", from: record.sourceURL) {
            _ = removeJSONLLine(at: root.appendingPathComponent("session_index.jsonl"), id: record.conversationId)
        }
        return true
    }

    private static func deleteFileAndSidecars(_ file: URL, extensions: [String]) -> Bool {
        guard removePrimary(file) else { return false }
        let stem = file.deletingPathExtension()
        for ext in extensions {
            try? FileManager.default.removeItem(at: stem.appendingPathExtension(ext))
        }
        return true
    }

    private static func deleteReasonix(_ file: URL) -> Bool {
        guard removePrimary(file) else { return false }
        let stem = file.deletingPathExtension()
        for sidecar in [
            file.appendingPathExtension("meta"),
            stem.appendingPathExtension("events.jsonl"),
            stem.appendingPathExtension("conflicts.jsonl"),
            stem.appendingPathExtension("guardian.jsonl"),
            stem.appendingPathExtension("cleanup-pending.json")
        ] {
            try? FileManager.default.removeItem(at: sidecar)
        }
        return true
    }
    private static func removePrimary(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func ancestor(named name: String, from url: URL) -> URL? {
        var current = url.deletingLastPathComponent()
        for _ in 0..<12 {
            if current.lastPathComponent == name { return current }
            let parent = current.deletingLastPathComponent()
            if parent == current { return nil }
            current = parent
        }
        return nil
    }

    private static func ancestor(containing name: String, from url: URL) -> URL? {
        var current = url.deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(name).path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent == current { return nil }
            current = parent
        }
        return nil
    }

    private static func removeJSONLLine(at url: URL, id: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.filter { line in
            guard let object = jsonObject(Data(line.utf8)) else { return true }
            return (object["sessionId"] as? String) != id && (object["session_id"] as? String) != id
        }
        guard kept.count != lines.count else { return true }
        do {
            let outputText = kept.map(String.init).joined(separator: "\n")
            guard let output = outputText.data(using: String.Encoding.utf8) else { return false }
            try output.write(to: url, options: Data.WritingOptions.atomic)
            return true
        } catch {
            return false
        }
    }

    private static func removeJSONArrayEntry(at url: URL, id: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        guard var entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        let originalCount = entries.count
        entries.removeAll { entry in
            (entry["sessionId"] as? String) == id || (entry["session_id"] as? String) == id || (entry["id"] as? String) == id
        }
        guard entries.count != originalCount else { return true }
        do {
            let output = try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted])
            try output.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func deleteSQLiteRow(
        root: URL,
        table: String,
        idColumn: String,
        id: String,
        secondColumn: String? = nil,
        secondValue: String? = nil
    ) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        guard sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        let sql = secondColumn == nil
            ? "DELETE FROM \(table) WHERE \(idColumn) = ?"
            : "DELETE FROM \(table) WHERE \(idColumn) = ? AND \(secondColumn!) = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if let secondValue { sqlite3_bind_text(statement, 2, secondValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    // MARK: On-demand first-message text (history hover)

    /// Full (untruncated, multi-line) text of a conversation's first user
    /// message, read only when the History row is hovered — never during a
    /// scan. `record.sourceURL` locates the backing store per agent; agents
    /// whose first-message format isn't cheaply recoverable (OpenCode,
    /// Cursor, Kimi, Droid) return nil so the hover falls back to the title.
    static func firstMessageText(for record: AgentSessionRecord) -> String? {
        switch record.agentId {
        case AgentTemplate.claudeCodeID:
            return claudeFirstUserText(of: record.sourceURL)
        case AgentTemplate.codex.id:
            return codexFirstUserText(of: record.sourceURL)
        case AgentTemplate.pi.id, AgentTemplate.ohMyPi.id:
            return piStyleFirstUserText(of: record.sourceURL)
        case AgentTemplate.gemini.id:
            return geminiFirstUserText(of: record.sourceURL)
        case AgentTemplate.grok.id:
            return grokFirstUserText(in: record.sourceURL)
        case AgentTemplate.reasonix.id:
            return reasonixFirstUserText(of: record.sourceURL)
        case AgentTemplate.copilot.id:
            return copilotFirstPrompt(of: record.sourceURL)
        case AgentTemplate.kiro.id:
            return kiroFirstPrompt(root: record.sourceURL, conversationId: record.conversationId, cwd: record.cwd.path)
        default:
            return nil
        }
    }

    /// Claude: first non-sidechain `user` line's text block. Mirrors the
    /// `claudeRecord` extraction minus the title truncation/flattening. A
    /// sidechain line is skipped, not terminal — a real user ask may follow
    /// (unlike the record build, where sidechain means "drop the file").
    private static func claudeFirstUserText(of file: URL) -> String? {
        for line in headLines(of: file) {
            guard let object = jsonObject(line), object["type"] as? String == "user" else { continue }
            if object["isSidechain"] as? Bool == true { continue }
            guard let message = object["message"] as? [String: Any] else { continue }
            if let text = displayableUserText(messageContent(message["content"])) { return text }
        }
        return nil
    }

    /// Codex: first `user_message` event's text.
    private static func codexFirstUserText(of file: URL) -> String? {
        for line in headLines(of: file).dropFirst() {
            guard line.range(of: userMessageMarker) != nil, let object = jsonObject(line) else { continue }
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message"
            else { continue }
            return displayableUserText(payload["message"] as? String)
        }
        return nil
    }

    /// Pi / OhMyPi: first `role == user` message.
    private static func piStyleFirstUserText(of file: URL) -> String? {
        for line in headLines(of: file) {
            guard let object = jsonObject(line), object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "user"
            else { continue }
            if let text = displayableUserText(messageContent(message["content"])) { return text }
        }
        return nil
    }

    /// Gemini: first user message across `$set.messages` snapshots.
    private static func geminiFirstUserText(of file: URL) -> String? {
        for line in headLines(of: file) {
            guard let object = jsonObject(line),
                  let set = object["$set"] as? [String: Any],
                  let messages = set["messages"] as? [[String: Any]]
            else { continue }
            for message in messages where message["type"] as? String == "user" {
                let text = (message["content"] as? [[String: Any]])?
                    .compactMap { $0["text"] as? String }
                    .first
                if let usable = displayableUserText(text) { return usable }
            }
        }
        return nil
    }

    /// Grok: first `user` line of the sibling chat_history.jsonl, unwrapping
    /// the `<user_query>` wrapper like the scan fallback does.
    private static func grokFirstUserText(in sessionDir: URL) -> String? {
        let history = sessionDir.appendingPathComponent("chat_history.jsonl")
        for line in headLines(of: history) {
            guard let entry = jsonObject(line), entry["type"] as? String == "user" else { continue }
            let text = messageContent(entry["content"])
            if let usable = displayableUserText(grokUserQuery(in: text) ?? text) { return usable }
        }
        return nil
    }

    /// Reasonix: `.meta` sidecar's `preview` — already the first real user
    /// prompt with synthetic blocks filtered.
    private static func reasonixFirstUserText(of file: URL) -> String? {
        let meta = file.appendingPathExtension("meta")
        guard let data = try? Data(contentsOf: meta),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let preview = object["preview"] as? String
        else { return nil }
        return displayableUserText(preview)
    }

    /// Copilot: `name` in workspace.yaml. The scan keeps only the block
    /// scalar's FIRST line for the title; hover wants the whole prompt, so
    /// re-read the `name` block across all its indented lines.
    private static func copilotFirstPrompt(of sessionDir: URL) -> String? {
        let file = sessionDir.appendingPathComponent("workspace.yaml")
        guard let data = try? Data(contentsOf: file) else { return nil }
        var collecting = false
        var blockLines: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.first == " " || line.first == "\t" {
                if collecting { blockLines.append(String(line)) }
                continue
            }
            collecting = false
            guard let separator = line.range(of: ": ") else { continue }
            let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            if key == "name" {
                let value = line[separator.upperBound...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if value.hasPrefix("|") || value.hasPrefix(">") {
                    collecting = true
                } else if !value.isEmpty {
                    return displayableUserText(String(value))
                }
            }
        }
        guard !blockLines.isEmpty else { return nil }
        return displayableUserText(blockLines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
    }

    /// Kiro: the first user prompt read whole out of the blob via
    /// json_extract — same column the scan uses, without the title cap.
    private static func kiroFirstPrompt(root: URL, conversationId: String, cwd: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT json_extract(value, '$.history[0].user.content.Prompt.prompt') FROM conversations_v2 WHERE conversation_id = ? AND key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, conversationId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, cwd, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return displayableUserText(String(cString: text))
    }
}
