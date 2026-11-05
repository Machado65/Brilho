// SPDX-FileCopyrightText: 2026 Machado65
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Where the running service listens for `brilho` commands: a Unix socket in
/// the user's runtime directory, which only they can reach.
public enum Socket {
    public static var path: String {
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
        return runtime + "/brilho.sock"
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        return address
    }

    private static func stream() -> Int32 {
        #if canImport(Glibc)
        socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
    }

    /// Sends a command to the running service and returns its reply; nil when it isn't running.
    public static func send(_ words: [String], to path: String = path) -> String? {
        guard var address = address(path) else { return nil }
        let fd = stream()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let request = Array((words.joined(separator: "\t") + "\n").utf8)
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: reply, as: UTF8.self)
    }

    /// Listens on the main queue: each connection is one command, a line of
    /// tab-separated words, answered and closed.
    public final class Server {
        private let fd: Int32
        private let source: DispatchSourceRead
        private let path: String

        /// `queue` is where commands are handled: the main queue, where Brilho's loop runs.
        public init?(path: String = Socket.path, queue: DispatchQueue = .main, handle: @escaping ([String]) -> String) {
            guard var address = Socket.address(path) else { return nil }
            unlink(path)
            let listening = Socket.stream()
            guard listening >= 0 else { return nil }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(listening, 8) == 0 else {
                close(listening)
                return nil
            }
            chmod(path, 0o600)
            fd = listening
            self.path = path
            source = DispatchSource.makeReadSource(fileDescriptor: listening, queue: queue)
            source.setEventHandler {
                let client = accept(listening, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var request = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while !request.contains(0x0A), request.count < 16384 {
                    let count = read(client, &buffer, buffer.count)
                    guard count > 0 else { break }
                    request.append(contentsOf: buffer[0..<count])
                }
                let line = String(decoding: request, as: UTF8.self).trimmingCharacters(in: .newlines)
                let reply = Array(handle(line.isEmpty ? [] : line.components(separatedBy: "\t")).utf8)
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            }
            source.resume()
        }

        deinit {
            source.cancel()
            close(fd)
            unlink(path)
        }
    }
}
