// main.swift — точка входа: обычное окно, self-test движка и оффскрин-рендер интерфейса.
import SwiftUI
import AppKit

struct RomashkaScene: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Ромашка") {
            RootView(state: state)
        }
        .defaultSize(width: 1340, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Ромашка") {
                Button("Обновить обход") { state.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.phase == .scanning)
                Button("Наверх") { state.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Показать в Finder") { state.revealFocused() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Домашний каталог") { state.scanHome() }
                Button("Данные тома") { state.scanDataVolume() }
                Button("Выбрать папку…") { state.chooseFolderAndScan() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run(args) }
            exit(SelfTest.exitCode)
        }
        if let i = args.firstIndex(of: "--render") {
            MainActor.assumeIsolated { RenderMode.run(args, outIndex: i) }
            exit(RenderMode.exitCode)
        }
        RomashkaScene.main()
    }
}

// MARK: - Self-test: проверка движка без интерфейса

enum SelfTest {
    nonisolated(unsafe) static var exitCode: Int32 = 0

    @MainActor
    static func run(_ args: [String]) {
        var path = NSHomeDirectory()
        var jobs: Int32 = 4
        var bigMin: UInt64 = 200 << 20
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--selftest":
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { path = args[i + 1]; i += 1 }
            case "--jobs":
                if i + 1 < args.count, let v = Int32(args[i + 1]) { jobs = v; i += 1 }
            case "--big-mb":
                if i + 1 < args.count, let v = UInt64(args[i + 1]) { bigMin = v << 20; i += 1 }
            default: break
            }
            i += 1
        }
        FileHandle.standardError.write("обход \(path) на \(jobs) потоках…\n".data(using: .utf8)!)
        guard let scan = Scan(root: path, jobs: jobs, bigFileMin: bigMin,
                              exclusions: AppState.exclusions(for: path)) else {
            FileHandle.standardError.write("не удалось создать обход\n".data(using: .utf8)!)
            exitCode = 2
            return
        }
        let t0 = Date()
        scan.start()
        if let e = scan.errorMessage {
            FileHandle.standardError.write("ошибка: \(e)\n".data(using: .utf8)!)
            exitCode = 2
            return
        }
        var lastPrint = Date()
        while scan.isRunning {
            usleep(300_000)
            if Date().timeIntervalSince(lastPrint) > 3 {
                lastPrint = Date()
                let p = scan.progress
                FileHandle.standardError.write("  … \(humanCount(p.files + p.dirs)) объектов, \(humanBytes(p.alloc)), \(humanDuration(p.elapsed))\n".data(using: .utf8)!)
            }
        }
        scan.wait()
        let p = scan.progress
        let wall = Date().timeIntervalSince(t0)

        print("roots=1 jobs=\(jobs) engine_elapsed=\(String(format: "%.2f", p.elapsed))s wall=\(String(format: "%.2f", wall))s")
        print("files=\(p.files) dirs=\(p.dirs) objects=\(p.files + p.dirs) rate=\(Int(Double(p.files + p.dirs) / max(p.elapsed, 0.001))) obj/s errors=\(p.errors) hardlinks_dedup=\(p.hardlinks)")
        print("allocated=\(p.alloc) (\(humanBytes(p.alloc))) logical=\(p.logical) (\(humanBytes(p.logical)))")

        let snap = scan.snapshot(minSize: 0, maxNodes: 8_000_000, namesCap: 96 << 20)
        let store = TreeStore()
        store.build(from: snap, isFull: true)
        let v = scan.verify()
        print("invariant size==own+sum(children): violations=\(v.bad) nodes=\(store.count)\(v.bad == 0 ? "" : " first: \(v.first)")")

        var denied: UInt64 = 0
        for i in 0..<store.count where store.denied[i] != 0 { denied += 1 }
        print("denied_dirs=\(denied)")

        // топ каталогов
        var idx: [Int32] = []
        for i in 1..<store.count where store.depth[i] >= 1 && store.depth[i] <= 6 { idx.append(Int32(i)) }
        idx.sort { store.size[Int($0)] > store.size[Int($1)] }
        print("--- топ каталогов (>= 2 ГБ, глубина 1..6):")
        var printed = 0
        for i in idx where store.size[Int(i)] >= (2 << 30) && printed < 15 {
            print(String(format: "%10@  d%-2d  %@", humanBytes(store.size[Int(i)]), store.depth[Int(i)],
                         store.path(i, rootPath: path)))
            printed += 1
        }

        let bigs = scan.bigFiles()
        print("--- крупных файлов (>= \(humanBytes(bigMin))): \(bigs.count), сумма \(humanBytes(bigs.reduce(0) { $0 &+ $1.size }))")
        for f in bigs.prefix(10) { print(String(format: "%10@  %@", humanBytes(f.size), f.path)) }

        // цена клика: раскладка колец для выбранного узла (то, что делается на каждый провал)
        if store.count > 1 {
            var byKids: [Int32] = []
            for i in 0..<store.count where store.children(Int32(i)).count > 1 { byKids.append(Int32(i)) }
            byKids.sort { store.children($0).count > store.children($1).count }
            let sample = Array(byKids.prefix(20))
            let t = Date()
            var ops = 0
            for n in sample {
                _ = makeLayout(store: store, focus: n, ringCount: 3, maxPerRing: 64,
                               cx: 600, cy: 400, rOut: 380, rCenter: 110)
                ops += 1
            }
            let ms = Date().timeIntervalSince(t) * 1000 / Double(max(ops, 1))
            let maxKids = sample.first.map { store.children($0).count } ?? 0
            print(String(format: "layout_ms_per_drill=%.2f (худший узел: %d детей, выборка %d)",
                         ms, maxKids, ops))
        }
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        print("peak_rss_mb=\(ru.ru_maxrss / 1024 / 1024)")
        exitCode = v.bad == 0 ? 0 : 1
    }
}

