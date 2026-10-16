import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var targeted = false
    @State private var renaming: ProjectSummary? = nil
    @State private var newName = ""
    @State private var selection: Set<URL> = []
    @State private var toDelete: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(Brand.name).font(.system(size: 26, weight: .bold))
                Spacer()
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)

            dropZone.padding(.horizontal, 28)

            if !app.projects.isEmpty {
                HStack(spacing: 10) {
                    Text("Your projects").font(.headline)
                    Spacer()
                    if !selection.isEmpty {
                        Text("\(selection.count) selected").font(.callout).foregroundStyle(.secondary)
                        Button("Deselect") { selection = [] }.buttonStyle(.borderless)
                        Button(role: .destructive) { askToDelete(Array(selection)) } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                        .help("Move the selected projects to the Trash (Delete key)")
                    } else if app.projects.count > 1 {
                        Text("⌘-click or ⇧-click to select several").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 24)
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 6)
                List(selection: $selection) {
                    ForEach(app.projects) { p in
                        HStack(spacing: 14) {
                            Image(systemName: "film.stack").font(.title2).foregroundStyle(Brand.green)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(p.name).font(.body.weight(.semibold))
                                    if app.claude?.folder == p.folder {
                                        Label("Claude is working on this", systemImage: "sparkles")
                                            .font(.caption).foregroundStyle(Brand.gold)
                                            .help("Claude has this project open. Open it to work on it together: you'll see each other's edits live.")
                                    }
                                }
                                Text("\(p.created.formatted(date: .abbreviated, time: .shortened))  ·  \(fmtTime(p.duration))  ·  \(p.clips) clip\(p.clips == 1 ? "" : "s")\(p.stage == .transcribed ? "" : "  ·  not finished analysing")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { newName = p.name; renaming = p } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Rename")
                            Button("Open") { app.open(p.folder) }
                        }
                        .padding(.vertical, 4)
                        .tag(p.folder)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: URL.self) { picked in
                    let ps = app.projects.filter { picked.contains($0.folder) }
                    if ps.count == 1, let p = ps.first {
                        Button("Open") { app.open(p.folder) }
                        Button("Rename…") { newName = p.name; renaming = p }
                        Button("Show project folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.folder]) }
                        Divider()
                        Button("Move to Trash", role: .destructive) { askToDelete([p.folder]) }
                    } else if ps.count > 1 {
                        Button("Show \(ps.count) project folders in Finder") { NSWorkspace.shared.activateFileViewerSelecting(ps.map(\.folder)) }
                        Divider()
                        Button("Move \(ps.count) Projects to Trash", role: .destructive) { askToDelete(ps.map(\.folder)) }
                    }
                } primaryAction: { picked in
                    // double-click or Return opens (only makes sense for one project)
                    if picked.count == 1, let f = picked.first { app.open(f) }
                }
                .onDeleteCommand { if !selection.isEmpty { askToDelete(Array(selection)) } }
            } else {
                Spacer()
            }
        }
        .onChange(of: app.projects) { _, list in
            // drop selections of projects that are gone
            let ids = Set(list.map(\.folder))
            selection = selection.intersection(ids)
        }
        .alert("Rename project", isPresented: renameAlert) {
            TextField("Project name", text: $newName)
            Button("Rename") { if let r = renaming { app.rename(r.folder, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("This is also the name of the folder exports are suggested in.") }
        .confirmationDialog(deleteTitle, isPresented: deleteAlert) {
            Button(toDelete.count == 1 ? "Move to Trash" : "Move \(toDelete.count) to Trash", role: .destructive) {
                app.delete(toDelete)
                selection.subtract(toDelete)
                toDelete = []
            }
            Button("Cancel", role: .cancel) { toDelete = [] }
        } message: {
            Text("Your camera and audio files aren't touched. Only Winnow's project (clips, captions and edits) goes to the Trash, so you can still put it back from there.")
        }
    }

    func askToDelete(_ folders: [URL]) {
        guard !folders.isEmpty else { return }
        // keep the list order so the dialog names them as they appear
        toDelete = app.projects.map(\.folder).filter { folders.contains($0) }
    }

    var deleteTitle: String {
        if toDelete.count == 1, let p = app.projects.first(where: { $0.folder == toDelete[0] }) {
            return "Move \u{201C}\(p.name)\u{201D} to the Trash?"
        }
        return "Move \(toDelete.count) projects to the Trash?"
    }

    var deleteAlert: Binding<Bool> { Binding(get: { !toDelete.isEmpty }, set: { if !$0 { toDelete = [] } }) }

    var renameAlert: Binding<Bool> { Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }) }

    var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 38)).foregroundStyle(Brand.green)
            Text("Drop your camera and audio files here").font(.title3.weight(.semibold))
            Text("Your camera angles (up to four), plus any separate audio recordings like lav or recorder files (up to four). Winnow lines them all up, transcribes everyone, and works out who's talking.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Choose Files…") {
                let p = NSOpenPanel()
                p.allowsMultipleSelection = true
                p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
                if p.runModal() == .OK { app.create(files: p.urls) }
            }
            .buttonStyle(.borderedProminent).tint(Brand.green).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Brand.green.opacity(0.12) : Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            .foregroundStyle(targeted ? Brand.green : Color.secondary.opacity(0.4)))
        .dropDestination(for: URL.self) { urls, _ in
            app.create(files: urls); return true
        } isTargeted: { targeted = $0 }
    }
}
