// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Testing

@testable import LexiconAssembly

// MARK: - POMTestSuite.POMGhostCandidateTests

extension POMTestSuite {
  /// 迴歸測試：讀音與資料值錯配的 POM 記憶，不得被注入成詞庫裡並不存在的候選。
  ///
  /// 這類壞記憶在實務上出現過：`嘞` 這個字在原廠詞庫裡只屬於 `ㄌㄟ˙`，卻有一筆記憶把它
  /// 記在 `ㄌㄜ˙` 名下。少了把關的話，該筆記憶會被原樣注入成一個 `ㄌㄜ˙` 的候選，而 POM
  /// 建議以高分覆寫套用、足以壓過該讀音真正的首選「了」；套用之後的節點又會再度被觀測、
  /// 把同一筆錯配寫回記憶，形成自我強化的迴圈——使用者除了整個清除記憶之外別無他法。
  ///
  /// - Remark: 測試用詞庫（`vanguardTextMap_test.txtMap`）並未收錄 `ㄌㄜ˙`，故改以其收錄的
  /// `ㄉㄜ˙`（首選「的」）重現同一情形：把「嘞」記在 `ㄉㄜ˙` 名下即構成錯配。
  @Suite(.serialized)
  final class POMGhostCandidateTests {
    // MARK: Internal

    /// 記憶的資料值不在該讀音的候選集合內時，不得供應該筆記憶（逐字路徑）。
    @Test
    func testMismatchedPerceptionIsNotInjected() throws {
      let instance = try makeInstance()
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }

      // 「嘞」並非 ㄉㄜ˙ 的合法候選，這是一筆讀音與資料值錯配的壞記憶。
      instance.lxPerceptor.memorizePerception(
        (ngramKey: "(ㄉㄚˋ,大)&(ㄒㄧㄣ,心)&(ㄉㄜ˙,嘞)", candidate: "嘞"),
        timestamp: Date().timeIntervalSince1970
      )

      let values = instance.unigramsFor(keyArray: ["ㄉㄜ˙"]).map(\.current)
      #expect(!values.contains("嘞"), "錯配的記憶不得成為候選：\(values)")
    }

    /// 聲調桶（`[Homa.PossibleKey]` alternatives）路徑同樣不得供應錯配的記憶。
    ///
    /// 該路徑供狂拼等「無法釘定聲調」的查詢使用，POM head 比對以去聲調等值進行；
    /// 把關邏輯須與逐字路徑一致，否則壞記憶仍能經由此路徑浮現。
    @Test
    func testMismatchedPerceptionIsNotInjectedViaBucketPath() throws {
      let instance = try makeInstance()
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }

      instance.lxPerceptor.memorizePerception(
        (ngramKey: "(ㄉㄚˋ,大)&(ㄒㄧㄣ,心)&(ㄉㄜ˙,嘞)", candidate: "嘞"),
        timestamp: Date().timeIntervalSince1970
      )
      let bucketQuery: [Homa.PossibleKey] = [
        .multipleKeys(["ㄉㄜ", "ㄉㄜˊ", "ㄉㄜˇ", "ㄉㄜˋ", "ㄉㄜ˙"]),
      ]
      let values = instance.unigramsFor(keyArray: bucketQuery, partiallyMatch: false).map(\.current)
      try #require(values.contains("的"), "測試前提：的 應為 ㄉㄜ˙ 的候選")
      #expect(!values.contains("嘞"), "錯配的記憶不得成為候選：\(values)")
    }

    /// 對照組：資料值確實屬於該讀音時，記憶照常供應，功能不受影響。
    ///
    /// POM 記憶是以「帶上下文（previous／anterior）的 gram」形式注入的，故以是否出現
    /// 這樣一筆 gram 來判定注入與否——單看資料值會與詞庫本身的候選混淆。
    @Test
    func testWellFormedPerceptionIsStillInjected() throws {
      let instance = try makeInstance()
      defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }

      // 注意：查詢結果會進 `unigramLRUCache`，故必須先記憶、後查詢，
      // 否則後續查詢會直接命中先前留下的快取而看不到注入結果。
      instance.lxPerceptor.memorizePerception(
        (ngramKey: "(ㄉㄚˋ,大)&(ㄒㄧㄣ,心)&(ㄉㄜ˙,的)", candidate: "的"),
        timestamp: Date().timeIntervalSince1970
      )
      let after = instance.unigramsFor(keyArray: ["ㄉㄜ˙"])
      try #require(after.map(\.current).contains("的"), "測試前提：的 應為 ㄉㄜ˙ 的候選")
      #expect(
        after.contains { $0.current == "的" && $0.previous != nil },
        "合法記憶應照常注入為帶上下文的 gram：\(after.map { "\($0.current)/\($0.previous ?? "nil")" })"
      )
    }

    // MARK: Private

    /// 以測試用原廠詞庫建立一個啟用了 POM 建議的 LXFacade。
    private func makeInstance() throws -> LXAssembly.LXFacade {
      let instance = LXAssembly.LXFacade()
      try #require(
        LXAssembly.LXFacade
          .connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData)
      )
      instance.setOptions { $0.fetchSuggestionsFromPerceptionOverrideModel = true }
      return instance
    }
  }
}
