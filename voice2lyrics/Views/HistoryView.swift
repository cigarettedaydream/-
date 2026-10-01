import SwiftUI

/// 识别历史列表：点击任一条直接进入歌词页（无需重新识曲，节省额度），
/// 支持左滑删除单条与清空全部。
struct HistoryView: View {
    let history: HistoryStore
    /// 选中某条历史时的回调（由上层负责关闭本页并跳转）
    let onSelect: (MatchInfo) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    ContentUnavailableView(
                        "暂无识别记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("成功识别到的歌曲会自动保存在这里，点击即可直接查看歌词，无需重新识曲。")
                    )
                } else {
                    List {
                        Section {
                            ForEach(history.items) { item in
                                Button {
                                    onSelect(item)
                                } label: {
                                    row(item)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        history.remove(item)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        } footer: {
                            Text("记录保存在本地，重复识别不会额外消耗额度。")
                        }
                    }
                }
            }
            .navigationTitle("识别历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        history.clear()
                    } label: {
                        Text("清空")
                    }
                    .disabled(history.items.isEmpty)
                }
            }
        }
    }

    private func row(_ item: MatchInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("识别于 \(item.matchedAt.formatted(date: .abbreviated, time: .shortened)) · \(Self.format(item.songOffset))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private static func format(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    HistoryView(history: HistoryStore.shared) { _ in }
}
