// (c) 2021 and onwards The vChewing Project (MIT-NTL License).
// ====================
// This code is released under the MIT license (SPDX-License-Identifier: MIT)
// ... with NTL restriction stating that:
// No trademark license is granted to use the trade names, trademarks, service
// marks, or product names of Contributor, except as required to fulfill notice
// requirements defined in MIT License.

import Foundation
import Homa
import LMAssemblyMaterials4Tests
import Testing

@testable import LangModelAssembly

// MARK: - POMTestSuite.POMGhostCandidateTests

extension POMTestSuite {
  /// 迴歸測試：讀音與資料值錯配的 POM 記憶，不得被注入成詞庫裡並不存在的候選。
  ///
  /// 這類壞記憶在實務上出現過：`嘞` 這個字在原廠詞庫裡只屬於 `ㄌㄟ˙`，卻有一筆記憶把它
  /// 記在 `ㄌㄜ˙` 名下。少了把關的話，該筆記憶會被原樣注入成一個 `ㄌㄜ˙` 的候選，而 POM
  /// 建議以高分覆寫套用、足以壓過該讀音真正的首選「了」；套用之後的節點又會再度被觀測、
  /// 把同一筆錯配寫回記憶，形成自我強化的迴圈——使用者除了整個清除記憶之外別無他法。
  @Suite(.serialized)
  final class POMGhostCandidateTests {
    // MARK: Internal

    /// 記憶的資料值不在該讀音的候選集合內時，不得供應該筆記憶。
    @Test
    func testMismatchedPerceptionIsNotInjected() throws {
      let instance = try makeInstance()
      defer { LMAssembly.LMInstantiator.disconnectFactoryDictionary() }

      // 「嘞」並非 ㄌㄜ˙ 的合法候選，這是一筆讀音與資料值錯配的壞記憶。
      instance.lxPerceptor.memorizePerception(
        (ngramKey: "(ㄨㄛˇ,我)&(ㄕㄨㄟˋ,睡)&(ㄌㄜ˙,嘞)", candidate: "嘞"),
        timestamp: Date().timeIntervalSince1970
      )

      let values = instance.unigramsFor(keyArray: ["ㄌㄜ˙"]).map(\.current)
      #expect(!values.contains("嘞"), "錯配的記憶不得成為候選：\(values)")
    }

    /// 對照組：資料值確實屬於該讀音時，記憶照常供應，功能不受影響。
    ///
    /// POM 記憶是以「帶上下文（previous／anterior）的 gram」形式注入的，故以是否出現
    /// 這樣一筆 gram 來判定注入與否——單看資料值會與詞庫本身的候選混淆。
    @Test
    func testWellFormedPerceptionIsStillInjected() throws {
      let instance = try makeInstance()
      defer { LMAssembly.LMInstantiator.disconnectFactoryDictionary() }

      // 注意：查詢結果會進 `unigramLRUCache`，故必須先記憶、後查詢，
      // 否則後續查詢會直接命中先前留下的快取而看不到注入結果。
      instance.lxPerceptor.memorizePerception(
        (ngramKey: "(ㄨㄛˇ,我)&(ㄕㄨㄟˋ,睡)&(ㄌㄜ˙,了)", candidate: "了"),
        timestamp: Date().timeIntervalSince1970
      )
      let after = instance.unigramsFor(keyArray: ["ㄌㄜ˙"])
      try #require(after.map(\.current).contains("了"), "測試前提：了 應為 ㄌㄜ˙ 的候選")
      #expect(
        after.contains { $0.current == "了" && $0.previous != nil },
        "合法記憶應照常注入為帶上下文的 gram：\(after.map { "\($0.current)/\($0.previous ?? "nil")" })"
      )
    }

    // MARK: Private

    /// 以原廠詞庫建立一個啟用了 POM 建議的 LMInstantiator。
    private func makeInstance() throws -> LMAssembly.LMInstantiator {
      let instance = LMAssembly.LMInstantiator(isCHS: false)
      try #require(
        LMAssembly.LMInstantiator
          .connectToTestFactoryDictionary(textMapData: LMATestsData.textMapTestCoreLMData)
      )
      instance.setOptions { $0.fetchSuggestionsFromPerceptionOverrideModel = true }
      return instance
    }
  }
}
