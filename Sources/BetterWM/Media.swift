import Cocoa

/// Now-playing track from Music or Spotify (read through their scripting interfaces while they run) and a
/// play/pause control that presses the system media key, which reaches whatever app is playing.
/// MediaRemote itself is closed to unentitled processes on current macOS.
final class MediaService {
    struct NowPlaying: Equatable {
        var playing: Bool
        var title: String
        var artist: String
        var text: String { artist.isEmpty ? title : "\(title) — \(artist)" }
    }

    private(set) var current: NowPlaying?
    var onUpdate: ((NowPlaying?) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let players = ["com.spotify.client", "com.apple.Music"]

    /// Both players announce every play, pause and track change; launches and quits cover the rest.
    func start() {
        guard observers.isEmpty else { return }
        Log.write("media", "watching Music/Spotify")
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            observers.append((dnc, dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.poll() }))
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if let self, self.players.contains(app?.bundleIdentifier ?? "") { self.poll() }
            }))
        }
        poll()
    }

    /// One script per player, compiled on first use: a script naming an app that is not installed does not compile.
    private var scripts: [String: NSAppleScript] = [:]
    private func script(for bundleID: String) -> NSAppleScript? {
        if let s = scripts[bundleID] { return s }
        let name = bundleID == "com.spotify.client" ? "Spotify" : "Music"
        let src = """
        tell application "\(name)"
            if player state is stopped then return ""
            if player state is playing then
                set s to "playing"
            else
                set s to "paused"
            end if
            set t to name of current track
            set a to artist of current track
        end tell
        return s & "|" & t & "|" & a
        """
        var err: NSDictionary?
        guard let s = NSAppleScript(source: src), s.compileAndReturnError(&err) else { Log.write("media", "script for \(name) did not compile: \(err?[NSAppleScript.errorMessage] ?? "?")"); return nil }
        scripts[bundleID] = s
        return s
    }

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        if current != nil { current = nil; onUpdate?(nil) }
    }

    private func poll() {
        // Nothing to ask (and no app to accidentally launch) when neither player is running.
        guard let running = NSWorkspace.shared.runningApplications.first(where: { players.contains($0.bundleIdentifier ?? "") }),
              let bundle = running.bundleIdentifier, let script = script(for: bundle) else {
            if current != nil { current = nil; onUpdate?(nil) }
            return
        }
        // NSAppleScript is main-thread only; a poll takes tens of milliseconds.
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error).stringValue ?? ""
        if let error { Log.write("media", "script error: \(error[NSAppleScript.errorMessage] ?? error)") }
        let parts = out.components(separatedBy: "|")
        let np: NowPlaying? = parts.count >= 3 && !parts[1].isEmpty
            ? NowPlaying(playing: parts[0] == "playing", title: parts[1], artist: parts[2]) : nil
        guard np != current else { return }
        current = np
        onUpdate?(np)
    }

    /// Presses the system Play/Pause media key (NX_KEYTYPE_PLAY), which the frontmost or last-playing app handles.
    func togglePlayPause() {
        func press(_ down: Bool) {
            let flags: UInt = down ? 0xa00 : 0xb00
            let data1 = Int((16 << 16) | (down ? 0xa << 8 : 0xb << 8))
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                                 timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        press(true); press(false)
    }
}
