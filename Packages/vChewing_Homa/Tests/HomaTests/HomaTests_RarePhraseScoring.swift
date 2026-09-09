// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import HomaSharedTestComponents
import Testing

@testable import Homa

// MARK: - HomaTestsRoot.HomaTests_RarePhraseScoring

extension HomaTestsRoot {
  /// 組句評分中，零頻兜底詞的長度縮放測試。
  ///
  /// 詞庫給零頻詞條的兜底分數是**固定值**、不隨音節數縮放，因此一個從未出現過的四音節
  /// 詞與一個從未出現過的雙音節詞領到相同的分數。DP 累加各節點的對數機率、節點越少總分
  /// 越高，於是這類長的零頻詞會系統性地擊敗逐字組合。原廠詞庫中，光是雙音節就有七千餘筆
  /// 「兩字皆常用、卻仍會被零頻詞蓋過」的讀音組合。
  struct HomaTests_RarePhraseScoring: HomaTestSuite {
    // MARK: Internal

    /// 迴歸測試：領兜底分數的雙音節詞，不得擊敗兩個常用單字的逐字組合。
    ///
    /// 權重取自原廠詞庫的真實數值：兜底分數為 -9.32，而兩個「中等常用度」單字的分數和
    /// 落在 -10.9 至 -11.9 之間——僅憑原始分數，零頻詞會以近 2 分的優勢勝出。
    @Test("[Homa] RarePhraseScoring_ZeroFrequencyPhraseMustLoseToPerCharPath")
    func testZeroFrequencyPhraseMustLoseToPerCharPath() throws {
      let assembled = try assemble(floor: Homa.Assembler.defaultRarePhrasePerSyllableFloor)
      #expect(assembled == ["甲", "乙"])
    }

    /// 對照組：停用長度縮放後，零頻詞會如實重現此前的病灶。
    @Test("[Homa] RarePhraseScoring_DisablingTheFloorReproducesThePathology")
    func testDisablingTheFloorReproducesThePathology() throws {
      let assembled = try assemble(floor: nil)
      #expect(assembled == ["甲乙"])
    }

    /// 未觸及零頻門檻的詞不受影響：正常的雙音節詞仍應勝過逐字組合。
    ///
    /// 這是本機制的分寸所在——它只矯正兜底分數不隨長度縮放這一件事，
    /// 不介入任何有真實語料支撐的詞條之評分。
    @Test("[Homa] RarePhraseScoring_NormalPhraseKeepsWinning")
    func testNormalPhraseKeepsWinning() throws {
      // 「甲乙」改為 -8.0（高於 -9.2 門檻）即不受縮放約束，仍應壓過逐字組合的 -11.0。
      let assembled = try assemble(
        floor: Homa.Assembler.defaultRarePhrasePerSyllableFloor,
        phraseScore: -8.0
      )
      #expect(assembled == ["甲乙"])
    }

    /// 單音節元圖不受長度縮放影響（否則罕用字會被無謂地再降一次權）。
    @Test("[Homa] RarePhraseScoring_SingleSyllableGramIsExempt")
    func testSingleSyllableGramIsExempt() throws {
      // k1 位置上只有一個領兜底分數的單音節候選，別無選擇，必須照常選中。
      let mockLM = TestLM(rawData: "k1 丙 -9.32")
      let assembler = Homa.Assembler(gramQuerier: { mockLM.queryGrams($0) })
      try assembler.insertKey("k1")
      #expect(assembler.assemble().values == ["丙"])
    }

    // MARK: Private

    /// 語料：雙音節的「甲乙」領兜底分數，而「甲」「乙」兩個單字皆屬中等常用度。
    /// 僅憑原始分數，-9.32 會勝過 -5.5 + -5.5 = -11.0。
    private func assemble(floor: Double?, phraseScore: Double = -9.32) throws -> [String] {
      let mockLM = TestLM(rawData: """
      k1 甲 -5.5
      k2 乙 -5.5
      k1-k2 甲乙 \(phraseScore)
      """)
      let assembler = Homa.Assembler(
        gramQuerier: { mockLM.queryGrams($0) },
        rarePhrasePerSyllableFloor: floor
      )
      try assembler.insertKey("k1")
      try assembler.insertKey("k2")
      return assembler.assemble().values
    }
  }
}
