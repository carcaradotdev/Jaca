import XCTest
@testable import Jaca

/// The proxy's upstream requests go direct. While Jaca sets the Mac system proxy for the iOS
/// Simulator, a session that used the system proxy would send each request back into Jaca.
final class UpstreamClientConfigurationTests: XCTestCase {
    func test_theConfiguration_ignoresTheSystemProxy() throws {
        let proxies = try XCTUnwrap(UpstreamClient.makeConfiguration().connectionProxyDictionary,
                                    "nil means the system proxy settings apply")
        XCTAssertTrue(proxies.isEmpty)
    }

    func test_theConfiguration_keepsNoCookies() {
        let config = UpstreamClient.makeConfiguration()
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertNil(config.httpCookieStorage)
    }
}
