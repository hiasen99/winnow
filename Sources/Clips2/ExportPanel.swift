import AppKit
import UniformTypeIdentifiers

enum ExportKind: Int, CaseIterable {
    case video, audioM4A, audioWAV, captions

    var label: String {
        switch self {
        case .video: return "Video (.mp4)"
        case .audioM4A: return "Audio only (.m4a)"
        case .audioWAV: return "Audio only (.wav, uncompressed)"
        case .captions: return "Captions only (.srt)"
        }
    }
    var ext: String {
        switch self { case .video: return "mp4"; case .audioM4A: return "m4a"; case .audioWAV: return "wav"; case .captions: return "srt" }
    }
    var type: UTType {
        switch self {
        case .video: return .mpeg4Movie
        case .audioM4A: return .mpeg4Audio
        case .audioWAV: return .wav
        case .captions: return UTType(filenameExtension: "srt") ?? .plainText
        }
    }
}

/// The save window for exports, with a "Format" menu (video / audio / captions) at the bottom.
@MainActor
final class ExportPanel: NSObject {
    let panel = NSSavePanel()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let srtBox = NSButton(checkboxWithTitle: "Also save captions (.srt) next to the video", target: nil, action: nil)
    private let burnBox = NSButton(checkboxWithTitle: "Burn the captions into the video", target: nil, action: nil)
    private(set) var kind: ExportKind
    var alsoSRT: Bool { srtBox.state == .on }
    var burnIn: Bool { burnBox.state == .on }

    init(title: String, baseName: String, folder: URL, burnIn: Bool = true) {
        let d = UserDefaults.standard
        kind = ExportKind(rawValue: d.integer(forKey: "exportKind")) ?? .video
        super.init()
        panel.title = title
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = folder
        panel.nameFieldStringValue = baseName + "." + kind.ext

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
        apply()
    }

    @objc private func formatChanged() {
        kind = ExportKind(rawValue: popup.indexOfSelectedItem) ?? .video
        apply()
    }

    private func apply() {
        panel.allowedContentTypes = [kind.type]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + kind.ext
        srtBox.isHidden = kind != .video
        burnBox.isHidden = kind != .video
        switch kind {
        case .video: panel.message = burnBox.state == .on
            ? "The finished clip with its camera cuts, sound and burned-in captions."
            : "The finished clip with its camera cuts and sound (no captions on the picture)."
        case .audioM4A, .audioWAV: panel.message = "Just the clip's sound, with your sound changes and cuts."
        case .captions: panel.message = "Caption file with the clip's timing, for YouTube, Final Cut or Premiere."
        }
    }

    /// Shows the window. Returns the chosen file, or nil if cancelled.
    func run() -> URL? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(kind.rawValue, forKey: "exportKind")
        UserDefaults.standard.set(alsoSRT, forKey: "exportAlsoSRT")
        return url
    }
}
