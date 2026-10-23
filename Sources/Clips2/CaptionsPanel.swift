import SwiftUI
import AppKit

/// Right-hand column inside a clip: the clip's captions, one row per caption. Type to fix one;
/// re-time them on the timeline. Replaces editing the video by its transcript.
struct CaptionsPanel: View {
    @ObservedObject var model: ProjectModel
    @Binding var showStyle: Bool
    @State private var currentID: UUID? = nil
    @State private var presets = Store.loadPresets()

    var body: some View {
        let items = model.captionItems
        VStack(spacing: 0) {
            header(items)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "captions.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(model.project.words.isEmpty ? "No transcript yet, so no captions." : "No speech in this clip.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(items) { it in
                                CaptionRow(model: model, item: it, isCurrent: it.id == currentID,
                                           isSelected: it.id == model.selectedCaption)
                                    .id(it.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: currentID) { _, id in
                        if model.engine.isPlaying, let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onChange(of: model.selectedCaption) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .background(CaptionClock(engine: model.engine, items: items, current: $currentID))
    }

    @ViewBuilder func header(_ items: [CaptionItem]) -> some View {
        let clip = model.selectedClip
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Captions").font(.headline)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                if model.captionsEdited {
                    Text("edited").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.2), in: Capsule())
                        .help("Some captions were edited by hand. Words added to the clip later still get automatic captions.")
                }
                Spacer()
                if clip?.captions == false {
                    Text("not burned in").font(.caption2).foregroundStyle(.secondary)
                        .help("This clip exports without captions on the picture. Change it in the Export window.")
                }
            }
            HStack(spacing: 8) {
                Menu {
                    Section("Built in") {
                        ForEach(CaptionStyleSheet.builtIns, id: \.name) { p in Button(p.name) { model.setCaptionStyle(p.style) } }
                    }
                    if !presets.presets.isEmpty {
                        Section("My presets") {
                            ForEach(presets.presets) { p in Button(p.name) { model.setCaptionStyle(p.style) } }
                        }
                    }
                } label: { Label("Look", systemImage: "paintpalette") }
                .fixedSize()
                .help("Pick a caption look")
                .onAppear { presets = Store.loadPresets() }
                Button { showStyle = true } label: { Label("Style…", systemImage: "textformat") }
                    .help("Font, colours, word animation, size and position")
                BrandMenu(model: model)
                Spacer()
                Button { model.splitCaptionAtPlayhead() } label: { Image(systemName: "scissors") }
                    .help("Split the caption under the playhead")
                Menu {
                    Button("Split caption at playhead") { model.splitCaptionAtPlayhead() }
                    Divider()
                    Button("Reset all captions to the transcript") { model.resetCaptions() }
                        .disabled(!model.captionsEdited)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More caption actions: split, or reset every caption to the transcript")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Watches the playhead and reports which caption is on screen, without redrawing the whole list 30 times a second.
private struct CaptionClock: View {
    @ObservedObject var engine: PlayerEngine
    var items: [CaptionItem]
    @Binding var current: UUID?
    var body: some View {
        Color.clear
            .onChange(of: engine.time) { _, t in update(t) }
            .onAppear { update(engine.time) }
    }
    func update(_ t: Double) {
        let id = items.last(where: { $0.start <= t + 0.001 && t < $0.end })?.id
        if id != current { current = id }
    }
}

struct CaptionRow: View {
    @ObservedObject var model: ProjectModel
    var item: CaptionItem
    var isCurrent: Bool
    var isSelected: Bool
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { pick() } label: {
                Text(fmtTime(item.start, frac: true)).font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Brand.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 50, alignment: .leading)
            .help("Jump here")
            TextField(item.text.isEmpty ? "No caption here — type to add one" : "Caption", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { commit(); focused = false }
                .onExitCommand { draft = item.text; focused = false }
            if hovering || isSelected {
                Menu {
                    rowMenu
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.yellow.opacity(0.8) : .clear, lineWidth: 1.5))
        .onHover { hovering = $0 }
        .contextMenu { rowMenu }
        .onAppear { draft = item.text }
        .onChange(of: item.text) { _, t in if !focused { draft = t } }
        .onChange(of: focused) { _, f in
            if f {
                model.selectedCaption = item.id
                model.engine.pause()
                if !(model.engine.time >= item.start && model.engine.time < item.end) { model.engine.seek(item.start) }
            } else { commit() }
        }
        .onChange(of: model.editingCaption) { _, id in takeFocusIfAsked(id) }
        .onAppear { takeFocusIfAsked(model.editingCaption) }
    }

    @ViewBuilder var rowMenu: some View {
        Button("Split at playhead") { model.splitCaption(item.id, atOutput: model.engine.time) }
            .disabled(!(model.engine.time > item.start + 0.1 && model.engine.time < item.end - 0.1))
        Button("Join with next caption") { model.joinCaptionWithNext(item.id) }
            .disabled(!model.canJoinNext(item.id))
        Divider()
        Button("Delete caption", role: .destructive) { model.deleteCaption(item.id) }
            .disabled(item.text.isEmpty)
    }

    var background: Color {
        if isCurrent { return Brand.green.opacity(0.14) }
        if item.text.isEmpty { return Color.primary.opacity(0.02) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }

    func pick() {
        model.selectedCaption = item.id
        model.engine.seek(item.start)
    }

    func takeFocusIfAsked(_ id: UUID?) {
        guard id == item.id else { return }
        focused = true
        DispatchQueue.main.async { model.editingCaption = nil }
    }

    func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if normalized != item.text { model.setCaptionText(item.id, normalized) }
    }
}
