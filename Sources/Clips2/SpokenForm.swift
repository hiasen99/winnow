import Foundation

/// How a word written with digits or symbols is said out loud ("$50" → "fifty dollars"), so the
/// aligner can listen for the spoken words instead of treating the number as one blip of sound.
/// Several readings are offered ("1500" → "one thousand five hundred" / "fifteen hundred"); the
/// aligner keeps whichever one matches the sound best.
enum SpokenForm {
    static let special: Set<Character> = ["$", "€", "£", "%", "&", "#", "+", "@", "=", "°", "×", "/"]

    /// nil for an ordinary word (letters only). Otherwise the likely readings, most likely first
    /// (at most `limit`), each as words separated by single spaces. May be empty.
    static func readings(_ text: String, limit: Int = 8) -> [String]? {
        let t = trimmed(text)
        guard t.contains(where: { $0.isASCII && $0.isNumber || special.contains($0) }) else { return nil }
        let p = lex(t)
        var groups: [[String]] = []
        var i = 0
        func num(_ k: Int) -> Num? { if k < p.count, case .num(let n) = p[k] { return n }; return nil }
        func sym(_ k: Int) -> Character? { if k < p.count, case .sym(let c) = p[k] { return c }; return nil }
        func letters(_ k: Int) -> String? { if k < p.count, case .letters(let l) = p[k] { return l.lowercased() }; return nil }
        while i < p.count {
            // $50, $4.99, $5M, £20
            if let c = sym(i), let unit = currencies[c], let n = num(i + 1) {
                var j = i + 2
                var scale: String? = nil
                if let l = letters(j), let s = scales[l] { scale = s; j += 1 }
                groups.append(currency(n, unit: unit, scale: scale)); i = j; continue
            }
            guard let n = num(i) else {
                if let l = letters(i) { groups.append(letterReadings(l)) }
                else if let c = sym(i) { groups.append(symbols[c] ?? [""]) }
                i += 1; continue
            }
            // 3:30
            if sym(i + 1) == ":", let m = num(i + 2), n.frac == nil, m.frac == nil {
                groups.append(time(n.int, m.int)); i += 3; continue
            }
            // 24/7, 1/2
            if sym(i + 1) == "/", let d = num(i + 2), n.frac == nil, d.frac == nil {
                groups.append(slash(n, d)); i += 3; continue
            }
            // 2-3 (a range); 800-555-1234 (groups said one after another)
            if let s = sym(i + 1), s == "-" || s == "–", num(i + 2) != nil {
                var chain = [n], k = i + 2
                while let m = num(k) {
                    chain.append(m)
                    if let s2 = sym(k + 1), s2 == "-" || s2 == "–", num(k + 2) != nil { k += 2 } else { k += 1; break }
                }
                if chain.count == 2 {
                    var r: [String] = []
                    for a in numberReadings(chain[0]).prefix(2) {
                        for b in numberReadings(chain[1]).prefix(2) {
                            r += [a + " to " + b, a + " " + b, a + " through " + b]
                        }
                    }
                    groups.append(r)
                } else {
                    for m in chain { groups.append(numberReadings(m)) }
                }
                i = k; continue
            }
            if let l = letters(i + 1) {
                // 1st, 22nd, 3rd, 4th
                if ["st", "nd", "rd", "th"].contains(l), n.frac == nil, let v = Int(n.int) {
                    groups.append([ordinal(cardinal(v))]); i += 2; continue
                }
                // 1990s, 90's
                if l == "s" || l == "'s", n.frac == nil {
                    groups.append(numberReadings(n).map(plural)); i += 2; continue
                }
                // 5k, 2M, 10x
                if let s = scales[l] {
                    groups.append(numberReadings(n).map { $0 + " " + s }); i += 2; continue
                }
                if l == "x" {
                    groups.append(numberReadings(n).flatMap { [$0 + " times", $0 + " x"] }); i += 2; continue
                }
            }
            // 50%
            if sym(i + 1) == "%" {
                groups.append(numberReadings(n).map { $0 + " percent" }); i += 2; continue
            }
            groups.append(numberReadings(n)); i += 1
        }
        // every combination, first readings first
        var out = [""]
        for g in groups where !g.isEmpty {
            var next: [String] = []
            for a in out { for b in g { next.append(join(a, b)) } }
            out = Array(dedupe(next).prefix(limit * 2))
        }
        return Array(dedupe(out.filter { !$0.isEmpty }).prefix(limit))
    }

    // MARK: - Pieces

    struct Num: Equatable {
        var int: String          // digits only
        var frac: String?        // digits after a decimal point
        var commas: Bool         // written with thousands separators (so it's an amount, not a code)
    }
    enum Piece { case num(Num), letters(String), sym(Character) }

