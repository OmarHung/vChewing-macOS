// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Testing

@testable import LexiconAssembly

// MARK: - POMTestSuite.POMGramShapingTests

extension POMTestSuite {
  /// POM 語境記憶注入 Homa 時的元圖塑形（B2 分級加分、B3 尾字退避）。
  ///
  /// - B2：語境元圖機率＝同讀音同值的詞庫分數＋ `kPOMContextBonusMax × w`（w ∈ [0, 1]，上限 6.0），
  ///   取代過去「直接以 POM 權重（約 −0.1）當機率、無條件壓倒詞庫」的全有全無行為。
  /// - B3：多字前文的記憶另派生一筆以前文尾字為條件、加分打八折的元圖；
  ///   Homa 對單字前文採尾字比對，故前一個詞換了分法時記憶仍能生效。
  @Suite(.serialized)
  final class POMGramShapingTests {
    // MARK: Internal

    // MARK: - 塑形函式本身（純函式、精確數值）

    /// 加分上限（`kPOMContextBonusMax`），以常數名稱引用、避免各測試寫死數值。
    static let maxBonus = LXAssembly.LXFacade.kPOMContextBonusMax

    /// 加分＝基準分數＋上限×強度；強度依 POM 權重相對於 `kWeightMultiplier` 換算。
    @Test
    func testShapedProbabilityIsBasePlusScaledBonus() throws {
      let pomWeight = -0.65 * LXAssembly.LXPerceptor.kWeightMultiplier
      let grams = LXAssembly.LXFacade.shapePOMContextualGrams(
        [(headReading: "ㄗㄞˋ", previous: "你", anterior: nil, candidate: "再", probability: pomWeight)],
        lexiconUnigrams: Self.zaiUnigrams
      )
      #expect(grams.count == 1, "單字前文不得派生尾字元圖：\(grams)")
      let gram = try #require(grams.first)
      #expect(gram.current == "再")
      #expect(gram.previous == "你")
      #expect(gram.keyArray == ["ㄗㄞˋ"])
      #expect(abs(gram.probability - (-5.012 + Self.maxBonus * 0.65)) < 1e-9)
    }

    /// 多字前文：另派生一筆尾字元圖，加分打八折；一般加分不得超過上限 `kPOMContextBonusMax`。
    @Test
    func testMultiCharPreviousSpawnsCharLevelTwin() throws {
      // 權重 −1.0 來自 `calculateWeight` 對「事件時間戳不早於查詢時間戳」的特例，
      // 已遠超 `kWeightMultiplier`，強度須截頂為 1。
      let grams = LXAssembly.LXFacade.shapePOMContextualGrams(
        [(headReading: "ㄗㄞˋ", previous: "分不清", anterior: nil, candidate: "再", probability: -1.0)],
        lexiconUnigrams: Self.zaiUnigrams
      )
      #expect(grams.count == 2)
      let wholeWord = try #require(grams.first { $0.previous == "分不清" })
      let charLevel = try #require(grams.first { $0.previous == "清" })
      #expect(abs(wholeWord.probability - (-5.012 + Self.maxBonus)) < 1e-9)
      #expect(abs(charLevel.probability - (-5.012 + Self.maxBonus * 0.8)) < 1e-9)
      #expect(wholeWord.probability > charLevel.probability)
      for gram in grams {
        #expect(gram.probability - (-5.012) <= LXAssembly.LXFacade.kPOMContextBonusMax + 1e-9)
      }
    }

    /// 尾字元圖與既有的單字前文記憶撞鍵時，只保留機率較高者。
    @Test
    func testCharLevelTwinIsDedupedKeepingHigherProbability() throws {
      let weak = -0.3 * LXAssembly.LXPerceptor.kWeightMultiplier
      let strong = -0.9 * LXAssembly.LXPerceptor.kWeightMultiplier
      // 甲：直接記在「清」之下的記憶較弱、多字前文的記憶較強 ⇒ 尾字版本勝出。
      let gramsA = LXAssembly.LXFacade.shapePOMContextualGrams(
        [
          (headReading: "ㄗㄞˋ", previous: "清", anterior: nil, candidate: "再", probability: weak),
          (headReading: "ㄗㄞˋ", previous: "分不清", anterior: nil, candidate: "再", probability: strong),
        ],
        lexiconUnigrams: Self.zaiUnigrams
      )
      let qingA = gramsA.filter { $0.previous == "清" }
      #expect(qingA.count == 1)
      #expect(abs((qingA.first?.probability ?? 0) - (-5.012 + Self.maxBonus * 0.9 * 0.8)) < 1e-9)
      // 乙：反之 ⇒ 保留直接記憶。
      let gramsB = LXAssembly.LXFacade.shapePOMContextualGrams(
        [
          (headReading: "ㄗㄞˋ", previous: "分不清", anterior: nil, candidate: "再", probability: weak),
          (headReading: "ㄗㄞˋ", previous: "清", anterior: nil, candidate: "再", probability: strong),
        ],
        lexiconUnigrams: Self.zaiUnigrams
      )
      let qingB = gramsB.filter { $0.previous == "清" }
      #expect(qingB.count == 1)
      #expect(abs((qingB.first?.probability ?? 0) - (-5.012 + Self.maxBonus * 0.9)) < 1e-9)
      #expect(gramsB.count == 2)
    }

