<p align="center">
  <img src="assets/logo.png" width="120" alt="出音谓来 logo">
</p>

<h1 align="center">voice2lyrics</h1>

<p align="center"><sub>App 显示名：出音谓来 · 声音一出来，就知其所谓</sub></p>

> 声音一出来，就知其所谓。—— 听歌识曲 · 歌词跟读工具

**voice2lyrics（出音谓来）** 是一款 iOS 应用：点一下「识曲」，即可识别环境中正在播放的歌曲，自动跳转到对应的歌曲时间点，并逐行显示歌词与日语假名、罗马音标注（中文歌也能显示歌词与中文译文）。

---

## ✨ 功能特性

- 🎧 **听歌识曲**：录音样本调用 [ACRCloud](https://www.acrcloud.cn/) 在线曲库识别，支持多版本结果时弹窗选择。
- ⏱️ **时间点跳转 + 自动跟读**：识别成功后按「识别时刻」推算歌曲进度并随时间滚动高亮歌词；点击任意一行歌词可直接跳转到该行继续。
- 🌐 **多歌词来源**：支持 **网易云音乐**（含中文译文、专辑封面）与 **LRCLIB**，可在设置内切换，主来源无结果时自动回退。
- 🔤 **日语标注**：离线词典生成平假名与罗马音，罗马音遵循 **黑本式（Hepburn）** 规则（叠辅音、长音、拨音、助词 wa/e/o 等），并做词间分词。
- 🈶 **多语言友好**：中文等不含假名的歌词只显示原文与译文，不显示假名/罗马音。
- 🪟 **液态玻璃交互**：译 / 假 / 罗 三个悬浮按钮切换标注显示；支持字号缩放。
- 🗂️ **识别历史**：识别成功的歌曲本地缓存，可从历史直接进入歌词页，无需重复识曲（节省调用额度）。
- 💡 **歌词页保持屏幕常亮**。

## 🧱 技术栈

| 模块 | 说明 |
| --- | --- |
| UI | SwiftUI（`@Observable`、NavigationStack、Glass Effect 液态玻璃） |
| 识曲 | ACRCloud REST API（录制 8kHz 单声道样本 → HMAC-SHA1 签名 → `POST /v1/identify`） |
| 歌词 | lrclib.net / 网易云音乐开放接口，LRC 解析与译文按时间戳对齐 |
| 罗马音/假名 | 打包的 JMDict / JmdictFurigana 词典（`Resources/jmdict_readings.tsv`）+ 自研分词与 Hepburn 转写 |
| 存储 | 识曲配置与歌词来源用 `UserDefaults`；识别历史以 JSON 持久化到应用沙盒 |

## 📁 项目结构

```
music_learning/
├── music_learning/
│   ├── MyApp.swift                 # App 入口
│   ├── ContentView.swift           # 主界面（识曲、历史入口、设置入口）
│   ├── Assets.xcassets
│   ├── Resources/
│   │   └── jmdict_readings.tsv     # 汉字→假名离线词典
│   ├── Services/
│   │   ├── SongMatcher.swift       # ACRCloud 识曲引擎与状态机
│   │   ├── LyricsService.swift     # 歌词来源调度（网易云 / LRCLIB）
│   │   ├── Romanizer.swift         # 分词 + 假名 + 罗马音（Hepburn）
│   │   └── HistoryStore.swift      # 识别历史本地缓存
│   └── Views/
│       ├── MatchedSongView.swift   # 歌词页（时间轴、标注切换、点行跳转、常亮）
│       ├── HistoryView.swift       # 识别历史列表
│       └── SettingsView.swift      # 识曲密钥 / 歌词来源设置
```

## 🚀 快速开始

1. Clone 本仓库并用 Xcode 打开 `music_learning.xcodeproj`。
2. 在 **设置 → 识曲服务 · ACRCloud** 中填入你自己的 **Access Key / Secret Key / API Host**（按教程注册 acrcloud.cn → 添加「听歌识曲」项目 → 集成页复制）。
3. 选择目标设备，Build & Run。首次识曲会请求麦克风权限。

> 识曲额度由 ACRCloud 提供（免费账户每天约 100 次）；历史缓存可避免对同一首歌重复调用。

## ⚠️ 说明与免责

- 假名/罗马音基于离线词典近似分词，特殊读法（当て字）可能与原唱标注略有出入。
- 网易云部分 VIP 歌曲可能取不到完整歌词或译文，此时会自动回退到 LRCLIB。
- 本项目仅供学习交流，请使用合法途径获取的接口与密钥，并遵守各服务方的使用条款。
