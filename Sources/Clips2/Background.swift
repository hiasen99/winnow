import AppKit
import SwiftUI

/// Winnow can run with no window and no Dock icon:
///  • when Claude's MCP connection starts it (`open -g -b … --args --background`), and
///  • when the window is closed while Claude is using it (recent request, or an export running).
/// Opening Winnow the usual way (Finder, Dock, Spotlight) or the app.show command brings the window
/// back on whatever project is open. With no window and nothing asked of it for a while, it quits.
@MainActor
enum Background {
    static let idleMinutes: Double = 15
    /// Last time anything came in over the control socket (set by ControlServer).
    static var lastRequest = Date.distantPast
    /// SwiftUI's own "open a window" action, saved the first time a window appears.
    static var openWindowByID: ((String) -> Void)? = nil
    /// The window showing Claude's own project (when it's open).
    static weak var claudeWindow: NSWindow? = nil
    private static var timer: Timer? = nil
    private static var launchQuietUntil = Date.distantPast

    static var mainWindows: [NSWindow] { NSApp.windows.filter { $0.isVisible && $0.canBecomeMain } }
    static var hasWindow: Bool { !mainWindows.isEmpty }
    /// Visible windows other than Claude's project window.
    static var primaryWindows: [NSWindow] { mainWindows.filter { $0 !== claudeWindow } }
    static var claudeWindowShowing: Bool { claudeWindow?.isVisible == true }
    static var anyBusy: Bool {
        guard let app = AppState.shared else { return false }
        return app.current?.busy != nil || app.claude?.busy != nil
    }
    static var isBackground: Bool { NSApp.activationPolicy() != .regular }
    static var inLaunchQuiet: Bool { Date() < launchQuietUntil }
    /// Has been running with no window by design at some point (started for Claude, or window closed while Claude was using it).
    private(set) static var everBackground = false

    /// macOS quits windowless apps on its own ("automatic termination"); hold that off while running for Claude.
    private static var holdingOff = false
    private static func holdOffAutoQuit(_ on: Bool) {
        guard on != holdingOff else { return }
        holdingOff = on
        if on { ProcessInfo.processInfo.disableAutomaticTermination("Winnow is running for Claude") }
        else { ProcessInfo.processInfo.enableAutomaticTermination("Winnow is running for Claude") }
    }

    /// Running with no window while Claude is using it (asked something in the last 10 minutes, or work going on).
    static var inUseWithoutWindow: Bool {
        guard everBackground, !hasWindow else { return false }
        return Date().timeIntervalSince(lastRequest) < 10 * 60 || Control.exportQueued > 0 || anyBusy
    }

