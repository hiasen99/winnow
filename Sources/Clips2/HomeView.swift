import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var targeted = false
    @State private var renaming: ProjectSummary? = nil
    @State private var newName = ""

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
                Text("Your projects").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 6)
                List {
                    ForEach(app.projects) { p in
                        HStack(spacing: 14) {
                            Image(systemName: "film.stack").font(.title2).foregroundStyle(Brand.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body.weight(.semibold))
                                Text("\(p.created.formatted(date: .abbreviated, time: .shortened))  ·  \(fmtTime(p.duration))  ·  \(p.clips) clip\(p.clips == 1 ? "" : "s")\(p.stage == .transcribed ? "" : "  ·  not finished analysing")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { newName = p.name; renaming = p } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Rename")
                            Button("Open") { app.open(p.folder) }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { app.open(p.folder) }
                        .contextMenu {
                            Button("Open") { app.open(p.folder) }
                            Button("Rename…") { newName = p.name; renaming = p }
                            Button("Show project folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.folder]) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { Store.delete(p.folder); app.refresh() }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }
        }
        .alert("Rename project", isPresented: renameAlert) {
            TextField("Project name", text: $newName)
            Button("Rename") { if let r = renaming { app.rename(r.folder, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("This is also the name of the folder exports are suggested in.") }
    }

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
