// Core.swift — мост к движку, дерево каталогов и раскладка ромашки.
import Foundation

// MARK: - Форматирование

func humanBytes(_ b: UInt64) -> String {
    var v = Double(b)
    let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    if i == 0 { return "\(Int(v)) \(units[i])" }
    return v >= 100 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
}

func humanCount(_ n: UInt64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = " "
    f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

func shareText(_ part: UInt64, _ total: UInt64) -> String {
    guard total > 0 else { return "—" }
    let p = Double(part) / Double(total) * 100
    return p >= 10 ? String(format: "%.0f %%", p) : String(format: "%.1f %%", p)
}

func humanDuration(_ s: Double) -> String {
    if s < 1 { return String(format: "%.2f с", s) }
    if s < 60 { return String(format: "%.1f с", s) }
    return String(format: "%d мин %.0f с", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

// MARK: - Движок

struct RKSnapshot {
    var nodes: [rk_node] = []
    var names: [CChar] = []
}

struct BigFile: Identifiable {
    var path: String
    var size: UInt64
    var mtime: Date
    var id: String { path }
}

final class Scan {
    private(set) var handle: OpaquePointer?
    let root: String

    init?(root: String, jobs: Int32 = 4, bigFileMin: UInt64 = 200 << 20, exclusions: [String] = []) {
        self.root = root
        let cstrings: [UnsafeMutablePointer<CChar>?] = exclusions.map { strdup($0) }
        defer { cstrings.forEach { free($0) } }
        let pointers = cstrings.map { UnsafePointer($0) }
        let h = pointers.withUnsafeBufferPointer { buf -> OpaquePointer? in
            root.withCString { r in
                rk_new(r, jobs, bigFileMin, buf.baseAddress, Int32(buf.count))
            }
        }
        guard let h else { return nil }
        handle = h
    }

    deinit {
        if let handle {
            rk_cancel(handle)
            rk_wait(handle)
            rk_free(handle)
        }
    }

    var isRunning: Bool { guard let handle else { return false }; return rk_running(handle) }

    var errorMessage: String? {
        guard let handle, let e = rk_error(handle) else { return nil }
        return String(cString: e)
    }

    func start() { if let handle { rk_start(handle) } }
    func cancel() { if let handle { rk_cancel(handle) } }
    func wait() { if let handle { rk_wait(handle) } }

    var progress: rk_progress {
        var p = rk_progress()
        if let handle { rk_progress_get(handle, &p) }
        return p
    }

    /// Снимок дерева. minSize > 0 — берём только крупные узлы (для живой картинки во время обхода).
    func snapshot(minSize: UInt64 = 0, maxNodes: Int = 20_000_000, namesCap: Int = 32 << 20) -> RKSnapshot {
        guard let handle else { return RKSnapshot() }
        let count = min(Int(rk_node_count(handle)) + 4096, maxNodes)
        guard count > 0 else { return RKSnapshot() }
        let nodePtr = UnsafeMutablePointer<rk_node>.allocate(capacity: count)
        let origPtr = UnsafeMutablePointer<UInt32>.allocate(capacity: count)
        let namePtr = UnsafeMutablePointer<CChar>.allocate(capacity: namesCap)
        defer { nodePtr.deallocate(); origPtr.deallocate(); namePtr.deallocate() }
        let n = Int(rk_snapshot(handle, nodePtr, origPtr, namePtr, UInt64(count), UInt64(namesCap), minSize))
        guard n > 0 else { return RKSnapshot() }
        var used = 0
        for i in 0..<n { used = max(used, Int(nodes_name_end(nodePtr[i]))) }
        used = min(max(used, 1), namesCap)
        return RKSnapshot(nodes: Array(UnsafeBufferPointer(start: nodePtr, count: n)),
                          names: Array(UnsafeBufferPointer(start: namePtr, count: used)))
    }

    func bigFiles() -> [BigFile] {
        guard let handle else { return [] }
        var len: UInt64 = 0
        guard let text = rk_bigfiles_text(handle, &len), len > 0 else { return [] }
        defer { rk_free_text(text) }
        let s = String(decoding: UnsafeRawBufferPointer(start: text, count: Int(len)), as: UTF8.self)
        var out: [BigFile] = []
        out.reserveCapacity(512)
        for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let size = UInt64(parts[0]), let mt = Double(parts[1]) else { continue }
            out.append(BigFile(path: String(parts[2]), size: size, mtime: Date(timeIntervalSince1970: mt)))
        }
        return out
    }

    func verify() -> (bad: UInt64, first: String) {
        guard let handle else { return (0, "") }
        var buf = [CChar](repeating: 0, count: 1024)
        let bad = buf.withUnsafeMutableBufferPointer { p in
            rk_verify(handle, p.baseAddress, UInt64(p.count))
        }
        return (bad, String(cString: buf))
    }
}

// конец имени узла в буфере имён (движок отдаёт смещение и длину)
private func nodes_name_end(_ n: rk_node) -> UInt32 {
    n.nameOff &+ n.nameLen
}

// MARK: - Дерево

final class TreeStore {
    private(set) var count: Int = 0
    private(set) var parent: [Int32] = []
    private(set) var size: [UInt64] = []
    private(set) var own: [UInt64] = []
    private(set) var logical: [UInt64] = []
    private(set) var depth: [Int32] = []
    private(set) var denied: [UInt32] = []
    private(set) var nameOff: [Int32] = []
    private(set) var nameLen: [Int32] = []
    private(set) var nameBytes: [CChar] = []
    private(set) var childStart: [Int32] = []
    private(set) var childList: [Int32] = []
    private(set) var root: Int32 = 0
    private(set) var full: Bool = false

    var isEmpty: Bool { count == 0 }

    func build(from snap: RKSnapshot, isFull: Bool) {
        let n = snap.nodes.count
        count = n
        full = isFull
        guard n > 0 else {
            parent = []; size = []; own = []; logical = []; depth = []; denied = []
            nameOff = []; nameLen = []; nameBytes = []; childStart = []; childList = []
            return
        }
        parent = [Int32](repeating: -1, count: n)
        size = [UInt64](repeating: 0, count: n)
        own = [UInt64](repeating: 0, count: n)
        logical = [UInt64](repeating: 0, count: n)
        depth = [Int32](repeating: 0, count: n)
        denied = [UInt32](repeating: 0, count: n)
        nameOff = [Int32](repeating: 0, count: n)
        nameLen = [Int32](repeating: 0, count: n)
        nameBytes = snap.names
        for i in 0..<n {
            let s = snap.nodes[i]
            parent[i] = s.parent == UInt32.max ? -1 : Int32(s.parent)
            size[i] = s.size
            own[i] = s.own
            logical[i] = s.logical
            depth[i] = Int32(s.depth)
            denied[i] = s.denied
            nameOff[i] = Int32(s.nameOff)
            nameLen[i] = Int32(s.nameLen)
        }
        // дети: CSR-индекс, внутри каждого узла — по убыванию размера
        var counts = [Int32](repeating: 0, count: n)
        for i in 1..<n {
            let p = Int(parent[i])
            if p >= 0 && p < n { counts[p] += 1 }
        }
        childStart = [Int32](repeating: 0, count: n + 1)
        var acc: Int32 = 0
        for i in 0..<n { childStart[i] = acc; acc += counts[i] }
        childStart[n] = acc
        var cursor = childStart
        childList = [Int32](repeating: 0, count: max(0, n - 1))
        for i in 1..<n {
            let p = Int(parent[i])
            if p >= 0 && p < n { childList[Int(cursor[p])] = Int32(i); cursor[p] += 1 }
        }
        for i in 0..<n {
            let s = Int(childStart[i]), e = Int(childStart[i + 1])
            if e - s > 1 { childList[s..<e].sort(by: { size[Int($0)] > size[Int($1)] }) }
        }
        root = 0
    }

    func children(_ i: Int32) -> ArraySlice<Int32> {
        guard i >= 0, Int(i) < count else { return [][...] }
        let s = Int(childStart[Int(i)]), e = Int(childStart[Int(i) + 1])
        guard s < e else { return [][...] }
        return childList[s..<e]
    }

    func name(_ i: Int32) -> String {
        guard i >= 0, Int(i) < count else { return "" }
        let off = Int(nameOff[Int(i)]), len = Int(nameLen[Int(i)])
        guard len > 0, off >= 0, off + len <= nameBytes.count else { return "" }
        let bytes = nameBytes[off..<(off + len)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Путь относительно корня обхода, массив имён (для крошек и восстановления фокуса).
    func chain(_ i: Int32) -> [String] {
        var out: [String] = []
        var cur = i
        var guardCount = 0
        while cur > 0 && guardCount < 512 {
            out.append(name(cur))
            cur = parent[Int(cur)]
            guardCount += 1
        }
        return out.reversed()
    }

    /// Найти узел по цепочке имён от корня.
    func resolve(_ chain: [String]) -> Int32 {
        var cur = root
        for part in chain {
            var found: Int32 = -1
            for c in children(cur) where name(c) == part { found = c; break }
            if found < 0 { return cur }
            cur = found
        }
        return cur
    }

    func path(_ i: Int32, rootPath: String) -> String {
        var p = rootPath
        for part in chain(i) {
            if p.hasSuffix("/") { p += part } else { p += "/" + part }
        }
        return p
    }

    /// Доля узла в его родителе (для подписи в центре).
    func parentShare(_ i: Int32) -> Double {
        guard i > 0, Int(i) < count else { return 1 }
        let p = Int(parent[Int(i)])
        guard p >= 0, p < count, size[p] > 0 else { return 1 }
        return Double(size[Int(i)]) / Double(size[p])
    }

    /// Сумма детей — остаток от размера узла показываем как «прочее».
    func childrenSum(_ i: Int32) -> UInt64 {
        var s: UInt64 = 0
        for c in children(i) { s &+= size[Int(c)] }
        return s
    }
}
