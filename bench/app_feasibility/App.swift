// Проверка: собирается и запускается ли нативный SwiftUI-апп одним swiftc из CommandLineTools
// (без Xcode.app), и работает ли ад-хок подпись. Запуск с --selftest: окно рисуется и сразу закрывается.
import SwiftUI
import AppKit

@main
struct FeasibilityApp: App {
    var body: some Scene {
        WindowGroup("Romashka self-test") {
            VStack {
                Text("SwiftUI ok")
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    for i in 0..<40 {
                        var p = Path()
                        p.move(to: c)
                        p.addArc(center: c, radius: 90, startAngle: .degrees(Double(i) * 9),
                                 endAngle: .degrees(Double(i) * 9 + 7), clockwise: false)
                        ctx.stroke(p, with: .color(.accentColor), lineWidth: 14)
                    }
                }
                .frame(width: 200, height: 200)
            }
            .onAppear {
                guard CommandLine.arguments.contains("--selftest") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    print("SELFTEST_OK window=\(NSApp.windows.count) canvas_paths=40")
                    exit(0)
                }
            }
        }
    }
}
