// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Testing

@testable import LexiconAssembly
@testable import LibVanguard

// MARK: - 漸退記憶（POM）之寫入規則

/// `consolidateNode` 對漸退記憶模組之寫入規則：
/// - **修正**（選了與預設組句不同之候選）：寫入新記憶。
/// - **再度確認既有 POM 建議**：刷新該記憶（`cnt` 遞增、`ts` 更新），以免天天在用的記憶照樣過期。
/// - **確認預設**（選了預設組句本來就顯示之候選、且無 POM 記憶相符）：只固化節點、不寫入新記憶。
extension LibVanguardTestsRoot.InputHandlerTests {
  /// 以只含「ㄗㄞˋ：在、再」的迷你原廠辭典進行測試；結束時還原測試用核心辭典。
  func withZai4WriteRuleFixture(_ body: (MockInputHandler) throws -> ()) rethrows {
    guard let testHandler else {
      Issue.record("testHandler is nil.")
      return
    }
    clearTestPOM()
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let textMap = makeTypingTextMap([
      (
        "ㄗㄞˋ",
        [
          (value: "在", probability: -5.004, typeID: factoryTypeID),
          (value: "再", probability: -5.007, typeID: factoryTypeID),
        ]
      ),
    ])
    defer {
      testLX?.disconnectFactoryDictionary()
      #expect(testLX?.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData) == true)
      clearTestPOM()
      testHandler.clear()
    }
    testLX?.disconnectFactoryDictionary()
    #expect(testLX?.connectToTestFactoryDictionary(textMapData: textMap) == true)
    testHandler.clear()
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.useRearCursorMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    testHandler.currentLM.syncPrefs()
    try body(testHandler)
  }

  /// 清空組字器後重打「ㄗㄞˋ」；預設組句應為「在」。
  func retypeZai4(_ testHandler: MockInputHandler) {
    testHandler.clear()
    #expect(throws: Never.self) { try testHandler.assembler.insertKey("ㄗㄞˋ") }
    #expect(testHandler.assembler.assemble().values == ["在"])
  }

  /// 漸退記憶模組內「再」這個候選之 (cnt, ts) 紀錄（逐鍵列出）。
  func storedPOMOverrides(for candidate: String) -> [(key: String, count: Int, timestamp: Double)] {
    guard let testHandler else { return [] }
    return testHandler.currentLM.lxPerceptor.getSavableData().compactMap { pair in
      guard let override = pair.perception.overrides[candidate] else { return nil }
      return (key: pair.key, count: override.count, timestamp: override.timestamp)
    }
  }

  /// IH710：修正（預設「在」→ 選「再」）寫入記憶；之後再度選取同一個 POM 建議時，
  /// 應刷新同一筆記憶（`cnt` 遞增、`ts` 不倒退），而非讓它自初次學習起照樣過期。
  ///
  /// 舊行為：POM 快捷路徑（`.withSpecified` 覆寫）從不呼叫 `memorizePerception`。
  @Test
  func test_IH710_ReselectingPOMSuggestionRefreshesMemory() throws {
    withZai4WriteRuleFixture { testHandler in
      retypeZai4(testHandler)
      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "再"), explicitlyChosen: true)
      #expect(testHandler.assembler.assembledSentence.values == ["再"])
      let firstWrite = storedPOMOverrides(for: "再")
      guard firstWrite.count == 1, let first = firstWrite.first else {
        Issue.record("修正後應恰有一筆「再」之記憶。Got: \(firstWrite)")
        return
      }
      #expect(first.count == 1)

      // 重打：bare unigram 記憶不影響 DP，預設組句仍是「在」，但 POM 建議應指向「再」。
      retypeZai4(testHandler)
      let suggestedValues = testHandler.retrievePOMSuggestions(apply: false).map(\.1.current)
      #expect(suggestedValues.contains("再"), "前置條件：POM 建議須含「再」。Got: \(suggestedValues)")

      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "再"), explicitlyChosen: true)
      #expect(testHandler.assembler.assembledSentence.values == ["再"])
      let afterRefresh = storedPOMOverrides(for: "再")
      #expect(afterRefresh.count == 1, "刷新不得新增記憶鍵。Got: \(afterRefresh)")
      guard let refreshed = afterRefresh.first else { return }
      #expect(refreshed.key == first.key)
      #expect(refreshed.count == 2, "再度確認 POM 建議須遞增 cnt。Got: \(refreshed)")
      #expect(refreshed.timestamp >= first.timestamp)
    }
  }

  /// IH711：確認預設組句本來就顯示之候選（且無 POM 記憶相符）時，只固化節點、不寫入記憶。
  ///
  /// 舊行為：`makePerceptionIntel` 不檢查值是否改變，「確認預設」照樣寫下一筆新記憶。
  @Test
  func test_IH711_ConfirmingDisplayedDefaultWritesNoMemory() throws {
    withZai4WriteRuleFixture { testHandler in
      retypeZai4(testHandler)
      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "在"), explicitlyChosen: true)
      // 覆寫（固化節點）照常發生。
      #expect(testHandler.assembler.assembledSentence.values == ["在"])
      #expect(testHandler.assembler.assembledSentence.first?.isExplicit == true)
      // 但不寫入任何記憶。
      #expect(testHandler.currentLM.lxPerceptor.getSavableData().isEmpty)
      #expect(testHandler.retrievePOMSuggestions(apply: false).isEmpty)

      // 對照：修正（選「再」）仍照常寫入。
      retypeZai4(testHandler)
      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "再"), explicitlyChosen: true)
      #expect(storedPOMOverrides(for: "再").count == 1)
    }
  }

  /// IH712：`skipObservation` 對 POM 快捷路徑之刷新亦須生效。
  @Test
  func test_IH712_SkipObservationAlsoSuppressesRefresh() throws {
    withZai4WriteRuleFixture { testHandler in
      retypeZai4(testHandler)
      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "再"), explicitlyChosen: true)
      #expect(storedPOMOverrides(for: "再").first?.count == 1)

      retypeZai4(testHandler)
      testHandler.consolidateNode(
        candidate: (["ㄗㄞˋ"], "再"),
        skipObservation: true,
        explicitlyChosen: true
      )
      #expect(testHandler.assembler.assembledSentence.values == ["再"])
      #expect(storedPOMOverrides(for: "再").first?.count == 1)
    }
  }
}
