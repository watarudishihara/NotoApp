import CoreGraphics
import UIKit

enum PreviewStock { case usLetter, a4 }

enum PreviewSpec {
    static var stock: PreviewStock = .usLetter  // switch to .a4 if you want

    static var pageSize: CGSize {
        switch stock {
        case .usLetter: return .init(width: 8.5 * 72,  height: 11.0 * 72)  // 612x792
        case .a4:       return .init(width: 8.27 * 72, height: 11.69 * 72) // 595x842
        }
    }

    // preview margins (points). tweak to taste
    static let margin = UIEdgeInsets(top: 54, left: 54, bottom: 54, right: 54)

    static var pageRect: CGRect { .init(origin: .zero, size: pageSize) }
    static var contentRect: CGRect { pageRect.inset(by: margin) }

    // WKWebView uses CSS px ~ iOS pt
    static var contentCSSWidth: Int { Int(contentRect.width.rounded()) }
}
