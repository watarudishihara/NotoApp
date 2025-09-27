//
//  PaperBackground.swift
//  Noto
//
//  Created by Wataru Ishihara on 9/14/25.
//

import SwiftUI

enum PaperStyle: String, CaseIterable, Identifiable, Codable {
    case plain, lined, dotted, grid
    var id: String { rawValue }
}

struct PaperBackground: View {
    var style: PaperStyle
    var lineColorLight = Color.black.opacity(0.08)
    var lineColorDark  = Color.white.opacity(0.10)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color(UIColor.systemBackground)   // the page base

                switch style {
                case .plain:
                    EmptyView()

                case .lined:
                    LinedPaper(size: size)

                case .dotted:
                    DotGridPaper(size: size)

                case .grid:
                    SquareGridPaper(size: size)
                }
            }
        }
        .clipped()
    }

    // MARK: Variants
    private func strokeColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? lineColorDark : lineColorLight
    }

    private struct LinedPaper: View {
        var size: CGSize
        @Environment(\.colorScheme) private var scheme
        // Tunables:
        var spacing: CGFloat = 28           // distance between rules
        var topPadding: CGFloat = 32        // header space

        var body: some View {
            Canvas { ctx, s in
                let color = (scheme == .dark ? Color.white.opacity(0.12)
                                             : Color.black.opacity(0.10))
                // horizontal rules
                var y: CGFloat = topPadding
                while y < s.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: s.width, y: y))
                    ctx.stroke(path, with: .color(color), lineWidth: 0.6)
                    y += spacing
                }
            }
        }
    }

    private struct DotGridPaper: View {
        var size: CGSize
        @Environment(\.colorScheme) private var scheme
        // Tunables:
        var spacing: CGFloat = 24
        var radius: CGFloat = 0.9
        var inset: CGFloat = 20
        var body: some View {
            Canvas { ctx, s in
                let color = (scheme == .dark ? Color.white.opacity(0.20)
                                             : Color.black.opacity(0.18))
                let cols = Int((s.width  - inset * 2) / spacing)
                let rows = Int((s.height - inset * 2) / spacing)
                for r in 0...rows {
                    for c in 0...cols {
                        let x = inset + CGFloat(c) * spacing
                        let y = inset + CGFloat(r) * spacing
                        let rect = CGRect(x: x - radius, y: y - radius,
                                          width: radius * 2, height: radius * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
            }
        }
    }

    private struct SquareGridPaper: View {
        var size: CGSize
        @Environment(\.colorScheme) private var scheme
        // Tunables:
        var spacing: CGFloat = 24
        var body: some View {
            Canvas { ctx, s in
                let color = (scheme == .dark ? Color.white.opacity(0.10)
                                             : Color.black.opacity(0.10))
                // verticals
                var x: CGFloat = 0
                while x <= s.width {
                    var p = Path(); p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: s.height))
                    ctx.stroke(p, with: .color(color), lineWidth: 0.5)
                    x += spacing
                }
                // horizontals
                var y: CGFloat = 0
                while y <= s.height {
                    var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: s.width, y: y))
                    ctx.stroke(p, with: .color(color), lineWidth: 0.5)
                    y += spacing
                }
            }
        }
    }
}
