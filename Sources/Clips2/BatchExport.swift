import AppKit
import UniformTypeIdentifiers

struct BatchExportState: Equatable {
    var done: Int
    var total: Int
    var current: String
    var currentID: UUID? = nil
    var stopping = false
}

/// "Export Marked Use": every clip marked Use, into one folder, one after another.
@MainActor
extension ProjectModel {
    var useClips: [Clip] { project.clips.filter { $0.status == .used } }

    /// Asks for a folder and a format, then exports every clip marked Use.
    func exportUseClipsAsking() async {
        guard batchExport == nil else { return }
        let clips = useClips
        guard !clips.isEmpty else {
            notice = "No clips are marked Use yet. Select a clip and press U to mark it."
            return
        }
        engine.pause()
        let panel = BatchExportPanel(count: clips.count, folder: exportFolder, burnIn: clips.contains { $0.captions })
        guard let folder = panel.run() else { return }
        UserDefaults.standard.set(folder.path, forKey: "exportDir.\(project.id.uuidString)")
        UserDefaults.standard.set(folder.path, forKey: "lastExportDir")

        let kind = panel.kind
        var jobs = Self.batchFiles(clips, folder: folder, ext: kind.ext)
        let existing = jobs.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if !existing.isEmpty {
            let a = NSAlert()
            a.messageText = existing.count == 1 ? "“\(existing[0].url.lastPathComponent)” is already in that folder."
                                                : "\(existing.count) of these files are already in that folder."
            a.informativeText = existing.prefix(6).map { $0.url.lastPathComponent }.joined(separator: "\n")
                + (existing.count > 6 ? "\n…" : "") + "\n\nReplace them with the new exports, or keep both (the new ones get a number)?"
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Keep Both")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: jobs = Self.batchFiles(clips, folder: folder, ext: kind.ext, avoidExisting: true)
            default: return
            }
        }
        await runBatchExport(jobs, kind: kind, alsoSRT: panel.alsoSRT, burnIn: kind == .video ? panel.burnIn : nil, folder: folder)
    }

    /// One file per clip, named after the clip; two clips with the same title get "Title 2".
    static func batchFiles(_ clips: [Clip], folder: URL, ext: String, avoidExisting: Bool = false) -> [(clip: Clip, url: URL)] {
        var taken = Set<String>()
        return clips.map { c in
            let base = Exporter.safeName(c.title)
            var name = base, n = 2
            func busy(_ s: String) -> Bool {
                taken.contains(s.lowercased())
                    || (avoidExisting && FileManager.default.fileExists(atPath: folder.appendingPathComponent(s + "." + ext).path))
            }
            while busy(name) { name = "\(base) \(n)"; n += 1 }
            taken.insert(name.lowercased())
            return (c, folder.appendingPathComponent(name + "." + ext))
        }
    }

    func runBatchExport(_ jobs: [(clip: Clip, url: URL)], kind: ExportKind, alsoSRT: Bool, burnIn: Bool?, folder: URL) async {
        guard !jobs.isEmpty else { return }
        batchExport = BatchExportState(done: 0, total: jobs.count, current: jobs[0].clip.title)
        defer { batchExport = nil }
        var saved: [URL] = [], failed: [String] = []
        for (i, j) in jobs.enumerated() {
            if batchExport?.stopping == true { break }
            batchExport?.done = i
            batchExport?.current = j.clip.title
            batchExport?.currentID = j.clip.id
            let t0 = Date()
            if await export(j.clip.id, to: j.url, kind: kind, alsoSRT: alsoSRT, burnIn: burnIn, quiet: true) {
                saved.append(j.url)
                Log.write(String(format: "batch export %d/%d %@ in %.1fs", i + 1, jobs.count, j.url.lastPathComponent, Date().timeIntervalSince(t0)))
            } else {
                failed.append(j.clip.title)
            }
        }
        let stopped = batchExport?.stopping == true && saved.count + failed.count < jobs.count
        lastExportBatch = saved
        lastExport = saved.last
        let place = folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if saved.isEmpty && failed.isEmpty {
            notice = "Export stopped before the first clip was saved."
        } else {
            notice = "Saved \(saved.count) of \(jobs.count) clip\(jobs.count == 1 ? "" : "s") in \(place)" + (stopped ? " (stopped)" : "")
        }
        if !failed.isEmpty {
            errorText = "\(failed.count) clip\(failed.count == 1 ? "" : "s") didn't export: " + failed.joined(separator: ", ") + ". The log has the details."
        }
    }

    func stopBatchExport() { batchExport?.stopping = true }
}

/// The folder window for "Export Marked Use", with the same Format / captions choices as a single export.
@MainActor
final class BatchExportPanel: NSObject {
    let panel = NSOpenPanel()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let srtBox = NSButton(checkboxWithTitle: "Also save captions (.srt) next to each video", target: nil, action: nil)
    private let burnBox = NSButton(checkboxWithTitle: "Burn the captions into the videos", target: nil, action: nil)
    private let count: Int
    private(set) var kind: ExportKind
    var alsoSRT: Bool { srtBox.state == .on }
    var burnIn: Bool { burnBox.state == .on }

    init(count: Int, folder: URL, burnIn: Bool) {
        let d = UserDefaults.standard
        self.count = count
        kind = ExportKind(rawValue: d.integer(forKey: "exportKind")) ?? .video
        super.init()
        panel.title = "Export \(count) Clip\(count == 1 ? "" : "s") Marked Use"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Export \(count) Here"

        for k in ExportKind.allCases { popup.addItem(withTitle: k.label) }
        popup.selectItem(at: kind.rawValue)
        popup.target = self
        popup.action = #selector(formatChanged)
        srtBox.state = (d.object(forKey: "exportAlsoSRT") as? Bool ?? true) ? .on : .off
        burnBox.state = burnIn ? .on : .off
        burnBox.target = self
        burnBox.action = #selector(formatChanged)

        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        let stack = NSStackView(views: [row, burnBox, srtBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 92))
        holder.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
            stack.topAnchor.constraint(equalTo: holder.topAnchor),
            stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        panel.accessoryView = holder
        panel.isAccessoryViewDisclosed = true
        apply()
    }

    @objc private func formatChanged() {
        kind = ExportKind(rawValue: popup.indexOfSelectedItem) ?? .video
        apply()
    }

    private func apply() {
        srtBox.isHidden = kind != .video
        burnBox.isHidden = kind != .video
        let each = "Choose a folder. Each clip is saved as its own file, named after the clip."
        switch kind {
        case .video: panel.message = each + (burnBox.state == .on ? " Captions are burned in." : " No captions on the picture.")
        case .audioM4A, .audioWAV: panel.message = each + " Just each clip's sound."
        case .captions: panel.message = each + " Caption files only."
        }
    }

    /// Shows the window. Returns the chosen folder, or nil if cancelled.
    func run() -> URL? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(kind.rawValue, forKey: "exportKind")
        UserDefaults.standard.set(alsoSRT, forKey: "exportAlsoSRT")
        return url
    }
}
