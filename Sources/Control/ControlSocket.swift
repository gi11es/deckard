import Foundation

/// A Unix domain socket server that listens for JSON messages from
/// the deckard CLI tool and Claude Code hooks.
class ControlSocket {
    static let shared = ControlSocket()

    private var serverSocket: Int32 = -1
    private var socketPath: String = ""
    private var listenSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private let socketQueue = DispatchQueue(label: "com.deckard.control-socket")

    /// Callback for incoming messages.
    var onMessage: ((ControlMessage, @escaping (ControlResponse) -> Void) -> Void)?

    /// The socket path, made available to child processes via environment.
    var path: String { socketPath }

    func start() {
        let tmpDir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        socketPath = "\(tmpDir)deckard-\(getuid()).sock"

        // Clean up old socket
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("Failed to create socket: \(errno)")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        pathBytes.withUnsafeBufferPointer { buf in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let count = min(buf.count, maxLen)
                dest.copyBytes(from: UnsafeRawBufferPointer(buf).prefix(count))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("Failed to bind socket: \(errno)")
            close(serverSocket)
            return
        }

        // Listen
        guard listen(serverSocket, 5) == 0 else {
            print("Failed to listen on socket: \(errno)")
            close(serverSocket)
            return
        }

        // Accept connections on a serial queue to protect shared state
        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: socketQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
            }
        }
        source.resume()
        listenSource = source

        print("Control socket listening at \(socketPath)")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        for source in clientSources.values {
            source.cancel()
        }
        clientSources.removeAll()
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(serverSocket, sockaddrPtr, &clientAddrLen)
            }
        }
        guard clientFd >= 0 else { return }

        // Read data from the client
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: socketQueue)
        source.setEventHandler { [weak self] in
            self?.readFromClient(fd: clientFd)
        }
        source.setCancelHandler {
            close(clientFd)
        }
        source.resume()
        clientSources[clientFd] = source
    }

    private func readFromClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            // Client disconnected — cancel source (its cancel handler closes fd)
            clientSources.removeValue(forKey: fd)?.cancel()
            return
        }

        let data = Data(buffer[0..<bytesRead])
        guard let message = try? JSONDecoder().decode(ControlMessage.self, from: data) else {
            // Try to send error response
            let errorResp = "{\"ok\":false,\"error\":\"invalid JSON\"}\n"
            _ = errorResp.withCString { write(fd, $0, strlen($0)) }
            clientSources.removeValue(forKey: fd)?.cancel()
            return
        }

        // Remove the source now — we've read the message and will close fd after replying
        let source = clientSources.removeValue(forKey: fd)

        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(message) { response in
                if let respData = try? JSONEncoder().encode(response) {
                    var resp = respData
                    resp.append(0x0A) // newline
                    resp.withUnsafeBytes { ptr in
                        _ = write(fd, ptr.baseAddress!, resp.count)
                    }
                }
                // Cancel the source (its cancel handler closes fd)
                source?.cancel()
            }
        }
    }
}

// MARK: - Protocol Messages

struct ControlMessage: Codable {
    let command: String
    var surfaceId: String?
    var sessionId: String?
    var pid: Int32?
    var notificationType: String?
    var message: String?
    var workingDirectory: String?
    var name: String?
    var tabId: String?
    var key: String?
    var value: String?
}

struct ControlResponse: Codable {
    var ok: Bool = true
    var error: String?
    var message: String?
    var tabs: [TabInfo]?
}

struct TabInfo: Codable {
    var id: String
    var name: String
    var isClaude: Bool
    var isMaster: Bool
    var sessionId: String?
    var badgeState: String
    var workingDirectory: String?
}
