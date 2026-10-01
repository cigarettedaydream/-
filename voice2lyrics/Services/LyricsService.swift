import Foundation

/// 一行歌词：原文、中文翻译、假名、罗马音，以及（同步歌词时的）时间戳
struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// 该行开始的歌曲时间（秒）；纯文本歌词为 nil
    let time: TimeInterval?
    let text: String
    /// 中文翻译（来自网易云 tlyric，可能为空）
    let translation: String
    /// 平假名读音（按词以空格分隔，非日语为空）
    let kana: String
    /// 罗马音（按词以空格分隔，非日语为空）
    let romaji: String
}

/// 歌词抓取整体结果：逐行歌词 + 可选的专辑封面
struct LyricsResult: Sendable {
    let lines: [LyricLine]
    let artworkURL: URL?
}

enum LyricsError: LocalizedError {
    case notFound
    case network

    var errorDescription: String? {
        switch self {
        case .notFound: return "未找到这首歌的歌词"
        case .network: return "歌词服务暂时不可用"
        }
    }
}

/// 歌词来源
enum LyricsSource: String, CaseIterable, Identifiable {
    case lrclib
    case netease

    var id: String { rawValue }
    var label: String {
        switch self {
        case .lrclib: return "LRCLIB（全球曲库）"
        case .netease: return "网易云音乐"
        }
    }

    nonisolated static let storageKey = "lyrics_source"

