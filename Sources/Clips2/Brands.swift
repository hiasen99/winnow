import Foundation
import AppKit
import ImageIO
import SwiftUI

/// The two kinds of follow popup.
enum PopupKind: String, Codable, CaseIterable, Identifiable {
    case circle     // profile picture in a coloured ring with a Follow pill under it
    case bar        // YouTube style: picture, name, Subscribe button and bell
    var id: String { rawValue }
    var label: String { self == .circle ? "Circle + Follow" : "YouTube bar" }
    var shortLabel: String { self == .circle ? "Circle" : "YouTube bar" }
    var icon: String { self == .circle ? "person.crop.circle.badge.plus" : "bell.badge" }
}

/// A channel or account: its name, @handle, profile picture and colours (how its follow popups look),
/// and the caption / thumbnail look that goes with it. One library shared by every project.
struct ChannelBrand: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "My Channel"
    var handle: String = ""
    /// Second line on the YouTube bar ("12K subscribers"). nil = the handle.
    var subtitle: String? = nil
    /// The profile picture: a file name inside the Brands folder.
    var picture: String? = nil
    /// Ring and button colour.
    var color: RGBA = RGBA(r: 0.235, g: 0.549, b: 0.251)
    /// A second ring colour (the ring fades from one to the other). nil = one colour.
    var color2: RGBA? = nil
    /// Text on the button. nil = white.
    var buttonTextColor: RGBA? = nil
    /// The YouTube bar on a dark card instead of a white one.
    var darkCard: Bool? = nil
    var followWord: String? = nil
    var followingWord: String? = nil
    var subscribeWord: String? = nil
    var subscribedWord: String? = nil
    /// The brand's caption look (applied when the brand is picked for a project). nil = leave captions alone.
    var captionStyle: CaptionStyle? = nil
    /// Where that look came from (a preset name, or "From <project>"), just for showing.
    var captionLookName: String? = nil
    /// The brand's thumbnail look. nil = leave thumbnails alone.
    var thumbnailStyle: ThumbnailStyle? = nil

    init() {}
    init(name: String) { self.name = name }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = ChannelBrand()
        func g<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        func o<T: Decodable>(_ k: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil }
        id = g(.id, UUID()); name = g(.name, z.name); handle = g(.handle, z.handle)
        subtitle = o(.subtitle); picture = o(.picture); color = g(.color, z.color); color2 = o(.color2)
        buttonTextColor = o(.buttonTextColor); darkCard = o(.darkCard)
        followWord = o(.followWord); followingWord = o(.followingWord); subscribeWord = o(.subscribeWord); subscribedWord = o(.subscribedWord)
        captionStyle = o(.captionStyle); captionLookName = o(.captionLookName); thumbnailStyle = o(.thumbnailStyle)
    }

    static func word(_ s: String?, _ def: String) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? def : t
    }
    var follow: String { Self.word(followWord, "Follow") }
    var following: String { Self.word(followingWord, "Following") }
    var subscribe: String { Self.word(subscribeWord, "Subscribe") }
    var subscribed: String { Self.word(subscribedWord, "Subscribed") }
    var secondLine: String {
        let s = (subtitle ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? displayHandle : s
    }
    /// The handle with an @ in front (unless it's empty or already has one).
    var displayHandle: String {
        let h = handle.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return "" }
        return h.hasPrefix("@") ? h : "@" + h
    }
    var buttonText: RGBA { buttonTextColor ?? .white }
    var dark: Bool { darkCard ?? false }
    var pictureURL: URL? { picture.map { BrandStore.dir.appendingPathComponent($0) } }

    /// Used when a popup has no brand to draw: a stand-in until one is made.
    static let placeholder: ChannelBrand = {
        var b = ChannelBrand(name: "Your Channel")
        b.id = UUID(uuidString: "00000000-0000-0000-0000-00000000B4A0")!
        b.handle = "yourchannel"
        return b
    }()
}

