import SwiftUI

/// 识别成功后的歌词页：自动跳转到识别出的时间点，并随时间滚动歌词。
struct MatchedSongView: View {
    let match: MatchInfo
    let matcher: SongMatcher

    @Environment(\.dismiss) private var dismiss
    @State private var lyricState: LyricState = .loading
    @State private var position: TimeInterval
    @State private var showRomaji = false
    @State private var showKana = false
    @State private var showTranslation = false
    /// 从歌词来源（网易云）解析到的专辑封面
    @State private var resolvedArtworkURL: URL?

    /// 歌词字号缩放系数（持久化，对所有歌曲生效）。用 _lyricScale 键避免与旧值冲突。
    @AppStorage("lyric_font_scale") private var fontScale: Double = 1.0
    /// 本次识别的手动延迟补偿（秒）：点击歌词行跳转、以及进度推算都基于它
    @State private var manualOffset: TimeInterval = 0

    enum LyricState: Equatable {
        case loading
        case loaded([LyricLine])
        case failed(String)
    }

    init(match: MatchInfo, matcher: SongMatcher) {
        self.match = match
        self.matcher = matcher
        _position = State(initialValue: match.songOffset)
    }

    private var lines: [LyricLine] {
        if case .loaded(let loadedLines) = lyricState { return loadedLines }
        return []
    }

    /// 当前位置对应的歌词行（同步歌词才有）
    private var currentIndex: Int? {
        guard let first = lines.first, first.time != nil else { return nil }
        var result: Int?
        for line in lines {
            if let time = line.time, time <= position + 0.3 {
                result = line.id
            } else {
                break
            }
        }
        return result
    }

    /// 是否有可切换的标注（译/假名/罗马音任一存在），决定悬浮按钮是否出现
    private var hasAnnotations: Bool {
        lines.contains { !$0.kana.isEmpty || !$0.romaji.isEmpty || !$0.translation.isEmpty }
    }

    var body: some View {
        VStack(spacing: 12) {
            headerCard
            controlBar
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .padding(.horizontal)
                        .padding(.bottom, 120)
                }
                .onChange(of: currentIndex) { _, newIndex in
                    guard let newIndex else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onChange(of: lyricState) { _, newState in
                    if case .loaded = newState, let idx = currentIndex {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
                // 切换标注会改变每行高度，这里重新把当前行居中，避免跳回顶部
                .onChange(of: showKana) { _, _ in scrollToCurrent(proxy) }
                .onChange(of: showRomaji) { _, _ in scrollToCurrent(proxy) }
                .onChange(of: showTranslation) { _, _ in scrollToCurrent(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    if hasAnnotations {
                        floatingControls
                    }
                }
            }
        }
        .navigationTitle("识别结果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新识曲") {
                    matcher.startRecognizing()
                }
            }
        }
        .task { await loadLyrics() }
        .task { await advancePosition() }
        .onAppear { setIdleTimerDisabled(true) }
        .onDisappear { setIdleTimerDisabled(false) }
    }

