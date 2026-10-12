// Sunburst.swift — раскладка колец, попадание курсора и отрисовка ромашки.
import SwiftUI

struct SunSegment: Identifiable {
    let id: Int
    var node: Int32            // индекс узла, -1 если это агрегат «прочее»
    var rest: Bool
    var depth: Int
    var a0: Double             // радианы: 0 = 3 часа, растут по часовой стрелке
    var a1: Double
    var rIn: Double
    var rOut: Double
    var size: UInt64
    var hue: Double
    var label: String?
    var labelShare: Double
}

struct SunLayout {
    var segments: [SunSegment] = []
    var focus: Int32 = 0
    var focusSize: UInt64 = 0
    var focusName: String = ""
    var isEmpty: Bool { segments.isEmpty }
}

func sunColor(hue: Double, depth: Int, dim: Bool = false) -> Color {
    let s = min(0.36 + 0.10 * Double(depth), 0.92)
    let v = max(0.98 - 0.13 * Double(depth), 0.34)
    let c = Color(hue: hue.truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: dim ? v * 0.72 : v)
    return c
}

/// Раскладка колец вокруг текущего каталога.
/// maxPerRing — сколько детей рисуем отдельными сегментами (остальное уходит в «прочее»).
func makeLayout(store: TreeStore, focus: Int32, ringCount: Int,
                maxPerRing: Int, cx: Double, cy: Double,
                rOut: Double, rCenter: Double) -> SunLayout {
    var layout = SunLayout()
    guard !store.isEmpty, focus >= 0, Int(focus) < store.count else { return layout }
    layout.focus = focus
    layout.focusSize = store.size[Int(focus)]
    layout.focusName = store.name(focus)
    let ringW = (rOut - rCenter) / Double(max(1, ringCount))
    var uid = 0

    func walk(_ node: Int32, span: Double, rO: Double, a0: Double, a1: Double, depth: Int, hue: Double) {
        guard depth <= ringCount, span > 0 else { return }
        let kids = store.children(node)
        var items: [(Int32, UInt64)] = []
        var shown = 0
        var sumShown: UInt64 = 0
        for c in kids {
            let sz = store.size[Int(c)]
            if sz == 0 { continue }
            if shown < maxPerRing - 1 { items.append((c, sz)); sumShown &+= sz; shown += 1 }
        }
        let totalKids = store.childrenSum(node)
        let restSize = store.size[Int(node)] > sumShown ? store.size[Int(node)] - sumShown : 0
        if restSize > 0 && (kids.count > shown || totalKids < store.size[Int(node)]) {
            items.append((-1, restSize))
        }
        var a = a0
        for (i, item) in items.enumerated() {
            let (child, sz) = item
            let frac = Double(sz) / span
            let b = a + (a1 - a0) * frac
            if b - a < 0.0008 { a = b; continue }
            let rIn = max(rCenter, rO - ringW)
            let childHue = (hue + Double(i) * (depth == 1 ? 0.137 : 0.021)).truncatingRemainder(dividingBy: 1.0)
            var seg = SunSegment(id: uid, node: child, rest: child < 0, depth: depth,
                                 a0: a, a1: b, rIn: rIn, rOut: rO, size: sz, hue: childHue,
                                 label: nil, labelShare: frac)
            uid += 1
            if child >= 0, depth == 1 {
                let mid = (a + b) / 2
                let arcLen = (b - a) * ((rIn + rO) / 2)
                if frac >= 0.045 && arcLen > 44 {
                    seg.label = store.name(child)
                }
            }
            layout.segments.append(seg)
            if child >= 0 {
                if depth < ringCount {
                    walk(child, span: Double(sz), rO: rIn, a0: a, a1: b, depth: depth + 1, hue: childHue)
                }
            } else {
                // у агрегата «прочее» детей нет — добиваем внутренние кольца тем же сектором,
                // иначе в ромашке остаётся дырка до самого центра
                var r = rIn
                var d = depth
                while d < ringCount {
                    let ri = max(rCenter, r - ringW)
                    layout.segments.append(SunSegment(id: uid, node: -1, rest: true, depth: d + 1,
                                                      a0: a, a1: b, rIn: ri, rOut: r,
                                                      size: 0, hue: 0, label: nil, labelShare: 0))
                    uid += 1
                    r = ri
                    d += 1
                }
            }
            a = b
        }
    }

    walk(focus, span: Double(layout.focusSize), rO: rOut, a0: 0, a1: 2 * .pi, depth: 1, hue: 0.56)
    return layout
}

/// Сегмент под точкой (nil — попали в центр или мимо).
func hitTest(_ layout: SunLayout, _ point: CGPoint, cx: Double, cy: Double, rCenter: Double) -> SunSegment? {
    let dx = Double(point.x) - cx
    let dy = Double(point.y) - cy
    let r = (dx * dx + dy * dy).squareRoot()
    if r < rCenter { return nil }
    var a = atan2(dy, dx)
    if a < 0 { a += 2 * .pi }
    for seg in layout.segments where r >= seg.rIn - 0.5 && r <= seg.rOut + 0.5 && a >= seg.a0 && a <= seg.a1 {
        return seg
    }
    return nil
}

