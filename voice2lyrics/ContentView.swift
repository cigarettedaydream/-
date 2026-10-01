import SwiftUI

struct ContentView: View {
    @State private var matcher = SongMatcher()
    @State private var history = HistoryStore.shared
    @State private var lastMatch: MatchInfo?
    @State private var isPulsing = false
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showChoices = false
    @State private var candidates: [MatchInfo] = []
    @State private var showManualSearch = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("出音谓来")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("听歌识曲 · 歌词跟读")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 16)

                Spacer()

                recognitionVisual

                statusView
                    .frame(minHeight: 72)

                actionButton

                manualSearchButton

                Spacer()

                Text("把手机靠近正在播放的歌曲，点击「识曲」，成功后将自动跳转歌词进度并显示罗马音标注")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal)
            .navigationDestination(item: $lastMatch) { match in
                MatchedSongView(match: match, matcher: matcher)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showManualSearch) {
                ManualSearchView { title, artist, album in
                    let info = MatchInfo(
                        id: "manual-\(UUID().uuidString)",
                        title: title,
                        artist: artist.isEmpty ? "未知歌手" : artist,
                        album: album.isEmpty ? nil : album,
                        artworkURL: nil,
                        appleMusicURL: nil,
                        songOffset: 0,
                        matchedAt: Date()
                    )
                    history.record(info)
                    lastMatch = info
                }
            }
        }
        .onChange(of: matcher.phase) { _, newPhase in
            switch newPhase {
            case .matched(let info):
                history.record(info)
                lastMatch = info
            case .choices(let list):
                candidates = list
                showChoices = true
            case .idle, .requestingPermission, .listening:
                lastMatch = nil
            default:
                break
            }
        }
        .sheet(isPresented: $showChoices) {
            choicesSheet
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(history: history) { item in
                showHistory = false
                lastMatch = item.reanchoredToNow()
            }
        }
    }

    // MARK: - 多版本选择

    private var choicesSheet: some View {
        NavigationStack {
            List(candidates) { item in
                Button {
                    showChoices = false
                    matcher.select(item)   // → phase .matched → 记录历史并跳转
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        HStack {
                            Text(item.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if let score = item.score {
                                Text("匹配 \(Int(score * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if let album = item.album, !album.isEmpty {
                            Text(album)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("识别到多个版本，请选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        showChoices = false
                        matcher.dismissChoices()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 视觉

    private var recognitionVisual: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 220, height: 220)
            Circle()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                .frame(width: 260, height: 260)
            Image(systemName: matcher.isBusy ? "waveform" : "music.note.list")
                .font(.system(size: 76))
                .foregroundStyle(.tint)
        }
        .scaleEffect(matcher.isBusy && isPulsing ? 1.06 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch matcher.phase {
        case .idle:
            Text("准备就绪")
                .foregroundStyle(.secondary)
        case .requestingPermission:
            Label("请求麦克风权限…", systemImage: "lock.open")
                .foregroundStyle(.secondary)
        case .listening:
            VStack(spacing: 8) {
                ProgressView()
                Text(matcher.progressHint ?? "正在聆听环境中的歌曲…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let detail = matcher.lastAttemptError {
                    Text("上次尝试：\(detail)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        case .noMatch:
            VStack(spacing: 6) {
                Label("没有识别到歌曲，请靠近扬声器重试", systemImage: "questionmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                if let detail = matcher.lastAttemptError {
                    Text("诊断信息：\(detail)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }
            }
        case .micDenied:
            Label("需要麦克风权限才能识曲，请在系统设置中开启", systemImage: "mic.slash")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case .choices(let list):
            Label("识别到 \(list.count) 个版本，请在弹窗中选择", systemImage: "list.bullet")
                .font(.subheadline)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
        case .matched(let info):
            VStack(spacing: 4) {
                Text("识别成功")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Text("\(info.title) — \(info.artist)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if matcher.phase == .listening {
            Button {
                matcher.stopRecognizing()
            } label: {
                Label("停止识别", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            Button {
                matcher.startRecognizing()
            } label: {
                Label("识 曲", systemImage: "ear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - 手动搜索歌词入口

    @ViewBuilder
    private var manualSearchButton: some View {
        Button {
            showManualSearch = true
        } label: {
            Label("手动搜索歌词", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

#Preview {
    ContentView()
}

/// 手动输入歌曲信息、跳过识曲直接搜索歌词的表单
struct ManualSearchView: View {
    var onSubmit: (_ title: String, _ artist: String, _ album: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("歌曲名（必填）", text: $title)
                        .textInputAutocapitalization(.never)
                    TextField("歌手（选填）", text: $artist)
                        .textInputAutocapitalization(.never)
                    TextField("专辑（选填，可帮助匹配）", text: $album)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("跳过识曲，直接按你输入的信息搜索歌词并进入歌词页。歌手 / 专辑填得越全，匹配越准。")
                }
            }
            .navigationTitle("手动搜索歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("搜索") {
                        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        onSubmit(t,
                                 artist.trimmingCharacters(in: .whitespacesAndNewlines),
                                 album.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