    /// 歌词查看期间保持屏幕常亮
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit) && os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    /// 把当前高亮行重新滚动到中部（用于切换标注后保持位置）
    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let idx = currentIndex else { return }
        // 等内容高度变化后再滚动
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }

    // MARK: - 子视图

    private var headerCard: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                Text(match.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(match.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("识别于 \(Self.format(match.songOffset)) 处")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(Self.format(position))
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text("歌曲进度")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.1))
        )
        .padding(.horizontal)
    }

    /// 字号缩放控制条
    private var controlBar: some View {
        HStack(spacing: 0) {
            Spacer()
            Label("字号", systemImage: "textformat.size")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                fontScale = max(0.7, fontScale - 0.1)
            } label: {
                Image(systemName: "minus.circle")
            }
            .disabled(fontScale <= 0.7)
            Text("\(Int(fontScale * 100))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 34)
            Button {
                fontScale = min(1.8, fontScale + 0.1)
            } label: {
                Image(systemName: "plus.circle")
            }
            .disabled(fontScale >= 1.8)
            Spacer()
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.08))
        )
        .padding(.horizontal)
    }

    /// 右下角悬浮的液态玻璃开关：译 / 假 / 罗（仅一个字的方形小按钮）
    private var floatingControls: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .trailing, spacing: 8) {
                if hasTranslation {
                    glassToggle(active: showTranslation, glyph: "译", full: "中文翻译") {
                        withAnimation(.easeInOut(duration: 0.2)) { showTranslation.toggle() }
                    }
                }
                if hasKana {
                    glassToggle(active: showKana, glyph: "假", full: "假名") {
                        withAnimation(.easeInOut(duration: 0.2)) { showKana.toggle() }
                    }
                }
                if hasRomaji {
                    glassToggle(active: showRomaji, glyph: "罗", full: "罗马音") {
                        withAnimation(.easeInOut(duration: 0.2)) { showRomaji.toggle() }
                    }
                }
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 20)
    }

    private var hasTranslation: Bool { lines.contains { !$0.translation.isEmpty } }
    private var hasKana: Bool { lines.contains { !$0.kana.isEmpty } }
    private var hasRomaji: Bool { lines.contains { !$0.romaji.isEmpty } }

    /// 圆角方形玻璃小按钮：按下（active）时用 prominent 高亮填充
    @ViewBuilder
    private func glassToggle(active: Bool, glyph: String, full: String,
                             action: @escaping () -> Void) -> some View {
        let label = Text(glyph)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())

        if active {
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .accessibilityLabel(full)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: action) { label }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .accessibilityLabel(full)
        }
    }

    private var artwork: some View {
        Group {
            if let artworkURL = resolvedArtworkURL ?? match.artworkURL {
                AsyncImage(url: artworkURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.15))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var content: some View {
        switch lyricState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("正在获取歌词…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "text.quote")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("罗马音由本地词典自动生成，特殊读法（当て字）可能与原唱略有出入。")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        case .loaded(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines) { line in
                    lineRow(line, isCurrent: line.id == currentIndex)
                }

                if match.appleMusicURL != nil {
                    HStack {
                        Spacer()
                        if let url = match.appleMusicURL {
                            Link(destination: url) {
                                Label("在 Apple Music 打开", systemImage: "arrow.up.forward.app")
                            }
                            .font(.footnote)
                            .padding(.top, 24)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func lineRow(_ line: LyricLine, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // 1. 原文
            Text(line.text)
                .font(scaledFont(isCurrent ? 20 : 18,
                                 weight: isCurrent ? .semibold : .regular))
            // 2. 中文翻译（点“译”按钮显示）
            if showTranslation && !line.translation.isEmpty {
                Text(line.translation)
                    .font(scaledFont(14))
                    .foregroundStyle(isCurrent ? Color.primary.opacity(0.8)
                                               : Color.primary.opacity(0.35))
            }
            // 3. 平假名（点“假名”按钮显示）
            if showKana && !line.kana.isEmpty {
                Text(line.kana)
                    .font(scaledFont(13))
                    .foregroundStyle(.secondary)
            }
            // 4. 罗马音（点“罗马音”按钮显示）
            if showRomaji && !line.romaji.isEmpty {
                Text(line.romaji)
                    .font(scaledFont(13))
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isCurrent ? Color.primary : Color.primary.opacity(0.4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.gray.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            jump(to: line.time)
        }
        .id(line.id)
    }

    /// 点击歌词行：把播放进度跳到该行起始时间。
    /// 由于 position 由 matchedAt 推算，这里通过补偿 manualOffset 实现即时跳转。
    private func jump(to time: TimeInterval?) {
        guard let time else { return }
        let elapsed = Date().timeIntervalSince(match.matchedAt)
        withAnimation(.easeInOut(duration: 0.3)) {
            manualOffset = time - match.songOffset - elapsed
        }
    }

    /// 按当前字号缩放系数生成字体
    private func scaledFont(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: base * fontScale, weight: weight)
    }

    // MARK: - 行为

    private func loadLyrics() async {
        do {
            let result = try await LyricsService.shared.lyrics(
                title: match.title,
                artist: match.artist,
                album: match.album
            )
            resolvedArtworkURL = result.artworkURL
            lyricState = .loaded(result.lines)
        } catch {
            let message = (error as? LyricsError)?.errorDescription
                ?? error.localizedDescription
            lyricState = .failed(message)
        }
    }

    /// 模拟播放进度：以录音结束时刻 matchedAt 为基准，
    /// 加上「至今真实流逝时间」（已包含查询曲库+跳转造成的延迟）与手动补偿。
    private func advancePosition() async {
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(match.matchedAt)
            position = match.songOffset + elapsed + manualOffset
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func format(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