    /// 詞庫裡查不到基準分數的資料值不予注入（與 ghost guard 一致的保底）。
    @Test
    func testUnknownValueIsDropped() {
      let grams = LXAssembly.LXFacade.shapePOMContextualGrams(
        [(headReading: "ㄗㄞˋ", previous: "你", anterior: nil, candidate: "嘞", probability: -0.05)],
        lexiconUnigrams: Self.zaiUnigrams
      )
      #expect(grams.isEmpty)
    }

    // MARK: - 經由 `unigramsFor` 注入（測試用 TextMap）

    /// 逐字路徑：注入的語境元圖機率＝詞庫分數＋ `kPOMContextBonusMax` × w（w 依實際記憶權重換算）。
    @Test
    func testInjectedGramUsesShapedProbability() throws {
      let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
      let memorizedAt = Date().timeIntervalSince1970 - 86_400 // 一天前：w 明確小於 1。
      instance.memorizePerception((ngramKey: "(ㄋㄧˇ,你)&(ㄗㄞˋ,再)", candidate: "再"), timestamp: memorizedAt)
      instance.memorizePerception(
        (ngramKey: "(ㄈㄣ-ㄅㄨˋ-ㄑㄧㄥ,分不清)&(ㄗㄞˋ,再)", candidate: "再"), timestamp: memorizedAt
      )

      let grams = instance.unigramsFor(keyArray: ["ㄗㄞˋ"])
      let base = try #require(grams.first { $0.isUnigram && $0.current == "再" }).probability
      let expectedWeight = instance.lxPerceptor.calculateWeight(
        eventCount: 1, totalCount: 1, eventTimestamp: memorizedAt, timestamp: Date().timeIntervalSince1970
      )
      let w = LXAssembly.LXFacade.pomMemoryStrength(of: expectedWeight)
      #expect(w > 0.3 && w < 0.7, "測試前提：w 應介於 0.3 與 0.7 之間，實得 \(w)")

      let niGram = try #require(grams.first { $0.current == "再" && $0.previous == "你" })
      #expect(abs(niGram.probability - (base + Self.maxBonus * w)) < 1e-3)
      // 單字前文「你」不派生尾字元圖。
      #expect(grams.filter { $0.current == "再" && $0.previous == "你" }.count == 1)
      // 多字前文「分不清」派生尾字元圖「清」，加分打八折。
      let wholeWord = try #require(grams.first { $0.current == "再" && $0.previous == "分不清" })
      let charLevel = try #require(grams.first { $0.current == "再" && $0.previous == "清" })
      #expect(abs(wholeWord.probability - (base + Self.maxBonus * w)) < 1e-3)
      #expect(abs(charLevel.probability - (base + Self.maxBonus * w * 0.8)) < 1e-3)
      // 任何語境元圖的加分都不得超過上限。
      for gram in grams where !gram.isUnigram {
        #expect(gram.probability - base <= LXAssembly.LXFacade.kPOMContextBonusMax + 1e-9)
      }
    }

    /// 聲調桶路徑採同一套塑形規則。
    @Test
    func testBucketPathUsesSameShaping() throws {
      let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
      instance.memorizePerception(
        (ngramKey: "(ㄈㄣ-ㄅㄨˋ-ㄑㄧㄥ,分不清)&(ㄗㄞˋ,再)", candidate: "再"),
        timestamp: Date().timeIntervalSince1970 - 60
      )
      let bucketQuery: [Homa.PossibleKey] = [.multipleKeys(["ㄗㄞ", "ㄗㄞˇ", "ㄗㄞˋ"])]
      let grams = instance.unigramsFor(keyArray: bucketQuery, partiallyMatch: false)
      let base = try #require(grams.first { $0.isUnigram && $0.current == "再" }).probability
      let wholeWord = try #require(grams.first { $0.current == "再" && $0.previous == "分不清" })
      let charLevel = try #require(grams.first { $0.current == "再" && $0.previous == "清" })
      let bonus = wholeWord.probability - base
      #expect(bonus > 1.5 && bonus <= LXAssembly.LXFacade.kPOMContextBonusMax)
      #expect(abs((charLevel.probability - base) - bonus * 0.8) < 1e-9)
    }

