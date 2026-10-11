import SwiftUI
import AppKit

/// Winnow's look: one green, plus a wheat gold used sparingly (Claude / kept clips).
enum Brand {
    static let name = "Winnow"

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        func c(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                    blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        return NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light)
        }
    }

    static let greenNS = dynamic(light: 0x3c8c40, dark: 0x5aae5e)
    static let goldNS = dynamic(light: 0xc99a2e, dark: 0xd4a537)
    static let green = Color(nsColor: greenNS)
    static let gold = Color(nsColor: goldNS)
}
