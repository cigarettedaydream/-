import Foundation

/// 将日文文本转写为罗马音（本地离线词典方案）。
/// 词表来自 JMdict/JmdictFurigana（CC BY-SA，EDRDG），随应用打包在
/// Resources/jmdict_readings.tsv 中，格式为“写法<TAB>平假名读音”。
actor Romanizer {
    static let shared = Romanizer()

    /// 词组/汉字串 -> 整体读音（如 明日 -> あした）
    private var wordReadings: [String: String] = [:]
    /// 单个汉字 -> [(送假名, 读音)]，用于匹配不到整词时的兜底（如 開 + く -> ひらく）
    private var kanjiEntries: [Character: [(tail: String, reading: String)]] = [:]
    /// 纯假名词汇集合，用于把连续假名（助词/副词等）切分成词，改善罗马音可读性
    private var kanaVocabulary: Set<String> = []
    private var isLoaded = false

    /// 小写假名/长音符：单独出现时并入前一个词，避免产生 “~tsu” 之类的残缺罗马音
    private let smallKana: Set<Character> = ["っ", "ッ", "ゃ", "ゅ", "ょ", "ャ", "ュ", "ョ", "ー", "ゎ", "ヮ"]

    /// 五段动词终止形假名 -> 允许出现的活用后续假名（含て形促音的“っ”）
    private let conjugationRows: [Character: String] = [
        "う": "あいうえおわ", "く": "かきくけこい", "ぐ": "がぎぐげごい",
        "す": "さしすせそ", "つ": "たちつてと", "ぬ": "なにぬねの",
        "む": "まみむめも", "ぶ": "ばびぶべぼ", "る": "らりるれろ",
    ]

    /// 批量生成「假名 + 罗马音」标注。
    /// 返回的每个字符串都按词切分、词间用空格分隔；罗马音按黑本式（Hepburn）规则转写。
    func annotations(for texts: [String]) -> (kana: [String], romaji: [String]) {
        ensureLoaded()
        var kanaOut: [String] = []
        var romajiOut: [String] = []
        kanaOut.reserveCapacity(texts.count)
        romajiOut.reserveCapacity(texts.count)
        for text in texts {
            let tokens = kanaTokens(of: text)
            kanaOut.append(tokens.joined(separator: " "))
            romajiOut.append(
                tokens
                    .map { romaji(ofToken: $0) }
                    .joined(separator: " ")
            )
        }
        return (kanaOut, romajiOut)
    }

    /// 词级罗马音：对助词は/へ/を套用特殊读法，其余按音节规则转写。
    private func romaji(ofToken token: String) -> String {
        switch token {
        case "は": return "wa"
        case "へ": return "e"
        case "を": return "o"
        default: return kanaToRomaji(token)
        }
    }

    // MARK: - 假名 -> 罗马音（黑本式规则）

    /// 每个假名音节的（辅音词干, 元音）。词干用于加词、拗音与叠 consonant，元音用于长音。
    private static let moraTable: [Character: (initial: String, vowel: Character)] = [
        "あ":("", "a"), "い":("", "i"), "う":("", "u"), "え":("", "e"), "お":("", "o"),
        "か":("k","a"), "き":("k","i"), "く":("k","u"), "け":("k","e"), "こ":("k","o"),
        "さ":("s","a"), "し":("sh","i"), "す":("s","u"), "せ":("s","e"), "そ":("s","o"),
        "た":("t","a"), "ち":("ch","i"), "つ":("ts","u"), "て":("t","e"), "と":("t","o"),
        "な":("n","a"), "に":("n","i"), "ぬ":("n","u"), "ね":("n","e"), "の":("n","o"),
        "は":("h","a"), "ひ":("h","i"), "ふ":("f","u"), "へ":("h","e"), "ほ":("h","o"),
        "ま":("m","a"), "み":("m","i"), "む":("m","u"), "め":("m","e"), "も":("m","o"),
        "や":("y","a"), "ゆ":("y","u"), "よ":("y","o"),
        "ら":("r","a"), "り":("r","i"), "る":("r","u"), "れ":("r","e"), "ろ":("r","o"),
        "わ":("w","a"), "ゐ":("w","i"), "ゑ":("w","e"),
        "ん":("N","n"), "ゔ":("v","u"),
        "が":("g","a"), "ぎ":("g","i"), "ぐ":("g","u"), "げ":("g","e"), "ご":("g","o"),
        "ざ":("z","a"), "じ":("j","i"), "ず":("z","u"), "ぜ":("z","e"), "ぞ":("z","o"),
        "ぢ":("j","i"), "づ":("z","u"),
        "だ":("d","a"), "で":("d","e"), "ど":("d","o"),
        "ば":("b","a"), "び":("b","i"), "ぶ":("b","u"), "べ":("b","e"), "ぼ":("b","o"),
        "ぱ":("p","a"), "ぴ":("p","i"), "ぷ":("p","u"), "ぺ":("p","e"), "ぽ":("p","o"),
    ]

    /// 拗音（小 ゃゅょ）：与前一个辅音拼成 ky/sh/ch… 形式
    private static let smallYa: [Character: Character] = [
        "ゃ": "a", "ゅ": "u", "ょ": "o",
    ]
    /// 小元音（_foreign ャ行以外的ァィゥェォ）：替换前音节的元音
    private static let smallVowel: [Character: Character] = [
        "ぁ":"a", "ぃ":"i", "ぅ":"u", "ぇ":"e", "ぉ":"o",
    ]

    /// 罗马音转写用的单个音节
    private struct Mora {
        var initial: String
        var vowel: Character
        var geminate: Bool
        var doubledVowel: Bool
    }

    /// 把（可能含片假名的）假名字符串转写为黑本式罗马音。
    private func kanaToRomaji(_ input: String) -> String {
        let chars = Array(normalizeToHiragana(input))

        var moras: [Mora] = []
        var pendingGeminate = false

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "っ" {
                pendingGeminate = true
                i += 1
                continue
            }
            if ch == "ー" {
                // 长音符：重复前一音节的元音
                if !moras.isEmpty {
                    moras[moras.count - 1].doubledVowel = true
                }
                i += 1
                continue
            }
            if let smallV = Self.smallYa[ch] ?? Self.smallVowel[ch],
               !moras.isEmpty, var last = moras.last {
                if Self.smallYa[ch] != nil {
                    // 拗音：sh/ch/j 直接合并（sha/cha/ja），其余加 y
                    if !(last.initial.hasSuffix("sh") || last.initial.hasSuffix("ch") || last.initial == "j") {
                        last.initial += "y"
                    }
                }
                last.vowel = smallV
                moras[moras.count - 1] = last
                i += 1
                continue
            }
            guard let entry = Self.moraTable[ch] else {
                // 未知字符（标点等）跳过
                i += 1
                continue
            }
            moras.append(Mora(initial: entry.initial, vowel: entry.vowel,
                              geminate: pendingGeminate, doubledVowel: false))
            pendingGeminate = false
            i += 1
        }

        return buildRomaji(moras)
    }

    /// 由音节序列拼装罗马音字符串，处理 ん(n/m) 与叠辅音。
    private func buildRomaji(_ moras: [Mora]) -> String {
        var output = ""
        for (index, mora) in moras.enumerated() {
            var romaji = mora.initial
            if romaji == "N" {
                // ん：在 b/m/p 前用 m，其它用 n；后面是元音/y 时加撇号避免歧义
                let nextInitial = index + 1 < moras.count ? moras[index + 1].initial : ""
                if nextInitial.first == "b" || nextInitial.first == "m" || nextInitial.first == "p" {
                    romaji = "m"
                } else if nextInitial.isEmpty || nextInitial.first == "y" {
                    romaji = "n'"
                } else {
                    romaji = "n"
                }
                output += romaji
                continue
            }
            // 叠辅音：把下一音节辅音词干首字母翻倍
            if mora.geminate, let first = mora.initial.first {
                output.append(first)
            }
            output += romaji
            output.append(mora.vowel)
            if mora.doubledVowel { output.append(mora.vowel) }
        }
        return output
    }

    /// 片假名 -> 平假名（便于统一查表）。仅覆盖 0x30A1...0x30F6（ア〜ケ゛等）区间。
    private func normalizeToHiragana(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x30A1 && scalar.value <= 0x30F6 {
                let shifted = UnicodeScalar(scalar.value - 0x60)!
                result.unicodeScalars.append(shifted)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - 词典加载

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let url = Bundle.main.url(forResource: "jmdict_readings", withExtension: "tsv"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        wordReadings.reserveCapacity(220_000)
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let expression = String(parts[0])
            let reading = String(parts[1])
            guard !expression.isEmpty, !reading.isEmpty else { continue }
            let chars = Array(expression)
            if chars.count >= 2 {
                if wordReadings[expression] == nil {
                    wordReadings[expression] = reading
                }
                // 纯假名词（且读音与写法基本一致）加入假名词汇，供分词使用
                if chars.allSatisfy(isKana) {
                    kanaVocabulary.insert(expression)
                }
                // “汉字 + 纯假名送假名”的条目，供单字兜底使用（開く / 食べる…）
                if isKanji(chars[0]), chars[1...].allSatisfy(isKana) {
                    let tail = String(chars[1...])
                    kanjiEntries[chars[0], default: []].append((tail, reading))
                }
            } else if isKanji(chars[0]) {
                // 单字条目（開 -> カイ）
                kanjiEntries[chars[0], default: []].append(("", reading))
            }
        }
    }

    // MARK: - 汉字 -> 假名（分词）

    /// 把文本切成「词」的假名序列：每个汉字词（含其送假名）为一个词元，
    /// 连续的独立假名段（助词等）为一个词元，标点/空白作为词边界被丢弃。
    /// 注意：这是基于词典的近似分词，非 MeCab，词界偶有偏差。
    private func kanaTokens(of text: String) -> [String] {
        let chars = Array(text)
        var tokens: [String] = []
        var index = 0

        while index < chars.count {
            let character = chars[index]
            if isKanji(character) {
                let (reading, consumed) = resolveKanji(chars, at: index)
                if !reading.isEmpty { tokens.append(reading) }
                index += max(1, consumed)
                continue
            }
            if isKana(character) {
                var run: [Character] = []
                while index < chars.count, isKana(chars[index]) {
                    run.append(chars[index])
                    index += 1
                }
                // 连续假名按词汇/助词边界尽量切分成词，切不开的部分保持成段（不会逐字拆碎）
                tokens.append(contentsOf: segmentKanaRun(run))
                continue
            }
            // 标点、空白、其它字符：作为词边界跳过
            index += 1
        }
        return tokens
    }

    /// 解析以 index 处汉字开头的词，返回（假名读音，消耗字符数）。
    /// 优先级：整词最长匹配 > 送假名精确匹配 > 动词活用拆分 > 单字读音。
    /// 把一段连续假名按“词汇表 + 常见助词”做贪心切分；切不开的字符累积成段，
    /// 促音/拗音/长音等小假名并入当前段，避免出现残缺罗马音（如 “~tsu”）。
    private func segmentKanaRun(_ run: [Character]) -> [String] {
        guard !run.isEmpty else { return [] }
        // 助词/常见功能词，作为词汇表之外的补充切分点（按长度优先匹配）
        let functionWords = ["ながら", "ばかり", "ずつ", "なんて", "など", "しか", "だけ",
                             "でも", "から", "まで", "より",
                             "のに", "ので",
                             "は", "が", "の", "に", "へ", "で", "と", "や", "も"]

        var tokens: [String] = []
        var pending = ""
        func flush() { if !pending.isEmpty { tokens.append(pending); pending = "" } }

        var i = 0
        while i < run.count {
            var matched: String? = nil
            let maxLen = min(8, run.count - i)
            if maxLen >= 2 {
                for length in stride(from: maxLen, through: 2, by: -1) {
                    let candidate = String(run[i..<(i + length)])
                    if kanaVocabulary.contains(candidate) || functionWords.contains(candidate) {
                        matched = candidate
                        break
                    }
                }
            }
            if let word = matched {
                flush()
                tokens.append(word)
                i += word.count
            } else {
                let ch = run[i]
                // 无法成词的字符先累积；小假名自然并入同一段，不会被单独拆开
                pending.append(ch)
                i += 1
            }
        }
        flush()
        return tokens
    }

    private func resolveKanji(_ chars: [Character], at index: Int) -> (String, Int) {
        let character = chars[index]

        // 1) 词组最长匹配
        let maxLength = min(12, chars.count - index)
        if maxLength >= 2 {
            for length in stride(from: maxLength, through: 2, by: -1) {
                let candidate = String(chars[index..<(index + length)])
                if let reading = wordReadings[candidate] {
                    return (reading, length)
                }
            }
        }

        let candidates = kanjiEntries[character] ?? []
        let following = String(chars[(index + 1)...])

        // 2) 送假名精确匹配：辞书形原样出现（開く…）
        if let exact = candidates.filter({ !$0.tail.isEmpty && following.hasPrefix($0.tail) })
                                    .max(by: { $0.tail.count < $1.tail.count }) {
            return (exact.reading, 1 + exact.tail.count)
        }

        // 3) 动词活用拆分：開いて -> ひら + いて；食べて -> た + べて
        if let nextCharacter = following.first, isKana(nextCharacter),
           let conjugated = candidates.first(where: { candidate in
               guard let tailKana = candidate.tail.last,
                     readingLengthUsable(candidate) else { return false }
               return canConjugate(tail: tailKana, to: nextCharacter)
           }) {
            let stem = String(conjugated.reading.dropLast(conjugated.tail.count))
            return (stem, 1)
        }

        // 4) 单字读音兜底（优先无送假名的独立条目）
        if let single = candidates.first(where: { $0.tail.isEmpty })?.reading
            ?? candidates.first?.reading {
            return (single, 1)
        }
        return (String(character), 1)
    }

    private func readingLengthUsable(_ candidate: (tail: String, reading: String)) -> Bool {
        candidate.reading.count > candidate.tail.count
    }

    private func canConjugate(tail: Character, to following: Character) -> Bool {
        // て形的促音便：書いて / 読んで / 買って…
        if following == "っ" || following == "ッ" {
            return "くぐむぶぬすつるう".contains(tail)
        }
        if let row = conjugationRows[tail], row.contains(following) { return true }
        // 一段动词：見て / 見た
        if tail == "る", "たてだで".contains(following) { return true }
        return false
    }

    // MARK: - 字符判断

    private func isKanji(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value)
    }

    private func isKana(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x3041...0x3096).contains(value)
            || (0x30A1...0x30FA).contains(value)
            || value == 0x30FC
    }
}
