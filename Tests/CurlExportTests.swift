import XCTest
@testable import Jaca

final class CurlExportTests: XCTestCase {
    private func txn(method: String = "GET",
                     url: String = "https://api.example.com/v1/users?page=2",
                     headers: [HeaderPair] = [],
                     body: Data? = nil) -> NetworkTransaction {
        NetworkTransaction(method: method, url: url, host: "api.example.com", scheme: "https",
                           requestHeaders: headers, requestBody: body)
    }

    func testGetOmitsMethodAndQuotesURL() {
        let command = CurlExport.command(for: txn(headers: [HeaderPair(name: "Accept", value: "application/json")]))
        XCTAssertEqual(command, """
        curl 'https://api.example.com/v1/users?page=2' \\
          -H 'Accept: application/json'
        """)
    }

    func testPostIncludesMethodAndBody() {
        let command = CurlExport.command(for: txn(
            method: "POST",
            headers: [HeaderPair(name: "Content-Type", value: "application/json")],
            body: Data(#"{"name":"ada"}"#.utf8)))
        XCTAssertTrue(command.contains("-X POST"), command)
        XCTAssertTrue(command.contains("-H 'Content-Type: application/json'"), command)
        XCTAssertTrue(command.contains(#"--data-raw '{"name":"ada"}'"#), command)
    }

    func testGetWithBodyStillSpellsOutTheMethod() {
        let command = CurlExport.command(for: txn(body: Data("hi".utf8)))
        XCTAssertTrue(command.contains("-X GET"), command)
    }

    func testEmptyBodyIsNotSentAsData() {
        let command = CurlExport.command(for: txn(method: "POST", body: Data()))
        XCTAssertFalse(command.contains("--data"), command)
        XCTAssertTrue(command.contains("-X POST"), command)
    }

    func testSingleQuotesInValuesAreEscaped() {
        let command = CurlExport.command(for: txn(
            method: "POST",
            headers: [HeaderPair(name: "X-Note", value: "it's fine")],
            body: Data("don't".utf8)))
        XCTAssertTrue(command.contains(#"-H 'X-Note: it'\''s fine'"#), command)
        XCTAssertTrue(command.contains(#"--data-raw 'don'\''t'"#), command)
    }

    func testDropsContentLengthAndPseudoHeaders() {
        let command = CurlExport.command(for: txn(headers: [
            HeaderPair(name: ":method", value: "GET"),
            HeaderPair(name: ":authority", value: "api.example.com"),
            HeaderPair(name: "Content-Length", value: "42"),
            HeaderPair(name: "Accept", value: "*/*"),
        ]))
        XCTAssertFalse(command.contains(":method"), command)
        XCTAssertFalse(command.contains(":authority"), command)
        XCTAssertFalse(command.lowercased().contains("content-length"), command)
        XCTAssertTrue(command.contains("-H 'Accept: */*'"), command)
    }

    func testAcceptEncodingBecomesCompressedFlag() {
        let command = CurlExport.command(for: txn(headers: [
            HeaderPair(name: "Accept-Encoding", value: "gzip, deflate, br"),
        ]))
        XCTAssertFalse(command.lowercased().contains("accept-encoding"), command)
        XCTAssertTrue(command.hasSuffix("--compressed"), command)
    }

    func testUnknownAcceptEncodingIsKeptAsAHeader() {
        let command = CurlExport.command(for: txn(headers: [
            HeaderPair(name: "Accept-Encoding", value: "identity"),
        ]))
        XCTAssertTrue(command.contains("-H 'Accept-Encoding: identity'"), command)
        XCTAssertFalse(command.contains("--compressed"), command)
    }

    func testBinaryBodyUsesAnsiCQuoting() {
        let command = CurlExport.command(for: txn(method: "POST", body: Data([0x00, 0xFF, 0x10])))
        XCTAssertTrue(command.contains(#"--data-binary $'\x00\xff\x10'"#), command)
    }

    func testEscapesNonLetterMethod() {
        let command = CurlExport.command(for: txn(method: "M-SEARCH"))
        XCTAssertTrue(command.contains("-X 'M-SEARCH'"), command)
    }
}
