import BetterWMCore
import Cocoa

/// Checks GitHub Releases for a newer version and, if allowed, installs it: download the zip, verify the
/// signature, swap the bundle, relaunch. A dev build never installs anything; it only points at the release page.
final class Updater {
    static let repo = "nanot1m/better-win-manager"
    var config: Config { didSet { schedule() } }
    private var timer: Timer?
    private var busy = false

    struct Release {
        let version: String
        let page: URL
        let zip: URL?
        let notes: String
    }

    init(config: Config) {
        self.config = config
        schedule()
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    var isDevBuild: Bool { currentVersion == "dev" }

    /// Once a day while the app runs, the first time half a minute after launch so startup stays quick. A dev
    /// build is always "older" than the latest release, so it only checks when asked.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard config.checkForUpdates, !isDevBuild else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check(interactive: false) }
        let last = UserDefaults.standard.object(forKey: "updates.lastCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 23 * 3600 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check(interactive: false) }
        }
    }

    /// `interactive`: the user asked, so "you are up to date" and errors are shown too.
    func check(interactive: Bool) {
        guard !busy else { return }
        busy = true
        UserDefaults.standard.set(Date(), forKey: "updates.lastCheck")
        fetchLatest { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case let .failure(error):
                Log.write("update", "check failed: \(error.localizedDescription)")
                if interactive { self.alert("Could not check for updates", error.localizedDescription, buttons: ["OK"]) }
            case let .success(release):
                Log.write("update", "latest \(release.version), running \(self.currentVersion)")
                guard Version.isNewer(release.version, than: self.currentVersion) else {
                    if interactive { self.alert("BetterWM is up to date", "You are running \(self.currentVersion).", buttons: ["OK"]) }
                    return
                }
                let skipped = UserDefaults.standard.string(forKey: "updates.skipped")
                if !interactive, skipped == release.version { return }
                if !interactive, self.config.autoUpdate, !self.isDevBuild, release.zip != nil {
                    self.install(release, quiet: true)
                } else {
                    self.offer(release)
                }
            }
        }
    }

    private func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("BetterWM/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let result: Result<Release, Error>
            if let error {
                result = .failure(error)
            } else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String, let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                    .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
                result = .success(Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, zip: zip,
                                          notes: json["body"] as? String ?? ""))
            } else {
                result = .failure(NSError(domain: "BetterWM.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected answer from GitHub."]))
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    private func offer(_ r: Release) {
        let canInstall = !isDevBuild && r.zip != nil
        let notes = r.notes.split(separator: "\n").prefix(12).joined(separator: "\n")
        let choice = alert("BetterWM \(r.version) is available",
                           "You are running \(currentVersion).\(notes.isEmpty ? "" : "\n\n\(notes)")",
                           buttons: canInstall ? ["Install and Relaunch", "Release Page", "Skip This Version", "Later"]
                                               : ["Release Page", "Skip This Version", "Later"])
        switch (canInstall, choice) {
        case (true, 0): install(r, quiet: false)
        case (true, 1), (false, 0): NSWorkspace.shared.open(r.page)
        case (true, 2), (false, 1): UserDefaults.standard.set(r.version, forKey: "updates.skipped")
        default: break
        }
    }

    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String]) -> Int {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Download, unpack, verify, swap in place of the running bundle, relaunch. `quiet` installs without asking
    /// (the auto-update setting); a failure is logged and, when not quiet, shown.
    private func install(_ r: Release, quiet: Bool) {
        guard let zip = r.zip, !busy else { return }
        busy = true
        Log.write("update", "installing \(r.version) from \(zip)")
        URLSession.shared.downloadTask(with: zip) { [weak self] tmp, _, error in
            guard let self else { return }
            let outcome: Result<URL, Error>
            if let tmp { outcome = Result { try self.unpackAndVerify(tmp) } }
            else { outcome = .failure(error ?? NSError(domain: "BetterWM.Updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download failed."])) }
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case let .failure(e):
                    Log.write("update", "install failed: \(e.localizedDescription)")
                    if !quiet { self.alert("Could not install the update", e.localizedDescription, buttons: ["OK"]) }
                case let .success(newApp):
                    do {
                        try self.swap(in: newApp)
                        Log.write("update", "installed \(r.version); relaunching")
                        self.relaunch()
                    } catch {
                        Log.write("update", "swap failed: \(error.localizedDescription)")
                        if !quiet { self.alert("Could not install the update", error.localizedDescription, buttons: ["OK"]) }
                    }
                }
            }
        }.resume()
    }

    private func unpackAndVerify(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("betterwm-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "BetterWM.Updater", code: 3, userInfo: [NSLocalizedDescriptionKey: "The download holds no app."])
        }
        // Only a properly signed and notarized bundle replaces the running one.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/sbin/spctl", ["--assess", "--type", "exec", app.path])
        return app
    }

    private func swap(in newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let old = current.deletingLastPathComponent().appendingPathComponent(".BetterWM-old.app")
        try? FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: current, to: old)
        do {
            try FileManager.default.moveItem(at: newApp, to: current)
        } catch {
            try? FileManager.default.moveItem(at: old, to: current)
            throw error
        }
        try? FileManager.default.removeItem(at: old)
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "BetterWM.Updater", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(msg)"])
        }
    }
}
