// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import HomaSharedTestComponents
import Testing

@testable import Homa

// MARK: - HomaTestsRoot.HomaTests_PathFinderParentGram

extension HomaTestsRoot {
  /// 組句 DP 回溯所記錄之元圖，須為節點**計分之後**所選取的元圖。
  ///
  /// `getScore(previous:anterior:)` 會依語境移動節點的 `currentGramIndex`（命中語境元圖時
  /// 改指該元圖，未命中時退回最佳單元圖）。若回溯陣列記的是計分**之前**的 `currentGram`，
  /// 而兩者之值不同，則當次 `assemble()` 輸出的句子會與路徑分數不一致，要到下一次組句才自癒。
  /// 兩支靶各釘住一個方向：
  /// - 計分時改採語境元圖（值由「丙」變「餅」）。
  /// - 計分時因語境改變而退回單元圖（值由「餅」變「丙」）。
  struct HomaTests_PathFinderParentGram: HomaTestSuite {
    /// 「ㄅㄧㄥˇ」節點的元圖依權重排序後，首位是「前驅為甲」的「丙」雙元圖（此處語境不符），
    /// 故節點初始 `currentGram` 為「丙」；但前驅為「乙」時，「餅」雙元圖（-0.5）勝過單元圖
    /// 基線（-5），計分時節點改指「餅」。第一次組句（插入讀音時即自動進行）即須輸出「餅」，且路徑分數為 -5 + -0.5。
    @Test("[Homa] PathFinder Records Context-Adopted Gram On First Assembly")
    func testPathFinderRecordsContextAdoptedGramOnFirstAssembly() throws {
      let mockLX = TestLX(rawData: """
      ㄧˇ 乙 -5
      ㄅㄧㄥˇ 丙 -5
      ㄅㄧㄥˇ 丙 -0.1 甲
      ㄅㄧㄥˇ 餅 -0.5 乙
      """)
      let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) })
      try ["ㄧˇ", "ㄅㄧㄥˇ"].forEach { try assembler.insertKey($0) }
      // `insertKey` 經 `assignNodes()` 自行呼叫一次 `assemble()`，此即第一次組句之結果。
      let firstResult = assembler.assembledSentence
      #expect(firstResult.values == ["乙", "餅"])
      #expect(firstResult.last?.gram.previous == "乙")
      #expect(firstResult.last?.score == -0.5)
      #expect(assembler.mostRecentPathScore == -5.5)
      // 再組一次：結果與分數皆不變（冪等）。
      #expect(assembler.assemble().values == ["乙", "餅"])
      #expect(assembler.mostRecentPathScore == -5.5)
    }

    /// 先組出「乙餅」（「餅」雙元圖權重最高、居元圖首位，節點即指向它）。之後把前驅覆寫為
    /// 「已」：語境不再相符，計分時節點退回單元圖「丙」。覆寫後的第一次組句即須輸出「丙」。
    @Test("[Homa] PathFinder Records Unigram Fallback After Context Change")
    func testPathFinderRecordsUnigramFallbackAfterContextChange() throws {
      let mockLX = TestLX(rawData: """
      ㄧˇ 乙 -5
      ㄧˇ 已 -6
      ㄅㄧㄥˇ 丙 -5
      ㄅㄧㄥˇ 餅 -0.5 乙
      """)
      let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) })
      try ["ㄧˇ", "ㄅㄧㄥˇ"].forEach { try assembler.insertKey($0) }
      #expect(assembler.assemble().values == ["乙", "餅"])
      #expect(assembler.mostRecentPathScore == -5.5)

      // `overrideCandidate` 於結束前自行呼叫一次 `assemble()`。
      try assembler.overrideCandidate(
        .init(keyArray: ["ㄧˇ"], value: "已"),
        at: 0,
        type: .withSpecified,
        isExplicitlyOverridden: true
      )
      #expect(assembler.assembledSentence.values == ["已", "丙"])
      #expect((assembler.assembledSentence.last?.gram.previous ?? "").isEmpty)
      #expect(assembler.assembledSentence.last?.score == -5)
      #expect(assembler.mostRecentPathScore == 114_514 - 5)
    }
  }
}
