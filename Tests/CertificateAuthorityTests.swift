import Crypto
import SwiftASN1
import X509
import XCTest
@testable import Jaca

/// The CA directory lock, the Keychain migration flag and the IP SAN of a leaf.
final class CertificateAuthorityTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-ca-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Counts Keychain calls and answers with fixed values.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var existsChecks = 0
        let hasItem: Bool
        let storedKey: String?

        init(hasItem: Bool, storedKey: String? = nil) {
            self.hasItem = hasItem
            self.storedKey = storedKey
        }

        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
        var existsCount: Int { lock.lock(); defer { lock.unlock() }; return existsChecks }

        var access: CAKeychainAccess {
            CAKeychainAccess(
                exists: { [self] _ in lock.lock(); existsChecks += 1; lock.unlock(); return hasItem },
                read: { [self] _ in lock.lock(); reads += 1; lock.unlock(); return storedKey }
            )
        }
    }

    // MARK: Lock

    private final class PEMList: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ pem: String) { lock.lock(); items.append(pem); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func test_parallelInits_shareOneCA() throws {
        let count = 6
        let results = PEMList()
        let directory = dir!
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            if let pem = (try? CertificateAuthority(directory: directory))?.rootCertificatePEM { results.add(pem) }
        }
        let loaded = results.all
        XCTAssertEqual(loaded.count, count, "every init should load or mint a CA")
        XCTAssertEqual(Set(loaded).count, 1, "parallel inits minted more than one CA")

        let reloaded = try CertificateAuthority(directory: dir)
        XCTAssertEqual(reloaded.rootCertificatePEM, loaded.first)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != ".lock" }
        XCTAssertEqual(Set(files), ["rootCA.pem", "rootCA.key.pem"])
    }

    // MARK: Keychain migration

    func test_migratesFromKeychain_table() {
        XCTAssertTrue(CertificateAuthority.migratesFromKeychain(usesLegacyKeychain: true, allowKeychainMigration: true))
        XCTAssertFalse(CertificateAuthority.migratesFromKeychain(usesLegacyKeychain: true, allowKeychainMigration: false))
        XCTAssertFalse(CertificateAuthority.migratesFromKeychain(usesLegacyKeychain: false, allowKeychainMigration: true))
        XCTAssertFalse(CertificateAuthority.migratesFromKeychain(usesLegacyKeychain: false, allowKeychainMigration: false))
    }

    func test_withoutMigration_aKeyOnlyInTheKeychain_throws_andNeverReadsIt() throws {
        let keychain = FakeKeychain(hasItem: true, storedKey: "unused")
        XCTAssertThrowsError(try CertificateAuthority(directory: dir, allowKeychainMigration: false,
                                                      keychain: keychain.access, usesLegacyKeychain: true)) {
            guard case CAError.keyPresentButUnreadable = $0 else { return XCTFail("unexpected error \($0)") }
        }
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rootCA.pem").path),
                       "no CA may be minted over the Keychain key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rootCA.key.pem").path))
    }

    func test_withoutMigration_andNoKeychainItem_mints_andNeverReadsTheKeychain() throws {
        let keychain = FakeKeychain(hasItem: false)
        let ca = try CertificateAuthority(directory: dir, allowKeychainMigration: false,
                                          keychain: keychain.access, usesLegacyKeychain: true)
        XCTAssertFalse(ca.rootCertificatePEM.isEmpty)
        XCTAssertEqual(keychain.readCount, 0)
    }

    func test_withoutMigration_aKeyFile_isUsed_andTheKeychainIsNotTouched() throws {
        let minted = try CertificateAuthority(directory: dir)
        let keychain = FakeKeychain(hasItem: true, storedKey: "unused")
        let loaded = try CertificateAuthority(directory: dir, allowKeychainMigration: false,
                                              keychain: keychain.access, usesLegacyKeychain: true)
        XCTAssertEqual(loaded.rootCertificatePEM, minted.rootCertificatePEM)
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertEqual(keychain.existsCount, 0)
    }

    func test_withMigration_theKeychainKey_movesToTheFile() throws {
        let source = dir.appendingPathComponent("source", isDirectory: true)
        let target = dir.appendingPathComponent("target", isDirectory: true)
        let original = try CertificateAuthority(directory: source)
        let keyPEM = try String(contentsOf: source.appendingPathComponent("rootCA.key.pem"), encoding: .utf8)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try original.rootCertificatePEM.write(to: target.appendingPathComponent("rootCA.pem"),
                                              atomically: true, encoding: .utf8)

        let keychain = FakeKeychain(hasItem: true, storedKey: keyPEM)
        let migrated = try CertificateAuthority(directory: target, allowKeychainMigration: true,
                                                keychain: keychain.access, usesLegacyKeychain: true)
        XCTAssertEqual(migrated.rootCertificatePEM, original.rootCertificatePEM)
        XCTAssertEqual(keychain.readCount, 1)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("rootCA.key.pem"), encoding: .utf8), keyPEM)
    }

    func test_aCustomDirectory_neverTouchesTheKeychain() throws {
        let keychain = FakeKeychain(hasItem: true, storedKey: "unused")
        _ = try CertificateAuthority(directory: dir, allowKeychainMigration: true,
                                     keychain: keychain.access, usesLegacyKeychain: false)
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertEqual(keychain.existsCount, 0)
    }

    // MARK: IP SAN

    func test_anIPHost_getsAnIPAddressSAN() {
        XCTAssertEqual(CertificateAuthority.subjectAlternativeName(forHost: "10.0.2.2"),
                       .ipAddress(ASN1OctetString(contentBytes: [10, 0, 2, 2])))
        var loopback6 = [UInt8](repeating: 0, count: 16)
        loopback6[15] = 1
        XCTAssertEqual(CertificateAuthority.subjectAlternativeName(forHost: "::1"),
                       .ipAddress(ASN1OctetString(contentBytes: ArraySlice(loopback6))))
        XCTAssertEqual(CertificateAuthority.subjectAlternativeName(forHost: "[::1]"),
                       .ipAddress(ASN1OctetString(contentBytes: ArraySlice(loopback6))))
        XCTAssertEqual(CertificateAuthority.subjectAlternativeName(forHost: "api.example.com"),
                       .dnsName("api.example.com"))
        XCTAssertEqual(CertificateAuthority.subjectAlternativeName(forHost: "10.0.2"), .dnsName("10.0.2"))
    }

    func test_aLeafForAnIPHost_isMinted() throws {
        let ca = try CertificateAuthority(directory: dir)
        XCTAssertNoThrow(try ca.serverContext(forHost: "192.168.1.20"))
        XCTAssertNoThrow(try ca.serverContext(forHost: "::1"))
    }
}