    static func trimmed(_ s: String) -> String {
        let lead: Set<Character> = ["\"", "'", "(", "[", "\u{201C}", "\u{2018}", "\u{2019}", "\u{201D}"]
        let trail: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "\"", "'", "\u{201D}", "\u{2019}", "\u{2026}"]
        var c = Array(s)
        while let f = c.first, lead.contains(f) { c.removeFirst() }
        while let l = c.last, trail.contains(l) { c.removeLast() }
        return String(c)
    }

    static func lex(_ s: String) -> [Piece] {
        let c = Array(s.replacingOccurrences(of: "\u{2019}", with: "'"))
        var out: [Piece] = []
        var i = 0
        func digit(_ k: Int) -> Bool { k < c.count && c[k].isASCII && c[k].isNumber }
        while i < c.count {
            if digit(i) {
                var raw = ""
                while i < c.count, digit(i) || ((c[i] == "," || c[i] == ".") && digit(i + 1)) { raw.append(c[i]); i += 1 }
                let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                if parts.count > 2 {          // 1.2.3 → one point two point three
                    for (k, part) in parts.enumerated() {
                        if k > 0 { out.append(.letters("point")) }
                        out.append(.num(Num(int: part.filter { $0 != "," }, frac: nil, commas: false)))
                    }
                    continue
                }
                let whole = parts[0]
                out.append(.num(Num(int: whole.filter { $0 != "," }, frac: parts.count == 2 ? parts[1] : nil,
                                    commas: whole.contains(","))))
            } else if c[i].isLetter || (c[i] == "'" && i + 1 < c.count && c[i + 1].isLetter && !out.isEmpty) {
                var l = ""
                while i < c.count, c[i].isLetter || (c[i] == "'" && i + 1 < c.count && c[i + 1].isLetter) { l.append(c[i]); i += 1 }
                out.append(.letters(l))
            } else {
                out.append(.sym(c[i])); i += 1
            }
        }
        return out
    }

    // MARK: - Readings

    static let currencies: [Character: (one: String, many: String, cents: String)] = [
        "$": ("dollar", "dollars", "cents"), "€": ("euro", "euros", "cents"), "£": ("pound", "pounds", "pence")]
    static let scales: [String: String] = ["k": "thousand", "m": "million", "mm": "million", "b": "billion",
                                           "bn": "billion", "t": "trillion"]
    static let symbols: [Character: [String]] = [
        "&": ["and"], "+": ["plus", ""], "#": ["number", "hashtag", ""], "@": ["at"], "=": ["equals"],
        "°": ["degrees", ""], "%": ["percent"], "/": ["slash", "or", ""], "×": ["times", "by"]]

    static func letterReadings(_ l: String) -> [String] {
        switch l {
        case "am", "pm": return [l.map(String.init).joined(separator: " "), l]
        default: return [l]
        }
    }

    static func numberReadings(_ n: Num) -> [String] {
        guard let f = n.frac, !f.isEmpty else { return integerReadings(n.int, commas: n.commas) }
        let whole = n.int.isEmpty ? [] : integerReadings(n.int, commas: n.commas).prefix(2).map { $0 }
        var r: [String] = []
        for w in whole.isEmpty ? ["zero"] : whole { r.append(w + " point " + digits(f)) }
        if n.int.isEmpty || n.int == "0" { r.append("point " + digits(f)); r.append("oh point " + digits(f)) }
        if f.count == 2, let v = Int(f), v >= 10, let w = whole.first { r.append(w + " point " + cardinal(v)) }
        return dedupe(r)
    }

    static func integerReadings(_ s: String, commas: Bool) -> [String] {
        guard !s.isEmpty else { return [] }
        guard s.count <= 15, let v = Int(s) else { return [digits(s)] }
        if s.count > 1, s.first == "0" { return [digits(s), digits(s, zero: "zero")] }
        var r: [String] = []
        if !commas && s.count >= 7 { r.append(digits(s)) }              // phone and account numbers
        let yearish = !commas && s.count == 4 && (1100...2099).contains(v)
        if yearish && v >= 1900 { r.append(year(v)) }
        r.append(cardinal(v))
        if yearish && v < 1900 { r.append(year(v)) }
        if (1100...9999).contains(v), v % 1000 != 0, (v / 100) % 10 != 0 {   // fifteen hundred (fifty)
            let lo = v % 100
            r.append(cardinal(v / 100) + " hundred" + (lo == 0 ? "" : " " + cardinal(lo)))
        }
        if let c = r.first(where: { $0.hasPrefix("one hundred") || $0.hasPrefix("one thousand") }) {
            r.append("a" + String(c.dropFirst(3)))                              // a hundred, a thousand
        }
        if !commas && (3...6).contains(s.count) { r.append(digits(s)) }
        return dedupe(r)
    }

    static func currency(_ n: Num, unit: (one: String, many: String, cents: String), scale: String?) -> [String] {
        if let scale {
            return numberReadings(n).flatMap { [$0 + " " + scale + " " + unit.many, $0 + " " + scale] }
        }
        let dollars = Int(n.int) ?? 0
        let many = dollars == 1 ? unit.one : unit.many
        if let f = n.frac, f.count == 2, let c = Int(f) {
            if c == 0 { return integerReadings(n.int.isEmpty ? "0" : n.int, commas: n.commas).map { $0 + " " + many } }
            let cs = cardinal(c)
            if dollars == 0 { return [cs + " " + unit.cents, "zero " + unit.many + " and " + cs + " " + unit.cents] }
            var r: [String] = []
            for d in integerReadings(n.int, commas: n.commas).prefix(2) {
                r += [d + " " + many + " and " + cs + " " + unit.cents, d + " " + cs, d + " " + many + " " + cs]
            }
            return dedupe(r)
        }
        let base = numberReadings(n)
        return dedupe(base.map { $0 + " " + many } + base.prefix(1))
    }

    static func time(_ h: String, _ m: String) -> [String] {
        guard let hv = Int(h), let mv = Int(m) else { return [digits(h + m)] }
        let hs = cardinal(hv)
        if mv == 0 { return [hs, hs + " o'clock", hs + " hundred"] }
        if mv < 10 { return [hs + " oh " + cardinal(mv), hs + " " + cardinal(mv), hs + " zero " + cardinal(mv)] }
        return [hs + " " + cardinal(mv), hs + " to " + cardinal(mv)]      // also ratios / verses: 3:16
    }

    static func slash(_ a: Num, _ b: Num) -> [String] {
        guard let av = Int(a.int), let bv = Int(b.int) else { return [digits(a.int) + " " + digits(b.int)] }
        let A = cardinal(av), B = cardinal(bv)
        var r = [A + " " + B, A + " out of " + B, A + " slash " + B, A + " over " + B]
        if av < bv, (2...10).contains(bv) {
            var frac: [String]
            switch bv {
            case 2: frac = av == 1 ? ["one half", "a half", "half"] : [A + " halves"]
            case 4: frac = av == 1 ? ["one quarter", "a quarter", "one fourth"] : [A + " quarters", A + " fourths"]
            default: frac = av == 1 ? ["one " + ordinal(B), "a " + ordinal(B)] : [A + " " + ordinal(B) + "s"]
            }
            r = frac + r
        }
        return r
    }

    // MARK: - Words for numbers

    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                       "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func cardinal(_ v: Int) -> String {
        if v < 0 { return "minus " + cardinal(-v) }
        if v < 20 { return ones[v] }
        if v < 100 { return tens[v / 10] + (v % 10 == 0 ? "" : " " + ones[v % 10]) }
        if v < 1000 { return ones[v / 100] + " hundred" + (v % 100 == 0 ? "" : " " + cardinal(v % 100)) }
        for (size, name) in [(1_000_000_000_000, "trillion"), (1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")]
        where v >= size {
            return cardinal(v / size) + " " + name + (v % size == 0 ? "" : " " + cardinal(v % size))
        }
        return String(v)
    }

    static func year(_ v: Int) -> String {
        if (2000...2009).contains(v) { return v == 2000 ? "two thousand" : "two thousand " + cardinal(v - 2000) }
        let hi = v / 100, lo = v % 100
        if lo == 0 { return cardinal(hi) + " hundred" }
        if lo < 10 { return cardinal(hi) + " oh " + cardinal(lo) }
        return cardinal(hi) + " " + cardinal(lo)
    }

    static func digits(_ s: String, zero: String = "oh") -> String {
        s.compactMap { $0.wholeNumberValue }.map { $0 == 0 ? zero : ones[$0] }.joined(separator: " ")
    }

    static func ordinal(_ words: String) -> String {
        var w = words.split(separator: " ").map(String.init)
        guard let last = w.popLast() else { return words }
        let special = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                       "nine": "ninth", "twelve": "twelfth"]
        let o = special[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        return (w + [o]).joined(separator: " ")
    }

    static func plural(_ words: String) -> String {
        var w = words.split(separator: " ").map(String.init)
        guard let last = w.popLast() else { return words }
        let p = last.hasSuffix("y") ? String(last.dropLast()) + "ies" : (last == "six" ? "sixes" : last + "s")
        return (w + [p]).joined(separator: " ")
    }

    static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : (b.isEmpty ? a : a + " " + b) }

    static func dedupe(_ v: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in v where seen.insert(s).inserted { out.append(s) }
        return out
    }
}
