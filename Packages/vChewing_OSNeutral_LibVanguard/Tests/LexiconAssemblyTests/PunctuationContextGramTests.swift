// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Testing

@testable import LexiconAssembly

// MARK: - PunctuationContextGramTests

/// 句末語氣詞後接全形標點的語境元圖（`LXFacade_PunctuationContextGrams.swift`）。
///
/// - 只對「恰為單一索引鍵、以 `_punctuation_` 起首」的讀音鍵注入（`_punctuation_list` 除外）；
///   半形與帶修飾鍵的標點鍵名不以 `_punctuation_` 起首，故不受影響。
/// - 以標點單元圖的**資料值**比對表格，注入分數＝該單元圖分數＋ `kParticlePunctuationBonus`。
/// - 逐字路徑與聲調桶（替代讀音）路徑皆注入。
@Suite(.serialized)
struct PunctuationContextGramTests {
  static let bonus = LXAssembly.LXFacade.kParticlePunctuationBonus

  // MARK: - 純函式

  /// 「？」：注入表內每個疑問語氣詞各一筆，分數＝單元圖分數＋加分。
  @Test
  func testQuestionMarkGramsFromPureFunction() throws {
    let key = ["_punctuation_?"]
    let grams = LXAssembly.LXFacade.punctuationContextGrams(
      keyArray: key,
      lexiconUnigrams: [Homa.Gram(keyArray: key, value: "？", score: -0.5)]
    )
    #expect(grams.map { $0.previous ?? "" } == LXAssembly.LXFacade.kParticlesBeforeQuestionMark)
    #expect(grams.map { $0.previous ?? "" } == ["嗎", "呢", "吧", "嘛", "啊", "呀", "哦", "喔", "麼"])
    for gram in grams {
      #expect(gram.current == "？")
      #expect(gram.keyArray == key)
      #expect(gram.anterior == nil)
      #expect(abs(gram.probability - (-0.5 + Self.bonus)) < 1e-12)
    }
    #expect(Self.bonus == 1.0)
  }

