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
    private var timer: Timer?
    private let players = ["com.spotify.client", "com.apple.Music"]

    func start() {
        guard timer == nil else { return }
        Log.write("media", "polling Music/Spotify")
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
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
        timer?.invalidate(); timer = nil
        if current != nil { current = nil; onUpdate?(nil) }
    }

    private func poll() {
        // Nothing to ask (and no app to accidentally launch) when neither player is running.
        guard let running = NSWorkspace.shared.runningApplications.first(where: { players.contains($0.bundleIdentifier ?? "") }),
              let bundle = running.bundleIdentifier, let script = script(for: bundle) else {
            if current != nil { current = nil; onUpdate?(nil) }
            return
        }
        // NSAppleScript is main-thread only; a poll takes tens of milliseconds and runs every few seconds.
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
        // Refresh soon; players take a moment to flip state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.poll() }
    }
}