    /// Launched for Claude: stay out of sight.
    static func launched() {
        Log.write("background: started with no window (for Claude)")
        everBackground = true
        holdOffAutoQuit(true)
        launchQuietUntil = Date().addingTimeInterval(2)
        // in case macOS restores a window, or SwiftUI opens one anyway
        for delay in [0.1, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isBackground else { return }
                for w in mainWindows { w.close() }
            }
        }
        startTimer()
    }

    /// Called as the last window closes. true = quit like before; false = keep running out of sight.
    static func shouldQuitWhenWindowCloses() -> Bool {
        let recent = Date().timeIntervalSince(lastRequest) < 10 * 60
        guard AppDelegate.launchedInBackground || recent || Control.exportQueued > 0 else { return true }
        goBackground()
        return false
    }

    static func goBackground(_ why: String = "window closed") {
        for m in [AppState.shared?.current, AppState.shared?.claude].compactMap({ $0 }) { m.engine.pause(); m.saveNow() }
        if !isBackground { NSApp.setActivationPolicy(.accessory) }
        everBackground = true
        holdOffAutoQuit(true)
        Log.write("background: \(why), still running for Claude")
        startTimer()
    }

    /// A window appeared: become a normal app again (Dock icon, menu bar).
    static func windowAppeared() {
        Log.write("window: appeared")
        if !(AppDelegate.launchedInBackground && inLaunchQuiet) { holdOffAutoQuit(false) }
        if AppDelegate.launchedInBackground && Date() < launchQuietUntil && isBackground { return }
        guard isBackground else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.write("background: window opened")
    }

    /// Bring the window up (app.show, or Winnow opened again by the person).
    static func show() {
        launchQuietUntil = .distantPast
        if isBackground { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let w = primaryWindows.first { w.makeKeyAndOrderFront(nil); return }
        ensureWindow()
    }

    /// Bring up the window with Claude's own project (app.show while Claude works on a different project).
    static func showClaude() {
        launchQuietUntil = .distantPast
        if isBackground { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let w = claudeWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        openWindowByID?("claude")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !claudeWindowShowing else { return }
            if let (menu, i) = menuItem(in: NSApp.mainMenu, where: { $0.title == ClaudeWindowRoot.title }) {
                menu.performActionForItem(at: i); Log.write("background: opened Claude's window (Window menu)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard !claudeWindowShowing else { return }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1383, height: 868),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                w.title = ClaudeWindowRoot.title
                w.isReleasedWhenClosed = false
                w.contentView = NSHostingView(rootView: ClaudeWindowRoot().environmentObject(AppState.main)
                    .frame(minWidth: 1100, minHeight: 720).tint(Brand.green))
                w.center(); w.makeKeyAndOrderFront(nil)
                fallbackClaudeWindow = w
                Log.write("background: opened Claude's window (plain fallback)")
            }
        }
    }
    private static var fallbackClaudeWindow: NSWindow? = nil

    static func menuItem(in menu: NSMenu?, where test: (NSMenuItem) -> Bool) -> (NSMenu, Int)? {
        guard let menu else { return nil }
        for (i, it) in menu.items.enumerated() {
            if test(it) { return (menu, i) }
            if let hit = menuItem(in: it.submenu, where: test) { return hit }
        }
        return nil
    }

    private static var lastEnsure = Date.distantPast
    /// Make a window if there isn't one. SwiftUI doesn't make one by itself when Winnow was started with
    /// no window, so use its own "open window" action if we have it, else its File ▸ New Window item.
    static func ensureWindow() {
        guard primaryWindows.isEmpty, Date().timeIntervalSince(lastEnsure) > 1.5 else { return }
        lastEnsure = Date()
        if let open = openWindowByID {
            open("main"); Log.write("background: opened a window (openWindow)"); return
        }
        if let (menu, i) = newWindowItem(in: NSApp.mainMenu) {
            menu.performActionForItem(at: i); Log.write("background: opened a window (\(menu.items[i].title))"); return
        }
        // last resort: a plain window holding the same view
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1383, height: 868),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = Brand.name
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: RootView().environmentObject(AppState.main)
            .frame(minWidth: 1100, minHeight: 720).tint(Brand.green))
        w.center()
        w.makeKeyAndOrderFront(nil)
        fallbackWindow = w
        Log.write("background: opened a window (plain fallback)")
    }
    private static var fallbackWindow: NSWindow? = nil

    /// SwiftUI's "New Winnow Window" (⌘N) menu item.
    private static func newWindowItem(in menu: NSMenu?) -> (NSMenu, Int)? {
        guard let menu else { return nil }
        for (i, it) in menu.items.enumerated() {
            if it.keyEquivalent == "n", it.keyEquivalentModifierMask == [.command], it.title.hasPrefix("New") { return (menu, i) }
            if let hit = newWindowItem(in: it.submenu) { return hit }
        }
        return nil
    }

    /// Winnow was opened again (Finder, Dock, Spotlight) or became active with no window.
    static func reopened() {
        // only when Winnow has been running windowless on purpose; a normal launch makes its own window
        guard everBackground, !hasWindow, !inLaunchQuiet else { return }
        if isBackground { NSApp.setActivationPolicy(.regular) }
        // give SwiftUI a moment in case it makes a window itself
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ensureWindow() }
    }

    /// Close the window but keep running (app.hide).
    static func hide() {
        let ws = mainWindows
        if ws.isEmpty { goBackground("hide asked with no window open"); return }
        lastRequest = Date()          // so closing the last window keeps Winnow running
        for w in ws { w.close() }
    }

    private static func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    private static func tick() {
        guard isBackground, !hasWindow else { return }
        if Control.exportQueued > 0 { return }
        if anyBusy { return }      // still syncing / transcribing
        guard Date().timeIntervalSince(lastRequest) > idleMinutes * 60 else { return }
        Log.write("background: no window and nothing asked for \(Int(idleMinutes)) min, quitting")
        AppState.shared?.close()
        AppState.shared?.closeClaude()
        NSApp.terminate(nil)
    }
}
