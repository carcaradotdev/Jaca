import Foundation
import Crypto
import X509
import SwiftASN1
import NIOSSL

/// Failures that must not be papered over by minting a replacement CA.
enum CAError: Error { case keyPresentButUnreadable }

/// How `CertificateAuthority` reaches the Keychain, so a test can check that a process without
/// migration never reads it.
struct CAKeychainAccess: Sendable {
    /// Whether an item exists. Reads no secret data, so it shows no prompt.
    var exists: @Sendable (_ account: String) -> Bool
    /// The item's secret. It can show a Keychain prompt.
    var read: @Sendable (_ account: String) -> String?

    static let system = CAKeychainAccess(
        exists: { KeychainStore.exists(account: $0) },
        read: { KeychainStore.read(account: $0) }
    )
}

/// Generates and persists a local root CA, and mints per-host leaf certificates
/// signed by it so the MITM proxy can terminate TLS for any host. The user
/// installs/ trusts the root CA on the device; leaves are cached per host.
final class CertificateAuthority: @unchecked Sendable {
    private let caCertificate: Certificate
    private let caKey: P256.Signing.PrivateKey
    private let caNIOCertificate: NIOSSLCertificate

    private let lock = NSLock()
    private var contextCache: [String: NIOSSLContext] = [:]

    let rootCertificatePEM: String
    let storageDirectory: URL

    /// Loads the CA from `directory` (default: Application Support/Jaca/ca), generating and
    /// persisting a new one if absent. The private key is a 0600 file next to the cert. A key
    /// still in the Keychain from older builds is migrated to the file on first read (one last
    /// prompt), then used from the file. This avoids the per-launch Keychain ACL prompt of
    /// locally signed dev builds (mitmproxy and Charles keep their CA key in a file too).
    ///
    /// Set `allowKeychainMigration` to false in a process that must never show a Keychain
    /// prompt (jacad). If the key is still only in the Keychain, that process throws
    /// `CAError.keyPresentButUnreadable` instead of minting a second CA; the app migrates it.
    convenience init(directory: URL? = nil, allowKeychainMigration: Bool = true) throws {
        try self.init(directory: directory, allowKeychainMigration: allowKeychainMigration,
                      keychain: .system, usesLegacyKeychain: directory == nil)
    }

    /// The designated init. `usesLegacyKeychain` says whether this directory is the one older
    /// builds paired with the Keychain key: only the real app location is. Tests pass a temp
    /// directory with `usesLegacyKeychain: true` and a fake `keychain`.
    init(directory: URL?, allowKeychainMigration: Bool, keychain: CAKeychainAccess,
         usesLegacyKeychain: Bool) throws {
        let dir = directory ?? Self.defaultDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageDirectory = dir

        // Two processes (the app and jacad) can start at once. Without the lock both find no CA
        // and each mints its own; the second write wins and the first process signs leaves with
        // a CA nobody installed. The lock is advisory and released when the descriptor closes.
        let lockFD = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }

        let certURL = dir.appendingPathComponent("rootCA.pem")
        let keyURL = dir.appendingPathComponent("rootCA.key.pem")
        let keyAccount = "ca-private-key"
        let migrate = Self.migratesFromKeychain(usesLegacyKeychain: usesLegacyKeychain,
                                                allowKeychainMigration: allowKeychainMigration)

        func loadKeyPEM() -> String? {
            if let fromFile = try? String(contentsOf: keyURL, encoding: .utf8) { return fromFile }
            // One-time migration: read an existing key still in the Keychain (a final prompt),
            // write it to the file, and use the file from then on.
            if migrate, let stored = keychain.read(keyAccount) {
                try? Self.writeKeyFile(stored, to: keyURL)
                return stored
            }
            return nil
        }

