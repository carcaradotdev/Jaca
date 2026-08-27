import XCTest
@testable import Jaca

/// Merge vs replace semantics, and the framing headers Jaca must always own.
final class ResponseEditTests: XCTestCase {

    private let origin = InterceptedResponse(
        statusCode: 200,
        headers: [
            HeaderPair(name: "Content-Type", value: "application/json"),
            HeaderPair(name: "Set-Cookie", value: "session=abc"),
            HeaderPair(name: "X-Origin", value: "real"),
        ],
        body: Data("{\"real\":true}".utf8)
    )

    func test_mergeKeepsOriginHeadersAndAddsNewOnes() {
        let edit = ResponseEdit(headerMode: .merge, headers: [HeaderPair(name: "X-Added", value: "1")])
        let out = ResponseEditing.apply(edit, to: origin)
        XCTAssertTrue(out.headers.contains { $0.name == "X-Origin" })
        XCTAssertTrue(out.headers.contains { $0.name == "X-Added" })
    }

    func test_mergeReplacesASameNamedHeaderRatherThanDuplicatingIt() {
        let edit = ResponseEdit(headerMode: .merge,
                                headers: [HeaderPair(name: "content-type", value: "text/plain")])
        let out = ResponseEditing.apply(edit, to: origin)
        let contentTypes = out.headers.filter { $0.name.lowercased() == "content-type" }
        XCTAssertEqual(contentTypes.count, 1)
        XCTAssertEqual(contentTypes.first?.value, "text/plain")
    }

    func test_replaceDropsEveryOriginHeader() {
        let edit = ResponseEdit(headerMode: .replace, headers: [HeaderPair(name: "X-Only", value: "1")])
        let out = ResponseEditing.apply(edit, to: origin)
        XCTAssertEqual(out.headers.map(\.name), ["X-Only"])
    }

    func test_removeHeadersDropsNamedHeadersOnMerge() {
        let edit = ResponseEdit(headerMode: .merge, removeHeaders: ["set-cookie"])
        let out = ResponseEditing.apply(edit, to: origin)
        XCTAssertFalse(out.headers.contains { $0.name.lowercased() == "set-cookie" })
        XCTAssertTrue(out.headers.contains { $0.name == "X-Origin" })
    }

    func test_statusIsOverriddenOnlyWhenSpecified() {
        XCTAssertEqual(ResponseEditing.apply(ResponseEdit(), to: origin).statusCode, 200)
        XCTAssertEqual(ResponseEditing.apply(ResponseEdit(statusCode: 503), to: origin).statusCode, 503)
    }

    func test_bodyIsReplacedOnlyWhenSpecified() {
        XCTAssertEqual(ResponseEditing.apply(ResponseEdit(), to: origin).body, origin.body)
        let edited = ResponseEditing.apply(ResponseEdit(body: .inline("{}")), to: origin)
        XCTAssertEqual(edited.body, Data("{}".utf8))
    }

    /// Framing headers describe the bytes Jaca is about to write, so an edit must never be able
    /// to set them — a stale `Content-Length` would truncate or hang the client.
    func test_framingHeadersAreNeverTakenFromAnEdit() {
        let edit = ResponseEdit(headerMode: .replace, headers: [
            HeaderPair(name: "Content-Length", value: "99999"),
            HeaderPair(name: "Content-Encoding", value: "gzip"),
            HeaderPair(name: "Transfer-Encoding", value: "chunked"),
            HeaderPair(name: "X-Kept", value: "yes"),
        ])
        let out = ResponseEditing.apply(edit, to: origin)
        XCTAssertEqual(out.headers.map(\.name), ["X-Kept"])
    }

    // MARK: - Outbound header sanitisation

    /// `X-Jaca-Original-URL` is not a hop-by-hop header, so without an explicit rule it would be
    /// forwarded to the real origin — leaking Jaca's presence and the app's URL structure.
    func test_jacaInternalHeadersNeverReachTheOrigin() {
        XCTAssertTrue(HTTPWireFormat.shouldDropFromOutbound(OverrideHeaders.originalURL))
        XCTAssertTrue(HTTPWireFormat.shouldDropFromOutbound(OverrideHeaders.divert))
        XCTAssertTrue(HTTPWireFormat.shouldDropFromOutbound(OverrideHeaders.override))
        XCTAssertTrue(HTTPWireFormat.shouldDropFromOutbound("x-jaca-anything-future"))
    }

