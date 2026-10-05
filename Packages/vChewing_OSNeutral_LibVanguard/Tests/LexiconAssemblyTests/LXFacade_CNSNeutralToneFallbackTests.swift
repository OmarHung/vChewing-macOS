// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Testing

@testable import LexiconAssembly

/// 「僅允許 CNS 讀音」（`filterNonCNSReadings`）的輕聲容錯測試。
///
/// 臺灣使用者習慣以一聲（不標聲調）輸入輕聲語助詞（例：以 ㄇㄚ 打「嗎」），
/// 但 CNS 11643 只把「嗎」列在 ㄇㄚ˙ 之下。`checkCNSConformation` 須在不帶聲調的讀音
/// 查無該字時，改查「讀音＋˙」的 CNS 清單，避免「嗎」被降權至 −9.5 而讓「媽」勝出。
@Suite(.serialized)
struct LXFacadeCNSNeutralToneFallbackTests {
  // MARK: Internal

  /// 「嗎」只見於 ㄇㄚ˙ 的 CNS 清單：在 ㄇㄚ 之下應保留原始權重並維持首選。
  @Test
  func testNeutralToneParticleKeepsWeightUnderTonelessKey() throws {
    let instance = try makeInstance(filterNonCNSReadings: true)
    defer { Self.restoreDefaultFactoryDictionary() }

    let grams = instance.unigramsFor(keyArray: ["ㄇㄚ"])
    #expect(probability(of: "嗎", in: grams) == -5.1)
    #expect(probability(of: "媽", in: grams) == -5.2)
    #expect(grams.first?.current == "嗎")
  }

  /// 兩份 CNS 清單皆未收錄的字仍應降權至 −9.5。
  @Test
  func testCharacterAbsentFromBothCNSListsIsStillDemoted() throws {
    let instance = try makeInstance(filterNonCNSReadings: true)
    defer { Self.restoreDefaultFactoryDictionary() }

    let grams = instance.unigramsFor(keyArray: ["ㄇㄚ"])
    #expect(probability(of: "抹", in: grams) == -9.5)
  }

  /// 已帶聲調的讀音（ㄇㄚˊ）不得參考輕聲清單：
  /// 不論是「剝除聲調後補 ˙」（ㄇㄚ˙）或「直接補 ˙」（ㄇㄚˊ˙），「嗎」都應降權。
  @Test
  func testTonedKeyDoesNotConsultNeutralToneList() throws {
    let instance = try makeInstance(filterNonCNSReadings: true)
    defer { Self.restoreDefaultFactoryDictionary() }

    let grams = instance.unigramsFor(keyArray: ["ㄇㄚˊ"])
    #expect(probability(of: "麻", in: grams) == -5.0)
    #expect(probability(of: "嗎", in: grams) == -9.5)
    #expect(grams.first?.current == "麻")
  }

  /// 關閉過濾時，所有權重維持詞庫原值。
  @Test
  func testFilterDisabledLeavesScoresUntouched() throws {
    let instance = try makeInstance(filterNonCNSReadings: false)
    defer { Self.restoreDefaultFactoryDictionary() }

    let tonelessGrams = instance.unigramsFor(keyArray: ["ㄇㄚ"])
    #expect(probability(of: "嗎", in: tonelessGrams) == -5.1)
    #expect(probability(of: "媽", in: tonelessGrams) == -5.2)
    #expect(probability(of: "抹", in: tonelessGrams) == -5.3)
    let tonedGrams = instance.unigramsFor(keyArray: ["ㄇㄚˊ"])
    #expect(probability(of: "麻", in: tonedGrams) == -5.0)
    #expect(probability(of: "嗎", in: tonedGrams) == -5.1)
  }

  // MARK: Private

  private static let chtTypeID: Int32 = 6
  private static let cnsTypeID: Int32 = 7

  /// 測試用迷你詞庫：
  /// - 原廠繁體（type 6）：ㄇㄚ → 嗎／媽／抹；ㄇㄚˊ → 麻／嗎。
  /// - CNS（type 7）：ㄇㄚ → 媽；ㄇㄚ˙ → 嗎；ㄇㄚˊ → 麻；ㄇㄚˊ˙ → 嗎（用以抓出「直接補 ˙」的錯誤實作）。
  private static func neutralToneTextMap() -> String {
    makeTypingTextMap([
      ("ㄇㄚ", [("嗎", -5.1, chtTypeID), ("媽", -5.2, chtTypeID), ("抹", -5.3, chtTypeID), ("媽", -11, cnsTypeID)]),
      ("ㄇㄚ˙", [("嗎", -11, cnsTypeID)]),
      ("ㄇㄚˊ", [("麻", -5.0, chtTypeID), ("嗎", -5.1, chtTypeID), ("麻", -11, cnsTypeID)]),
      ("ㄇㄚˊ˙", [("嗎", -11, cnsTypeID)]),
    ])
  }

  /// 產生 Vanguard TYPING 格式的 TextMap（每筆條目自帶 typeID）。
  private static func makeTypingTextMap(_ entriesByKey: [(String, [(String, Double, Int32)])]) -> String {
    var valueLines: [String] = []
    var keyLines: [String] = []
    for (key, entries) in entriesByKey {
      let startLine = valueLines.count
      for (value, probability, typeID) in entries {
        valueLines.append("\(value)\t\(probability)\t\(typeID)")
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

  private static func restoreDefaultFactoryDictionary() {
    LXAssembly.LXFacade.disconnectFactoryDictionary()
    _ = LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData)
  }

  private func makeInstance(filterNonCNSReadings: Bool) throws -> LXAssembly.LXFacade {
    LXAssembly.LXFacade.disconnectFactoryDictionary()
    try #require(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: Self.neutralToneTextMap()))
    let instance = LXAssembly.LXFacade(isCHS: false)
    instance.setOptions { config in
      config.isCNSEnabled = false
      config.isSymbolEnabled = false
      config.alwaysSupplyETenDOSUnigrams = false
      config.filterNonCNSReadings = filterNonCNSReadings
    }
    return instance
  }

  private func probability(of value: String, in grams: [Homa.Gram]) -> Double? {
    grams.first(where: { $0.current == value })?.probability
  }
}
