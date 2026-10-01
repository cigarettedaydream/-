import Foundation
import Observation

/// 识别历史记录：缓存成功识别到的歌曲，再次打开可直接进入歌词页，
/// 避免重复调用识曲接口（节省每日额度）。数据以 JSON 持久化到应用沙盒。
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    /// 最多保留的历史条数
    private let limit = 60

    private(set) var items: [MatchInfo] = []

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("recognition_history.json")
    }

    private init() {
        load()
    }

    // MARK: - 增删

    /// 记录一次识别成功。按“歌名+歌手”去重，新记录置顶。
    func record(_ info: MatchInfo) {
        let key = Self.dedupeKey(title: info.title, artist: info.artist)
        items.removeAll { Self.dedupeKey(title: $0.title, artist: $0.artist) == key }
        items.insert(info, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save()
    }

    func remove(_ info: MatchInfo) {
        items.removeAll { $0.id == info.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([MatchInfo].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[History] 保存失败: \(error.localizedDescription)")
        }
    }

    private static func dedupeKey(title: String, artist: String) -> String {
        (title + "|" + artist)
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                     locale: nil)
    }
}
