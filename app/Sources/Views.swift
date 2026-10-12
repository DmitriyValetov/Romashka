// Views.swift — экран приложения: панель, ромашка, боковой список, статус.
import SwiftUI
import AppKit

/// Оффскрин-рендер не наполняет ScrollView — для проверки внешнего вида
/// списки рисуются плоским стеком (в самом приложении они скроллятся).
enum RenderFlags {
    static let flat = CommandLine.arguments.contains("--render")
}

struct SegButtons<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var value: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                Button {
                    value = opt.1
                } label: {
                    Text(opt.0)
                        .font(.system(size: 11, weight: value == opt.1 ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(value == opt.1 ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.14))
                        .foregroundStyle(value == opt.1 ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct RootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TopBar(state: state)
            Divider()
            HStack(spacing: 0) {
                SunburstPane(state: state)
                Divider()
                Sidebar(state: state).frame(width: 350)
            }
            Divider()
            StatusBar(state: state)
        }
        .frame(minWidth: 980, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Верхняя панель

struct TopBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text("Ромашка").font(.system(size: 15, weight: .bold))
            Text(state.rootPath)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let free = state.freeSpace {
                Text("свободно \(humanBytes(free))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            SegButtons(options: [("2", 2), ("3", 3), ("4", 4)], value: $state.ringCount)
                .frame(width: 84)
                .help("Сколько колец показывать")
            Button("Дом") { state.scanHome() }
            Button("Данные тома") { state.scanDataVolume() }
            Button("Папка…") { state.chooseFolderAndScan() }
            Button {
                state.rescan()
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.phase == .scanning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Ромашка

struct SunburstPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            ZStack {
                if state.store.isEmpty {
                    emptyState
                } else {
                    SunburstView(state: state)
                    if state.phase == .scanning || state.phase == .finishing {
                        VStack {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                                Text("идёт обход: \(humanCount(state.scanProgress.objects)) объектов")
                                    .font(.system(size: 11))
                                Spacer()
                                Text("\(Int(state.scanProgress.rate / 1000)) тыс. об/с")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                            .padding(10)
                            Spacer()
                        }
                    }
                }
            }
            if state.deniedCount > 0 {
                permissionBanner
            }
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 6) {
            Button {
                state.jump(to: 0)
            } label: {
                Text(state.rootLabel).font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            ForEach(Array(state.focusChain.enumerated()), id: \.offset) { idx, part in
                Text("›").foregroundStyle(.tertiary).font(.system(size: 11))
                Button {
                    state.jump(to: idx + 1)
                } label: {
                    Text(part)
                        .font(.system(size: 12, weight: idx == state.focusChain.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == state.focusChain.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !state.focusChain.isEmpty {
                Button {
                    state.goUp()
                } label: {
                    Label("наверх", systemImage: "arrow.up.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.upArrow, modifiers: .command)
            }
            Button {
                state.revealFocused()
            } label: {
                Label("показать в Finder", systemImage: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Открыть текущий каталог в Finder (удаление — уже там, вручную)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
            Text("\(humanCount(state.deniedCount)) каталогов закрыто системой — их размеры не видны")
                .font(.system(size: 11))
            Spacer()
            Button("Открыть настройки доступа") { state.openFullDiskAccessSettings() }
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text("Выберите, что обойти").font(.system(size: 15, weight: .semibold))
            Text("Обход домашнего каталога занимает около 20 секунд и показывает, где лежит объём.\nПриложение ничего не удаляет.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Домашний каталог") { state.scanHome() }.buttonStyle(.borderedProminent)
                Button("Данные тома") { state.scanDataVolume() }
                Button("Выбрать папку…") { state.chooseFolderAndScan() }
            }
            if case .failed(let m) = state.phase {
                Text(m).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
        .padding(30)
    }
}

// MARK: - Боковой список

struct Sidebar: View {
    @ObservedObject var state: AppState
    @State private var mode = RenderFlags.flat && CommandLine.arguments.contains("--files") ? 1 : 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SegButtons(options: [("Каталоги", 0), ("Крупные файлы", 1)], value: $mode)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            if mode == 0 { childrenList } else { bigFilesList }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.focusName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Text(state.path(of: state.focus))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Text(humanBytes(state.focusSize)).font(.system(size: 12, weight: .semibold))
                if state.focus != 0 {
                    Text("\(String(format: "%.1f", state.focusShareOfParent * 100)) % родителя")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if state.store.own.count > Int(state.focus), state.focus >= 0 {
                    Text("· своих файлов \(humanBytes(state.store.own[Int(state.focus)]))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var childrenList: some View {
        let rows = state.topChildren(limit: RenderFlags.flat ? 12 : 30)
        return Group {
            if RenderFlags.flat {
                VStack(alignment: .leading, spacing: 0) { childRows(rows) }
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 0) { childRows(rows) } }
            }
        }
    }

    @ViewBuilder
    private func childRows(_ rows: [(node: Int32, size: UInt64, hue: Double)]) -> some View {
        Group {
                if rows.isEmpty {
                    Text("Нет данных").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                }
                ForEach(rows, id: \.node) { row in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(sunColor(hue: row.hue, depth: 1))
                            .frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.store.name(row.node))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text(shareText(row.size, state.focusSize))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(humanBytes(row.size)).font(.system(size: 11)).monospacedDigit()
                        Button {
                            state.revealNode(row.node)
                        } label: {
                            Image(systemName: "folder").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("Показать в Finder")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { state.drill(row.node) }
                    .contextMenu {
                        Button("Провалиться") { state.drill(row.node) }
                        Button("Показать в Finder") { state.revealNode(row.node) }
                        Button("Скопировать путь") { state.copyPath(row.node) }
                    }
                    Divider().opacity(0.25)
                }
        }
    }

    private var bigFilesList: some View {
        Group {
            if RenderFlags.flat {
                VStack(alignment: .leading, spacing: 0) { bigRows }
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 0) { bigRows } }
            }
        }
    }

    @ViewBuilder
    private var bigRows: some View {
        Group {
                if state.bigFiles.isEmpty {
                    Text(state.phase == .ready
                         ? "Файлов ≥ \(humanBytes(state.bigFileMin)) не найдено"
                         : "Список появится после обхода")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                } else {
                    Text("\(state.bigFiles.count) файлов ≥ \(humanBytes(state.bigFileMin)) · всего \(humanBytes(state.bigFilesTotal))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.bottom, 6)
                }
                ForEach(state.bigFiles.prefix(RenderFlags.flat ? 8 : 400)) { f in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((f.path as NSString).lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text((f.path as NSString).deletingLastPathComponent)
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(humanBytes(f.size)).font(.system(size: 11)).monospacedDigit()
                        Button {
                            state.revealPath(f.path)
                        } label: {
                            Image(systemName: "folder").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("Показать в Finder — удалять там же, вручную")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .contextMenu {
                        Button("Показать в Finder") { state.revealPath(f.path) }
                        Button("Скопировать путь") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(f.path, forType: .string)
                        }
                    }
                    Divider().opacity(0.25)
                }
        }
    }
}

// MARK: - Строка состояния

struct StatusBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            switch state.phase {
            case .scanning:
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                Text(state.statusLine).font(.system(size: 11))
                Spacer()
                Button("Отменить") { state.cancelScan() }.font(.system(size: 11))
            case .finishing:
                Image(systemName: "hourglass").font(.system(size: 11))
                Text(state.statusLine).font(.system(size: 11))
                Spacer()
            case .ready:
                Image(systemName: state.verifyBad == 0 ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(state.verifyBad == 0 ? .green : .orange)
                Text(state.statusLine).font(.system(size: 11))
                Spacer()
                if state.storeIsPartial { Text("частичные данные").font(.system(size: 11)).foregroundStyle(.secondary) }
                Text("\(humanCount(state.scanProgress.errors)) отказов доступа")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .idle, .failed:
                Text(state.statusLine).font(.system(size: 11))
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
