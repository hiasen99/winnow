import Foundation

/// Going through the clip list: which clips the list shows, next / previous clip, and U / X that move on.
extension ProjectModel {
    /// The clip list's filter (the sidebar stores it as "clipFilter").
    static var clipFilter: String { UserDefaults.standard.string(forKey: "clipFilter") ?? "all" }

    static func clipShown(_ c: Clip, filter: String) -> Bool {
        switch filter {
        case "hideRejected": return c.status != .rejected
        case "unmarked": return c.status == nil
        case "used": return c.status == .used
        case "rejected": return c.status == .rejected
        default: return true
        }
    }

    /// The next (or previous) clip the list shows, counted from `id` in list order.
    func adjacentClip(to id: UUID?, next: Bool) -> Clip? {
        let f = Self.clipFilter
        let all = project.clips
        guard let id, let k = all.firstIndex(where: { $0.id == id }) else {
            let shown = all.filter { Self.clipShown($0, filter: f) }
            return next ? shown.first : shown.last
        }
        if next { return all[(k + 1)...].first { Self.clipShown($0, filter: f) } }
        return all[..<k].last { Self.clipShown($0, filter: f) }
    }

    func selectAdjacentClip(next: Bool) {
        if let c = adjacentClip(to: selectedClipID, next: next) { select(clip: c.id) }
    }

    /// U / X: mark the clip (or clear the mark if it already has it). Marking moves on to the next clip.
    func markAndAdvance(_ s: ClipStatus) {
        guard let id = selectedClipID, let c = project.clips.first(where: { $0.id == id }) else { return }
        let marking = c.status != s
        toggleStatus(s, for: id)
        guard marking else { return }
        if let n = adjacentClip(to: id, next: true) {
            select(clip: n.id)
        } else {
            notice = "That was the last clip in the list."
        }
    }
}
