import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pending: [URL] = []
    static var handler: (([URL]) -> Void)?
    static func deliver(_ urls: [URL]) {
        if let h = handler { h(urls) } else { pending += urls }
    }
    func application(_ application: NSApplication, open urls: [URL]) { AppDelegate.deliver(urls) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { ControlServer.shared.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class AppState: ObservableObject {
    @Published var current: ProjectModel? = nil
    @Published var projects: [ProjectSummary] = []
    @Published var errorText: String? = nil

    /// The one AppState, for the control socket (Claude's MCP connection).
    static weak var shared: AppState?

    init() {
        refresh()
        AppState.shared = self
        ControlServer.shared.start()
        AppDelegate.handler = { [weak self] urls in
            Task { @MainActor in
                guard let self else { return }
                // with a project open, files dropped on the Dock icon are added to it
                if let m = self.current { await m.addFiles(urls) } else { self.create(files: urls) }
            }
        }
        if !AppDelegate.pending.isEmpty {
            let urls = AppDelegate.pending; AppDelegate.pending = []
            Task { @MainActor in self.create(files: urls) }
        }
    }

    func refresh() { projects = Store.list() }

    func open(_ folder: URL) {
        do {
            let m = try ProjectModel(folder: folder)
            current = m
            Task { await m.open() }
        } catch { errorText = "Couldn't open that project: \(error.localizedDescription)" }
    }

    func create(files: [URL]) {
        let videos = files.filter { Store.videoExts.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { errorText = "Drop one to four video files (.mov or .mp4), plus any separate audio recordings."; return }
        let name = defaultProjectName(videos[0])
        do {
            let folder = try Store.create(name: name, files: files)
            refresh()
            open(folder)
        } catch { errorText = error.localizedDescription }
    }

    func rename(_ folder: URL, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, var p = try? Store.load(folder) else { return }
        p.name = n
        try? Store.save(p, to: folder)
        if let m = current, m.folder == folder { m.liveEdit { $0.name = n } }
        refresh()
    }

    func close() {
        current?.engine.pause()
        current?.saveNow()
        current = nil
        refresh()
    }
}

struct Clips2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup(Brand.name) {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 720)
                .tint(Brand.green)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { app.current?.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") { app.current?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Clip") {
                Button("Make Clip from Selection") { app.current?.makeClipFromSelection() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Delete Selected Words from Clip") { app.current?.cutSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Restore Selected Words") { app.current?.restoreSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Cut to Angle A") { app.current?.cutTo(angle: 0) }.keyboardShortcut("1", modifiers: .command)
                Button("Cut to Angle B") { app.current?.cutTo(angle: 1) }.keyboardShortcut("2", modifiers: .command)
                Button("Back to Automatic Angles") { app.current?.cutTo(angle: nil) }.keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Zoom Timeline In") { app.current?.zoomTimeline(by: 1.6) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Timeline Out") { app.current?.zoomTimeline(by: 1 / 1.6) }.keyboardShortcut("-", modifiers: .command)
                Button("Fit Timeline") { app.current?.fitTimeline() }.keyboardShortcut("0", modifiers: [.command, .option])
                Button("Cut Timeline Selection") { app.current?.cutTimelineSelection() }
                Button("Shorten Pauses in Clip") { app.current?.shortenPauses(over: 0.6, keep: 0.25) }
                Divider()
                Button("Blade at Playhead") { app.current?.bladeAtPlayhead() }.keyboardShortcut("b", modifiers: .command)
                Button("Trim Start to Playhead") { app.current?.trimStartToPlayhead() }.keyboardShortcut("[", modifiers: .option)
                Button("Trim End to Playhead") { app.current?.trimEndToPlayhead() }.keyboardShortcut("]", modifiers: .option)
                Button("Add Marker") { app.current?.addMarker() }
                Button("Next Edit Point") { app.current?.jumpEditPoint(next: true) }
                Button("Previous Edit Point") { app.current?.jumpEditPoint(next: false) }
                Divider()
                Button("Fix Transcript Text…") { app.current?.beginEditingText() }
                Divider()
                Button("Mark as Used, Go to Next  (U)") { app.current?.markAndAdvance(.used) }
                Button("Mark as Rejected, Go to Next  (X)") { app.current?.markAndAdvance(.rejected) }
                Button("Clear Clip Mark") { app.current?.setStatus(nil) }
                Button("Previous Clip") { app.current?.selectAdjacentClip(next: false) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Clip") { app.current?.selectAdjacentClip(next: true) }.keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button("Export Clip…") {
                    if let m = app.current, let id = m.selectedClipID { Task { await m.exportAsking(id) } }
                }.keyboardShortcut("e", modifiers: .command)
            }
        }
        Settings { SettingsView().tint(Brand.green) }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Group {
            if let m = app.current {
                ProjectView(model: m)
            } else {
                HomeView()
            }
        }
        .alert(Brand.name, isPresented: Binding(get: { app.errorText != nil }, set: { if !$0 { app.errorText = nil } })) {
            Button("OK") { app.errorText = nil }
        } message: { Text(app.errorText ?? "") }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("claudeModel") var model = ClipFinder.models[0].id
    @AppStorage("exportDir") var exportDir = ""
    @AppStorage("language") var language = "en-US"
    @State private var key = ClipFinder.loadKey()
    @State private var saved = false

    var body: some View {
        Form {
            Section("Clip finder (Claude API)") {
                SecureField("API key (sk-ant-…)", text: $key)
                HStack {
                    Button("Save key") { ClipFinder.saveKey(key); saved = true }
                    if saved { Text("Saved").foregroundStyle(.secondary) }
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
                Picker("Model", selection: $model) {
                    ForEach(ClipFinder.models, id: \.id) { Text($0.label).tag($0.id) }
                }
                Text("The key is stored only on this Mac. Only the transcript text is sent to Claude, never your video or audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saving") {
                HStack {
                    Text(exportDir.isEmpty ? Store.defaultExportDir.path : exportDir).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url { exportDir = u.path }
                    }
                }
            }
            Section("Transcription") {
                Picker("Language", selection: $language) {
                    Text("English (US)").tag("en-US"); Text("English (UK)").tag("en-GB")
                    Text("Spanish").tag("es-ES"); Text("French").tag("fr-FR"); Text("German").tag("de-DE")
                    Text("Portuguese (Brazil)").tag("pt-BR")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--mcp") { MCPServer.run() }
        if let i = args.firstIndex(of: "--synctest"), i + 1 < args.count {
            exit(MainActor.assumeIsolated { SelfTest.syncReport(folder: URL(fileURLWithPath: args[i + 1])) })
        }
        if let i = args.firstIndex(of: "--resynctest"), i + 1 < args.count {
            let f = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in exit(await SelfTest.resyncTest(folder: f)) }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--selftest") {
            let files = Array(args[(i + 1)...]).map { URL(fileURLWithPath: $0) }
            Task { @MainActor in
                let code = await SelfTest.run(files: files)
                exit(code)
            }
            dispatchMain()
        } else {
            if let i = args.firstIndex(of: "--new") {
                AppDelegate.pending = Array(args[(i + 1)...]).map { URL(fileURLWithPath: $0) }
            }
            Clips2App.main()
        }
    }
}

/// A readable name for a new project: the first camera file's name, unless that's just numbers
/// (like "1790787574635" from a recording platform), then "Recording Oct 9, 2026" from the file's date.
func defaultProjectName(_ url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent
    if stem.rangeOfCharacter(from: .letters) != nil,
       !(stem.count >= 20 && stem.allSatisfy { $0.isHexDigit || $0 == "-" }) { return stem }
    let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    let d = v?.creationDate ?? v?.contentModificationDate ?? Date()
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
    return "Recording " + f.string(from: d)
}