// MARK: - Оффскрин-рендер интерфейса в PNG (для проверки внешнего вида без скриншотов экрана)

enum RenderMode {
    nonisolated(unsafe) static var exitCode: Int32 = 0

    @MainActor
    static func run(_ args: [String], outIndex: Int) {
        guard outIndex + 1 < args.count else {
            FileHandle.standardError.write("--render требует путь к PNG\n".data(using: .utf8)!)
            exitCode = 2
            return
        }
        let out = args[outIndex + 1]
        var path = NSHomeDirectory() + "/Library"
        var focus: [String] = []
        var width: CGFloat = 1340, height: CGFloat = 860
        var liveSeconds: Double = 0
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--live": if i + 1 < args.count, let v = Double(args[i + 1]) { liveSeconds = v; i += 1 }
            case "--path": if i + 1 < args.count { path = args[i + 1]; i += 1 }
            case "--focus": if i + 1 < args.count { focus = args[i + 1].split(separator: "/").map(String.init); i += 1 }
            case "--size":
                if i + 1 < args.count {
                    let parts = args[i + 1].split(separator: "x")
                    if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                        width = CGFloat(w); height = CGFloat(h)
                    }
                    i += 1
                }
            default: break
            }
            i += 1
        }
        _ = NSApplication.shared                       // инициализируем AppKit: нужны шрифты и цвета

        if liveSeconds > 0 {                            // проверка живого режима: ромашка во время обхода
            let state = AppState()
            state.startScan(path: path)
            let deadline = Date().addingTimeInterval(liveSeconds)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if state.phase == .ready { break }        // обход завершился — дальше обычная готовность
            }
            let store = state.store
            FileHandle.standardError.write("живой снимок: узлов=\(store.count), объектов=\(state.scanProgress.objects), фокус=\(state.focusName)\n".data(using: .utf8)!)
            let view = RootView(state: state).frame(width: width, height: height)
            writePNG(view, to: out)
            return
        }

        FileHandle.standardError.write("обход \(path)…\n".data(using: .utf8)!)
        guard let scan = Scan(root: path, jobs: 6, bigFileMin: 200 << 20,
                              exclusions: AppState.exclusions(for: path)) else {
            FileHandle.standardError.write("не удалось создать обход\n".data(using: .utf8)!)
            exitCode = 2
            return
        }
        scan.start()
        scan.wait()
        let p = scan.progress
        let snap = scan.snapshot(minSize: 0, maxNodes: 8_000_000, namesCap: 96 << 20)
        let store = TreeStore()
        store.build(from: snap, isFull: true)
        let v = scan.verify()
        FileHandle.standardError.write("готово: \(store.count) узлов, \(humanBytes(p.alloc)), \(humanDuration(p.elapsed))\n".data(using: .utf8)!)

        let state = AppState()
        state.adopt(store: store, bigFiles: scan.bigFiles(), verifyBad: v.bad,
                    files: p.files, dirs: p.dirs, alloc: p.alloc, errors: p.errors,
                    elapsed: p.elapsed, root: path, label: (path as NSString).lastPathComponent)
        state.focusChain = focus
        state.focus = store.resolve(focus)
        let kids = state.topChildren(limit: 6)
        FileHandle.standardError.write("диагностика: детей у фокуса=\(store.children(state.focus).count), строк=\(kids.count), первые=\(kids.map { store.name($0.node) }), крупных файлов=\(state.bigFiles.count)\n".data(using: .utf8)!)

        writePNG(RootView(state: state).frame(width: width, height: height), to: out)
        if exitCode == 0 { print("saved \(out) \(Int(width))x\(Int(height)) focus=\(state.path(of: state.focus))") }
    }

    @MainActor
    static func writePNG<V: View>(_ view: V, to out: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("не удалось отрисовать\n".data(using: .utf8)!)
            exitCode = 3
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: out))
            print("saved \(out)")
        } catch {
            FileHandle.standardError.write("не записалось: \(error)\n".data(using: .utf8)!)
            exitCode = 3
        }
    }
}
