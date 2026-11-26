import CryptoKit
import Foundation
import Network
import Security

struct Pairing: Codable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16
    var fingerprint: Data
    var token: Data
    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 200 && !host.isEmpty && host.utf8.count <= 253
            && host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && port != 0 && fingerprint.count == 32 && token.count == 32
    }

    var code: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return "desklink:" + data.base64EncodedString()
    }

    init(name: String, host: String, port: UInt16, fingerprint: Data, token: Data) {
        self.name = name
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.token = token
    }

    init?(code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("desklink:"), code.utf8.count < 2048,
              let data = Data(base64Encoded: String(code.dropFirst(9))),
              let pairing = try? JSONDecoder().decode(Self.self, from: data),
              pairing.isValid else { return nil }
        self = pairing
    }
}

struct RemoteDisplay: Codable, Identifiable {
    let id: UInt32
    let name: String
    let width: Int
    let height: Int
}

struct RemotePoint: Codable {
    var x: Double
    var y: Double
}

enum PointerAction: String, Codable {
    case move, click, rightClick, doubleClick, down, up
}

struct Pointer: Codable {
    let display: UInt32
    let point: RemotePoint
    let action: PointerAction
}

struct RemoteKey: Codable {
    static let command: UInt8 = 1
    static let shift: UInt8 = 2
    static let option: UInt8 = 4
    static let control: UInt8 = 8

    let code: UInt16
    var modifiers: UInt8 = 0
    var down: Bool? = nil
}

struct Desktop: Codable {
    let displays: [RemoteDisplay]
    let selected: UInt32
}

enum Command: Codable {
    case authenticate(Data)
    case desktop(Desktop)
    case failure(String)
    case selectDisplay(UInt32)
    case pointer(Pointer)
    case scroll(RemotePoint)
    case key(RemoteKey)
    case text(String)
    case writeClipboard(String)
    case readClipboard
    case clipboard(String)
    case audioEnabled(Bool)
    case releaseInputs
}

enum PacketType: UInt8 {
    case control = 1, video, audio

    var limit: Int {
        switch self {
        case .control: 1_048_576
        case .video: 4_194_304
        case .audio: 65_536
        }
    }
}

enum DeskError: LocalizedError {
    case protocolError
    case system(String)

    var errorDescription: String? {
        switch self {
        case .protocolError: "Соединение прервано. Некорректные данные."
        case .system(let message): message
        }
    }
}

final class Wire {
    private static let queue = DispatchQueue(label: "DeskLink.network")
    private let connection: NWConnection
    private var closed = false
    private var buffer = Data()
    private var onClose: ((Error?) -> Void)?
    private var onPacket: ((PacketType, Data) -> Void)?
    private let sendLock = NSLock()
    private var pendingBytes = 0

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(onReady: (() -> Void)? = nil, onPacket: @escaping (PacketType, Data) -> Void,
               onClose: @escaping (Error?) -> Void) {
        self.onPacket = onPacket
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                onReady?()
                self.receive()
            case .failed(let error):
                self.finish(error)
            case .waiting(let error):
                if case .tls = error { self.finish(error) }
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
    }

    func send(_ command: Command, completion: (() -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(command) else {
            completion?()
            return
        }
        send(.control, data, completion: completion)
    }

    func send(_ type: PacketType, _ payload: Data, completion: (() -> Void)? = nil) {
        guard payload.count <= type.limit else {
            completion?()
            return
        }
        sendLock.lock()
        guard pendingBytes + payload.count <= 4_456_448 else {
            sendLock.unlock()
            completion?()
            if type != .audio {
                Self.queue.async { self.finish(DeskError.system("Сеть не успевает передавать данные.")) }
            }
            return
        }
        pendingBytes += payload.count
        var length = UInt32(payload.count).bigEndian
        var packet = Data([type.rawValue])
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let self {
                self.sendLock.lock()
                self.pendingBytes -= payload.count
                self.sendLock.unlock()
                if let error { self.finish(error) }
            }
            completion?()
        })
        sendLock.unlock()
    }

    func cancel() {
        Self.queue.async { self.finish(nil) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] bytes, _, eof, error in
            guard let self, !self.closed else { return }
            if let bytes {
                self.buffer.append(bytes)
                guard self.deliverPackets() else {
                    self.finish(DeskError.protocolError)
                    return
                }
            }
            if eof || error != nil {
                self.finish(error)
            } else {
                self.receive()
            }
        }
    }

    private func deliverPackets() -> Bool {
        var index = buffer.startIndex
        while buffer.endIndex - index >= 5 {
            guard let type = PacketType(rawValue: buffer[index]) else { return false }
            let count = buffer[(index + 1)..<(index + 5)].reduce(0) { ($0 << 8) | Int($1) }
            guard count > 0 && count <= type.limit else { return false }
            guard buffer.endIndex - index - 5 >= count else { break }
            let end = index + 5 + count
            onPacket?(type, buffer.subdata(in: (index + 5)..<end))
            index = end
        }
        buffer.removeSubrange(buffer.startIndex..<index)
        return true
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        connection.stateUpdateHandler = nil
        let callback = onClose
        onClose = nil
        onPacket = nil
        callback?(error)
    }
}

func clientParameters(pin: Data) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
        let trust = sec_trust_copy_ref(trust).takeRetainedValue()
        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
        guard let leaf = chain?.first else {
            complete(false)
            return
        }
        let digest = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        complete(digest == pin)
    }, DispatchQueue(label: "DeskLink.certificate"))
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: tls, tcp: tcp)
}

func secureRandom(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
    }
    guard status == errSecSuccess else {
        throw DeskError.system("Не удалось создать ключ подключения.")
    }
    return data
}