    nonisolated static var current: LyricsSource {
        LyricsSource(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .netease
    }

    nonisolated static func save(_ source: LyricsSource) {
        UserDefaults.standard.set(source.rawValue, forKey: storageKey)
    }
}

/// 歌词获取：按设置里的来源在 LRCLIB / 网易云之间切换；当前来源无结果时自动回退到另一个来源。
/// 仅对含假名的（日语）歌词生成假名/罗马音，中文等其它语言只显示原文。
actor LyricsService {
    static let shared = LyricsService()

    // MARK: - 入口

    func lyrics(title: String, artist: String, album: String? = nil) async throws -> LyricsResult {
        let chosen = LyricsSource.current
        do {
            let result = try await fetch(from: chosen, title: title, artist: artist, album: album)
            return await buildResult(result)
        } catch {
            // 主来源失败 → 尝试另一个来源
            let fallback: LyricsSource = (chosen == .lrclib) ? .netease : .lrclib
            if let result = try? await fetch(from: fallback, title: title, artist: artist, album: album),
               !result.texts.isEmpty {
                return await buildResult(result)
            }
            throw error
        }
    }

    /// 一次歌词抓取的结果（三数组等长，按行对齐）
    private struct FetchedLyrics {
        var times: [TimeInterval?]
        var texts: [String]
        var translations: [String]
        var artworkURL: URL? = nil
    }

    private func fetch(from source: LyricsSource, title: String, artist: String, album: String?)
        async throws -> FetchedLyrics {
        switch source {
        case .lrclib: return try await fetchFromLrclib(title: title, artist: artist, album: album)
        case .netease: return try await fetchFromNetease(title: title, artist: artist, album: album)
        }
    }

    /// 对每行做假名/罗马音标注；非日语（不含假名）的行留空。
    private func buildResult(_ lyrics: FetchedLyrics) async -> LyricsResult {
        let annotations = await Romanizer.shared.annotations(for: lyrics.texts)
        let lines = lyrics.texts.indices.map { index in
            let isJapanese = containsKana(lyrics.texts[index])
            return LyricLine(
                id: index,
                time: lyrics.times[index],
                text: lyrics.texts[index],
                translation: index < lyrics.translations.count ? lyrics.translations[index] : "",
                kana: isJapanese ? annotations.kana[index] : "",
                romaji: isJapanese ? annotations.romaji[index] : ""
            )
        }
        return LyricsResult(lines: lines, artworkURL: lyrics.artworkURL)
    }

    // MARK: - LRCLIB

    private struct SearchEntry: Decodable {
        let trackName: String?
        let artistName: String?
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private func fetchFromLrclib(title: String, artist: String, album: String?) async throws -> FetchedLyrics {
        let entries = try await lrclibSearch(title: title, artist: artist, album: album)
        let withSynced = entries.filter { !($0.syncedLyrics ?? "").isEmpty }
        let withPlain = entries.filter { !($0.plainLyrics ?? "").isEmpty }
        guard let chosen = withSynced.first ?? withPlain.first else {
            throw LyricsError.notFound
        }

        var timed: [(TimeInterval, String)] = []
        if let synced = chosen.syncedLyrics, !synced.isEmpty {
            timed = Self.parseLRC(synced)
        }
        var plain: [String] = []
        if timed.isEmpty, let plainText = chosen.plainLyrics, !plainText.isEmpty {
            plain = plainText
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if timed.isEmpty && plain.isEmpty { throw LyricsError.notFound }

        if timed.isEmpty {
            return FetchedLyrics(times: Array(repeating: nil, count: plain.count),
                                 texts: plain,
                                 translations: Array(repeating: "", count: plain.count))
        }
        return FetchedLyrics(times: timed.map { $0.0 },
                             texts: timed.map { $0.1 },
                             translations: Array(repeating: "", count: timed.count))
    }

    private func lrclibSearch(title: String, artist: String, album: String?) async throws -> [SearchEntry] {
        var exactItems: [URLQueryItem] = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album, !album.isEmpty {
            exactItems.append(URLQueryItem(name: "album_name", value: album))
        }
        if let exact = try? await lrclibRequest(queryItems: exactItems), !exact.isEmpty {
            return exact
        }
        return try await lrclibRequest(queryItems: [
            URLQueryItem(name: "q", value: "\(artist) \(title)"),
        ])
    }

    private func lrclibRequest(queryItems: [URLQueryItem]) async throws -> [SearchEntry] {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = queryItems
        guard let url = components?.url else { throw LyricsError.network }
        var request = URLRequest(url: url)
        request.setValue("music-learning/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { throw LyricsError.network }
            return try JSONDecoder().decode([SearchEntry].self, from: data)
        } catch let error as LyricsError {
            throw error
        } catch {
            throw LyricsError.network
        }
    }

    // MARK: - 网易云音乐

    private struct NESearchResponse: Decodable {
        struct Song: Decodable {
            struct Artist: Decodable { let name: String? }
            struct Album: Decodable { let name: String? }
            let id: Int
            let name: String?
            let artists: [Artist]?
            let album: Album?
        }
        struct Result: Decodable { let songs: [Song]? }
        let result: Result?
    }

    private struct NELyricResponse: Decodable {
        struct Lrc: Decodable { let lyric: String? }
        let lrc: Lrc?
        let tlyric: Lrc?      // 翻译歌词（中文）
        let code: Int?
    }

    private func fetchFromNetease(title: String, artist: String, album: String?) async throws -> FetchedLyrics {
        let candidates = try await neteaseCandidates(title: title, artist: artist, album: album)
        guard !candidates.isEmpty else { throw LyricsError.notFound }

        // 优先尝试「歌手匹配」的候选（显著减少命中翻唱/同名曲）；都不行再尝试其余
        let ordered = candidates.filter { $0.artistMatch } + candidates.filter { !$0.artistMatch }

        for candidate in ordered {
            guard let raw = try? await neteaseLyric(id: candidate.id) else { continue }
            let original = Self.parseLRC(raw.original).filter { !Self.isCreditLine($0.1) }
            if original.count >= 3 {
                let translationByTime = Self.parseLRC(raw.translated)
                let translations = original.map { line in
                    Self.matchTranslation(lineTime: line.0, in: translationByTime)
                }
                let cover = await neteaseCoverURL(songId: candidate.id)
                return FetchedLyrics(times: original.map { $0.0 },
                                     texts: original.map { $0.1 },
                                     translations: translations,
                                     artworkURL: cover)
            }
        }
        throw LyricsError.notFound
    }

    private struct NEDetailResponse: Decodable {
        struct Album: Decodable { let picUrl: String? }
        struct Song: Decodable { let al: Album? }
        let songs: [Song]?
    }

    /// 通过歌曲详情接口获取专辑封面 URL。
    private func neteaseCoverURL(songId: Int) async -> URL? {
        guard let url = URL(string: "https://music.163.com/api/v3/song/detail") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("c=[{\"id\":\(songId)}]".utf8)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(NEDetailResponse.self, from: data),
              let pic = decoded.songs?.first?.al?.picUrl else { return nil }
        return URL(string: pic)
    }

    /// 按时间戳就近匹配译文行（NetEase 译文时间轴常与原曲略有偏移）。
    private static func matchTranslation(lineTime: TimeInterval,
                                         in translated: [(TimeInterval, String)]) -> String {
        var best: (delta: TimeInterval, text: String)?
        for entry in translated where !entry.1.isEmpty {
            let delta = abs(entry.0 - lineTime)
            if best == nil || delta < best!.delta {
                best = (delta, entry.1)
            }
        }
        // 只在时间差较小（<1.5s）时采用，避免错配
        if let best, best.delta < 1.5 { return best.text }
        return ""
    }

    /// 网易云候选：id + 是否歌手匹配 + 综合匹配分。
    private struct NECandidate { let id: Int; let artistMatch: Bool; let score: Int }

    /// 搜索并按「歌手 + 歌名 + 专辑名」综合匹配度排序候选；歌手匹配权重最高，专辑作为辅助。
    private func neteaseCandidates(title: String, artist: String, album: String?) async throws -> [NECandidate] {
        let targetArtist = Self.normalize(artist)
        let targetTitle = Self.normalize(title)
        let targetAlbum = album.map { Self.normalize($0) } ?? ""

        // 合并「歌手+歌名」与「仅歌名」两次搜索结果，扩大命中正版的概率
        var byId: [Int: NESearchResponse.Song] = [:]
        for song in (try? await neteaseSearch(query: "\(artist) \(title)")) ?? [] { byId[song.id] = song }
        for song in (try? await neteaseSearch(query: title)) ?? [] where byId[song.id] == nil { byId[song.id] = song }

        return byId.values.map { song -> NECandidate in
            let names = (song.artists ?? []).compactMap { Self.normalize($0.name ?? "") }
            let artistExact = !targetArtist.isEmpty && names.contains { $0 == targetArtist }
            let artistPartial = !targetArtist.isEmpty && names.contains { !$0.isEmpty && (targetArtist.contains($0) || $0.contains(targetArtist)) }
            let artistMatch = artistExact || artistPartial

            let normTitle = Self.normalize(song.name ?? "")
            let titleExact = !targetTitle.isEmpty && normTitle == targetTitle
            let titlePartial = !targetTitle.isEmpty && (normTitle.contains(targetTitle) || targetTitle.contains(normTitle))

            let normAlbum = Self.normalize(song.album?.name ?? "")
            let albumMatch = !targetAlbum.isEmpty && !normAlbum.isEmpty
                && (normAlbum == targetAlbum || normAlbum.contains(targetAlbum) || targetAlbum.contains(normAlbum))

            var score = 0
            if artistExact { score += 6 } else if artistPartial { score += 3 }
            if titleExact { score += 4 } else if titlePartial { score += 2 }
            if albumMatch { score += 3 }
            return NECandidate(id: song.id, artistMatch: artistMatch, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    private func neteaseSearch(query: String) async throws -> [NESearchResponse.Song] {
        var components = URLComponents(string: "https://music.163.com/api/search/get/web")
        components?.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "15"),
        ]
        guard let url = components?.url else { throw LyricsError.network }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { throw LyricsError.network }
        let decoded = try JSONDecoder().decode(NESearchResponse.self, from: data)
        return decoded.result?.songs ?? []
    }

    private func neteaseLyric(id: Int) async throws -> (original: String, translated: String) {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "lv", value: "-1"),
            URLQueryItem(name: "kv", value: "-1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        guard let url = components?.url else { throw LyricsError.network }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { throw LyricsError.network }
        let decoded = try JSONDecoder().decode(NELyricResponse.self, from: data)
        return (decoded.lrc?.lyric ?? "", decoded.tlyric?.lyric ?? "")
    }

    // MARK: - 工具

    /// 去掉空白与常见标点、转小写，用于宽松比较歌名/歌手。
    private static func normalize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let lowered = text.lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) { out.unicodeScalars.append(scalar) }
        }
        return out
    }

    /// 是否含有假名（判定为日语文本）
    private func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3041...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) { return true }
        }
        return false
    }

    /// 网易云歌词里的制作信息行（作词/作曲/编曲…），不作为歌词展示。
    private static func isCreditLine(_ text: String) -> Bool {
        let trimmed = text.replacingOccurrences(of: " ", with: "")
        let markers = ["作词", "作曲", "编曲", "制作人", "出品", "发行", "录音", "混音",
                       "母带", "和声", "合声", "配唱", "吉他", "贝斯", "鼓", "弦", "演奏",
                       "Program", "Sound", "OP", "SP", "PV", "封面", "企划"]
        return markers.contains { trimmed.hasPrefix($0) }
    }

    /// 解析 `[00:12.45]歌词` 格式的同步歌词，返回按时间排序的 (秒, 文本)
    private static func parseLRC(_ raw: String) -> [(TimeInterval, String)] {
        var result: [(TimeInterval, String)] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"\[(\d{1,2}):([0-5]?\d(?:[.:]\d{1,3})?)\]"#
        ) else { return [] }

        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let text = String(line)
            let ns = text as NSString
            var times: [Double] = []
            var contentStart = ns.length

            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.range.location < contentStart else { return }
                contentStart = match.range.location + match.range.length
                guard let minuteRange = Range(match.range(at: 1), in: text),
                      let secondRange = Range(match.range(at: 2), in: text) else { return }
                let minutes = Double(text[minuteRange]) ?? 0
                let secondsText = text[secondRange].replacingOccurrences(of: ":", with: ".")
                let seconds = Double(secondsText) ?? 0
                times.append(minutes * 60 + seconds)
            }

            guard !times.isEmpty else { continue }
            let content = (ns.substring(from: contentStart) as String)
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            for time in times {
                result.append((time, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}
