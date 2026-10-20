import SwiftUI
import AppKit

/// A Winnow release on GitHub.
struct WinnowRelease: Equatable {
    var version: String          // "1.7" (the tag without its "v")
    var title: String
    var notes: String            // markdown, as written on GitHub
    var page: URL                // the release page
    var download: URL            // Winnow.dmg (or the page if there's no DMG)
    var published: Date?
}

/// Checks GitHub for a newer Winnow and says so (a banner in the main window, or an alert for
/// Winnow ▸ Check for Updates…). It never installs anything itself: Download opens the DMG in the browser.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    nonisolated static let repo = "hiasen99/winnow"
    static let autoKey = "checkForUpdates"           // on unless turned off in Settings
    static let skipKey = "skippedUpdateVersion"
    static let lastKey = "lastUpdateCheck"

    @Published var available: WinnowRelease?         // newer than this copy
    @Published var dismissed = false                 // banner closed until Winnow next opens
    @Published var checking = false
    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: lastKey) as? Date
    @Published var lastError: String?
    private var timer: Timer?

    /// This copy's version. (`defaults write com.samuelroys.clips2 updatePretendVersion 1.0` fakes an older one for testing.)
    nonisolated static var current: String {
        if let v = UserDefaults.standard.string(forKey: "updatePretendVersion"), !v.isEmpty { return v }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var autoEnabled: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }

    /// What the banner shows: a newer release that wasn't skipped or closed.
    var bannerRelease: WinnowRelease? {
        guard let r = available, !dismissed,
              r.version != UserDefaults.standard.string(forKey: Self.skipKey) else { return nil }
        return r
    }

    /// At launch: check a few seconds in, then about once a day while Winnow stays open.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            Task { @MainActor in Updates.shared.checkIfDue(atLaunch: false) }
        }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            checkIfDue(atLaunch: true)
        }
    }

    func checkIfDue(atLaunch: Bool) {
        guard Self.autoEnabled, !checking else { return }
        if !atLaunch, let l = lastChecked, Date().timeIntervalSince(l) < 20 * 3600 { return }
        Task { await check() }
    }

    /// Asks GitHub for the latest release; nil if the check failed (see `lastError`).
    @discardableResult
    func check() async -> WinnowRelease? {
        checking = true
        defer { checking = false }
        do {
            let r = try await Self.fetchLatest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastKey)
            lastError = nil
            if Self.isNewer(r.version, than: Self.current) {
                if available != r { dismissed = false }
                available = r
                Log.write("updates: Winnow \(r.version) is available (this is \(Self.current))")
            } else {
                available = nil
                Log.write("updates: up to date (\(Self.current); latest on GitHub \(r.version))")
            }
            return r
        } catch {
            lastError = error.localizedDescription
            Log.write("updates: check failed: \(error.localizedDescription)")
            return nil
        }
    }

    struct Failure: LocalizedError { var errorDescription: String? }

    nonisolated static func fetchLatest() async throws -> WinnowRelease {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Winnow/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 || code == 429 { throw Failure(errorDescription: "GitHub is limiting checks right now. Try again in an hour.") }
        if code == 404 { throw Failure(errorDescription: "There are no Winnow releases on GitHub yet.") }
        guard code == 200 else { throw Failure(errorDescription: "GitHub answered with error \(code).") }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Rel: Decodable {
            let tag_name: String; let name: String?; let body: String?; let html_url: String
            let published_at: String?; let assets: [Asset]?
        }
        let r = try JSONDecoder().decode(Rel.self, from: data)
        let page = URL(string: r.html_url) ?? URL(string: "https://github.com/\(repo)/releases/latest")!
        let dmg = r.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browser_download_url) } ?? page
        var v = r.tag_name.trimmingCharacters(in: .whitespaces)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        while v.hasSuffix(".0"), v.filter({ $0 == "." }).count > 1 { v.removeLast(2) }   // "1.6.0" → "1.6"
        let title = (r.name?.isEmpty == false) ? r.name! : "Winnow \(v)"
        return WinnowRelease(version: v, title: title, notes: r.body ?? "", page: page, download: dmg,
                             published: r.published_at.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    /// "1.10" > "1.9", "1.6" == "1.6.0", a leading "v" is ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            var s = v.trimmingCharacters(in: .whitespaces)
            if s.first == "v" || s.first == "V" { s.removeFirst() }
            return s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func download(_ r: WinnowRelease) { NSWorkspace.shared.open(r.download) }
    func openPage(_ r: WinnowRelease) { NSWorkspace.shared.open(r.page) }
    func skip(_ r: WinnowRelease) {
        UserDefaults.standard.set(r.version, forKey: Self.skipKey)
        objectWillChange.send()
    }

    /// Winnow ▸ Check for Updates… and Settings ▸ Check Now: always answers, even for a skipped version.
    func checkNowAndTell() {
        guard !checking else { return }
        Task {
            let r = await check()
            let a = NSAlert()
            if let r, Self.isNewer(r.version, than: Self.current) {
                a.messageText = "Winnow \(r.version) is available"
                var info = "You have \(Self.current)."
                let notes = Self.plainNotes(r.notes)
                if !notes.isEmpty { info += "\n\n" + (notes.count > 450 ? String(notes.prefix(450)) + "…" : notes) }
                info += "\n\nDownload opens Winnow.dmg. Quit Winnow, then drag the new Winnow into Applications and choose Replace."
                a.informativeText = info
                a.addButton(withTitle: "Download")
                a.addButton(withTitle: "View on GitHub")
                a.addButton(withTitle: "Later")
                switch a.runModal() {
                case .alertFirstButtonReturn: download(r)
                case .alertSecondButtonReturn: openPage(r)
                default: break
                }
            } else if r != nil {
                a.messageText = "You're up to date"
                a.informativeText = "Winnow \(Self.current) is the newest version."
                a.addButton(withTitle: "OK")
                a.runModal()
            } else {
                a.alertStyle = .warning
                a.messageText = "Couldn't check for updates"
                a.informativeText = (lastError ?? "No answer from GitHub.") + "\n\nCheck your internet connection and try again."
                a.addButton(withTitle: "OK")
                a.runModal()
            }
        }
    }

    /// Release notes without markdown symbols, for an alert.
    nonisolated static func plainNotes(_ md: String) -> String {
        NoteLine.parse(md).map { l in
            let t = String(l.text.characters)
            return l.kind == .bullet ? "• " + t : t
        }.joined(separator: "\n")
    }
}