/// Путь кольцевого сектора.
func arcPath(cx: Double, cy: Double, rIn: Double, rOut: Double, a0: Double, a1: Double) -> Path {
    var p = Path()
    let c = CGPoint(x: cx, y: cy)
    let sweep = min(a1 - a0, 2 * .pi - 0.0001)
    p.addArc(center: c, radius: rOut, startAngle: .radians(a0), endAngle: .radians(a0 + sweep), clockwise: false)
    p.addArc(center: c, radius: rIn, startAngle: .radians(a0 + sweep), endAngle: .radians(a0), clockwise: true)
    p.closeSubpath()
    return p
}

struct SunburstView: View {
    @ObservedObject var state: AppState
    @State private var hoverNode: Int32? = nil
    @State private var hoverPoint: CGPoint = .zero
    @State private var hoverSeg: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let rOut = max(80, side / 2 - 18)
            let rCenter = max(56, rOut * 0.30)
            let layout = makeLayout(store: state.store, focus: state.focus,
                                    ringCount: state.ringCount, maxPerRing: 64,
                                    cx: Double(cx), cy: Double(cy),
                                    rOut: Double(rOut), rCenter: Double(rCenter))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    draw(ctx: &ctx, layout: layout, cx: Double(cx), cy: Double(cy),
                         rCenter: Double(rCenter))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    guard let seg = hitTest(layout, v.location, cx: Double(cx), cy: Double(cy),
                                            rCenter: Double(rCenter)) else {
                        state.goUp()                       // клик в центр — наверх
                        return
                    }
                    if seg.rest { return }
                    state.drill(seg.node)
                })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hoverPoint = p
                        let seg = hitTest(layout, p, cx: Double(cx), cy: Double(cy), rCenter: Double(rCenter))
                        hoverSeg = seg?.id
                        hoverNode = (seg?.rest ?? true) ? nil : seg?.node
                    case .ended:
                        hoverSeg = nil
                        hoverNode = nil
                    }
                }
                .contextMenu {
                    let target = hoverNode ?? state.focus
                    Button("Показать в Finder") { state.revealNode(target) }
                    Button("Скопировать путь") { state.copyPath(target) }
                    Button("Сделать корнем вида") { state.drill(target) }
                    Divider()
                    Button("Пересканировать") { state.rescan() }
                }

                if let seg = layout.segments.first(where: { $0.id == hoverSeg }), !seg.rest {
                    tooltip(seg: seg, store: state.store, container: geo.size)
                }
            }
        }
    }

    private func tooltip(seg: SunSegment, store: TreeStore, container: CGSize) -> some View {
        let name = store.name(seg.node)
        let parent = seg.node >= 0 ? store.parentShare(seg.node) : 0
        let w: CGFloat = 300
        let x = min(max(hoverPoint.x + 16, 8), max(8, container.width - w - 8))
        let y = min(max(hoverPoint.y + 16, 8), max(8, container.height - 74))
        return VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text("\(humanBytes(seg.size)) · \(String(format: "%.1f", parent * 100)) % родителя")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: w, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.12)))
        .offset(x: x, y: y)
        .allowsHitTesting(false)
    }

    private func draw(ctx: inout GraphicsContext, layout: SunLayout, cx: Double, cy: Double, rCenter: Double) {
        // подсветка: сам сегмент и вся его ветка до центра
        var highlighted = Set<Int32>()
        if let h = hoverNode {
            var cur = h
            var guardCount = 0
            while cur >= 0 && Int(cur) < state.store.count && guardCount < 512 {
                highlighted.insert(cur)
                cur = state.store.parent[Int(cur)]
                guardCount += 1
            }
        }
        for seg in layout.segments {
            let path = arcPath(cx: cx, cy: cy, rIn: seg.rIn, rOut: seg.rOut, a0: seg.a0, a1: seg.a1)
            let isHot = !seg.rest && highlighted.contains(seg.node)
            let col = seg.rest
                ? Color(white: max(0.16, 0.30 - 0.05 * Double(seg.depth - 1)))
                : sunColor(hue: seg.hue, depth: seg.depth, dim: !highlighted.isEmpty && !isHot)
            ctx.fill(path, with: .color(col))
            if isHot {
                ctx.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
            }
        }
        // подписи первого кольца
        for seg in layout.segments {
            guard let label = seg.label else { continue }
            let mid = (seg.a0 + seg.a1) / 2
            let rr = (seg.rIn + seg.rOut) / 2
            let pt = CGPoint(x: cx + rr * cos(mid), y: cy + rr * sin(mid))
            let light = seg.depth >= 2
            let text = Text(label).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(light ? Color.white.opacity(0.92) : Color.black.opacity(0.80))
            ctx.draw(ctx.resolve(text), at: pt, anchor: .center)
        }
        // центр
        let circle = Path(ellipseIn: CGRect(x: cx - rCenter, y: cy - rCenter, width: rCenter * 2, height: rCenter * 2))
        ctx.fill(circle, with: .color(Color(white: 0.12)))
        ctx.stroke(circle, with: .color(.white.opacity(0.10)), lineWidth: 1)
        let name = state.focusName
        ctx.draw(ctx.resolve(Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)),
                 at: CGPoint(x: cx, y: cy - 26), anchor: .center)
        ctx.draw(ctx.resolve(Text(humanBytes(layout.focusSize)).font(.system(size: 19, weight: .bold))
            .foregroundStyle(Color(red: 0.37, green: 0.66, blue: 1.0))),
                 at: CGPoint(x: cx, y: cy + 2), anchor: .center)
        let sub = state.storeIsPartial ? "идёт обход…" : "на диске"
        ctx.draw(ctx.resolve(Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)),
                 at: CGPoint(x: cx, y: cy + 26), anchor: .center)
    }
}