  /// 表外的標點、半形／帶修飾鍵的標點、符號選單、一般讀音：一律不注入。
  @Test
  func testNoGramsForIneligibleKeysOrValues() {
    func grams(_ key: String, _ value: String) -> [Homa.Gram] {
      LXAssembly.LXFacade.punctuationContextGrams(
        keyArray: [key], lexiconUnigrams: [Homa.Gram(keyArray: [key], value: value, score: 0)]
      )
    }
    #expect(grams("_punctuation_(", "（").isEmpty)
    #expect(grams("_punctuation_>", "．").isEmpty)
    #expect(grams("_half_punctuation_?", "?").isEmpty)
    #expect(grams("_half_punctuation_?", "？").isEmpty)
    #expect(grams("_ctrl_punctuation_.", "。").isEmpty)
    #expect(grams("_alt_punctuation_;", "；").isEmpty)
    #expect(grams("_shift_alt_punctuation_1", "！").isEmpty)
    #expect(grams("_punctuation_list", "？").isEmpty)
    #expect(grams("ㄇㄚ", "？").isEmpty)
    #expect(
      LXAssembly.LXFacade.punctuationContextGrams(
        keyArray: ["_punctuation_?", "_punctuation_?"],
        lexiconUnigrams: [Homa.Gram(keyArray: ["_punctuation_?"], value: "？", score: 0)]
      ).isEmpty
    )
  }

  /// 每個表內標點各自對應正確的語氣詞清單；同值的單元圖只以最高分者（首筆）為基準。
  @Test
  func testTableCoverageAndFirstUnigramBase() {
    let table = LXAssembly.LXFacade.kParticlesBeforePunctuation
    #expect(Set(table.keys) == ["？", "！", "。", "，", "；", "："])
    #expect(table["！"] == ["啊", "呀", "吧", "啦", "耶", "喔", "哦", "囉", "哇", "呢"])
    for value in ["。", "，", "；", "："] {
      #expect(table[value] == ["吧", "呢", "啦", "嘛", "啊", "呀", "喔", "哦", "囉"])
    }
    let key = ["_punctuation_Standard_>"]
    let grams = LXAssembly.LXFacade.punctuationContextGrams(
      keyArray: key,
      lexiconUnigrams: [
        Homa.Gram(keyArray: key, value: "。", score: 0),
        Homa.Gram(keyArray: key, value: "〉", score: -1),
        Homa.Gram(keyArray: key, value: "。", score: -2),
      ]
    )
    #expect(grams.count == table["。"]?.count)
    #expect(grams.allSatisfy { $0.current == "。" && abs($0.probability - Self.bonus) < 1e-12 })
  }

  // MARK: - 經由 LXFacade（測試用 TextMap）

  /// 逐字路徑：測試用 TextMap 的 `_punctuation_?` → 「？」。單元圖之後附加語境元圖；
  /// 半形標點鍵與表外標點鍵則只有單元圖。
  @Test
  func testFacadeInjectsGramsOnSingleKeyPath() throws {
    defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
    let instance = LXAssembly.LXFacade(isCHS: false)

    let question = instance.unigramsFor(keyArray: ["_punctuation_?"])
    let unigrams = question.filter(\.isUnigram)
    let contextual = question.filter { !$0.isUnigram }
    // 首選為全形「？」（其後可能另有半形「?」等單元圖，但不在表內、不派生語境元圖）。
    #expect(unigrams.first?.current == "？")
    let base = try #require(unigrams.first?.probability)
    #expect(Set(contextual.compactMap(\.previous)) == Set(LXAssembly.LXFacade.kParticlesBeforeQuestionMark))
    #expect(contextual.count == LXAssembly.LXFacade.kParticlesBeforeQuestionMark.count)
    #expect(contextual.allSatisfy { $0.current == "？" && $0.keyArray == ["_punctuation_?"] })
    #expect(contextual.allSatisfy { abs($0.probability - (base + Self.bonus)) < 1e-12 })
    // 語境元圖附加於單元圖之後（節點以首個單元圖為基準）。
    #expect(question.first?.isUnigram == true)
    // 再查一次（命中 LRU 快取）結果相同。
    #expect(instance.unigramsFor(keyArray: ["_punctuation_?"]) == question)

    let exclamation = instance.unigramsFor(keyArray: ["_punctuation_!"])
    #expect(
      Set(exclamation.filter { !$0.isUnigram }.compactMap(\.previous))
        == Set(LXAssembly.LXFacade.kParticlesBeforeExclamationMark)
    )
    // 逗號與句號依鍵盤排列落在不同鍵名之下，以資料值比對。
    let comma = instance.unigramsFor(keyArray: ["_punctuation_Standard_<"])
    #expect(comma.filter { !$0.isUnigram }.allSatisfy { $0.current == "，" })
    #expect(!comma.filter { !$0.isUnigram }.isEmpty)

    #expect(!instance.unigramsFor(keyArray: ["_half_punctuation_?"]).isEmpty)
    #expect(instance.unigramsFor(keyArray: ["_half_punctuation_?"]).allSatisfy { $0.isUnigram })
    #expect(!instance.unigramsFor(keyArray: ["_punctuation_("]).isEmpty)
    #expect(instance.unigramsFor(keyArray: ["_punctuation_("]).allSatisfy { $0.isUnigram })
  }

  /// 聲調桶（替代讀音）路徑同樣注入。
  @Test
  func testFacadeInjectsGramsOnAlternativesPath() throws {
    defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
    let instance = LXAssembly.LXFacade(isCHS: false)

    let grams = instance.unigramsFor(
      keyArray: [.multipleKeys(["_punctuation_?", "_punctuation_("])],
      partiallyMatch: false
    )
    let contextual = grams.filter { !$0.isUnigram }
    #expect(grams.contains { $0.isUnigram && $0.current == "？" })
    #expect(Set(contextual.compactMap(\.previous)) == Set(LXAssembly.LXFacade.kParticlesBeforeQuestionMark))
    #expect(contextual.allSatisfy { $0.current == "？" })
    let base = try #require(grams.first { $0.isUnigram && $0.current == "？" }?.probability)
    #expect(contextual.allSatisfy { abs($0.probability - (base + Self.bonus)) < 1e-12 })
  }
}
