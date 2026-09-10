import Darwin
import Foundation

/// A test owned STUN binding server with a loopback UDP mapping for each client.
/// The advertised mapped port really forwards datagrams, rather than inventing
/// an unreachable candidate. It never opens a listener outside loopback.
final class CallingLocalSTUNServer {
    private struct Mapping {
        let descriptor: Int32
        let port: UInt16
        let client: sockaddr_in
        var remote: sockaddr_in?
    }

    private let queue = DispatchQueue(label: "Calling local STUN fixture")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let stopped = DispatchGroup()
    private var sources: [DispatchSourceRead] = []
    private var mappings: [String: Mapping] = [:]
    private var bindingResponses = 0
    private var forwardedDatagrams = 0
    private var errors = 0
    private var isStopping = false
    let port: UInt16

    var url: String { "stun:127.0.0.1:\(port)" }

    init() throws {
        let listener = try Self.openLoopbackSocket()
        port = listener.port
        queue.setSpecific(key: queueKey, value: true)
        queue.sync {
            watch(listener.descriptor) { [weak self] data, address in
                self?.handleBinding(data, from: address, descriptor: listener.descriptor)
            }
        }
    }

    deinit {
        cancelListeners()
    }

    func snapshot() -> [String: Any] {
        queue.sync {
            ["stunPort": Int(port), "mappedPorts": mappings.values.map { Int($0.port) }.sorted(),
             "bindingResponses": bindingResponses, "forwardedDatagrams": forwardedDatagrams,
             "errors": errors, "activeListeners": sources.count]
        }
    }

    func stopAndWait(_ timeout: TimeInterval) -> Bool {
        cancelListeners()
        return stopped.wait(timeout: .now() + timeout) == .success
    }

    private func cancelListeners() {
        let cancel = {
            guard !self.isStopping else { return }
            self.isStopping = true
            self.sources.forEach { $0.cancel() }
            self.sources.removeAll()
            self.mappings.removeAll()
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cancel() }
        else { queue.sync(execute: cancel) }
    }

    private static func openLoopbackSocket() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw socketError() }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw socketError() }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
            }
            guard named == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw socketError() }
            return (descriptor, UInt16(bigEndian: address.sin_port))
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func socketError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func watch(_ descriptor: Int32, receive: @escaping (Data, sockaddr_in) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let group = stopped
        group.enter()
        source.setCancelHandler {
            Darwin.close(descriptor)
            group.leave()
        }
        source.setEventHandler { [weak self] in
            guard let self, !self.isStopping else { return }
            for _ in 0..<128 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                var address = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = bytes.withUnsafeMutableBytes { buffer in
                    withUnsafeMutablePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, $0, &length)
                        }
                    }
                }
                if count < 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK { self.errors += 1 }
                    return
                }
                guard count > 0, address.sin_family == sa_family_t(AF_INET) else { continue }
                receive(Data(bytes.prefix(count)), address)
            }
        }
        sources.append(source)
        source.resume()
    }

    private func handleBinding(_ data: Data, from client: sockaddr_in, descriptor: Int32) {
        let request = [UInt8](data)
        guard request.count >= 20, request[0] == 0, request[1] == 1,
              Array(request[4..<8]) == [0x21, 0x12, 0xa4, 0x42],
              Int(request[2]) * 256 + Int(request[3]) + 20 <= request.count else { return }
        let key = "\(client.sin_addr.s_addr):\(client.sin_port)"
        if mappings[key] == nil {
            guard mappings.count < 8 else { errors += 1; return }
            do {
                let endpoint = try Self.openLoopbackSocket()
                mappings[key] = Mapping(descriptor: endpoint.descriptor, port: endpoint.port, client: client)
                watch(endpoint.descriptor) { [weak self] data, address in
                    self?.forward(data, from: address, mapping: key)
                }
            } catch { errors += 1; return }
        }
        guard let mapping = mappings[key] else { errors += 1; return }
        let encodedPort = mapping.port ^ 0x2112
        var response: [UInt8] = [0x01, 0x01, 0x00, 0x0c]
        response.append(contentsOf: request[4..<20])
        // XOR-MAPPED-ADDRESS, IPv4 loopback and an actual mapped UDP listener.
        response.append(contentsOf: [0x00, 0x20, 0x00, 0x08, 0x00, 0x01])
        response.append(UInt8(encodedPort >> 8))
        response.append(UInt8(encodedPort & 0xff))
        let loopback: [UInt8] = [127, 0, 0, 1]
        let cookie: [UInt8] = [0x21, 0x12, 0xa4, 0x42]
        for index in loopback.indices { response.append(loopback[index] ^ cookie[index]) }
        if send(Data(response), to: client, descriptor: descriptor) { bindingResponses += 1 }
    }

    private func forward(_ data: Data, from sender: sockaddr_in, mapping key: String) {
        guard var mapping = mappings[key] else { return }
        let isClient = sender.sin_addr.s_addr == mapping.client.sin_addr.s_addr && sender.sin_port == mapping.client.sin_port
        let destination: sockaddr_in
        if isClient {
            guard let remote = mapping.remote else { return }
            destination = remote
        } else {
            mapping.remote = sender
            mappings[key] = mapping
            destination = mapping.client
        }
        if send(data, to: destination, descriptor: mapping.descriptor) { forwardedDatagrams += 1 }
    }

    private func send(_ data: Data, to destination: sockaddr_in, descriptor: Int32) -> Bool {
        var address = destination
        let sent = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { errors += 1; return false }
        return true
    }
}
