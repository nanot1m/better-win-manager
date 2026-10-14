import Foundation

struct Config: Codable {
    var gap: CGFloat = 16
    var outerGap: CGFloat = 16
    var handleWidth: CGFloat = 16

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/betterwm/config.json")

    static func load() -> Config {
        if let data = try? Data(contentsOf: path),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = Config()
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(cfg).write(to: path)
        return cfg
    }
}
