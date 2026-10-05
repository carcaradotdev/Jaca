import Foundation

/// Decodes a single element without failing the whole array, so one unreadable record can't wipe
/// an entire cache file.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Migration-safe decoding for the on-disk caches. Combined with each model's tolerant
/// `init(from:)` (missing keys fall back to defaults), this guarantees that adding a field in a
/// new release never drops the user's existing ~/.jaca data — the cardinal rule for these stores.
enum CloudPersistence {
    /// Tolerantly decodes a JSON array: the whole array first, then element-by-element, skipping
    /// any record that fails. Returns [] only when the data isn't a JSON array at all.
    ///
    /// `decoder` lets a store match the strategy it *encoded* with. A mismatch is silent and
    /// total: every record throws, the array comes back empty, and the next save writes nothing.
    static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data,
                                          decoder: JSONDecoder = JSONDecoder()) -> [T] {
        if let all = try? decoder.decode([T].self, from: data) { return all }
        guard let wrapped = try? decoder.decode([FailableDecodable<T>].self, from: data) else { return [] }
        return wrapped.compactMap { $0.value }
    }
}