/// Brands on disk: Application Support/Clips 2/Brands/brands.json, with each profile picture beside it.
/// Safe to read from any thread (exports build their popups off the main thread).
enum BrandStore {
    struct File: Codable {
        var brands: [ChannelBrand] = []
        /// New projects start with this brand.
        var defaultID: UUID? = nil
    }
    static var dir: URL {
        let u = Store.supportDir.appendingPathComponent("Brands", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var url: URL { dir.appendingPathComponent("brands.json") }

    private static let lock = NSLock()
    private static var cache: File? = nil
    private static var pictures: [String: CGImage] = [:]

    static func load() -> File {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var f = File()
        if let d = try? Data(contentsOf: url), let ff = try? Store.decoder.decode(File.self, from: d) { f = ff }
        cache = f
        return f
    }
    static func save(_ f: File) {
        lock.lock()
        cache = f
        lock.unlock()
        try? Store.encoder.encode(f).write(to: url, options: .atomic)
    }
    static var all: [ChannelBrand] { load().brands }
    static func brand(_ id: UUID?) -> ChannelBrand? {
        guard let id else { return nil }
        return load().brands.first { $0.id == id }
    }
    static var defaultBrand: ChannelBrand? { brand(load().defaultID) }

    static func upsert(_ b: ChannelBrand) {
        var f = load()
        if let i = f.brands.firstIndex(where: { $0.id == b.id }) { f.brands[i] = b } else { f.brands.append(b) }
        save(f)
    }
    static func remove(_ id: UUID) {
        var f = load()
        if let pic = f.brands.first(where: { $0.id == id })?.picture {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(pic))
            lock.lock(); pictures[pic] = nil; lock.unlock()
        }
        f.brands.removeAll { $0.id == id }
        if f.defaultID == id { f.defaultID = nil }
        save(f)
    }
    /// Finds a brand by name, id or the start of its id (for Claude).
    static func find(_ s: String) -> ChannelBrand? {
        let low = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !low.isEmpty else { return nil }
        let bs = all
        if let b = bs.first(where: { $0.id.uuidString.lowercased() == low || $0.name.lowercased() == low }) { return b }
        if let b = bs.first(where: { $0.displayHandle.lowercased() == low || $0.displayHandle.lowercased() == "@" + low }) { return b }
        if low.count >= 4, let b = bs.first(where: { $0.id.uuidString.lowercased().hasPrefix(low) }) { return b }
        let hits = bs.filter { $0.name.lowercased().contains(low) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Copies a picture into the Brands folder as a square PNG (centre crop, up to 640 px). Returns its file name.
    static func importPicture(_ src: URL, for id: UUID) throws -> String {
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
              let im = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                  kCGImageSourceCreateThumbnailWithTransform: true,
                                                                  kCGImageSourceThumbnailMaxPixelSize: 1400] as CFDictionary) else {
            throw ClipsError("Couldn't read that picture.")
        }
        let side = min(im.width, im.height)
        let crop = im.cropping(to: CGRect(x: (im.width - side) / 2, y: (im.height - side) / 2, width: side, height: side)) ?? im
        let out = min(640, side)
        guard let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0, space: Stills.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClipsError("Couldn't read that picture.") }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: out, height: out))
        guard let sq = ctx.makeImage() else { throw ClipsError("Couldn't read that picture.") }
        let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).png"
        try Stills.write(sq, to: dir.appendingPathComponent(name), format: .png)
        return name
    }
    /// The brand's profile picture (cached).
    static func picture(_ b: ChannelBrand) -> CGImage? {
        guard let name = b.picture else { return nil }
        lock.lock()
        if let c = pictures[name] { lock.unlock(); return c }
        lock.unlock()
        let u = dir.appendingPathComponent(name)
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let im = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        lock.lock(); pictures[name] = im; lock.unlock()
        return im
    }
}

/// The brand library for the UI (one per app, saved through BrandStore).
@MainActor
final class BrandLibrary: ObservableObject {
    static let shared = BrandLibrary()
    @Published private(set) var brands: [ChannelBrand] = []
    @Published private(set) var defaultID: UUID? = nil
    /// Bumped on every change, so views that draw popups redraw.
    @Published private(set) var version = 0

    init() { reload() }
    func reload() {
        let f = BrandStore.load()
        brands = f.brands; defaultID = f.defaultID
    }
    func brand(_ id: UUID?) -> ChannelBrand? { id.flatMap { i in brands.first { $0.id == i } } }
    func save(_ b: ChannelBrand) {
        BrandStore.upsert(b)
        reload(); version += 1
    }
    func remove(_ id: UUID) {
        BrandStore.remove(id)
        reload(); version += 1
    }
    func setDefault(_ id: UUID?) {
        var f = BrandStore.load(); f.defaultID = id; BrandStore.save(f)
        reload(); version += 1
    }
    func add(named name: String) -> ChannelBrand {
        var b = ChannelBrand(name: name)
        // a different colour for each new brand
        let palette: [RGBA] = [RGBA(r: 0.235, g: 0.549, b: 0.251), RGBA(r: 0.80, g: 0.12, b: 0.15), RGBA(r: 0.10, g: 0.45, b: 0.85),
                               RGBA(r: 0.55, g: 0.25, b: 0.80), RGBA(r: 0.95, g: 0.50, b: 0.10), RGBA(r: 0.10, g: 0.10, b: 0.12)]
        b.color = palette[brands.count % palette.count]
        save(b)
        return b
    }
}
