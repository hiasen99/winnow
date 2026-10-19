import Foundation
import AppKit
import CoreText

/// The fonts installed on this Mac, grouped by family, plus the weight axis of variable fonts.
enum FontCatalog {
    /// One installed style of a family (Regular, Bold, Black, Bold Italic…).
    struct Member: Hashable {
        let postScript: String
        let style: String
        let weight: Int        // NSFontManager scale: 5 = regular, 9 = bold, 11+ = black
        let italic: Bool
    }

    /// 'wght' as an OpenType axis tag.
    static let wghtTag = 0x77676874

    /// Families shown first in the caption font menu (when installed).
    static let suggested = ["Avenir Next", "Futura", "Helvetica Neue", "Arial", "Impact", "Gill Sans",
                            "Montserrat", "Poppins", "Noto Sans", "Inter", "Menlo", "Georgia"]

    @MainActor private static var familyCache: [String]? = nil
    @MainActor static var families: [String] {
        if let f = familyCache { return f }
        let f = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        familyCache = f
        return f
    }

    @MainActor
    static func members(_ family: String) -> [Member] {
        let raw = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let ms: [Member] = raw.compactMap { a in
            guard a.count >= 2, let ps = a[0] as? String else { return nil }
            let style = (a[1] as? String) ?? ps
            let w = (a.count > 2 ? (a[2] as? NSNumber)?.intValue : nil) ?? 5
            let t = (a.count > 3 ? (a[3] as? NSNumber)?.uintValue : nil) ?? 0
            return Member(postScript: ps, style: style, weight: w,
                          italic: NSFontTraitMask(rawValue: t).contains(.italicFontMask))
        }
        // upright first, then italics; light → heavy inside each (stable for equal weights)
        return ms.enumerated().sorted { x, y in
            let (a, b) = (x.element, y.element)
            if a.italic != b.italic { return !a.italic }
            if a.weight != b.weight { return a.weight < b.weight }
            return x.offset < y.offset
        }.map { $0.element }
    }

    /// The family of a font name (PostScript or family name), e.g. "noto sans" → "Noto Sans".
    @MainActor
    static func family(of name: String) -> String? {
        if let f = NSFont(name: name, size: 12)?.familyName { return f }
        let lower = name.lowercased()
        return NSFontManager.shared.availableFontFamilies.first { $0.lowercased() == lower }
    }

    /// The PostScript name a stored font name resolves to ("noto sans" → "NotoSans-Regular").
    static func postScript(of name: String) -> String {
        NSFont(name: name, size: 12)?.fontName ?? name
    }

    @MainActor
    static func member(_ name: String) -> Member? {
        guard let fam = family(of: name) else { return nil }
        let ps = postScript(of: name)
        return members(fam).first { $0.postScript == ps }
    }

    /// The style in `family` closest to the font in use now (keeps bold bold and italic italic).
    @MainActor
    static func closestMember(in family: String, to current: String) -> Member? {
        let ms = members(family)
        guard !ms.isEmpty else { return nil }
        let cur = NSFont(name: current, size: 12)
        let tw = cur.map { NSFontManager.shared.weight(of: $0) } ?? 5
        let ti = cur.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
        return ms.min { a, b in
            (abs(a.weight - tw) * 2 + (a.italic != ti ? 20 : 0)) < (abs(b.weight - tw) * 2 + (b.italic != ti ? 20 : 0))
        }
    }

    /// The weight axis of a variable font, or nil for a font with fixed weights.
    static func weightAxis(_ name: String) -> (min: Double, max: Double, def: Double)? {
        guard let f = NSFont(name: name, size: 12),
              let axes = CTFontCopyVariationAxes(f as CTFont) as? [[String: Any]] else { return nil }
        for ax in axes {
            guard let id = (ax[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.intValue, id == wghtTag,
                  let lo = (ax[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                  let hi = (ax[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue, hi > lo else { continue }
            let def = (ax[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? lo
            return (lo, hi, def)
        }
        return nil
    }

    /// The weight a variable font draws at before any change (its named style's value, else the axis default).
    static func baseWeight(_ name: String) -> Double? {
        guard let ax = weightAxis(name) else { return nil }
        if let f = NSFont(name: name, size: 12),
           let v = CTFontCopyVariation(f as CTFont) as? [NSNumber: NSNumber],
           let w = v[NSNumber(value: wghtTag)] { return w.doubleValue }
        return ax.def
    }

    /// The caption font: the stored font, drawn at `weight` on its weight axis if it has one.
    static func font(_ name: String, size: CGFloat, weight: Double?) -> NSFont? {
        guard let f = NSFont(name: name, size: size) else { return nil }
        guard let w = weight, let ax = weightAxis(name) else { return f }
        let v = min(ax.max, max(ax.min, w))
        let d = f.fontDescriptor.addingAttributes([.variation: [NSNumber(value: wghtTag): NSNumber(value: v)]])
        return NSFont(descriptor: d, size: size) ?? f
    }

    /// A CSS-style weight (100 thin … 400 regular … 700 bold … 900 black) on NSFontManager's scale.
    static func managerWeight(css: Double) -> Int {
        let table: [(Double, Int)] = [(100, 2), (200, 3), (300, 4), (400, 5), (500, 6), (600, 8), (700, 9), (800, 10), (900, 11), (1000, 12)]
        return table.min { abs($0.0 - css) < abs($1.0 - css) }!.1
    }

    /// Weight words → CSS weight.
    static let cssWords: [String: Double] = [
        "thin": 100, "hairline": 100, "extralight": 200, "ultralight": 200, "light": 300,
        "regular": 400, "normal": 400, "book": 400, "roman": 400, "medium": 500,
        "semibold": 600, "demibold": 600, "bold": 700, "extrabold": 800, "ultrabold": 800,
        "heavy": 900, "black": 900, "extrablack": 1000, "ultrablack": 1000,
    ]

    /// A readable number for a weight-axis value (900, or 2.10 for fonts with a small scale like Skia).
    static func weightText(_ v: Double, axisMax: Double) -> String {
        axisMax > 20 ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }
}
