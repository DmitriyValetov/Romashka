// AppState.swift — состояние приложения: обход, вид, навигация, Finder.
import SwiftUI
import AppKit

struct ScanProgress: Equatable {
    var files: UInt64 = 0
    var dirs: UInt64 = 0
    var alloc: UInt64 = 0
    var errors: UInt64 = 0
    var elapsed: Double = 0
    var running = false
    var objects: UInt64 { files &+ dirs }
    var rate: Double { elapsed > 0.01 ? Double(objects) / elapsed : 0 }
}

extension Scan: @unchecked Sendable {}
extension TreeStore: @unchecked Sendable {}

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable { case idle, scanning, finishing, ready, failed(String) }

    @Published var phase: Phase = .idle
    @Published var scanProgress = ScanProgress()
    @Published var store = TreeStore()
    @Published var storeIsPartial = false
    @Published var focus: Int32 = 0
    @Published var focusChain: [String] = []
    @Published var rootPath: String = NSHomeDirectory()
    @Published var rootLabel: String = "~"
    @Published var bigFiles: [BigFile] = []
    @Published var showBigFiles = false
    @Published var ringCount = 3
    @Published var deniedCount: UInt64 = 0
    @Published var verifyBad: UInt64 = 0
    @Published var verifyNodes: UInt64 = 0
    @Published var freeSpace: UInt64? = nil
    @Published var scanDuration: Double = 0
    @Published var fileCount: UInt64 = 0
    @Published var dirCount: UInt64 = 0
    @Published var bigFileMin: UInt64 = 200 << 20

    private var scan: Scan?
    private var pollTask: Task<Void, Never>?
    private var ticks = 0

    // MARK: - Обход

    static func exclusions(for root: String) -> [String] {
        var e: [String] = []
        if root == "/" {
            e += ["/System", "/Volumes", "/dev", "/net", "/home", "/private/var/vm", "/.vol", "/cores"]
        }
        if root == "/System/Volumes/Data" {
            e += ["/System/Volumes/Data/Volumes"]
        }
        return e
    }

    func startScan(path: String, label: String? = nil, jobs: Int32 = 4) {
        stopPolling()
        scan?.cancel()
        scan = nil
        store = TreeStore()
        storeIsPartial = false
        focus = 0
        focusChain = []
        bigFiles = []
        deniedCount = 0
        verifyBad = 0
        verifyNodes = 0
        scanProgress = ScanProgress()
        scanDuration = 0
        fileCount = 0
        dirCount = 0
        ticks = 0

        let expanded = (path as NSString).expandingTildeInPath
        rootPath = expanded
        rootLabel = label ?? (expanded == NSHomeDirectory() ? "~" : (expanded as NSString).lastPathComponent)
        guard let s = Scan(root: expanded, jobs: jobs, bigFileMin: bigFileMin,
                           exclusions: Self.exclusions(for: expanded)) else {
            phase = .failed("не удалось создать обход")
            return
        }
        scan = s
        s.start()
        if let e = s.errorMessage { phase = .failed(e); return }
        phase = .scanning
        updateFreeSpace()
        startPolling()
    }

    func rescan() { startScan(path: rootPath, label: rootLabel) }
    func cancelScan() {
        scan?.cancel()
        stopPolling()
        phase = .idle
        storeIsPartial = false
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                self.tickScan()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tickScan() {
        guard let s = scan else { return }
        let p = s.progress
        scanProgress = ScanProgress(files: p.files, dirs: p.dirs, alloc: p.alloc,
                                    errors: p.errors, elapsed: p.elapsed, running: p.running)
        ticks += 1
        if p.running {
            if ticks % 3 == 0 { refreshLiveStore(alloc: p.alloc) }
        } else {
            finishScan()
        }
    }

    /// Живая картинка во время обхода: берём только крупные узлы, чтобы снимок был дешёвым.
    private func refreshLiveStore(alloc: UInt64) {
        guard let s = scan else { return }
        let minSize = max(4 << 20, alloc / 1500)
        let snap = s.snapshot(minSize: minSize, maxNodes: 50_000, namesCap: 4 << 20)
        guard !snap.nodes.isEmpty else { return }
        let st = TreeStore()
        st.build(from: snap, isFull: false)
        store = st
        storeIsPartial = true
        if focusChain.count > 6 { focusChain = Array(focusChain.prefix(6)) }
        focus = st.resolve(focusChain)
    }

    private func finishScan() {
        stopPolling()
        guard let s = scan else { return }
        let p = s.progress
        scanDuration = p.elapsed
        fileCount = p.files
        dirCount = p.dirs
        if p.cancelled { phase = .idle; return }
        phase = .finishing
        Task.detached(priority: .userInitiated) {
            let snap = s.snapshot(minSize: 0, maxNodes: 8_000_000, namesCap: 96 << 20)
            let st = TreeStore()
            st.build(from: snap, isFull: true)
            let bigs = s.bigFiles()
            let v = s.verify()
            let root = s.root
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.adopt(store: st, bigFiles: bigs, verifyBad: v.bad,
                           files: p.files, dirs: p.dirs, alloc: p.alloc, errors: p.errors,
                           elapsed: p.elapsed, root: root,
                           label: root == NSHomeDirectory() ? "~" : (root as NSString).lastPathComponent)
            }
        }
    }

    /// Принять готовый результат обхода (используется и из finishScan, и из режима --render).
    func adopt(store: TreeStore, bigFiles: [BigFile], verifyBad: UInt64, files: UInt64, dirs: UInt64,
               alloc: UInt64, errors: UInt64, elapsed: Double, root: String, label: String) {
        self.store = store
        self.storeIsPartial = false
        self.bigFiles = bigFiles
        self.verifyBad = verifyBad
        self.verifyNodes = UInt64(store.count)
        self.fileCount = files
        self.dirCount = dirs
        self.scanDuration = elapsed
        self.rootPath = root
        self.rootLabel = label
        self.scanProgress = ScanProgress(files: files, dirs: dirs, alloc: alloc,
                                         errors: errors, elapsed: elapsed, running: false)
        var denied: UInt64 = 0
        for i in 0..<store.count where store.denied[i] != 0 { denied += 1 }
        self.deniedCount = denied
        self.focus = store.resolve(self.focusChain)
        self.phase = .ready
        self.updateFreeSpace()
    }

    func updateFreeSpace() {
        let url = URL(fileURLWithPath: rootPath)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let c = v.volumeAvailableCapacityForImportantUsage {
            freeSpace = UInt64(c)
        }
    }

    // MARK: - Навигация

    func drill(_ node: Int32) {
        guard node >= 0, Int(node) < store.count, node != focus else { return }
        focusChain = store.chain(node)
        focus = node
    }

    func goUp() {
        guard !focusChain.isEmpty else { return }
        focusChain = Array(focusChain.dropLast())
        focus = store.resolve(focusChain)
    }

    func jump(to depth: Int) {                      // клик по крошке: 0 — корень обхода
        guard depth <= focusChain.count else { return }
        focusChain = Array(focusChain.prefix(depth))
        focus = store.resolve(focusChain)
    }

    func revealNode(_ node: Int32) {
        guard node >= 0, Int(node) < store.count else { revealPath(rootPath); return }
        revealPath(store.path(node, rootPath: rootPath))
    }

    func revealFocused() { revealNode(focus) }

    func revealPath(_ p: String) {
        let url = URL(fileURLWithPath: p)
        if FileManager.default.fileExists(atPath: p) || !p.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copyPath(_ node: Int32) {
        let p = (node >= 0 && Int(node) < store.count) ? store.path(node, rootPath: rootPath) : rootPath
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(p, forType: .string)
    }

    func path(of node: Int32) -> String {
        guard node >= 0, Int(node) < store.count else { return rootPath }
        return store.path(node, rootPath: rootPath)
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath)
        panel.message = "Выберите каталог для обхода"
        panel.prompt = "Сканировать"
        if panel.runModal() == .OK, let url = panel.url {
            startScan(path: url.path, label: url.lastPathComponent)
        }
    }

    func scanHome() { startScan(path: NSHomeDirectory(), label: "~") }
    func scanDataVolume() { startScan(path: "/System/Volumes/Data", label: "Данные тома") }

    // MARK: - Данные для интерфейса

    var focusName: String {
        if focus == 0 || store.isEmpty { return rootLabel }
        guard Int(focus) < store.count else { return rootLabel }
        let n = store.name(focus)
        return n.isEmpty ? rootLabel : n
    }

    var focusSize: UInt64 { (!store.isEmpty && Int(focus) < store.count) ? store.size[Int(focus)] : 0 }

    var focusShareOfParent: Double { store.parentShare(focus) }

    /// Топ детей текущего каталога (по убыванию размера).
    func topChildren(limit: Int = 24) -> [(node: Int32, size: UInt64, hue: Double)] {
        guard !store.isEmpty, Int(focus) < store.count else { return [] }
        var out: [(Int32, UInt64, Double)] = []
        for (i, c) in store.children(focus).enumerated() {
            if i >= limit { break }
            out.append((c, store.size[Int(c)], (0.56 + Double(i) * 0.137).truncatingRemainder(dividingBy: 1.0)))
        }
        return out.map { (node: $0.0, size: $0.1, hue: $0.2) }
    }

    var bigFilesTotal: UInt64 { bigFiles.reduce(0) { $0 &+ $1.size } }

    var statusLine: String {
        switch phase {
        case .idle:
            return store.isEmpty ? "Готово к обходу" : "Обход отменён"
        case .scanning:
            return "Обход: \(humanCount(scanProgress.objects)) объектов · \(humanBytes(scanProgress.alloc)) · \(humanDuration(scanProgress.elapsed))"
        case .finishing:
            return "Собираю дерево…"
        case .ready:
            return "Просканировано \(humanCount(fileCount)) файлов и \(humanCount(dirCount)) каталогов за \(humanDuration(scanDuration)) · инвариант дерева: \(verifyBad == 0 ? "держится" : "нарушен (\(verifyBad))")"
        case .failed(let m):
            return "Ошибка: \(m)"
        }
    }
}