    /// Ghost guard 照舊：資料值不屬於本讀音的記憶不得注入（含尾字元圖）。
    @Test
    func testGhostGuardStillDropsUnknownValues() throws {
      let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
      instance.memorizePerception(
        (ngramKey: "(ㄈㄣ-ㄅㄨˋ-ㄑㄧㄥ,分不清)&(ㄗㄞˋ,嘞)", candidate: "嘞"),
        timestamp: Date().timeIntervalSince1970 - 60
      )
      #expect(!instance.unigramsFor(keyArray: ["ㄗㄞˋ"]).contains { $0.current == "嘞" })
      let bucketQuery: [Homa.PossibleKey] = [.multipleKeys(["ㄗㄞ", "ㄗㄞˇ", "ㄗㄞˋ"])]
      #expect(!instance.unigramsFor(keyArray: bucketQuery, partiallyMatch: false).contains { $0.current == "嘞" })
    }

    // MARK: - 端到端組句（Homa.Assembler × LXFacade）

    /// 「你再把」：零頻雙字詞「你在」（−9.32）原本吞掉使用者要的「再」。
    /// 選過一次「再」之後（新鮮記憶，w ≈ 0.65），組句即改為「你／再／把」；
    /// 將近過期的舊記憶則不足以推翻詞庫（分級而非全有全無）。
    ///
    /// - Remark: 詞庫刻意不收「再把」：若收了 −9.32 的「再把」，未記憶前的組句就已是
    /// 「你／再把」（−14.40 勝過「你在／把」的 −14.52），本測試便無從觀察記憶的效果。
    @Test
    func testNiZaiBaFlipsAfterOneMemorization() throws {
      let readings = ["ㄋㄧˇ", "ㄗㄞˋ", "ㄅㄚˇ"]
      // 未記憶：你在／把。
      do {
        let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
        defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
        #expect(try assemble(readings, with: instance) == ["你在", "把"])
      }
      // 選過一次「再」：你／再／把。
      do {
        let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
        defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
        instance.memorizePerception(
          (ngramKey: "(ㄋㄧˇ,你)&(ㄗㄞˋ,再)", candidate: "再"),
          timestamp: Date().timeIntervalSince1970 - 60
        )
        #expect(try assemble(readings, with: instance) == ["你", "再", "把"])
      }
      // 將近過期（7.5 天前）的記憶：加分趨近於零，不足以擊敗「你在」。
      do {
        let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
        defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
        instance.memorizePerception(
          (ngramKey: "(ㄋㄧˇ,你)&(ㄗㄞˋ,再)", candidate: "再"),
          timestamp: Date().timeIntervalSince1970 - 7.5 * 86_400
        )
        #expect(try assemble(readings, with: instance) == ["你在", "把"])
      }
    }

    /// 詞庫證據差距超過加分上限（6.0）者，語境記憶即便反覆選擇也無法推翻（分級而非全有全無）。
    @Test
    func testStrongLexiconEvidenceIsNotOverturned() throws {
      let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
      // 「載」(−11.5) 與首選「在」(−5.009) 相差約 6.5，超過加分上限；記三次以拉高強度。
      for _ in 0 ..< 3 {
        instance.memorizePerception(
          (ngramKey: "(ㄋㄧˇ,你)&(ㄗㄞˋ,載)", candidate: "載"),
          timestamp: Date().timeIntervalSince1970 - 60
        )
      }
      let result = try assemble(["ㄋㄧˇ", "ㄗㄞˋ", "ㄅㄚˇ"], with: instance)
      #expect(!result.contains("載"), "Got: \(result)")
    }

    /// 前一個詞換了分法：記憶時前文是「分不清」，如今前文是「看不清」。
    /// 整詞比對不中，靠 B3 的尾字元圖（前文「清」）命中。
    @Test
    func testCharLevelBackoffSurvivesDifferentPredecessorWord() throws {
      let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
      let readings = ["ㄎㄢˋ", "ㄅㄨˋ", "ㄑㄧㄥ", "ㄗㄞˋ"]
      #expect(try assemble(readings, with: instance) == ["看不清", "在"])
      instance.memorizePerception(
        (ngramKey: "(ㄈㄣ-ㄅㄨˋ-ㄑㄧㄥ,分不清)&(ㄗㄞˋ,再)", candidate: "再"),
        timestamp: Date().timeIntervalSince1970 - 60
      )
      #expect(try assemble(readings, with: instance) == ["看不清", "再"])
      // 原本的整詞語境照常生效。
      #expect(try assemble(["ㄈㄣ", "ㄅㄨˋ", "ㄑㄧㄥ", "ㄗㄞˋ"], with: instance) == ["分不清", "再"])
    }

