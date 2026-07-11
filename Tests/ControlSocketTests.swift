import XCTest
@testable import Deckard

final class ControlSocketTests: XCTestCase {

    /// Create a ControlSocket with a unique temp path so tests don't conflict
    /// with the running Deckard instance.
    private func makeSocket() -> ControlSocket {
        let path = NSTemporaryDirectory() + "deckard-test-\(UUID().uuidString).sock"
        return ControlSocket(path: path)
    }

    // MARK: - Lifecycle

    func testStartCreatesListeningSocket() throws {
        let cs = makeSocket()
        cs.start()
        spinRunLoop(0.3)

        let path = cs.path
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(canConnect(to: path))

        cs.stop()
    }

    func testStopCleansUp() throws {
        let cs = makeSocket()
        cs.start()
        spinRunLoop(0.3)
        let path = cs.path

        cs.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(canConnect(to: path))
    }

    func testDoubleStartDoesNotBreak() throws {
        let cs = makeSocket()
        cs.start()
        spinRunLoop(0.3)
        cs.start()
        spinRunLoop(0.3)

        XCTAssertTrue(canConnect(to: cs.path))
        cs.stop()
    }

    // MARK: - Message Round-trip

    func testMessageRoundTrip() throws {
        let cs = makeSocket()
        let received = expectation(description: "message received")

        cs.onMessage = { message, reply in
            XCTAssertEqual(message.command, "ping")
            reply(ControlResponse(ok: true, message: "pong"))
            received.fulfill()
        }

        cs.start()
        spinRunLoop(0.3)

        // Send on a background thread so we don't block the main run loop
        var responseData: Data?
        let sent = expectation(description: "message sent")
        DispatchQueue.global().async {
            responseData = self.sendMessage("{\"command\":\"ping\"}\n", to: cs.path)
            sent.fulfill()
        }

        wait(for: [received, sent], timeout: 3)

        if let data = responseData,
           let resp = try? JSONDecoder().decode(ControlResponse.self, from: data) {
            XCTAssertTrue(resp.ok)
            XCTAssertEqual(resp.message, "pong")
        } else {
            XCTFail("Expected a valid JSON response")
        }

        cs.stop()
    }

    func testInvalidJsonReturnsError() throws {
        let cs = makeSocket()
        cs.onMessage = { _, reply in
            XCTFail("onMessage should not be called for invalid JSON")
            reply(ControlResponse(ok: false))
        }

        cs.start()
        spinRunLoop(0.3)

        var responseData: Data?
        let sent = expectation(description: "sent")
        DispatchQueue.global().async {
            responseData = self.sendMessage("not json\n", to: cs.path)
            sent.fulfill()
        }

        wait(for: [sent], timeout: 3)

        if let data = responseData,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(json["ok"] as? Bool, false)
        }

        cs.stop()
    }

    // MARK: - Client disconnects before reply

    /// A hook client (nc -w 1) that times out closes its end before Deckard
    /// writes the reply. The reply write must not raise SIGPIPE and kill the
    /// process — this exact scenario crashed a 35-hour session.
    func testClientDisconnectBeforeReplyDoesNotKillProcess() throws {
        let cs = makeSocket()
        let received = expectation(description: "message received")
        let deferredReply = Mutex<((ControlResponse) -> Void)?>(nil)

        cs.onMessage = { _, reply in
            // Hold the reply until after the client has disconnected.
            deferredReply.withLock { $0 = reply }
            received.fulfill()
        }

        cs.start()
        spinRunLoop(0.3)

        // Connect, send a message, and close immediately without reading the reply.
        let sent = expectation(description: "sent and closed")
        let path = cs.path
        DispatchQueue.global().async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            self.withPath(path, into: &addr)
            let connected = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 {
                "{\"command\":\"ping\"}\n".withCString { ptr in
                    _ = write(fd, ptr, strlen(ptr))
                }
            }
            close(fd)
            sent.fulfill()
        }

        wait(for: [received, sent], timeout: 3)
        // Let the close propagate, then reply into the dead socket.
        spinRunLoop(0.2)
        deferredReply.withLock { $0 }?(ControlResponse(ok: true, message: "pong"))
        spinRunLoop(0.2)

        // Reaching this line at all is the real assertion: without SIGPIPE
        // protection the write above terminates the test process.
        XCTAssertTrue(canConnect(to: cs.path), "socket should still be alive")
        cs.stop()
    }

    // MARK: - Recovery

    func testRestartAfterSocketFileRemoved() throws {
        let cs = makeSocket()
        cs.start()
        spinRunLoop(0.3)

        let path = cs.path
        XCTAssertTrue(canConnect(to: path))

        unlink(path)
        XCTAssertFalse(canConnect(to: path))

        cs.start()
        spinRunLoop(0.3)

        XCTAssertTrue(canConnect(to: cs.path))
        cs.stop()
    }

    // MARK: - Multiple Clients

    func testMultipleConcurrentClients() throws {
        let cs = makeSocket()
        let messageCount = Mutex(0)

        cs.onMessage = { message, reply in
            messageCount.withLock { $0 += 1 }
            reply(ControlResponse(ok: true, message: message.command))
        }

        cs.start()
        spinRunLoop(0.3)

        let clientCount = 5
        let allSent = expectation(description: "all sent")
        allSent.expectedFulfillmentCount = clientCount

        for i in 0..<clientCount {
            DispatchQueue.global().async {
                _ = self.sendMessage("{\"command\":\"client-\(i)\"}\n", to: cs.path)
                allSent.fulfill()
            }
        }

        wait(for: [allSent], timeout: 5)
        // Spin so onMessage callbacks on main can fire
        spinRunLoop(0.5)

        XCTAssertEqual(messageCount.withLock({ $0 }), clientCount)
        cs.stop()
    }

    // MARK: - Helpers

    /// Spin the main run loop for `duration` seconds so dispatched blocks can execute.
    private func spinRunLoop(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withPath(path, into: &addr)

        return withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private func sendMessage(_ message: String, to path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withPath(path, into: &addr)

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        message.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }

        // Wait for response with a timeout
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 2000) // 2 second timeout
        guard ready > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return Data(buffer[0..<n])
    }

    private func withPath(_ path: String, into addr: inout sockaddr_un) {
        let pathBytes = path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        pathBytes.withUnsafeBufferPointer { buf in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let count = min(buf.count, maxLen)
                dest.copyBytes(from: UnsafeRawBufferPointer(buf).prefix(count))
            }
        }
    }
}

/// Simple mutex wrapper for thread-safe access in tests.
private final class Mutex<T> {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
