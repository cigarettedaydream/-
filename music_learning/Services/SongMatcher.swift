import AVFoundation
import CryptoKit
import Foundation
import Observation

// MARK: - ACRCloud 配置（可在“设置”页修改，UserDefaults 优先）

enum ACRConfiguration {
    // 出于隐私，仓库内不包含任何真实密钥。
    // 请自行在 App「设置 → 识曲服务 · ACRCloud」中填入 Access Key / Secret Key（仅保存在本机）。
    static let defaultAccessKey = ""
    static let defaultSecretKey = ""
    static let defaultHost = "identify-cn-north-1.acrcloud.cn"

    private static func value(forKey key: String, fallback: String) -> String {
        let stored = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false) ? stored! : fallback
    }

    // 使用 _v2 键名，避免旧版本里保存的错误 Access Key / Host 覆盖内置默认值
    static var accessKey: String { value(forKey: "acr_access_key_v2", fallback: defaultAccessKey) }
    static var secretKey: String { value(forKey: "acr_secret_key_v2", fallback: defaultSecretKey) }
    static var apiHost: String { value(forKey: "acr_api_host_v2", fallback: defaultHost) }
}

// MARK: - 数据模型

/// 识别成功后的一首歌曲信息（含识别出的歌曲时间点）
struct MatchInfo: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let appleMusicURL: URL?
    /// 识别时刻对应歌曲内部的时间点（秒）
    let songOffset: TimeInterval
    /// 该时间点对应的系统时间，用于推算当前歌曲进度
    let matchedAt: Date
    /// ACRCloud 匹配度（0~1），仅候选展示用；历史记录里可为 nil
    var score: Double? = nil

    /// 从历史记录再次打开时：保留识别到的歌曲内位置，但把基准时间重置为“现在”，
    /// 这样进度会从该位置继续前进（可再点歌词行做手动对齐），避免用旧时间戳。
    func reanchoredToNow() -> MatchInfo {
        MatchInfo(id: id, title: title, artist: artist, album: album,
                  artworkURL: artworkURL, appleMusicURL: appleMusicURL,
                  songOffset: songOffset, matchedAt: Date(), score: score)
    }
}

/// 识曲流程的状态机
enum MatcherPhase: Equatable {
    case idle
    case requestingPermission
    case listening
    case noMatch
    case micDenied
    case error(String)
    case matched(MatchInfo)
    /// 识别到多个候选版本，需用户在列表中挑选
    case choices([MatchInfo])
}

private struct ACRError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 识曲引擎（ACRCloud REST API）

/// 通过 ACRCloud 在线曲库做“听歌识曲”：
/// 录制 8kHz 单声道 PCM 样本 -> 计算 HMAC-SHA1 签名 -> POST /v1/identify。
/// 免费账号也可用（每天 100 次识别额度），返回结果含识别时间点 offset_seconds。
@Observable
final class SongMatcher {
    private(set) var phase: MatcherPhase = .idle
    /// 最近一次识别尝试的错误信息（用于界面诊断）
    private(set) var lastAttemptError: String?
    /// 进行中的提示（如“正在录制样本…”）
    private(set) var progressHint: String?

    private var recorder: AVAudioRecorder?
    private var matchingTask: Task<Void, Never>?

    /// 单次样本时长（秒），ACRCloud 建议 3~10 秒
    private let sampleDuration: TimeInterval = 6
    /// 连续未匹配的次数上限
    private let maxNoMatchAttempts = 3

    var isBusy: Bool {
        switch phase {
        case .listening, .requestingPermission: return true
        default: return false
        }
    }

