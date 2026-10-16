import Foundation

public enum PageRanges {
    /// "1,3-5" → [0, 2, 3, 4] (zero-based, sorted, unique, clamped to `count`).
    public static func parse(_ text: String, count: Int) -> [Int] {
        var pages = Set<Int>()
        for token in text.split(separator: ",") {
            let bounds = token.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = Int(bounds[0]) else { continue }
            let last = bounds.count > 1 ? (Int(bounds[1]) ?? count) : first
            guard first <= last else { continue }
            for p in first...last where p >= 1 && p <= count { pages.insert(p - 1) }
        }
        return pages.sorted()
    }

    /// [0, 2, 3, 4] → "1,3-5".
    public static func format(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i] + 1)" : "\(sorted[i] + 1)-\(sorted[j] + 1)")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    public struct Placement: Equatable, Sendable {
        /// Zero-based source page.
        public let page: Int
        /// Extra rotation in degrees (0, 90, 180, 270).
        public let rotation: Int
        public init(page: Int, rotation: Int) {
            self.page = page
            self.rotation = rotation
        }
    }

    /// "3,1:90,2" → placements. Empty text means every page in order.
    public static func parseArrangement(_ text: String, count: Int) -> [Placement] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (0..<count).map { Placement(page: $0, rotation: 0) } }
        return trimmed.split(separator: ",").compactMap { token in
            let parts = token.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let page = Int(parts[0]), page >= 1, page <= count else { return nil }
            let rotation = parts.count > 1 ? ((Int(parts[1]) ?? 0) % 360 + 360) % 360 : 0
            return Placement(page: page - 1, rotation: rotation)
        }
    }

    public static func formatArrangement(_ placements: [Placement]) -> String {
        placements.map { $0.rotation == 0 ? "\($0.page + 1)" : "\($0.page + 1):\($0.rotation)" }
            .joined(separator: ",")
    }
}