    /// 反方向：記憶時「清」是獨立的單字節點（前文＝「清」），如今前文是三字詞「分不清」。
    /// 單字前文元圖經 Homa 的尾字比對命中。
    @Test
    func testSingleCharMemorySurvivesMultiCharPredecessorWord() throws {
      let instance = try makeInstance(textMap: Self.niZaiBaTextMap())
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
      let readings = ["ㄈㄣ", "ㄅㄨˋ", "ㄑㄧㄥ", "ㄗㄞˋ"]
      #expect(try assemble(readings, with: instance) == ["分不清", "在"])
      instance.memorizePerception(
        (ngramKey: "(ㄅㄨˋ,不)&(ㄑㄧㄥ,清)&(ㄗㄞˋ,再)", candidate: "再"),
        timestamp: Date().timeIntervalSince1970 - 60
      )
      // 三段式記憶帶 anterior「不」，與此處的實際前驅二位（無）不符，故改用二段式記憶驗證。
      #expect(try assemble(readings, with: instance) == ["分不清", "在"])
      instance.memorizePerception(
        (ngramKey: "(ㄑㄧㄥ,清)&(ㄗㄞˋ,再)", candidate: "再"),
        timestamp: Date().timeIntervalSince1970 - 60
      )
      #expect(try assemble(readings, with: instance) == ["分不清", "再"])
    }

    // MARK: Private

    /// 讀音 ㄗㄞˋ 的詞庫單元圖（已依分數遞減排序）。
    private static let zaiUnigrams: [Homa.Gram] = [
      .init(keyArray: ["ㄗㄞˋ"], value: "在", score: -5.009),
      .init(keyArray: ["ㄗㄞˋ"], value: "再", score: -5.012),
      .init(keyArray: ["ㄗㄞˋ"], value: "載", score: -11.5),
    ]

    /// 測試用迷你詞庫：分數取自原廠詞庫的實際量級（單字首選 −5.0 至 −5.3、零頻詞 −9.32）。
    private static func niZaiBaTextMap() -> String {
      makeTypingTextMap([
        ("ㄋㄧˇ", [("你", -5.079)]),
        ("ㄗㄞˋ", [("在", -5.009), ("再", -5.012), ("載", -11.5)]),
        ("ㄅㄚˇ", [("把", -5.2)]),
        ("ㄋㄧˇ-ㄗㄞˋ", [("你在", -9.32)]),
        ("ㄈㄣ", [("分", -5.1)]),
        ("ㄅㄨˋ", [("不", -5.0)]),
        ("ㄑㄧㄥ", [("清", -5.2)]),
        ("ㄎㄢˋ", [("看", -5.1)]),
        ("ㄈㄣ-ㄅㄨˋ-ㄑㄧㄥ", [("分不清", -7.532)]),
        ("ㄎㄢˋ-ㄅㄨˋ-ㄑㄧㄥ", [("看不清", -7.0)]),
      ])
    }

    /// 產生 Vanguard TYPING 格式的 TextMap（與 LibVanguardTests 的同名工具一致）。
    private static func makeTypingTextMap(_ entriesByKey: [(String, [(String, Double)])]) -> String {
      let chtTypeID: Int32 = 6
      var valueLines: [String] = []
      var keyLines: [String] = []
      for (key, entries) in entriesByKey {
        let startLine = valueLines.count
        for (value, probability) in entries {
          valueLines.append("\(value)\t\(probability)\t\(chtTypeID)")
        }
        keyLines.append("\(key)\t\(startLine)\t\(entries.count)")
      }
      var result = "#PRAGMA:VANGUARD_HOMA_LEXICON_HEADER\n"
      result += "VERSION\t1.1\nTYPE\tTYPING\nREADING_SEPARATOR\t-\n"
      result += "ENTRY_COUNT\t\(valueLines.count)\nKEY_COUNT\t\(keyLines.count)\n"
      result += "#PRAGMA:VANGUARD_HOMA_LEXICON_VALUES\n"
      valueLines.forEach { result += $0 + "\n" }
      result += "#PRAGMA:VANGUARD_HOMA_LEXICON_KEY_LINE_MAP\n"
      keyLines.forEach { result += $0 + "\n" }
      return result
    }

    private func makeInstance(textMap: String) throws -> LXAssembly.LXFacade {
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      try #require(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
      let instance = LXAssembly.LXFacade()
      instance.setOptions { $0.fetchSuggestionsFromPerceptionOverrideModel = true }
      return instance
    }

    private func assemble(_ readings: [String], with instance: LXAssembly.LXFacade) throws -> [String] {
      let assembler = Homa.Assembler(
        gramQuerier: { instance.unigramsFor(keyArray: $0, partiallyMatch: false) }
      )
      try readings.forEach { try assembler.insertKey($0) }
      return assembler.assemble().values
    }
  }
}
