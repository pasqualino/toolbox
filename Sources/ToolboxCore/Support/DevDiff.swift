import Foundation

/// Line diff with unified-style hunks, using patience diff with a Myers fallback
/// so large inputs stay fast even when most lines moved.
enum DevDiff {
    /// Each op carries the line index on both sides at that point of the walk.
    enum Op {
        case equal(Int, Int)
        case remove(Int, Int)
        case insert(Int, Int)
    }

    static func diff(_ a: String, _ b: String, ignoreWhitespace: Bool, context: Int = 3) -> String {
        let old = a.isEmpty ? [] : DevTextReport.lines(a).lines
        let new = b.isEmpty ? [] : DevTextReport.lines(b).lines
        // Map each distinct line (or whitespace-free key) to an Int so the diff compares integers.
        var ids: [String: Int] = [:]
        func key(_ s: Substring) -> Int {
            let k =
                ignoreWhitespace
                ? String(s.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }) : String(s)
            if let id = ids[k] { return id }
            ids[k] = ids.count
            return ids.count - 1
        }
        let ka = old.map(key)
        let kb = new.map(key)

        var matches: [(Int, Int)] = []
        match(ka, kb, 0..<ka.count, 0..<kb.count, into: &matches)
        if matches.count == ka.count, matches.count == kb.count { return "No differences." }

        var ops: [Op] = []
        ops.reserveCapacity(ka.count + kb.count)
        var i = 0
        var j = 0
        for (x, y) in matches + [(ka.count, kb.count)] {
            while i < x {
                ops.append(.remove(i, j))
                i += 1
            }
            while j < y {
                ops.append(.insert(i, j))
                j += 1
            }
            if x < ka.count {
                ops.append(.equal(i, j))
                i += 1
                j += 1
            }
        }

        // Group changes into hunks that share context.
        let changes = ops.indices.filter {
            if case .equal = ops[$0] { return false }
            return true
        }
        var hunks: [(Int, Int)] = []
        for c in changes {
            if let last = hunks.last, c - last.1 <= 2 * context + 1 {
                hunks[hunks.count - 1].1 = c
            } else {
                hunks.append((c, c))
            }
        }
        var out: [String] = []
        for (first, last) in hunks {
            let lo = max(0, first - context)
            let hi = min(ops.count - 1, last + context)
            var aStart = -1
            var bStart = -1
            var aCount = 0
            var bCount = 0
            var body: [String] = []
            for op in ops[lo...hi] {
                switch op {
                case .equal(let x, let y):
                    if aStart < 0 { aStart = x }
                    if bStart < 0 { bStart = y }
                    aCount += 1
                    bCount += 1
                    body.append("  " + old[x])
                case .remove(let x, _):
                    if aStart < 0 { aStart = x }
                    aCount += 1
                    body.append("- " + old[x])
                case .insert(_, let y):
                    if bStart < 0 { bStart = y }
                    bCount += 1
                    body.append("+ " + new[y])
                }
            }
            // Unified diff numbers lines from 1; an empty side points at the line before it.
            let aPos = aCount == 0 ? linesBefore(ops[lo], old: true) : aStart + 1
            let bPos = bCount == 0 ? linesBefore(ops[lo], old: false) : bStart + 1
            out.append("@@ -\(aPos),\(aCount) +\(bPos),\(bCount) @@")
            out += body
        }
        return out.joined(separator: "\n")
    }

    /// Patience diff: trim equal ends, anchor on lines unique to both sides, recurse between
    /// anchors. Regions with no anchors fall back to CollectionDifference (Myers) when small.
    static func match(_ a: [Int], _ b: [Int], _ ra: Range<Int>, _ rb: Range<Int>, into out: inout [(Int, Int)]) {
        var lo = ra.lowerBound
        var loB = rb.lowerBound
        var hi = ra.upperBound
        var hiB = rb.upperBound
        while lo < hi, loB < hiB, a[lo] == b[loB] {
            out.append((lo, loB))
            lo += 1
            loB += 1
        }
        var tail: [(Int, Int)] = []
        while hi > lo, hiB > loB, a[hi - 1] == b[hiB - 1] {
            hi -= 1
            hiB -= 1
            tail.append((hi, hiB))
        }
        defer { out += tail.reversed() }
        guard lo < hi, loB < hiB else { return }

        // Lines that occur exactly once on each side, in order of side A.
        var count: [Int: (a: Int, b: Int, posB: Int)] = [:]
        for i in lo..<hi { count[a[i], default: (0, 0, 0)].a += 1 }
        for j in loB..<hiB where count[b[j]] != nil {
            count[b[j]]!.b += 1
            count[b[j]]!.posB = j
        }
        let unique = (lo..<hi).compactMap { i -> (Int, Int)? in
            guard let c = count[a[i]], c.a == 1, c.b == 1 else { return nil }
            return (i, c.posB)
        }
        let anchors = longestIncreasing(unique)
        if anchors.isEmpty {
            if (hi - lo) * (hiB - loB) <= 4_000_000 { myers(a, b, lo..<hi, loB..<hiB, into: &out) }
            return
        }
        var pa = lo
        var pb = loB
        for (x, y) in anchors {
            match(a, b, pa..<x, pb..<y, into: &out)
            out.append((x, y))
            pa = x + 1
            pb = y + 1
        }
        match(a, b, pa..<hi, pb..<hiB, into: &out)
    }

    /// Longest run of pairs increasing in both coordinates (patience sorting, n log n).
    static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tops: [Int] = []
        var back = [Int](repeating: -1, count: pairs.count)
        for (k, p) in pairs.enumerated() {
            var l = 0
            var r = tops.count
            while l < r {
                let m = (l + r) / 2
                if pairs[tops[m]].1 < p.1 { l = m + 1 } else { r = m }
            }
            if l > 0 { back[k] = tops[l - 1] }
            if l == tops.count { tops.append(k) } else { tops[l] = k }
        }
        var result: [(Int, Int)] = []
        var k = tops.last ?? -1
        while k >= 0 {
            result.append(pairs[k])
            k = back[k]
        }
        return result.reversed()
    }

    static func myers(_ a: [Int], _ b: [Int], _ ra: Range<Int>, _ rb: Range<Int>, into out: inout [(Int, Int)]) {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in Array(b[rb]).difference(from: Array(a[ra])) {
            switch change {
            case .remove(let o, _, _): removed.insert(o + ra.lowerBound)
            case .insert(let o, _, _): inserted.insert(o + rb.lowerBound)
            }
        }
        var i = ra.lowerBound
        var j = rb.lowerBound
        while i < ra.upperBound || j < rb.upperBound {
            if i < ra.upperBound, removed.contains(i) {
                i += 1
            } else if j < rb.upperBound, inserted.contains(j) {
                j += 1
            } else {
                out.append((i, j))
                i += 1
                j += 1
            }
        }
    }

    /// Lines of one side before this op.
    static func linesBefore(_ op: Op, old: Bool) -> Int {
        switch op {
        case .equal(let x, let y), .remove(let x, let y), .insert(let x, let y): old ? x : y
        }
    }
}
