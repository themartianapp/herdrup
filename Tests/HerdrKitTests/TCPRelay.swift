import Foundation
@testable import HerdrKit

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A loopback TCP relay in front of a real sshd, for the live transport tests: it
/// counts the TCP connections the transport opens, can cut them all (a dropped
/// network), and can hold back the server's first bytes (a slow handshake).
///
/// Plain sockets and threads, so it needs nothing beyond the test target's own
/// dependencies and shares no event loop with the transport under test.
final class TCPRelay: @unchecked Sendable {
    let port: UInt16
    private let upstreamPort: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var acceptedCount = 0
    private var open: [Int32] = []
    private var stopped = false
    /// Delay before the first bytes from the server reach the client, per connection.
    private let serverHello: TimeInterval

    init(upstreamPort: UInt16 = 22, serverHelloDelay: TimeInterval = 0) throws {
        self.upstreamPort = upstreamPort
        self.serverHello = serverHelloDelay
        let fd = socket(AF_INET, sockStream, 0)
        guard fd >= 0 else { throw RelayError.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else { close(fd); throw RelayError.socket }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    enum RelayError: Error { case socket }

    /// TCP connections accepted so far.
    var accepted: Int { lock.withLock { acceptedCount } }

    /// Cuts every relayed connection, both sides, as a network drop would. The
    /// listener keeps accepting, so a reconnect gets through.
    func severAll() {
        let fds = lock.withLock { () -> [Int32] in
            let all = open
            open.removeAll()
            return all
        }
        for fd in fds { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    /// Idempotent: a second close of the listener could close an unrelated socket that
    /// reused its descriptor number.
    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
        severAll()
    }

    deinit { stop() }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        return addr
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if lock.withLock({ stopped }) { return }
                continue
            }
            let upstream = socket(AF_INET, sockStream, 0)
            var addr = Self.loopback(port: upstreamPort)
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(client)
                close(upstream)
                continue
            }
            lock.withLock {
                acceptedCount += 1
                open.append(contentsOf: [client, upstream])
            }
            let delay = serverHello
            let pair = Pair(client: client, upstream: upstream)
            Thread { Self.pump(from: client, to: upstream, delay: 0); self.finished(pair) }.start()
            Thread { Self.pump(from: upstream, to: client, delay: delay); self.finished(pair) }.start()
        }
    }

    private final class Pair {
        let client: Int32
        let upstream: Int32
        var pumpsDone = 0
        init(client: Int32, upstream: Int32) { self.client = client; self.upstream = upstream }
    }

    /// Closes a relayed connection's sockets once both directions have stopped.
    private func finished(_ pair: Pair) {
        let last = lock.withLock { () -> Bool in
            pair.pumpsDone += 1
            guard pair.pumpsDone == 2 else { return false }
            open.removeAll { $0 == pair.client || $0 == pair.upstream }
            return true
        }
        if last {
            close(pair.client)
            close(pair.upstream)
        }
    }

    /// Copies `source` to `destination` until either side ends, then shuts both.
    private static func pump(from source: Int32, to destination: Int32, delay: TimeInterval) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var held = delay > 0
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            if held {
                Thread.sleep(forTimeInterval: delay)
                held = false
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(destination, $0.baseAddress! + offset, count - offset)
                }
                if written <= 0 { break }
                offset += written
            }
            if offset < count { break }
        }
        shutdown(source, Int32(SHUT_RDWR))
        shutdown(destination, Int32(SHUT_RDWR))
    }
}
