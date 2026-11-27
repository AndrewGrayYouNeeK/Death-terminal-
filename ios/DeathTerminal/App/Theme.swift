import SwiftUI
import UIKit

/// Death Terminal colours: near-black background, skull-green accent.
enum Theme {
    static let green = Color(red: 0.094, green: 0.812, blue: 0.490)        // #18CF7D
    static let greenDim = Color(red: 0.094, green: 0.812, blue: 0.490).opacity(0.6)
    static let background = Color(red: 0.035, green: 0.059, blue: 0.047)   // #090F0C
    static let panel = Color(red: 0.047, green: 0.106, blue: 0.086)        // #0C1B16
    static let text = Color(red: 0.878, green: 0.878, blue: 0.878)         // #E0E0E0
    static let danger = Color(red: 1.0, green: 0.0, blue: 0.2)             // #FF0033

    static let uiGreen = UIColor(red: 0.094, green: 0.812, blue: 0.490, alpha: 1)
    static let uiBackground = UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1)
    static let uiText = UIColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1)

    static func mono(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct DTBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

extension View {
    func dtBackground() -> some View { modifier(DTBackground()) }
}