        let certPEM = try? String(contentsOf: certURL, encoding: .utf8)
        let keyPEM = loadKeyPEM()
        if let certPEM, let keyPEM,
           let cert = try? Certificate(pemEncoded: certPEM),
           let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM) {
            caCertificate = cert
            caKey = key
        } else {
            // Don't silently replace an existing CA we couldn't read (the migration prompt was
            // dismissed, or this process may not migrate). That would invalidate every installed
            // cert. `exists` reads no secret data, so it shows no prompt.
            if usesLegacyKeychain, keyPEM == nil,
               !FileManager.default.fileExists(atPath: keyURL.path),
               keychain.exists(keyAccount) {
                throw CAError.keyPresentButUnreadable
            }
            let (cert, key) = try Self.makeRootCA()
            caCertificate = cert
            caKey = key
            try cert.serializeAsPEM().pemString.write(to: certURL, atomically: true, encoding: .utf8)
            try Self.writeKeyFile(key.pemRepresentation, to: keyURL)
        }

        rootCertificatePEM = try caCertificate.serializeAsPEM().pemString
        caNIOCertificate = try NIOSSLCertificate(bytes: Array(rootCertificatePEM.utf8), format: .pem)
    }

    /// Application Support/Jaca/ca.
    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jaca/ca", isDirectory: true)
    }

    /// Whether init may read the key out of the Keychain. Only the real app location had a
    /// Keychain key, and only a process that may show a prompt reads it.
    static func migratesFromKeychain(usesLegacyKeychain: Bool, allowKeychainMigration: Bool) -> Bool {
        usesLegacyKeychain && allowKeychainMigration
    }

    /// Write the CA private key to an owner-only (0600) file.
    private static func writeKeyFile(_ pem: String, to url: URL) throws {
        try pem.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A cached server-side TLS context presenting a leaf cert for `host`.
    func serverContext(forHost host: String) throws -> NIOSSLContext {
        lock.lock()
        if let cached = contextCache[host] { lock.unlock(); return cached }
        lock.unlock()

        let (leaf, leafKey) = try makeLeaf(forHost: host)
        let leafPEM = try leaf.serializeAsPEM().pemString
        let nioLeaf = try NIOSSLCertificate(bytes: Array(leafPEM.utf8), format: .pem)
        let nioKey = try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)

        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioLeaf), .certificate(caNIOCertificate)],
            privateKey: .privateKey(nioKey)
        )
        // Span TLS 1.2–1.3 so we interoperate with everything from old system
        // LibreSSL clients to modern Android/iOS. We only speak HTTP/1.1.
        config.minimumTLSVersion = .tlsv12
        config.maximumTLSVersion = .tlsv13
        config.applicationProtocols = ["http/1.1"]
        let context = try NIOSSLContext(configuration: config)

        lock.lock(); contextCache[host] = context; lock.unlock()
        return context
    }

    /// The base64 SHA-256 of the root's SubjectPublicKeyInfo, the form Chrome's
    /// `--ignore-certificate-errors-spki-list` takes. The root is in every chain the proxy sends.
    var rootSPKIHash: String {
        Data(SHA256.hash(data: caKey.publicKey.derRepresentation)).base64EncodedString()
    }

    func exportRootCertificate(to url: URL) throws {
        try rootCertificatePEM.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Certificate minting

    private static func makeRootCA() throws -> (Certificate, P256.Signing.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName("Jaca Proxy CA")
            OrganizationName("Jaca")
        }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-86_400),
            // Very long-lived (≈30y): the root is minted once per Mac, persisted (cert and
            // 0600 key file in the CA directory) and reused across every device and every Jaca
            // update, so a cert the user installs keeps working for the life of the machine.
            notValidAfter: Date().addingTimeInterval(30 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        return (cert, key)
    }

    /// The SAN entry for a leaf: an IP address SAN when `host` is an IPv4 or IPv6 literal (a
    /// client checks an IP against IP SANs only), otherwise a DNS name.
    static func subjectAlternativeName(forHost host: String) -> GeneralName {
        if let bytes = ipAddressBytes(host) {
            return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(bytes)))
        }
        return .dnsName(host)
    }

    /// The network-order bytes of an IPv4 (4 bytes) or IPv6 (16 bytes) literal; nil for a name.
    /// Brackets around an IPv6 literal are allowed.
    static func ipAddressBytes(_ host: String) -> [UInt8]? {
        var literal = host
        if literal.hasPrefix("["), literal.hasSuffix("]") { literal = String(literal.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    private func makeLeaf(forHost host: String) throws -> (Certificate, P256.Signing.PrivateKey) {
        let leafKey = P256.Signing.PrivateKey()
        let subject = try DistinguishedName { CommonName(host) }
        let san = SubjectAlternativeNames([Self.subjectAlternativeName(forHost: host)])
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(leafKey.publicKey),
            notValidBefore: Date().addingTimeInterval(-86_400),
            notValidAfter: Date().addingTimeInterval(825 * 86_400),
            issuer: caCertificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true, keyEncipherment: true)
                try ExtendedKeyUsage([.serverAuth])
                san
            },
            issuerPrivateKey: Certificate.PrivateKey(caKey)
        )
        return (cert, leafKey)
    }
}
