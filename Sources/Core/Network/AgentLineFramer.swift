import Foundation

/// Bytes → complete lines, shared by both agent readers so a fix reaches both.
///
/// A `recv` boundary is not a frame boundary: a 3 KB transaction routinely arrives as two reads,
/// and two small frames as one.
struct AgentLineFramer {
    /// Whatever arrived after the last newline, held across `consume` calls — dropping it would
    /// corrupt every frame that straddles a read.
    private var buffer = Data()
    /// Set while discarding an over-long line, so its tail can't be mistaken for a frame.
    private var discardingLine = false

    /// Bodies are capped at 1 MB each, so a legitimate line stays well under this. Without a
    /// ceiling a peer that never sends a newline grows `buffer` without bound.
    static let maxLineBytes = 16 * 1024 * 1024

    /// Appends `bytes` and returns every complete line it now contains. Invalid-UTF-8 lines are
    /// dropped without disturbing the remainder; blank lines are skipped.
    mutating func consume<C: Collection>(_ bytes: C) -> [String] where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            // Resynchronise on the newline that ends an over-long line; the bytes after it are a
            // fresh frame and must survive, exactly as for a mangled line below.
            if discardingLine { discardingLine = false; continue }
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            lines.append(line)
        }
        if buffer.count > Self.maxLineBytes {
            // No newline in sight and past the ceiling — drop what we hold and skip to the next.
            buffer.removeAll(keepingCapacity: false)
            discardingLine = true
        }
        return lines
    }
}