/// One line of release notes: a heading, a bullet or a paragraph (inline **bold**, `code` and links kept).
struct NoteLine: Identifiable {
    enum Kind { case heading, bullet, text }
    let id: Int
    let kind: Kind
    let text: AttributedString

    static func parse(_ md: String) -> [NoteLine] {
        var out: [NoteLine] = []
        for raw in md.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: true) {
            var s = raw.trimmingCharacters(in: .whitespaces)
            var kind = Kind.text
            if s.hasPrefix("#") { kind = .heading; s = String(s.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            else if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { kind = .bullet; s = String(s.dropFirst(2)) }
            if s.isEmpty { continue }
            let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(s)
            out.append(NoteLine(id: out.count, kind: kind, text: a))
        }
        return out
    }
}

/// The strip across the top of the main window when a newer Winnow is out.
struct UpdateBanner: View {
    @ObservedObject var updates = Updates.shared
    @State private var showNotes = false
    @State private var downloaded = false

    var body: some View {
        if let r = updates.bannerRelease {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(Brand.green)
                if downloaded {
                    Text("Downloading Winnow \(r.version)…").font(.callout.weight(.semibold))
                    Text("Open Winnow.dmg, quit Winnow, then drag the new one into Applications and choose Replace.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                } else {
                    Text("Winnow \(r.version) is available").font(.callout.weight(.semibold))
                    Text("You have \(Updates.current)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("What's New") { showNotes = true }
                    .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotesView(release: r) }
                if !downloaded {
                    Button("Skip This Version") { updates.skip(r) }
                        .help("Don't show this again until a newer version comes out. Winnow ▸ Check for Updates… still finds it.")
                }
                Button(downloaded ? "Download Again" : "Download") { updates.download(r); downloaded = true }
                    .buttonStyle(.borderedProminent)
                Button { updates.dismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide until Winnow opens again")
            }
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Brand.green.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

struct ReleaseNotesView: View {
    let release: WinnowRelease
    var body: some View {
        let lines = NoteLine.parse(release.notes)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(release.title).font(.title3.weight(.semibold))
                if let d = release.published {
                    Text("Released \(d.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if lines.isEmpty { Text("No notes for this release.").foregroundStyle(.secondary) }
                    ForEach(lines) { l in
                        switch l.kind {
                        case .heading: Text(l.text).font(.headline).padding(.top, 4)
                        case .bullet:
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(Brand.green)
                                Text(l.text).fixedSize(horizontal: false, vertical: true)
                            }
                        case .text: Text(l.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 340)
            HStack {
                Button("View on GitHub") { Updates.shared.openPage(release) }
                Spacer()
                Button("Download") { Updates.shared.download(release) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