    /// 开始一次识曲（先请求麦克风权限）
    func startRecognizing() {
        guard !isBusy else { return }
        lastAttemptError = nil
        phase = .requestingPermission
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                phase = .micDenied
                return
            }
            beginLoop()
        }
    }

    func stopRecognizing() {
        matchingTask?.cancel()
        matchingTask = nil
        recorder?.stop()
        recorder = nil
        if case .listening = phase { phase = .idle }
    }

    // MARK: - 识别循环

    private func beginLoop() {
        phase = .listening
        matchingTask = Task { [weak self] in
            guard let self else { return }
            var noMatchCount = 0
            var errorCount = 0

            while !Task.isCancelled {
                do {
                    await MainActor.run {
                        self.progressHint = "正在录制样本（第 \(noMatchCount + 1) 次，6 秒）…"
                    }
                    let sample = try await self.recordSample()
                    await MainActor.run { self.progressHint = "正在查询曲库…" }
                    if Task.isCancelled { break }

                    let candidates = try await self.identify(sample: sample)
                    if let candidates, !candidates.isEmpty {
                        await MainActor.run {
                            if candidates.count == 1 {
                                self.finish(with: candidates[0])
                            } else {
                                // 多个版本：交给界面让用户挑选
                                self.progressHint = nil
                                self.phase = .choices(candidates)
                            }
                        }
                        return
                    }
                    noMatchCount += 1
                    if noMatchCount >= self.maxNoMatchAttempts {
                        await MainActor.run { self.finish(.noMatch) }
                        return
                    }
                } catch is CancellationError {
                    break
                } catch {
                    errorCount += 1
                    let text = error.localizedDescription
                    await MainActor.run { self.lastAttemptError = text }
                    print("[ACR] 识别请求失败: \(text)")
                    // 鉴权类错误重试没有意义，直接失败并在界面显示原因
                    if errorCount >= 2 || Self.isAuthError(text) {
                        await MainActor.run { self.finish(.error("识别失败：\(text)")) }
                        return
                    }
                }
            }
            await MainActor.run {
                if case .listening = self.phase { self.finish(.noMatch) }
            }
        }
    }

    private static func isAuthError(_ text: String) -> Bool {
        text.contains("3001") || text.contains("Access Key")
            || text.contains("-38102") || text.contains("signature")
            || text.contains("Invalid")
    }

    private func finish(_ newPhase: MatcherPhase) {
        recorder?.stop()
        recorder = nil
        progressHint = nil
        phase = newPhase
    }

    private func finish(with info: MatchInfo) {
        finish(.matched(info))
    }

    /// 用户在多候选列表里选择了某一条 → 确认为匹配结果
    func select(_ info: MatchInfo) {
        finish(with: info)
    }

    /// 放弃本次多候选选择
    func dismissChoices() {
        finish(.idle)
    }

    // MARK: - 录音

    /// 录制一段 8kHz/16bit 单声道 WAV 样本，返回 (数据, 录制结束时刻)
    private func recordSample() async throws -> (data: Data, endedAt: Date) {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default)
        try audioSession.setActive(true)
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("acr_sample.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.delegate = nil
        recorder = newRecorder
        newRecorder.prepareToRecord()
        guard newRecorder.record() else {
            recorder = nil
            throw ACRError("无法启动录音")
        }

        do {
            try await Task.sleep(for: .seconds(sampleDuration))
        } catch {
            newRecorder.stop()
            recorder = nil
            throw CancellationError()
        }
        newRecorder.stop()
        recorder = nil

        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return (data, Date())
    }

    // MARK: - ACRCloud 请求

    /// 发起识别；返回候选歌曲（可能含多个版本），未匹配返回 nil，鉴权/网络错误抛出
    private func identify(sample: (data: Data, endedAt: Date)) async throws -> [MatchInfo]? {
        let host = ACRConfiguration.apiHost
        let accessKey = ACRConfiguration.accessKey
        let secretKey = ACRConfiguration.secretKey
        let timestamp = String(Date().timeIntervalSince1970)
        let boundary = "----MusicLearning\(UUID().uuidString)"

        // 中国区签名不含 host：POST\n/v1/identify\n{access_key}\n{data_type}\n{signature_version}\n{timestamp}
        let stringToSign = "POST\n/v1/identify\n\(accessKey)\naudio\n1\n\(timestamp)"
        let macKey = SymmetricKey(data: Data(secretKey.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8), using: macKey
        )
        let signature = Data(mac).base64EncodedString()

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        // sample 以原始文件字节（multipart file part）上传，而非 base64
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"sample\"; filename=\"sample.wav\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(sample.data)
        body.append(Data("\r\n".utf8))
        appendField("access_key", accessKey)
        appendField("sample_bytes", String(sample.data.count))
        appendField("data_type", "audio")
        appendField("signature", signature)
        appendField("signature_version", "1")
        appendField("timestamp", timestamp)
        body.append(Data("--\(boundary)--\r\n".utf8))

        guard let url = URL(string: "https://\(host)/v1/identify") else {
            throw ACRError("API Host 无效：\(host)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ACRError("无效的服务端响应")
        }
        guard http.statusCode == 200 else {
            throw ACRError("HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(ACRResponse.self, from: data)
        switch decoded.status.code {
        case 0:
            let tracks = decoded.metadata?.match
                ?? decoded.metadata?.humming
                ?? decoded.metadata?.music ?? []
            guard !tracks.isEmpty else { return nil }
            let base = Int(Date().timeIntervalSince1970)
            var candidates: [MatchInfo] = []
            var seen = Set<String>()
            for (index, track) in tracks.enumerated() {
                var artistNames = track.artists?.compactMap { $0.name }.joined(separator: ", ") ?? ""
                if artistNames.isEmpty { artistNames = track.artist ?? "" }
                let artists = artistNames.isEmpty ? "未知歌手" : artistNames
                let title = track.title ?? "未知歌曲"
                // 去重：同名同歌手只保留第一个（匹配度最高）
                let key = title.lowercased() + "|" + artists.lowercased()
                guard seen.insert(key).inserted else { continue }
                let album = track.album?.name ?? track.albumName
                // 样本起点在歌曲内的时间：优先 play_offset_ms，其次 metadata.offset_result（秒）
                let baseOffset: Double
                if let ms = track.playOffsetMs?.value {
                    baseOffset = ms / 1000.0
                } else {
                    baseOffset = decoded.metadata?.offsetResult?.value ?? 0
                }
                // 样本结束时歌曲已播放到 起点 + 样本时长
                let songOffset = max(0, baseOffset) + sampleDuration
                candidates.append(MatchInfo(
                    id: "acr-\(base)-\(index)",
                    title: title,
                    artist: artists,
                    album: album,
                    artworkURL: nil,
                    appleMusicURL: nil,
                    songOffset: songOffset,
                    matchedAt: sample.endedAt,
                    score: track.score?.value
                ))
            }
            return candidates.isEmpty ? nil : candidates
        case 1001:
            return nil // 未匹配
        default:
            let msg = decoded.status.msg ?? "未知错误"
            var hint = "ACRCloud 返回：\(msg)（code \(decoded.status.code)）"
            if decoded.status.code == 3001 {
                hint += "。请到 ACRCloud Console →「Audio & Video Recognition」项目页核对 Access Key / Secret Key，并确认 API Host 与项目区域一致（新建项目可能需要等几分钟生效或先验证邮箱）。"
            }
            throw ACRError(hint)
        }
    }
}

// MARK: - 响应解析

private struct ACRResponse: Decodable {
    struct Status: Decodable {
        let code: Int
        let msg: String?
    }

    struct Artist: Decodable {
        let name: String?
    }

    struct Album: Decodable {
        let name: String?
    }

    /// 单条匹配结果（听歌识曲在 metadata.match，哼唱在 metadata.humming）
    struct Track: Decodable {
        let title: String?
        let artists: [Artist]?
        let artist: String?                 // 兼容字符串形式的歌手字段
        let album: Album?
        let albumName: String?              // 兼容 album_name
        let score: LenientDouble?
        let playOffsetMs: LenientDouble?    // 样本起点在歌曲内的毫秒偏移

        private enum CodingKeys: String, CodingKey {
            case title, artists, artist, album, score
            case albumName = "album_name"
            case playOffsetMs = "play_offset_ms"
        }
    }

    struct Metadata: Decodable {
        let match: [Track]?
        let humming: [Track]?
        let music: [Track]?
        let offsetResult: LenientDouble?

        private enum CodingKeys: String, CodingKey {
            case match, humming, music
            case offsetResult = "offset_result"
        }
    }

    let status: Status
    let metadata: Metadata?
}

/// ACRCloud 部分字段可能是数字或字符串，做一次宽容解析
private struct LenientDouble: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}
