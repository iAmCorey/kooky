import XCTest
import KookyHookKit

final class ShellCommandProtocolTests: XCTestCase {
    func testCommandNormalizationRejectsControlsAndOversizedUTF8() {
        XCTAssertEqual(KookyHookKit.normalizedShellCommand("git switch '中文'\r"), "git switch '中文'")
        for command in ["", "\r", "nvm use v22\nexit", "nvm\0use", "\u{1B}evil", String(repeating: "a", count: 4097), String(repeating: "中", count: 1366)] {
            XCTAssertNil(KookyHookKit.normalizedShellCommand(command))
        }
    }

    func testRequestCarriesSessionAndShellIdentity() throws {
        let id = UUID()
        let request = KookyShellCommandRequest(surface: id, shellPID: 123)
        let line = try XCTUnwrap(KookyCLIProtocol.encodeLine(request))
        let decoded = try XCTUnwrap(KookyCLIProtocol.decodeLine(KookyShellCommandRequest.self, from: line))
        XCTAssertEqual(decoded.kind, "shellCommand")
        XCTAssertEqual(decoded.surface, id)
        XCTAssertEqual(decoded.shellPID, 123)
    }
}
