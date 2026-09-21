import Foundation

// 读取 / 落地 config.json。位置:~/.config/usage-bar/config.json。
// 文件不存在时写入默认配置,方便用户后续编辑。
enum AppConfigStore {
    static var configURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar", isDirectory: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        let url = configURL
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        // 不存在或解析失败:写默认配置并返回。
        let def = AppConfig.default
        writeDefaultIfNeeded(def)
        return def
    }

    static func save(_ cfg: AppConfig) throws {
        let url = configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(cfg)
        try data.write(to: url, options: .atomic)
    }

    private static func writeDefaultIfNeeded(_ cfg: AppConfig) {
        let url = configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? save(cfg)
    }
}
