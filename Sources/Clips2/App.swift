import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Started by Claude's MCP connection (`--background`): no window or Dock icon until someone opens Winnow.
    static var launchedInBackground = false
    static var pending: [URL] = []
    static var handler: (([URL]) -> Void)?
    static func deliver(_ urls: [URL]) {
        if let h = handler { h(urls) } else { pending += urls }
    }
    func application(_ application: NSApplication, open urls: [URL]) { AppDelegate.deliver(urls) }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppDelegate.launchedInBackground { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = AppState.main               // the control socket has to work even with no window
            Updates.shared.start()          // looks for a newer Winnow on GitHub
            if AppDelegate.launchedInBackground {
                Background.launched()
            } else {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Background.reopened() } }
        return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        // opened from Finder / Spotlight while running with no window
        MainActor.assumeIsolated { Background.reopened() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Another app asking Winnow to quit (some utilities quit every app with no window). While Winnow is
        // running windowless for Claude and in use, say no, unless the Mac is logging out, restarting or shutting down.
        guard let ev = NSAppleEventManager.shared().currentAppleEvent,
              ev.eventClass == 0x61657674 /* aevt */, ev.eventID == 0x71756974 /* quit */ else {
            Log.write("app: quitting"); return .terminateNow
        }
        let pid = ev.attributeDescriptor(forKeyword: 0x73706964 /* 'spid' */)?.int32Value ?? 0
        let sender = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "process \(pid)"
        let why = ev.attributeDescriptor(forKeyword: 0x77687920 /* 'why?' */)?.typeCodeValue
            ?? ev.paramDescriptor(forKeyword: 0x77687920)?.typeCodeValue ?? 0
        let system: Set<OSType> = [0x6c6f676f, 0x726c676f, 0x72727374, 0x7273646e, 0x72657374, 0x73687574] // logo rlgo rrst rsdn rest shut
        let busy = MainActor.assumeIsolated { Background.inUseWithoutWindow }
        if busy && !system.contains(why) && pid != getpid() {
            Log.write("app: \(sender) asked Winnow to quit; staying open because Claude is using it with no window")
            return .terminateCancel
        }
        Log.write("app: quitting (asked by \(sender))")
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared?.current?.saveNow(); AppState.shared?.claude?.saveNow() }
        ControlServer.shared.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { Background.shouldQuitWhenWindowCloses() }
    }
}

@MainActor
final class AppState: ObservableObject {
    /// The project in the main window.
    @Published var current: ProjectModel? = nil
    /// The project Claude is working on (its own, in the background, so your window never changes because of Claude).
    /// When it's the same project as the window's, both point at the same model: one live copy, one undo history.
    @Published var claude: ProjectModel? = nil
    /// The project the menus act on: Claude's when its window is in front, otherwise the main window's.
    var active: ProjectModel? {
        if let c = claude, c !== current, let w = Background.claudeWindow, w.isKeyWindow { return c }
        return current
    }
    @Published var projects: [ProjectSummary] = []
    @Published var errorText: String? = nil

    /// The one AppState, for the control socket (Claude's MCP connection).
    static weak var shared: AppState?
    /// Made at launch (not when the first window appears), so Winnow can run with no window.
    static let main = AppState()

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

    /// Moves projects to the Trash (only Winnow's project data; the camera and audio files aren't touched).
    /// Returns how many couldn't be moved.
    @discardableResult
    func delete(_ folders: [URL]) -> Int {
        if let m = current, folders.contains(m.folder) { close() }
        if let m = claude, folders.contains(m.folder) { closeClaude() }
        let failed = folders.filter { !Store.delete($0) }.count
        refresh()
        if failed > 0 { errorText = failed == 1 ? "One project couldn't be moved to the Trash." : "\(failed) projects couldn't be moved to the Trash." }
        return failed
    }

    func open(_ folder: URL) {
        // Claude already has it open: share that copy (same edits, same undo)
        if let c = claude, c.folder == folder { current = c; return }
        do {
            let m = try ProjectModel(folder: folder)
            current = m
            Task { await m.open() }
        } catch { errorText = "Couldn't open that project: \(error.localizedDescription)" }
    }

    /// Claude opens a project for itself. The window's project stays put; if it's the same one, they share it.
    @discardableResult
    func openForClaude(_ folder: URL) throws -> ProjectModel {
        if let c = claude, c.folder == folder { return c }
        closeClaude()
        if let m = current, m.folder == folder { claude = m; return m }
        let m = try ProjectModel(folder: folder)
        claude = m
        Task { await m.open() }
        return m
    }

    /// Claude is done with its project. If the window shows the same project it stays open there.
    func closeClaude() {
        guard let m = claude else { return }
        claude = nil
        if m !== current { m.engine.pause(); m.saveNow() }
        refresh()
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
        var seen = Set<ObjectIdentifier>()
        for m in [current, claude].compactMap({ $0 }) where m.folder == folder && seen.insert(ObjectIdentifier(m)).inserted {
            m.liveEdit { $0.name = n }
        }
        refresh()
    }

