import CryptoKit
import Foundation
import Network
import Security

struct HostIdentity {
    private struct KeyMaterial: Codable {
        let certificate: Data
        let privateKey: Data
    }

    private static let keyAttributes = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2048,
        kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
    ] as CFDictionary

    let identity: SecIdentity
    let fingerprint: Data
    private let directory: URL
    private(set) var token: Data

    init(directory overrideDirectory: URL? = nil) throws {
        directory = overrideDirectory ?? URL.applicationSupportDirectory.appending(path: "DeskLink")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let archive = directory.appending(path: "Identity.json")
        let tokenFile = directory.appending(path: "PairingKey")

        if !FileManager.default.fileExists(atPath: archive.path) {
            let scratch = directory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            guard let key = SecKeyCreateRandomKey(Self.keyAttributes, nil),
                  let keyBytes = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
                throw DeskError.system("Не удалось создать закрытый ключ Mac.")
            }
            let keyFile = scratch.appending(path: "key.der")
            let cert = scratch.appending(path: "cert.der")
            let bundle = scratch.appending(path: "identity.json")
            try keyBytes.write(to: keyFile)
            try Self.openssl(["req", "-x509", "-new", "-key", keyFile.path, "-keyform", "DER",
                              "-out", cert.path, "-outform", "DER", "-days", "3650", "-sha256", "-subj", "/CN=DeskLink"])
            let keys = KeyMaterial(certificate: try Data(contentsOf: cert), privateKey: keyBytes)
            try JSONEncoder().encode(keys).write(to: bundle)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
            try FileManager.default.moveItem(at: bundle, to: archive)
        }

        let keys = try JSONDecoder().decode(KeyMaterial.self, from: Data(contentsOf: archive))
        guard let certificate = SecCertificateCreateWithData(nil, keys.certificate as CFData),
              let key = SecKeyCreateWithData(keys.privateKey as CFData, Self.keyAttributes, nil),
              let identity = SecIdentityCreate(nil, certificate, key) else {
            throw DeskError.system("Сертификат Mac недоступен.")
        }
        self.identity = identity
        fingerprint = Data(SHA256.hash(data: keys.certificate))
        if let key = try? Data(contentsOf: tokenFile), key.count == 32 {
            token = key
        } else {
            token = try secureRandom(count: 32)
            try token.write(to: tokenFile, options: [.atomic])
        }
    }

    mutating func rotateToken() throws {
        let fresh = try secureRandom(count: 32)
        try fresh.write(to: directory.appending(path: "PairingKey"), options: .atomic)
        token = fresh
    }

    func parameters() throws -> NWParameters {
        guard let local = sec_identity_create(identity) else {
            throw DeskError.system("Не удалось настроить шифрование.")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    func matches(_ candidate: Data) -> Bool {
        guard candidate.count == token.count else { return false }
        return zip(candidate, token).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DeskError.system("Не удалось создать сертификат Mac.")
        }
    }
}
