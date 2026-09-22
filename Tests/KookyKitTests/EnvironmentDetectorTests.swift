import XCTest
@testable import KookyKit

final class EnvironmentDetectorTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tempDir = fm.temporaryDirectory.appendingPathComponent("kooky-env-test-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: tempDir)
        super.tearDown()
    }

    func testEmptyDirectoryReturnsEmpty() {
        let env = EnvironmentDetector.detect(cwd: tempDir, pid: nil)
        XCTAssertNil(env.pythonVenv)
        XCTAssertNil(env.nodeVersion)
        XCTAssertTrue(env.isEmpty)
    }

    func testNvmrcInCurrentDirReadsAndPrefixesV() throws {
        try "20.10.0\n".write(to: tempDir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EnvironmentDetector.detect(cwd: tempDir, pid: nil).nodeVersion, "v20.10.0")
    }

    func testNvmrcWithVPrefixUnchanged() throws {
        try "v18.17.0".write(to: tempDir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EnvironmentDetector.detect(cwd: tempDir, pid: nil).nodeVersion, "v18.17.0")
    }

    func testNvmrcAliasesPassThroughVerbatim() throws {
        // nvm/asdf/fnm aliases — must not be coerced into `vlts/*` etc.
        for alias in ["lts/*", "lts/iron", "node", "system"] {
            try alias.write(to: tempDir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
            XCTAssertEqual(
                EnvironmentDetector.detect(cwd: tempDir, pid: nil).nodeVersion,
                alias,
                "alias '\(alias)' should pass through unchanged"
            )
        }
    }

    func testNodeVersionFileFallback() throws {
        // .node-version is the asdf/fnm/mise convention — same role as .nvmrc.
        try "21.5.0".write(to: tempDir.appendingPathComponent(".node-version"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EnvironmentDetector.detect(cwd: tempDir, pid: nil).nodeVersion, "v21.5.0")
    }

    func testNvmrcInAncestorIsFound() throws {
        try "16.0.0".write(to: tempDir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        let nested = tempDir.appendingPathComponent("a/b/c", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(EnvironmentDetector.detect(cwd: nested, pid: nil).nodeVersion, "v16.0.0")
    }

    func testPyvenvCfgIsRequiredMarker() throws {
        // A bare `.venv` directory without `pyvenv.cfg` is not a virtualenv —
        // could be any user folder. Detector should return nil.
        let bareVenv = tempDir.appendingPathComponent(".venv", isDirectory: true)
        try fm.createDirectory(at: bareVenv, withIntermediateDirectories: true)
        XCTAssertNil(EnvironmentDetector.detect(cwd: tempDir, pid: nil).pythonVenv)
    }

    func testVenvWithCfgReturnsName() throws {
        let venv = tempDir.appendingPathComponent(".venv", isDirectory: true)
        try fm.createDirectory(at: venv, withIntermediateDirectories: true)
        try "home = /usr/bin\n".write(to: venv.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EnvironmentDetector.detect(cwd: tempDir, pid: nil).pythonVenv, ".venv")
    }

    func testNonStandardVenvName() throws {
        // The detector accepts `.venv`, `venv`, `env` — confirm `venv` works.
        let venv = tempDir.appendingPathComponent("venv", isDirectory: true)
        try fm.createDirectory(at: venv, withIntermediateDirectories: true)
        try "".write(to: venv.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EnvironmentDetector.detect(cwd: tempDir, pid: nil).pythonVenv, "venv")
    }

    // MARK: - shell env path (matches Warp accuracy: nvm use / venv activate)

    func testNvmBinExtractsVersionFromPath() {
        let env = [
            "NVM_BIN": "/Users/corey/.nvm/versions/node/v25.1.0/bin",
            "NVM_DIR": "/Users/corey/.nvm"
        ]
        let result = EnvironmentDetector.extract(shellEnv: env, cwd: tempDir)
        XCTAssertEqual(result.nodeVersion, "v25.1.0")
        XCTAssertEqual(result.nvmDirectory, "/Users/corey/.nvm")
    }

    func testNvmBinTakesPriorityOverNvmrc() throws {
        // Even when a `.nvmrc` says v18, the user's actual `nvm use 25` wins.
        try "18.0.0".write(to: tempDir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        let env = ["NVM_BIN": "/Users/me/.nvm/versions/node/v25.1.0/bin"]
        XCTAssertEqual(EnvironmentDetector.extract(shellEnv: env, cwd: tempDir).nodeVersion, "v25.1.0")
    }

    func testPromptReportedNodeVersionWinsOverNvmBin() {
        let env = [
            "KOOKY_NODE_VERSION": "v23.2.0",
            "NVM_BIN": "/Users/corey/.nvm/versions/node/v20.1.0/bin",
        ]
        XCTAssertEqual(EnvironmentDetector.extract(shellEnv: env, cwd: tempDir).nodeVersion, "v23.2.0")
    }

    func testNonNvmBinDoesNotPretendToBeVersion() {
        let env = ["NVM_BIN": "/usr/local/bin"]
        XCTAssertNil(EnvironmentDetector.extract(shellEnv: env, cwd: tempDir).nodeVersion)
    }

    func testVirtualEnvBasenameSurfaces() {
        let env = ["VIRTUAL_ENV": "/Users/corey/projects/api/.venv"]
        let result = EnvironmentDetector.extract(shellEnv: env, cwd: tempDir)
        XCTAssertEqual(result.pythonVenv, ".venv")
    }

    func testCondaDefaultEnvSurfaces() {
        let env = ["CONDA_DEFAULT_ENV": "base"]
        let result = EnvironmentDetector.extract(shellEnv: env, cwd: tempDir)
        XCTAssertEqual(result.pythonVenv, "base")
    }

    func testVirtualEnvWinsOverConda() {
        // Both shouldn't be set together in practice, but if they are,
        // VIRTUAL_ENV is more specific (a real path) and wins.
        let env = [
            "VIRTUAL_ENV": "/Users/corey/.venv",
            "CONDA_DEFAULT_ENV": "base"
        ]
        XCTAssertEqual(EnvironmentDetector.extract(shellEnv: env, cwd: tempDir).pythonVenv, ".venv")
    }

    func testEmptyShellEnvFallsBackToFileWalk() throws {
        try "20.10.0".write(to: tempDir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EnvironmentDetector.extract(shellEnv: [:], cwd: tempDir).nodeVersion, "v20.10.0")
    }

    func testLiveShellReportDoesNotFallBackToProjectFilesWhenEmpty() throws {
        try "20.10.0".write(to: tempDir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        let venv = tempDir.appendingPathComponent(".venv", isDirectory: true)
        try fm.createDirectory(at: venv, withIntermediateDirectories: true)
        try "".write(to: venv.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8)

        let env = EnvironmentDetector.extract(
            shellEnv: [
                "VIRTUAL_ENV": "",
                "CONDA_DEFAULT_ENV": "",
                "NVM_BIN": "",
                "NVM_DIR": "",
                "KOOKY_NODE_VERSION": "",
            ],
            cwd: tempDir,
            allowProjectFallback: false
        )
        XCTAssertNil(env.pythonVenv)
        XCTAssertNil(env.nodeVersion)
    }

    func testInstalledNvmVersionsAreReadNewestFirst() throws {
        let nvm = tempDir.appendingPathComponent(".nvm", isDirectory: true)
        let node = nvm.appendingPathComponent("versions/node", isDirectory: true)
        for version in ["v18.19.0", "v20.11.1", "v22.0.0"] {
            try fm.createDirectory(at: node.appendingPathComponent(version), withIntermediateDirectories: true)
        }

        XCTAssertEqual(
            NodeVersionInventory.installedVersions(nvmDirectory: nvm.path),
            ["v22.0.0", "v20.11.1", "v18.19.0"]
        )
    }

    func testNodeVersionComparisonIgnoresMissingVPrefix() {
        XCTAssertTrue(NodeVersionInventory.isSameVersion("20.10.0", "v20.10.0"))
        XCTAssertFalse(NodeVersionInventory.isSameVersion("20.10.0", "v20.11.0"))
    }

    // MARK: - Proxy

    func testProxyUnsetIsLimitedToKnownVariablesAndClearsBothCases() {
        for name in ["https_proxy", "http_proxy", "all_proxy"] {
            let expected = "_kooky_unset_proxy \(name) \(name.uppercased())"
            XCTAssertEqual(ProxyInfo.unsetCommand(for: name), expected)
            XCTAssertEqual(ProxyInfo.unsetCommand(for: name.uppercased()), expected)
        }
        for name in ["PATH", "", "http_proxy=value", "http_proxy; echo injected"] {
            XCTAssertNil(ProxyInfo.unsetCommand(for: name))
        }
    }

    func testNodeCommandKeepsShellSyntaxInsideOneArgument() {
        XCTAssertEqual(NodeVersionInventory.shellUseCommand(version: "lts/*"), "nvm use 'lts/*'\r")
        XCTAssertEqual(NodeVersionInventory.shellUseCommand(version: "v22; echo 'injected'"),
                       "nvm use 'v22; echo '\\''injected'\\'''\r")
    }

    func testProxyAbsentWhenAllVarsEmpty() {
        let env = EnvironmentDetector.extract(
            shellEnv: ["https_proxy": "", "http_proxy": "", "all_proxy": ""],
            cwd: tempDir,
            allowProjectFallback: false
        )
        XCTAssertNil(env.proxy)
    }

    func testProxyExtractsHostPortFromHttpsProxy() {
        let env = EnvironmentDetector.extract(
            shellEnv: ["https_proxy": "http://127.0.0.1:61271"],
            cwd: tempDir,
            allowProjectFallback: false
        )
        XCTAssertEqual(env.proxy?.summary, "127.0.0.1:61271")
        XCTAssertEqual(env.proxy?.entries, ["https_proxy=http://127.0.0.1:61271"])
    }

    func testProxyHttpsPriorityOverHttpAndAll() {
        let env = EnvironmentDetector.extract(
            shellEnv: [
                "https_proxy": "http://10.0.0.1:8080",
                "http_proxy": "http://127.0.0.1:7070",
                "all_proxy": "socks5://127.0.0.1:1080",
            ],
            cwd: tempDir,
            allowProjectFallback: false
        )
        XCTAssertEqual(env.proxy?.summary, "10.0.0.1:8080")
        XCTAssertEqual(env.proxy?.entries, [
            "https_proxy=http://10.0.0.1:8080",
            "http_proxy=http://127.0.0.1:7070",
            "all_proxy=socks5://127.0.0.1:1080",
        ])
    }

    func testProxyFallsBackToAllProxyWhenHttpsAndHttpEmpty() {
        let env = EnvironmentDetector.extract(
            shellEnv: ["all_proxy": "socks5://corp.proxy:1080"],
            cwd: tempDir,
            allowProjectFallback: false
        )
        XCTAssertEqual(env.proxy?.summary, "corp.proxy:1080")
        XCTAssertEqual(env.proxy?.entries, ["all_proxy=socks5://corp.proxy:1080"])
    }

    func testProxyStripsCredentialsFromSummary() {
        let env = EnvironmentDetector.extract(
            shellEnv: ["https_proxy": "http://user:pass@proxy.corp:8443"],
            cwd: tempDir,
            allowProjectFallback: false
        )
        // Summary is user-visible — never include creds. Full string with
        // creds remains in `entries` (popover) for the user to inspect.
        XCTAssertEqual(env.proxy?.summary, "proxy.corp:8443")
        XCTAssertEqual(env.proxy?.entries, ["https_proxy=http://user:pass@proxy.corp:8443"])
    }

    func testProxySchemelessValueIsAcceptable() {
        let env = EnvironmentDetector.extract(
            shellEnv: ["http_proxy": "127.0.0.1:3128"],
            cwd: tempDir,
            allowProjectFallback: false
        )
        XCTAssertEqual(env.proxy?.summary, "127.0.0.1:3128")
    }

    func testProxyIPv6HostIsBracketed() {
        let env = EnvironmentDetector.extract(
            shellEnv: ["https_proxy": "http://[::1]:8080"],
            cwd: tempDir,
            allowProjectFallback: false
        )
        XCTAssertEqual(env.proxy?.summary, "[::1]:8080")
    }
}
