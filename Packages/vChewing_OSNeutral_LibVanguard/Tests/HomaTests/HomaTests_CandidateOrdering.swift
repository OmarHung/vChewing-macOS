// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import HomaSharedTestComponents
import Testing

@testable import Homa

// MARK: - HomaTestsRoot.HomaTests_CandidateOrdering

extension HomaTestsRoot {
  /// 選字窗排序測試：驗證極罕見詞會沉至末尾，而其餘候選維持既有的詞長優先排序。
  ///
  /// 語料的權重取自原廠詞庫的真實分數分佈。該詞庫的分數存在一個地板（-9.32），最低的
  /// 一批詞條全部聚集於此——那是詞典有收、但語料中不曾出現的零頻詞條所領的兜底分數。
  struct HomaTests_CandidateOrdering: HomaTestSuite {
    // MARK: Internal

    /// 迴歸測試：領兜底分數的零頻長詞，不得單憑詞長佔據選字窗前列。
    ///
    /// 先前的排序鍵為 tuple `(segLength, weight, joinedKey)`，`segLength` 作為第一鍵
    /// 完全支配 `weight`，導致任何四音節詞都排在任何雙音節詞之前、無視兩者權重相差
    /// 幾個數量級。原廠詞庫收錄了大量頻次為 0 的詞條，這些詞因而長期佔據選字窗前列。
    @Test("[Homa] CandidateOrdering_ZeroFrequencyLongWordMustSinkToBottom")
    func testZeroFrequencyLongWordMustSinkToBottom() throws {
      let ordered = try fetchOrderedValues(
        threshold: Homa.Assembler.defaultRarityThreshold
      )
      // 領兜底分數的四音節詞沉至末位。
      #expect(ordered.last == "丙丙丙丙")
      // 其餘候選維持詞長優先：高頻四音節詞居首，雙音節次之，單音節在後。
      #expect(ordered == ["丁丁丁丁", "乙乙", "甲", "乙", "丙丙丙丙"])
    }

    /// 未觸及門檻的候選一律不受影響，詞長優先的既有語義完整保留。
    ///
    /// 這是刻意的克制：詞長排序承載著「敲了三個音通常是想要一個三字詞」這項輸入預期，
    /// 且選字窗不會高亮當前組句選中的詞、首項即是預設選項。若讓權重全面凌駕詞長，
    /// 敲完「水果汁」後首項會變成權重更高的「果汁」，一選就把正確的組字拆掉。
    @Test("[Homa] CandidateOrdering_NonRareCandidatesKeepLengthPriority")
    func testNonRareCandidatesKeepLengthPriority() throws {
      // 門檻壓到地板之下 → 無候選被判為罕見 → 應與歷史排序完全一致。
      let legacy = try fetchOrderedValues(threshold: -.infinity)
      #expect(legacy == ["丁丁丁丁", "丙丙丙丙", "乙乙", "甲", "乙"])
      // 對照：預設門檻下，除了那個零頻詞被移到末尾之外，其餘相對次序不變。
      let ordered = try fetchOrderedValues(
        threshold: Homa.Assembler.defaultRarityThreshold
      )
      #expect(legacy.filter { $0 != "丙丙丙丙" } == ordered.filter { $0 != "丙丙丙丙" })
    }

    /// 門檻本身是可調的：調高門檻會讓更多候選被判為罕見而沉底。
    @Test("[Homa] CandidateOrdering_ThresholdIsHonoured")
    func testThresholdIsHonoured() throws {
      // 門檻抬到 -6 時，「乙」（-6.4）與「丙丙丙丙」（-9.32）都落入罕見區。
      let ordered = try fetchOrderedValues(threshold: -6)
      #expect(ordered == ["丁丁丁丁", "乙乙", "甲", "丙丙丙丙", "乙"])
    }

    /// 組字器的拷貝必須沿用原組字器的罕見門檻與每音節代價，否則拷貝體（例如供預覽或
    /// 回溯用的副本）的選字窗排序與組句結果會與原組字器不一致。
    @Test("[Homa] CandidateOrdering_CopyCarriesRarityParameters")
    func testCopyCarriesRarityParameters() throws {
      let mockLX = TestLX(rawData: Self.sampleData)
      let assembler = Homa.Assembler(
        gramQuerier: { mockLX.queryGrams($0) },
        rarityThreshold: -6,
        rarePhrasePerSyllableFloor: -4.5
      )
      let copied = assembler.copy
      #expect(copied.rarityThreshold == -6)
      #expect(copied.rarePhrasePerSyllableFloor == -4.5)
      // 預設值：罕見門檻為原廠詞庫校準所得的數值（選字窗沉底維持啟用），
      // 組句評分的長度縮放則預設停用（詳見 `Homa.Assembler.suggestedRarePhrasePerSyllableFloor`）。
      let defaulted = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) })
      #expect(defaulted.rarityThreshold == Homa.Assembler.defaultRarityThreshold)
      #expect(defaulted.rarePhrasePerSyllableFloor == nil)
      #expect(defaulted.copy.rarePhrasePerSyllableFloor == nil)
    }

    // MARK: Private

    /// 語料：k1 起始處同時存在單音節、雙音節與四音節候選，用以觀察三者的相對次序。
    /// 「丙丙丙丙」領的正是原廠詞庫地板值 -9.32 的兜底分數，「丁丁丁丁」則是高頻四音節詞。
    private static let sampleData = """
    k1 甲 -5.1
    k1 乙 -6.4
    k2 丑 -5.5
    k3 寅 -5.5
    k4 卯 -5.5
    k1-k2 乙乙 -5.14
    k1-k2-k3-k4 丙丙丙丙 -9.32
    k1-k2-k3-k4 丁丁丁丁 -5.25
    """

    /// 以指定的罕見門檻取回 k1 位置上的候選字詞值（按選字窗實際排序）。
    private func fetchOrderedValues(threshold: Double) throws -> [String] {
      let mockLX = TestLX(rawData: Self.sampleData)
      let assembler = Homa.Assembler(
        gramQuerier: { mockLX.queryGrams($0) },
        rarityThreshold: threshold
      )
      for key in ["k1", "k2", "k3", "k4"] {
        try assembler.insertKey(key)
      }
      return assembler.fetchCandidates(at: 0, filter: .beginAt).map(\.pair.value)
    }
  }
}