    func test_hopByHopAndHostAreDroppedFromOutbound() {
        for name in ["Connection", "Proxy-Connection", "Transfer-Encoding", "Upgrade", "Host", "Content-Length"] {
            XCTAssertTrue(HTTPWireFormat.shouldDropFromOutbound(name), "\(name) should be dropped")
        }
        XCTAssertFalse(HTTPWireFormat.shouldDropFromOutbound("Authorization"))
        XCTAssertFalse(HTTPWireFormat.shouldDropFromOutbound("Accept"))
    }
}

/// URL recovery: matching must always run against the URL the app *meant* to call, never the
/// rewritten one on the wire.
final class OverrideURLTests: XCTestCase {

    func test_agentPrefersTheOriginalURLHeader() {
        let headers = [
            HeaderPair(name: "Host", value: "localhost:41234"),
            HeaderPair(name: OverrideHeaders.originalURL, value: "https://api.teya.xyz/v1/state"),
        ]
        XCTAssertEqual(AgentOriginalURL.recover(headers: headers, uri: "/v1/state"),
                       "https://api.teya.xyz/v1/state")
    }

    func test_agentFallsBackToHostPlusOriginFormURI() {
        let headers = [HeaderPair(name: "Host", value: "api.example.com")]
        XCTAssertEqual(AgentOriginalURL.recover(headers: headers, uri: "/v1/state"),
                       "http://api.example.com/v1/state")
    }

    func test_agentIgnoresAMalformedOriginalURLHeader() {
        let headers = [
            HeaderPair(name: "Host", value: "api.example.com"),
            HeaderPair(name: OverrideHeaders.originalURL, value: "not a url"),
        ]
        XCTAssertEqual(AgentOriginalURL.recover(headers: headers, uri: "/v1/state"),
                       "http://api.example.com/v1/state")
    }

    func test_agentReturnsNilWithNothingToGoOn() {
        XCTAssertNil(AgentOriginalURL.recover(headers: [], uri: "/v1/state"))
    }

    func test_proxyTlsModeRebuildsHttpsFromConnectHost() {
        XCTAssertEqual(ProxyOriginalURL.recover(mode: .tls(host: "api.example.com"),
                                                uri: "/v1/state", hostHeader: nil),
                       "https://api.example.com/v1/state")
    }

    func test_proxyInitialModeUsesAbsoluteFormURI() {
        XCTAssertEqual(ProxyOriginalURL.recover(mode: .initial,
                                                uri: "http://api.example.com/v1", hostHeader: nil),
                       "http://api.example.com/v1")
    }

    // MARK: - Redirect resolution (divert must follow; the proxy must not)

    func test_relativeRedirectsResolveAgainstTheCurrentURL() {
        XCTAssertEqual(OriginClient.resolve(location: "/v2/state", against: "https://a.com/v1/state"),
                       "https://a.com/v2/state")
        XCTAssertEqual(OriginClient.resolve(location: "https://b.com/x", against: "https://a.com/v1"),
                       "https://b.com/x")
    }

    func test_outboundRequestDropsInternalHeaders() throws {
        let request = InterceptedRequest(
            method: "POST",
            url: "https://api.example.com/v1",
            headers: [
                HeaderPair(name: "Authorization", value: "Bearer t"),
                HeaderPair(name: "Host", value: "localhost:41234"),
                HeaderPair(name: OverrideHeaders.originalURL, value: "https://api.example.com/v1"),
            ],
            body: Data("{}".utf8),
            transport: .agentDivert(package: "com.example"))

        let urlRequest = try XCTUnwrap(OriginClient.makeURLRequest(from: request))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: OverrideHeaders.originalURL))
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.httpBody, Data("{}".utf8))
    }
}
