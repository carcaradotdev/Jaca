import XCTest
@testable import Jaca

/// A `recv` boundary has nothing to do with a frame boundary. Both agent readers used to carry
/// their own copy of this loop, so a fix to one could never reach the other.
final class AgentLineFramerTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func test_lineSplitAcrossTwoReadsIsDeliveredOnce() {
        var framer = AgentLineFramer()
        XCTAssertTrue(framer.consume(bytes(#"{"type":"txn","url":"https://ex"#)).isEmpty)
        XCTAssertEqual(framer.consume(bytes("ample.com/a\"}\n")),
                       [#"{"type":"txn","url":"https://example.com/a"}"#])
    }

    func test_twoFramesInOneReadAreBothDelivered() {
        var framer = AgentLineFramer()
        XCTAssertEqual(framer.consume(bytes("{\"a\":1}\n{\"b\":2}\n")), ["{\"a\":1}", "{\"b\":2}"])
    }

    func test_trailingPartialLineStaysBuffered() {
        var framer = AgentLineFramer()
        XCTAssertEqual(framer.consume(bytes("{\"a\":1}\n{\"b\":")), ["{\"a\":1}"])
        XCTAssertEqual(framer.consume(bytes("2}\n")), ["{\"b\":2}"])
    }

    func test_blankLinesAreSkipped() {
        var framer = AgentLineFramer()
        XCTAssertEqual(framer.consume(bytes("\n\n{\"a\":1}\n\n")), ["{\"a\":1}"])
    }

    /// A line the agent mangled is dropped on its own — the bytes after it are still a valid
    /// frame and must survive.
    func test_invalidUTF8LineIsDroppedWithoutCorruptingTheRemainder() {
        var framer = AgentLineFramer()
        var chunk: [UInt8] = [0xFF, 0xFE, 0x0A]     // a lone continuation pair, then a newline
        chunk += bytes("{\"a\":1}\n")
        XCTAssertEqual(framer.consume(chunk), ["{\"a\":1}"])
    }

    /// A peer that never sends a newline used to grow the framer's buffer without bound. The
    /// ceiling drops the over-long line and resynchronises on the next newline — the frame after
    /// it must still arrive, or one wedged write would deafen the reader for good.
    func test_overLongLineIsDroppedAndTheNextFrameStillArrives() {
        var framer = AgentLineFramer()
        let oversize = [UInt8](repeating: 0x41, count: AgentLineFramer.maxLineBytes + 1024)
        XCTAssertTrue(framer.consume(oversize).isEmpty)

        // The tail of the discarded line, then a real frame.
        let rest = Array(#"junk\#n{"type":"hello"}\#n"#.utf8)
        XCTAssertEqual(framer.consume(rest), [#"{"type":"hello"}"#])
    }
}
