import XCTest
@testable import KookyKit

final class WorkspaceTransportTests: XCTestCase {
    func testDerivedPropertiesCoverEveryTransport() throws {
        XCTAssertFalse(WorkspaceTransport.local.isRemote)
        XCTAssertNil(WorkspaceTransport.local.remoteDestination)
        XCTAssertEqual(
            WorkspaceTransport.ssh(destination: " user@host ").remoteDestination,
            "user@host"
        )

        let mosh = WorkspaceTransport.mosh(try XCTUnwrap(
            MoshWorkspaceConfiguration(destination: "devbox")
        ))
        XCTAssertTrue(mosh.isRemote)
        XCTAssertTrue(mosh.supportsRemoteUpload)
        XCTAssertEqual(mosh.remoteKind, .mosh)
        XCTAssertEqual(mosh.label, "Mosh")

        let unknown = WorkspaceTransport.unsupported(kind: "future", destination: "box")
        XCTAssertTrue(unknown.isRemote)
        XCTAssertFalse(unknown.supportsRemoteUpload)
    }

    func testMoshTransportUsesStableWireShape() throws {
        let transport = WorkspaceTransport.mosh(try XCTUnwrap(MoshWorkspaceConfiguration(
            destination: "devbox",
            udpPort: .range(60_000...60_100),
            prediction: .never,
            serverPath: "/opt/bin/mosh-server",
            sshPort: 2_222,
            identityFile: "/tmp/key",
            networkTimeoutSeconds: 604_800
        )))
        let data = try JSONEncoder().encode(transport)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["kind"] as? String, "mosh")
        XCTAssertEqual(json["destination"] as? String, "devbox")
        XCTAssertEqual(json["prediction"] as? String, "never")
        XCTAssertEqual(json["networkTimeoutSeconds"] as? Int, 604_800)
        XCTAssertEqual(
            try JSONDecoder().decode(WorkspaceTransport.self, from: data),
            transport
        )
    }

    func testInvalidKnownAndUnknownTransportsFailClosedAsRemotePlaceholders() throws {
        let invalidMosh = Data(#"{"kind":"mosh","destination":"devbox","udpPort":{"kind":"port","port":0},"prediction":"adaptive"}"#.utf8)
        let future = Data(#"{"kind":"et","destination":"devbox"}"#.utf8)

        XCTAssertEqual(
            try JSONDecoder().decode(WorkspaceTransport.self, from: invalidMosh),
            .unsupported(kind: "mosh", destination: "devbox")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(WorkspaceTransport.self, from: future),
            .unsupported(kind: "et", destination: "devbox")
        )
    }

    func testMoshValidationRejectsInvalidPortsAndTimeouts() {
        XCTAssertNil(MoshWorkspaceConfiguration(destination: "devbox", sshPort: 0))
        XCTAssertNil(MoshWorkspaceConfiguration(
            destination: "devbox",
            networkTimeoutSeconds: 3_599
        ))
        XCTAssertNil(MoshWorkspaceConfiguration(
            destination: "devbox",
            udpPort: .port(0)
        ))
    }
}

final class LocalMoshAvailabilityTests: XCTestCase {
    func testFindsMoshFromPathBeforeCommonFallbacks() {
        var probed: [String] = []
        let result = LocalMoshAvailability.executablePath(
            environment: ["PATH": "/custom/bin:/usr/bin:/custom/bin"],
            homeDirectory: "/home/test"
        ) { candidate in
            probed.append(candidate)
            return candidate == "/custom/bin/mosh"
        }

        XCTAssertEqual(result, "/custom/bin/mosh")
        XCTAssertEqual(probed, ["/custom/bin/mosh"])
    }

    func testChecksCommonInstallLocationsAndReturnsNilWhenMissing() {
        var probed = Set<String>()
        let result = LocalMoshAvailability.executablePath(
            environment: ["PATH": ""],
            homeDirectory: "/home/test"
        ) { candidate in
            probed.insert(candidate)
            return false
        }

        XCTAssertNil(result)
        XCTAssertTrue(probed.contains("/opt/homebrew/bin/mosh"))
        XCTAssertTrue(probed.contains("/usr/local/bin/mosh"))
        XCTAssertTrue(probed.contains("/home/test/.local/bin/mosh"))
    }
}

final class MoshCommandBuilderTests: XCTestCase {
    private let token = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testBuildsStructuredMoshArgumentsAndPreservesUserValuesAsTokens() throws {
        let invocation = try MoshCommandBuilder.build(
            configuration: try XCTUnwrap(MoshWorkspaceConfiguration(
                destination: "dev box",
                udpPort: .range(60_000...60_100),
                prediction: .never,
                serverPath: "/opt/Mosh Tools/mosh-server",
                sshPort: 2_222,
                identityFile: "/tmp/key with spaces",
                networkTimeoutSeconds: 604_800
            )),
            runtimeToken: token,
            remoteAgentCommand: "claude --model 'sonnet latest'"
        )

        XCTAssertEqual(invocation.executable, "kooky-mosh")
        XCTAssertTrue(invocation.arguments.contains("--predict=never"))
        XCTAssertTrue(invocation.arguments.contains("-p"))
        XCTAssertTrue(invocation.arguments.contains("60000:60100"))
        XCTAssertTrue(invocation.arguments.contains("dev box"))
        XCTAssertTrue(invocation.arguments.contains(
            "KOOKY_RUNTIME_TOKEN=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        ))
        XCTAssertTrue(invocation.arguments.contains(
            "KOOKY_REMOTE_AGENT=claude --model 'sonnet latest'"
        ))
        XCTAssertLessThan(invocation.remoteCommandBytes, MoshCommandBuilder.maximumRemoteCommandBytes)

        let ssh = try XCTUnwrap(invocation.arguments.first { $0.hasPrefix("--ssh=") })
        XCTAssertTrue(ssh.contains("ControlMaster=auto"))
        XCTAssertTrue(ssh.contains("'-p' '2222'"))
        XCTAssertTrue(ssh.contains("'/tmp/key with spaces'"))
        let server = try XCTUnwrap(invocation.arguments.first { $0.hasPrefix("--server=") })
        XCTAssertTrue(server.contains("MOSH_SERVER_NETWORK_TMOUT=604800"))
        XCTAssertTrue(server.contains("'/opt/Mosh Tools/mosh-server'"))
    }

    func testAutomaticPortOmitsPortFlag() throws {
        let invocation = try MoshCommandBuilder.build(
            configuration: try XCTUnwrap(
                MoshWorkspaceConfiguration(destination: "devbox")
            ),
            runtimeToken: token,
            remoteAgentCommand: nil
        )

        XCTAssertFalse(invocation.arguments.contains("-p"))
    }

    func testPredictionFixedPortDestinationFormsAndHostileAgentTextStayStructured() throws {
        let destinations = [
            "host-alias",
            "user@host.example",
            "2001:db8::42",
            "host; printf pwned",
            "-oProxyCommand=printf-pwned",
        ]
        for destination in destinations {
            for prediction in MoshPredictionMode.allCases {
                let configuration = try XCTUnwrap(MoshWorkspaceConfiguration(
                    destination: destination,
                    udpPort: .port(60_123),
                    prediction: prediction
                ))
                let hostile = "codex -- '--server=evil' \"line 1\\n$HOME `id`\""
                let invocation = try MoshCommandBuilder.build(
                    configuration: configuration,
                    runtimeToken: token,
                    remoteAgentCommand: hostile
                )

                let separator = try XCTUnwrap(
                    invocation.arguments.firstIndex(of: "--")
                )
                XCTAssertEqual(invocation.arguments[separator + 1], destination)
                XCTAssertEqual(
                    invocation.arguments.filter { $0 == destination }.count,
                    1
                )
                XCTAssertTrue(invocation.arguments.contains("--predict=\(prediction.rawValue)"))
                XCTAssertTrue(invocation.arguments.contains("60123"))
                XCTAssertTrue(invocation.arguments.contains("KOOKY_REMOTE_AGENT=\(hostile)"))
            }
        }
    }

    func testRemoteCommandHardLimitUsesFinalQuotedBytesAndDebugIsRedacted() throws {
        let configuration = try XCTUnwrap(
            MoshWorkspaceConfiguration(destination: "devbox")
        )
        let oversized = String(
            repeating: "'$` hostile bootstrap text ",
            count: 4_000
        )
        XCTAssertThrowsError(try MoshCommandBuilder.build(
            configuration: configuration,
            runtimeToken: token,
            remoteAgentCommand: nil,
            bootstrapScript: oversized
        )) { error in
            guard let buildError = error as? MoshCommandBuildError,
                  case .remoteCommandTooLarge(let actual, let maximum) = buildError
            else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, 64 * 1_024)
        }

        let secret = "codex --api-key super-secret"
        let invocation = try MoshCommandBuilder.build(
            configuration: configuration,
            runtimeToken: token,
            remoteAgentCommand: secret
        )
        XCTAssertFalse(invocation.debugDescription.contains(secret))
        XCTAssertFalse(invocation.debugDescription.contains("super-secret"))
    }

    func testInvalidConfigurationIsRejected() {
        XCTAssertNil(MoshWorkspaceConfiguration(
            destination: " ",
            networkTimeoutSeconds: 604_800
        ))
    }
}
