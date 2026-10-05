// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import HomaSharedTestComponents
import Testing

@testable import Homa

// MARK: - HomaTestsRoot.HomaTests_ContextSuffixMatch

extension HomaTestsRoot {
  /// 語境元圖的「尾字比對」（B3 字級退避）。
  ///
  /// 元圖的 `previous` 恰為單一字元時，只要 DP 前述節點的詞值以該字元結尾即算命中，
  /// 用以容忍前一個詞換了分法（「分不清」vs「清」）的情形。整詞比對照舊有效；
  /// `anterior` 則一律維持整詞比對。
  struct HomaTests_ContextSuffixMatch: HomaTestSuite {
    /// 共用詞庫：「分不清」為單一節點，ㄗㄞˋ 的首選為「在」（與「再」近乎同分）。
    static let baseLexicon = """
    ㄨㄛˇ 我 -5
    ㄇㄣ˙ 們 -5
    ㄨㄛˇ-ㄇㄣ˙ 我們 -4
    ㄈㄣ 分 -5
    ㄅㄨˋ 不 -5
    ㄑㄧㄥ 清 -5
    ㄈㄣ-ㄅㄨˋ-ㄑㄧㄥ 分不清 -4
    ㄗㄞˋ 在 -5.009
    ㄗㄞˋ 再 -5.012
    ㄗㄞˋ 載 -6
    """

    static let readings = ["ㄈㄣ", "ㄅㄨˋ", "ㄑㄧㄥ", "ㄗㄞˋ"]

    private func assemble(extraGrams: String, readings: [String] = Self.readings) throws -> [String] {
      let mockLX = TestLX(rawData: Self.baseLexicon + "\n" + extraGrams)
      let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) })
      try readings.forEach { try assembler.insertKey($0) }
      return assembler.assemble().values
    }

    @Test("[Homa] Context Previous Matcher Rules")
    func testContextPreviousMatcherRules() {
      // 整詞比對。
      #expect(Homa.Node.contextPreviousMatches("分不清", actualPrevious: "分不清"))
      #expect(Homa.Node.contextPreviousMatches("清", actualPrevious: "清"))
      // 單字前文：尾字比對。
      #expect(Homa.Node.contextPreviousMatches("清", actualPrevious: "分不清"))
      #expect(!Homa.Node.contextPreviousMatches("分", actualPrevious: "分不清"))
      // 多字前文：不做尾字比對。
      #expect(!Homa.Node.contextPreviousMatches("不清", actualPrevious: "分不清"))
      // 空值／nil 一律不命中。
      #expect(!Homa.Node.contextPreviousMatches(nil, actualPrevious: "分不清"))
      #expect(!Homa.Node.contextPreviousMatches("", actualPrevious: "分不清"))
      // 以 Character 比對：帶異體字選擇器的尾字不得被拆開誤判。
      let kanjiWithIVS = "葛\u{E0100}"
      #expect(!Homa.Node.contextPreviousMatches("葛", actualPrevious: "諸" + kanjiWithIVS))
      #expect(Homa.Node.contextPreviousMatches(kanjiWithIVS, actualPrevious: "諸" + kanjiWithIVS))
    }

    /// (a) 單字前文元圖可匹配以該字結尾的多字前述節點，且勝過單元圖基線。
    @Test("[Homa] Single-Char Previous Matches Multi-Char Predecessor Suffix")
    func testSingleCharPreviousMatchesSuffix() throws {
      // 對照：無語境元圖時，ㄗㄞˋ 取首選「在」。
      #expect(try assemble(extraGrams: "") == ["分不清", "在"])
      #expect(try assemble(extraGrams: "ㄗㄞˋ 再 -3.5 清") == ["分不清", "再"])
    }

    /// (b) 多字前文元圖不做尾字比對。
    @Test("[Homa] Multi-Char Previous Does Not Suffix Match")
    func testMultiCharPreviousDoesNotSuffixMatch() throws {
      #expect(try assemble(extraGrams: "ㄗㄞˋ 再 -3.5 不清") == ["分不清", "在"])
    }

    /// (c) 整詞元圖與單字前文元圖同時命中時，取機率較高者。
    @Test("[Homa] Higher Probability Wins Between Whole-Word And Suffix Matches")
    func testHigherProbabilityWinsBetweenWholeWordAndSuffix() throws {
      let wholeWordHigher = """
      ㄗㄞˋ 再 -3.0 分不清
      ㄗㄞˋ 載 -3.5 清
      """
      #expect(try assemble(extraGrams: wholeWordHigher) == ["分不清", "再"])
      let suffixHigher = """
      ㄗㄞˋ 再 -3.5 分不清
      ㄗㄞˋ 載 -3.0 清
      """
      #expect(try assemble(extraGrams: suffixHigher) == ["分不清", "載"])
    }

    /// (d) 三元圖的 `anterior` 仍須整詞比對：`previous` 可尾字命中，`anterior` 不行。
    @Test("[Homa] Anterior Still Requires Exact Match")
    func testAnteriorStillRequiresExactMatch() throws {
      let readings = ["ㄨㄛˇ", "ㄇㄣ˙"] + Self.readings
      #expect(try assemble(extraGrams: "", readings: readings) == ["我們", "分不清", "在"])
      // anterior 只寫尾字「們」：不得命中。
      #expect(try assemble(extraGrams: "ㄗㄞˋ 再 -3.0 清 們", readings: readings) == ["我們", "分不清", "在"])
      // anterior 整詞「我們」、previous 尾字「清」：命中。
      #expect(try assemble(extraGrams: "ㄗㄞˋ 再 -3.0 清 我們", readings: readings) == ["我們", "分不清", "再"])
    }
  }
}