    func close() {
        current?.engine.pause()
        current?.saveNow()
        current = nil      // (if Claude shares it, Claude keeps working on it in the background)
        refresh()
    }
}

struct Clips2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState.main

    var body: some Scene {
        WindowGroup(Brand.name, id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 720)
                .tint(Brand.green)
        }
        .windowStyle(.titleBar)
        .defaultLaunchBehavior(AppDelegate.launchedInBackground ? .suppressed : .automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkNowAndTell() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { app.active?.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("Redo") { app.active?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Clip") {
                Button("Make Clip from Selection") { app.active?.makeClipFromSelection() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Delete Selected Words from Clip") { app.active?.cutSelection() }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Restore Selected Words") { app.active?.restoreSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Cut to Angle A") { app.active?.cutTo(angle: 0) }.keyboardShortcut("1", modifiers: .command)
                Button("Cut to Angle B") { app.active?.cutTo(angle: 1) }.keyboardShortcut("2", modifiers: .command)
                Button("Back to Automatic Angles") { app.active?.cutTo(angle: nil) }.keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Zoom Timeline In") { app.active?.zoomTimeline(by: 1.6) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Timeline Out") { app.active?.zoomTimeline(by: 1 / 1.6) }.keyboardShortcut("-", modifiers: .command)
                Button("Fit Timeline") { app.active?.fitTimeline() }.keyboardShortcut("0", modifiers: [.command, .option])
                Button("Cut Timeline Selection") { app.active?.cutTimelineSelection() }
                Button("Shorten Pauses in Clip") { app.active?.shortenPauses(over: 0.6, keep: 0.25) }
                Divider()
                Button("Blade at Playhead") { app.active?.bladeAtPlayhead() }.keyboardShortcut("b", modifiers: .command)
                Button("Trim Start to Playhead") { app.active?.trimStartToPlayhead() }.keyboardShortcut("[", modifiers: .option)
                Button("Trim End to Playhead") { app.active?.trimEndToPlayhead() }.keyboardShortcut("]", modifiers: .option)
                Button("Add Marker") { app.active?.addMarker() }
                Button("Next Edit Point") { app.active?.jumpEditPoint(next: true) }
                Button("Previous Edit Point") { app.active?.jumpEditPoint(next: false) }
                Divider()
                Button("Save Frame…") { if let m = app.active { Task { await m.saveFrameAsking() } } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Grab Frame / Un-grab  (G)") { app.active?.toggleGrab() }
                Button("Save Grabbed Frames…") { if let m = app.active { Task { await m.saveGrabsAsking() } } }
                Button("Use Frame as Thumbnail  (T)") { app.active?.useFrameAsThumbnail() }
                Button("Edit Thumbnail…") { if let m = app.active, m.selectedClip != nil { m.showThumbnail = true } }
                Button("Save Thumbnail…") { if let m = app.active, let id = m.selectedClipID { Task { await m.saveThumbnailAsking(id) } } }
                Divider()
                Button("Fix Transcript Text…") { app.active?.beginEditingText() }
                Button("Re-time Words to the Sound") { if let m = app.active { Task { await m.retimeWords() } } }
                Divider()
                Button("Mark as Use, Go to Next  (U)") { app.active?.markAndAdvance(.used) }
                Button("Mark as Rejected, Go to Next  (X)") { app.active?.markAndAdvance(.rejected) }
                Button("Clear Clip Mark") { app.active?.setStatus(nil) }
                Button("Previous Clip") { app.active?.selectAdjacentClip(next: false) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Clip") { app.active?.selectAdjacentClip(next: true) }.keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button("Export Clip…") {
                    if let m = app.active, let id = m.selectedClipID { Task { await m.exportAsking(id) } }
                }.keyboardShortcut("e", modifiers: .command)
                Button("Export All Marked Use…") {
                    if let m = app.active { Task { await m.exportUseClipsAsking() } }
                }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
        // Claude's own project, opened with app.show (or Window ▸ Claude's Project) while Claude works on a different project from yours
        Window(ClaudeWindowRoot.title, id: "claude") {
            ClaudeWindowRoot()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 720)
                .tint(Brand.green)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Settings { SettingsView().tint(Brand.green) }
    }
}

/// The window that shows the project Claude is working on (when it isn't the one in your main window).
struct ClaudeWindowRoot: View {
    static let title = "Claude's Project"
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if let m = app.claude, m !== app.current {
                ProjectView(model: m, isClaudeWindow: true).id(ObjectIdentifier(m))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(Brand.gold)
                    Text(app.claude == nil ? "Claude doesn't have a project open right now." : "Claude is working on the project in your main window.")
                        .font(.title3.weight(.semibold))
                    Text("When Claude works on a different project from yours, it shows up here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowReader { Background.claudeWindow = $0 })
        .onAppear {
            Background.openWindowByID = { openWindow(id: $0) }
            Background.windowAppeared()
        }
    }
}

/// Reports the NSWindow a SwiftUI view ends up in.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ReaderView { let v = ReaderView(); v.onWindow = onWindow; return v }
    func updateNSView(_ v: ReaderView, context: Context) { v.onWindow = onWindow }
    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { [weak self] in self?.onWindow?(w) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner()
            Group {
                if let m = app.current {
                    ProjectView(model: m).id(ObjectIdentifier(m))
                } else {
                    HomeView()
                }
            }
        }
        .alert(Brand.name, isPresented: Binding(get: { app.errorText != nil }, set: { if !$0 { app.errorText = nil } })) {
            Button("OK") { app.errorText = nil }
        } message: { Text(app.errorText ?? "") }
        .onAppear {
            Background.openWindowByID = { openWindow(id: $0) }
            Background.windowAppeared()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("claudeModel") var model = ClipFinder.models[0].id
    @AppStorage("exportDir") var exportDir = ""
    @AppStorage("language") var language = "en-US"
    @AppStorage(Updates.autoKey) var autoUpdates = true
    @ObservedObject var updates = Updates.shared
    @State private var key = ClipFinder.loadKey()
    @State private var saved = false

    private var updateStatus: String {
        var s = "You have Winnow \(Updates.current)"
        if let r = updates.available { s += " · \(r.version) is available" }
        else if let d = updates.lastChecked { s += " · checked \(d.formatted(.relative(presentation: .named)))" }
        return s
    }

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
            Section("Updates") {
                Toggle("Check GitHub for new versions of Winnow", isOn: $autoUpdates)
                HStack {
                    Text(updateStatus).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if updates.checking { ProgressView().controlSize(.small) }
                    Button("Check Now") { updates.checkNowAndTell() }.disabled(updates.checking)
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
        .frame(width: 520, height: 520)
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
        if let i = args.firstIndex(of: "--aligntest"), i + 3 < args.count {
            // --aligntest <16 kHz mono wav> <words.json> <out.json>
            let a = Array(args[(i + 1)...(i + 3)])
            Task {
                do {
                    let words = try JSONDecoder().decode([Word].self, from: Data(contentsOf: URL(fileURLWithPath: a[1])))
                    let (out, st) = try await Aligner.align(words: words, audioFile: URL(fileURLWithPath: a[0]))
                    try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: a[2]))
                    print("aligned \(st.aligned) kept \(st.kept) segments \(st.segments) in \(String(format: "%.1f", st.seconds)) s")
                    exit(0)
                } catch { print("aligntest failed: \(error)"); exit(1) }
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--alignmix"), i + 2 < args.count {
            // --alignmix <audio file> <out.wav>: the mix the app aligns against, for one mic at offset 0
            let src = URL(fileURLWithPath: args[i + 1]), dst = URL(fileURLWithPath: args[i + 2])
            Task {
                do {
                    let raw = FileManager.default.temporaryDirectory.appendingPathComponent("alignmix.f32")
                    let a = try await AudioAnalysis.analyze(url: src, rawOut: raw)
                    var ang = AngleSource(name: "Mic", path: src.path, isVideo: false)
                    ang.duration = Double(a.sampleCount) / AudioAnalysis.rawRate
                    try AudioAnalysis.writeMix(angles: [ang], audio: [a], total: ang.duration, to: dst)
                    print("gain \(AudioAnalysis.levelMatchGain(a.envelope)) dB, \(a.sampleCount) samples")
                    exit(0)
                } catch { print("alignmix failed: \(error)"); exit(1) }
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--updatetest") {
            // --updatetest [pretend version]: version comparisons + a live GitHub check
            let pretend = i + 1 < args.count ? args[i + 1] : nil
            Task {
                let cases: [(String, String, Bool)] = [("1.6", "1.5", true), ("v1.10.0", "1.9", true), ("1.5.0", "1.5", false),
                                                       ("1.5", "1.6", false), ("2", "1.99", true), ("v1.6.0", "1.6", false)]
                var ok = true
                for c in cases where Updates.isNewer(c.0, than: c.1) != c.2 { print("compare FAILED \(c)"); ok = false }
                print("compare \(ok ? "ok" : "FAILED")")
                do {
                    let r = try await Updates.fetchLatest()
                    print("latest \(r.version) '\(r.title)' dmg \(r.download.absoluteString) page \(r.page.absoluteString) notes \(r.notes.count) chars")
                    print("notes lines \(NoteLine.parse(r.notes).count)")
                    if let p = pretend { print("newer than \(p): \(Updates.isNewer(r.version, than: p))") }
                } catch { print("fetch FAILED: \(error.localizedDescription)"); ok = false }
                exit(ok ? 0 : 1)
            }
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
            if args.contains("--background") { AppDelegate.launchedInBackground = true }
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
