import Foundation

struct ProjectSummary: Identifiable, Hashable {
    var id: URL { folder }
    var folder: URL
    var name: String
    var created: Date
    var clips: Int
    var duration: Double
    var stage: Project.Stage
}

enum Store {
    static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clips 2", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var projectsDir: URL {
        let u = supportDir.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var defaultExportDir: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clips 2", isDirectory: true)
    }
    static var exportDir: URL {
        if let s = UserDefaults.standard.string(forKey: "exportDir"), !s.isEmpty { return URL(fileURLWithPath: s) }
        return defaultExportDir
    }

    static func projectFile(_ folder: URL) -> URL { folder.appendingPathComponent("project.json") }
    static func cacheDir(_ folder: URL) -> URL {
        let u = folder.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    static func load(_ folder: URL) throws -> Project {
        try decoder.decode(Project.self, from: Data(contentsOf: projectFile(folder)))
    }

    static func save(_ p: Project, to folder: URL) throws {
        try encoder.encode(p).write(to: projectFile(folder), options: .atomic)
    }

    static func list() -> [ProjectSummary] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let p = try? load(d) else { return nil }
            return ProjectSummary(folder: d, name: p.name, created: p.created, clips: p.clips.count,
                                  duration: p.masterDuration, stage: p.stage)
        }.sorted { $0.created > $1.created }
    }

    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mts"]
    static let audioExts: Set<String> = ["wav", "aif", "aiff", "m4a", "mp3", "caf", "flac", "aac"]

    static func create(name: String, files: [URL]) throws -> URL {
        let videos = files.filter { videoExts.contains($0.pathExtension.lowercased()) }.prefix(4)
        let audios = files.filter { audioExts.contains($0.pathExtension.lowercased()) }.prefix(4)
        guard !videos.isEmpty else { throw ClipsError("Add at least one video file (.mov or .mp4).") }
        let folder = projectsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let letters = ["A", "B", "C", "D"]
        var sources = videos.enumerated().map { i, u in AngleSource(name: "Angle \(letters[i])", path: u.path) }
        sources += audios.enumerated().map { i, u in AngleSource(name: "Mic \(i + 1)", path: u.path, isVideo: false) }
        var p = Project(name: name, angles: sources)
        p.language = UserDefaults.standard.string(forKey: "language") ?? "en-US"
        if let st = defaultCaptionStyle { p.captionStyle = st }
        try save(p, to: folder)
        return folder
    }

    // MARK: Caption presets (shared by all projects)

    struct PresetFile: Codable {
        var presets: [CaptionPreset] = []
        var defaultName: String? = nil
    }
    static var presetsURL: URL { supportDir.appendingPathComponent("caption-presets.json") }
    static func loadPresets() -> PresetFile {
        guard let d = try? Data(contentsOf: presetsURL), let f = try? decoder.decode(PresetFile.self, from: d) else { return PresetFile() }
        return f
    }
    static func savePresets(_ f: PresetFile) {
        try? encoder.encode(f).write(to: presetsURL, options: .atomic)
    }
    static var defaultCaptionStyle: CaptionStyle? {
        let f = loadPresets()
        guard let n = f.defaultName else { return nil }
        return f.presets.first { $0.name == n }?.style
    }

    @discardableResult
    static func delete(_ folder: URL) -> Bool {
        (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) != nil
    }

    // envelopes are small: keep them for re-running speaker detection
    static func saveEnvelope(_ env: [Float], folder: URL, angle: Int) {
        let d = env.withUnsafeBufferPointer { Data(buffer: $0) }
        try? d.write(to: cacheDir(folder).appendingPathComponent("env-\(angle).bin"))
    }
    static func loadEnvelope(folder: URL, angle: Int) -> [Float]? {
        guard let d = try? Data(contentsOf: cacheDir(folder).appendingPathComponent("env-\(angle).bin")) else { return nil }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
