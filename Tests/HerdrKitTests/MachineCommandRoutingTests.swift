import XCTest
import Foundation
import NIOCore
@testable import HerdrKit

/// The machine commands (`herdr session list`, `herdr machine federate|unfederate`)
/// are per-request execs, so they take `ExecBackend.execute` — in production
/// `SSHConnectionCore.execute`, which falls back to the overflow connection when the
/// shared one refuses a channel (herdrup#718).
///
/// The scripted host here is an sshd with `MaxSessions 1` whose only session is held
/// by a live subscription: an exec on the shared connection is refused, so a command
/// succeeds only by running on the overflow connection, as `execute` does.
final class MachineCommandRoutingTests: XCTestCase {
    private final class MaxSessionsOneHost: @unchecked Sendable {
        private let lock = NSLock()
        private var ran: [(connection: String, command: String)] = []
        let stdout: String
        let exitCode: Int
        let stderr: String

        init(stdout: String = "", exitCode: Int = 0, stderr: String = "") {
            self.stdout = stdout
            self.exitCode = exitCode
            self.stderr = stderr
        }

        var commands: [(connection: String, command: String)] { lock.withLock { ran } }

        var backend: ExecBackend {
            ExecBackend(
                execute: { command in
                    // The shared connection's one session is the subscription's, so the
                    // exec goes where `SSHConnectionCore.execute` sends a refused one.
                    self.lock.withLock { self.ran.append(("overflow", command)) }
                    return AsyncThrowingStream { continuation in
                        if !self.stdout.isEmpty { continuation.yield(.stdout(ByteBuffer(string: self.stdout))) }
                        if !self.stderr.isEmpty { continuation.yield(.stderr(ByteBuffer(string: self.stderr))) }
                        continuation.finish(
                            throwing: self.exitCode == 0 ? nil : ScriptedExit(remoteExitCode: self.exitCode))
                    }
                },
                openLink: { _ in ScriptedBridge() },
                openStreamLink: { _ in ScriptedBridge() })
        }
    }

    private func makeTransport(_ host: MaxSessionsOneHost) -> CitadelTransport {
        // Port 9 on loopback: a command that bypasses the backend and dials the shared
        // connection itself is refused, as on an sshd whose only session is taken.
        let credentials = SSHCredentials(host: "127.0.0.1", port: 9, username: "u", password: "p", remoteSocketPath: "")
        let connection = SSHConnectionCore(
            credentials: credentials, hostKeyValidator: .acceptAnything(), connectTimeoutNanoseconds: 500_000_000,
            reconnectBackoff: (.milliseconds(1), .milliseconds(1)))
        return CitadelTransport(credentials: credentials, connection: connection, backend: host.backend)
    }

    private let profileID = String(repeating: "ab", count: 16)

    func testListSessionsRunsThroughTheOverflowDispatcher() async throws {
        let host = MaxSessionsOneHost(
            stdout: #"{"sessions":[{"name":"default","default":true,"running":true}]}"#)
        let transport = makeTransport(host)
        let sessions = try await transport.listSessions()
        XCTAssertEqual(sessions, [HerdrSession(name: "default", running: true, default: true)])
        XCTAssertEqual(host.commands.map(\.connection), ["overflow"])
        XCTAssertTrue(host.commands.first?.command.contains("session list --json") == true)
    }

    func testSetMachineFederationRunsThroughTheOverflowDispatcher() async throws {
        let host = MaxSessionsOneHost()
        let transport = makeTransport(host)
        try await transport.setMachineFederation(profileID: profileID, enabled: true)
        try await transport.setMachineFederation(profileID: profileID, enabled: false)
        XCTAssertEqual(host.commands.map(\.connection), ["overflow", "overflow"])
        XCTAssertTrue(host.commands[0].command.contains("machine federate \(profileID)"))
        XCTAssertTrue(host.commands[1].command.contains("machine unfederate \(profileID)"))
    }

    func testMachineCommandFailuresKeepTheirErrors() async {
        let failing = makeTransport(MaxSessionsOneHost(exitCode: 1))
        do {
            _ = try await failing.listSessions()
            XCTFail("expected a failure")
        } catch TransportError.machineCommandFailed(let stderr) {
            XCTAssertEqual(stderr, "herdr session list failed (exit 1)")
        } catch {
            XCTFail("unexpected \(error)")
        }

        let refused = makeTransport(MaxSessionsOneHost(exitCode: 2, stderr: "unknown profile"))
        do {
            try await refused.setMachineFederation(profileID: profileID, enabled: true)
            XCTFail("expected a failure")
        } catch TransportError.machineCommandFailed(let stderr) {
            XCTAssertTrue(stderr.contains("unknown profile"), stderr)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
