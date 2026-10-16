import Foundation

/// `Clips2 --mcp`: the MCP server Claude starts (stdio, one JSON-RPC message per line).
/// It only describes the tools; each tool call is passed to the running app over the control socket
/// (ControlClient starts Clips 2 in the background if it isn't open).
enum MCPServer {

    static let version = "0.4"

    static var instructions: String {
        """
        Winnow is a Mac app for cutting short clips out of multicam recordings (2–4 synced cameras A/B/C/D plus separate mics), \
        with automatic camera switching by speaker, styled captions and a Final Cut-style timeline.
        Times: clip start/end, transcript times and "recording" times are seconds in the full synced recording; \
        caption times and the playhead inside a clip are seconds into the finished clip.
        When Claude starts Winnow it runs with no window or Dock icon; everything works the same. \
        You have your own open project, separate from the one in the person's window: project.open never changes their window. \
        If you open the project that's in their window you share it live (one copy, one undo history); then avoid clip.select, \
        playhead.seek and transport.*, which move their view. Your own project makes no sound. \
        command_run app.show opens your project in a "Claude's Project" window (or the main window when you share it); app.hide closes the windows. \
        With no window and no requests for 15 minutes it quits, so a later call may find no project open: run project.open again.
        Start with project_inspect (it lists projects if you have none open, and says which one is in the person's window). command_list shows every command with its parameters; \
        command_run runs one, command_batch several. Edits are one Undo step each (edit.undo).
        Edits work on any clip ("clip": number, id or title; default the one showing) without changing what's on screen.
        To find clips: read transcript_read, pick complete standalone moments (strong opening line, one idea, clean ending),         then add them all at once with command_run clip.createMany. Check a clip's captions with clip_inspect; \
        fix them with caption.setText / caption.setTexts (by caption number), caption.split / join / retime, \
        and a misheard name everywhere with text.replace. caption.style changes the look for the whole project.
        camera.set and sound.set take from/to (recording seconds) to change exactly one stretch. clip_inspect lists the clip's shots \
        (one camera between cuts); framing.set with shot: <seconds inside it> frames that one shot on its own (when someone moves).
        render_frame shows a frame exactly as it will export, so check your changes with it. \
        export.video / export.audio / export.srt export clips (also "used" for every clip marked used) in the background; export.status follows them.
        """
    }

    static func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    static var tools: [[String: Any]] {
        let clipRef: [String: Any] = ["type": ["integer", "string"], "description": "Clip number in the list (1 = first), its id, or its title."]
        return [
            tool("project_list", "Every Winnow project on this Mac: number, id, name, clip count, length in seconds, stage, and which one is open."),
            tool("project_inspect", "The open project as JSON: sources (cameras and mics, sync), speakers and their cameras, markers, caption style, every clip (number, id, title, used/rejected mark, start/end in recording seconds, length, format, Claude's note and score) and the app state (what's showing, playhead, playing, busy, undo). With no project open it returns the project list."),
            tool("clip_inspect", "One clip in detail: kept stretches and timeline blocks, camera switches, what you hear, framing per camera, and every caption (text, start/end in the finished clip, hand-edited or automatic). Defaults to the clip showing now.",
                 ["clip": clipRef]),
            tool("transcript_read", "The transcript as lines \"[start–end] Speaker: words\" (seconds in the full recording). Optionally limited to a time range or to one clip's stretch.",
                 ["from": ["type": "number", "description": "Start, seconds in the recording."],
                  "to": ["type": "number", "description": "End, seconds in the recording."],
                  "clip": clipRef]),
            tool("render_frame", "A frame of a clip as an image, drawn exactly as the export will look (picture, framing, camera choice and captions). Use it to check a clip after changing it.",
                 ["clip": ["type": ["integer", "string"], "description": "Clip number (1 = first), id or title; \"full\" for the full recording. Default: the clip showing."] as [String: Any],
                  "seconds": ["type": "number", "description": "Seconds into the clip (default: the playhead if that clip is showing, else 0)."],
                  "recording": ["type": "boolean", "description": "true = seconds are recording time instead."],
                  "captions": ["type": "boolean", "description": "Draw the captions (default true)."],
                  "max_side": ["type": "integer", "description": "Longest side in pixels (default 960)."]]),
            tool("command_list", "Every command (id, label, where it is in the app, shortcut, parameters, whether it changes the project, whether it can run right now).",
                 ["filter": ["type": "string", "description": "Only commands whose id or label contains this text."],
                  "enabled_only": ["type": "boolean", "description": "Only commands that can run right now."]]),
            tool("command_run", "Run one command by id with its parameters, e.g. {\"id\":\"clip.select\",\"params\":{\"clip\":3}}. Returns the result and the app state afterwards.",
                 ["id": ["type": "string", "description": "Command id from command_list, e.g. clip.select, playhead.seek, edit.undo."],
                  "params": ["type": "object", "description": "Parameters (see command_list)."]],
                 required: ["id"]),
            tool("command_batch", "Run several commands in order. Stops at the first failure unless stop_on_error is false.",
                 ["commands": ["type": "array", "description": "[{\"id\": …, \"params\": {…}}, …]",
                               "items": ["type": "object", "properties": ["id": ["type": "string"], "params": ["type": "object"]] as [String: Any],
                                         "required": ["id"]] as [String: Any]] as [String: Any],
                  "stop_on_error": ["type": "boolean"]],
                 required: ["commands"]),
        ]
    }

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let input = LineReader(fd: 0)
        while let line = input.next() {
            guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            guard let id = msg["id"], !(id is NSNull) else { continue }      // notifications need no answer
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
            switch method {
            case "initialize":
                reply["result"] = [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "clips", "title": "Winnow", "version": version],
                    "instructions": instructions,
                ] as [String: Any]
            case "ping":
                reply["result"] = [String: Any]()
            case "tools/list":
                reply["result"] = ["tools": tools]
            case "tools/call":
                reply["result"] = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            default:
                reply["error"] = ["code": -32601, "message": "Method not found: \(method)"] as [String: Any]
            }
            writeAll(1, jsonLine(reply) + Data([0x0A]))
        }
        exit(0)
    }

    static func text(_ s: String, error: Bool = false) -> [String: Any] {
        var r: [String: Any] = ["content": [["type": "text", "text": s]]]
        if error { r["isError"] = true }
        return r
    }

    static func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        guard tools.contains(where: { $0["name"] as? String == name }) else { return text("Unknown tool \(name).", error: true) }
        do {
            let r = try ControlClient.request(name, args)
            guard r["ok"] as? Bool == true else { return text(r["error"] as? String ?? "Winnow couldn't do that.", error: true) }
            if let img = r["image"] as? String {
                var content: [[String: Any]] = [["type": "image", "data": img, "mimeType": r["mime"] as? String ?? "image/jpeg"]]
                if let t = r["text"] as? String { content.append(["type": "text", "text": t]) }
                return ["content": content]
            }
            return text(r["text"] as? String ?? "done")
        } catch {
            return text("\(error)", error: true)
        }
    }
}
