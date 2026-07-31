import XCTest
@testable import KookyKit

@MainActor
final class PersistenceTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kooky-test-\(UUID().uuidString).json")
    }

    /// Minimal valid `PersistedState` — one workspace, one pane, one tab.
    private func makeState(workspaceId: UUID = UUID(), dir: String = "/tmp") -> PersistedState {
        let tab = PersistedTab(id: UUID(), agentId: "terminal", currentDirectoryPath: dir)
        let pane = PersistedPane(id: UUID(), tabs: [tab], activeTabId: tab.id)
        let node = PersistedPaneNode(id: pane.id, kind: .pane(pane))
        let ws = PersistedWorkspace(id: workspaceId, workingDirectoryPath: dir, root: node)
        return PersistedState(workspaces: [ws], activeWorkspaceId: workspaceId, sidebarMode: .full)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url)
    }

    // MARK: - Backward compatibility

    func testLoadsLegacyBarePersistedStateAsOneWindow() throws {
        // Pre-multi-window kooky wrote a bare PersistedState. It must migrate
        // to a single window, not get dropped.
        let url = tempURL()
        let legacy = makeState()
        try write(legacy, to: url)
        let app = AppPersistence(fileURL: url)
        XCTAssertEqual(app.windowIds.count, 1)
        XCTAssertEqual(app.state(for: app.windowIds[0]), legacy)
    }

    func testLoadsNewMultiWindowFormatInOrder() throws {
        let url = tempURL()
        let w1 = PersistedWindow(id: UUID(), state: makeState(dir: "/tmp/one"))
        let w2 = PersistedWindow(id: UUID(), state: makeState(dir: "/tmp/two"))
        try write(PersistedApp(windows: [w1, w2]), to: url)
        let app = AppPersistence(fileURL: url)
        XCTAssertEqual(app.windowIds, [w1.id, w2.id])
        XCTAssertEqual(app.state(for: w2.id), w2.state)
    }

    func testMissingOrCorruptFileLoadsEmpty() throws {
        XCTAssertTrue(AppPersistence(fileURL: tempURL()).windowIds.isEmpty)
        let url = tempURL()
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(AppPersistence(fileURL: url).windowIds.isEmpty)
    }

    // MARK: - Window slots

    func testSetWindowUpsertsAndAppendsNewIdsLast() {
        let app = AppPersistence(fileURL: tempURL())
        let a = UUID(), b = UUID()
        app.setWindow(a, state: makeState(dir: "/a"))
        app.setWindow(b, state: makeState(dir: "/b"))
        XCTAssertEqual(app.windowIds, [a, b])
        let updated = makeState(dir: "/a-updated")
        app.setWindow(a, state: updated)
        XCTAssertEqual(app.windowIds, [a, b], "updating an existing id keeps order")
        XCTAssertEqual(app.state(for: a), updated)
    }

    func testRemoveWindowDropsTheSlot() {
        let app = AppPersistence(fileURL: tempURL())
        let a = UUID(), b = UUID()
        app.setWindow(a, state: makeState())
        app.setWindow(b, state: makeState())
        app.removeWindow(a)
        XCTAssertEqual(app.windowIds, [b])
        XCTAssertNil(app.state(for: a))
    }

    func testSetWindowPersistsToDiskImmediately() {
        let url = tempURL()
        let app = AppPersistence(fileURL: url)
        let id = UUID()
        let state = makeState(dir: "/persisted")
        app.setWindow(id, state: state)
        // setWindow writes synchronously — a fresh reader sees it at once.
        let reloaded = AppPersistence(fileURL: url)
        XCTAssertEqual(reloaded.windowIds, [id])
        XCTAssertEqual(reloaded.state(for: id), state)
    }

    func testPendingRemoteReapPersistsAlongsideWindowsAndCanBeCleared() {
        let url = tempURL()
        let app = AppPersistence(fileURL: url)
        let token = UUID()
        let reap = PersistedRemoteReap(
            runtimeToken: token,
            destination: "deploy@example.com",
            sshPort: 2222,
            identityFile: "/tmp/id key",
            createdAt: Date(timeIntervalSince1970: 123)
        )

        app.recordPendingRemoteReap(reap)
        XCTAssertEqual(
            AppPersistence.loadAppFromDisk(from: url).pendingRemoteReaps,
            [reap]
        )

        app.clearPendingRemoteReap(runtimeToken: token)
        XCTAssertTrue(
            AppPersistence.loadAppFromDisk(from: url).pendingRemoteReaps.isEmpty
        )
    }

    func testPreReapAppSchemaDecodesWithEmptyLeaseList() throws {
        let window = PersistedWindow(id: UUID(), state: makeState())
        let data = try JSONSerialization.data(withJSONObject: [
            "windows": [
                try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(window)
                    ) as? [String: Any]
                ),
            ],
        ])
        let decoded = try JSONDecoder().decode(PersistedApp.self, from: data)
        XCTAssertEqual(decoded.windows, [window])
        XCTAssertTrue(decoded.pendingRemoteReaps.isEmpty)
    }

    // MARK: - WindowPersistence

    func testWindowPersistenceIsolatesTwoWindows() {
        // Two stores sharing one state.json must not see each other's slice.
        let app = AppPersistence(fileURL: tempURL())
        let a = WindowPersistence(windowId: UUID(), app: app)
        let b = WindowPersistence(windowId: UUID(), app: app)
        let stateA = makeState(dir: "/window-a")
        let stateB = makeState(dir: "/window-b")
        a.save(stateA)
        b.save(stateB)
        XCTAssertEqual(a.load(), stateA)
        XCTAssertEqual(b.load(), stateB)
    }

    // MARK: - Worktree fields

    func testPersistedWorkspaceRoundtripsWorktreeFields() throws {
        let parentId = UUID()
        let dir = "/tmp/parent-feat-x"
        let tab = PersistedTab(id: UUID(), agentId: "terminal", currentDirectoryPath: dir)
        let pane = PersistedPane(id: UUID(), tabs: [tab], activeTabId: tab.id)
        let node = PersistedPaneNode(id: pane.id, kind: .pane(pane))
        let ws = PersistedWorkspace(
            id: UUID(),
            workingDirectoryPath: dir,
            root: node,
            worktreeParentId: parentId,
            worktreeBranch: "feat-x",
            worktreePath: dir
        )
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(PersistedWorkspace.self, from: data)
        XCTAssertEqual(decoded.worktreeParentId, parentId)
        XCTAssertEqual(decoded.worktreeBranch, "feat-x")
        XCTAssertEqual(decoded.worktreePath, dir)
    }

    // MARK: - Sidebar content

    func testSidebarContentRoundtrips() throws {
        var state = makeState()
        state.sidebarContent = .files
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.sidebarContent, .files)
    }

    func testRightSidebarContentRoundtrips() throws {
        var state = makeState()
        state.rightSidebarContent = .history
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.rightSidebarContent, .history)
    }

    func testRightSidebarContentDecodesNilFromPreHistoryStateFiles() throws {
        // state.json files written before the History pane omit the key —
        // decode must succeed and leave it nil (→ `.agents`).
        let data = try JSONEncoder().encode(makeState())
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self).contains("rightSidebarContent"),
            "nil must encode as an absent key, or old kooky versions choke on the file"
        )
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertNil(decoded.rightSidebarContent)
    }

    func testSidebarContentDecodesNilFromPreFileTreeStateFiles() throws {
        // state.json files written before the file-tree toggle existed omit
        // the key — decode must succeed and leave it nil (→ `.workspaces`).
        let legacy = makeState()
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(
            String(decoding: data, as: UTF8.self).contains("sidebarContent"),
            "nil must encode as an absent key, or old kooky versions choke on the file"
        )
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertNil(decoded.sidebarContent)
    }

    func testPersistedWorkspaceDecodesNilWhenWorktreeFieldsMissing() throws {
        // Pre-worktree state.json files omit both keys — decode must succeed
        // and leave the fields nil so plain workspaces stay plain on upgrade.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "workingDirectoryPath": "/tmp",
          "root": {
            "id": "\(UUID().uuidString)",
            "kind": { "pane": { "id": "\(UUID().uuidString)", "tabs": [] } }
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            PersistedWorkspace.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.worktreeParentId)
        XCTAssertNil(decoded.worktreeBranch)
        XCTAssertNil(decoded.worktreePath)
    }

    func testLegacySSHWorkspaceMigratesToTransport() throws {
        let data = try JSONEncoder().encode(makeState())
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var workspaces = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        workspaces[0].removeValue(forKey: "transport")
        workspaces[0]["sshRemoteHost"] = " deploy@example.com "
        json["workspaces"] = workspaces
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(PersistedState.self, from: legacyData)
        XCTAssertEqual(
            decoded.workspaces[0].resolvedTransport,
            .ssh(try XCTUnwrap(SSHWorkspaceConfiguration(destination: "deploy@example.com")))
        )
    }

    func testMoshPersistenceDualWritesRealDestinationForOldKooky() throws {
        var state = makeState()
        let configuration = try XCTUnwrap(
            MoshWorkspaceConfiguration(destination: "devbox")
        )
        state.workspaces[0].transport = .mosh(configuration)
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let workspace = try XCTUnwrap(
            (json["workspaces"] as? [[String: Any]])?.first
        )
        let transport = try XCTUnwrap(workspace["transport"] as? [String: Any])

        XCTAssertEqual(workspace["sshRemoteHost"] as? String, "devbox")
        XCTAssertEqual(transport["kind"] as? String, "mosh")
        XCTAssertEqual(transport["destination"] as? String, "devbox")

        // Simulate an old decoder that knows only the legacy field.
        XCTAssertEqual(workspace["sshRemoteHost"] as? String, "devbox")
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(
            decoded.workspaces[0].resolvedTransport,
            .mosh(configuration)
        )
    }

    func testMalformedMoshTransportBecomesPlaceholderWithoutDroppingSiblingWorkspace() throws {
        var state = makeState()
        var sibling = state.workspaces[0]
        sibling.id = UUID()
        sibling.transport = .local
        sibling.sshRemoteHost = nil
        state.workspaces.append(sibling)
        let data = try JSONEncoder().encode(state)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var workspaces = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        workspaces[0]["transport"] = [
            "kind": "mosh",
            "destination": "devbox",
            "udpPort": ["kind": "range", "lower": 61_000, "upper": 60_000],
            "prediction": "adaptive",
        ]
        workspaces[0]["sshRemoteHost"] = "devbox"
        json["workspaces"] = workspaces

        let decoded = try JSONDecoder().decode(
            PersistedState.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertEqual(decoded.workspaces.count, 2)
        XCTAssertEqual(
            decoded.workspaces[0].resolvedTransport,
            .unsupported(kind: "mosh", destination: "devbox")
        )
        XCTAssertEqual(decoded.workspaces[1].resolvedTransport, .local)
    }
}
