// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Testing

@testable import LexiconAssembly
@testable import LibVanguard

// MARK: - 句末語氣詞後接標點（K-best 組句＋語境元圖）

/// 「語氣詞後接全形標點」語境元圖（LexiconAssembly）與 K-best 組句（Homa）的整合：
/// - 「ㄇㄚ」的「媽」(−5.0) 略勝「嗎」(−5.05)，單獨打時取「媽」；
/// - 後接全形問號時，「？」的「前文為嗎」語境元圖（+1.0）讓「嗎」勝出——但僅限
///   `assemblerBeamWidth` ≥ 2；為 1 時「？」計分前前驅早已定案為「媽」；
/// - 一個比「單字＋語氣詞」強 1.0 以上的真實雙字詞，不得被語氣詞加分拆散。
extension LibVanguardTestsRoot.InputHandlerTests {
  /// 以迷你原廠辭典進行測試：「ㄋㄚˇ：哪」「ㄇㄚ：媽、嗎」「ㄒㄧㄚˋ：下」「ㄅㄚ：吧、巴」
  /// 「ㄒㄧㄚˋ-ㄅㄚ：下巴」「_punctuation_?：？」。結束時還原測試用核心辭典與相關偏好設定。
  func withParticlePunctuationFixture(
    _ body: (MockInputHandler, MockSession) throws -> ()
  ) rethrows {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let punctuationTypeID: Int32 = 4 // `letterPunctuations`
    let textMap = makeTypingTextMap([
      ("ㄋㄚˇ", [(value: "哪", probability: -5.0, typeID: factoryTypeID)]),
      (
        "ㄇㄚ",
        [
          (value: "媽", probability: -5.0, typeID: factoryTypeID),
          (value: "嗎", probability: -5.05, typeID: factoryTypeID),
        ]
      ),
      ("ㄒㄧㄚˋ", [(value: "下", probability: -4.0, typeID: factoryTypeID)]),
      (
        "ㄅㄚ",
        [
          (value: "吧", probability: -5.2, typeID: factoryTypeID),
          (value: "巴", probability: -6.0, typeID: factoryTypeID),
        ]
      ),
      ("ㄒㄧㄚˋ-ㄅㄚ", [(value: "下巴", probability: -8.0, typeID: factoryTypeID)]),
      ("_punctuation_?", [(value: "？", probability: 0, typeID: punctuationTypeID)]),
    ])
    let beamWidthBackup = testHandler.prefs.assemblerBeamWidth
    let halfWidthPunctuationBackup = testHandler.prefs.halfWidthPunctuationEnabled
    defer {
      testLX?.disconnectFactoryDictionary()
      #expect(testLX?.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData) == true)
      testHandler.prefs.assemblerBeamWidth = beamWidthBackup
      testHandler.prefs.halfWidthPunctuationEnabled = halfWidthPunctuationBackup
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      testHandler.prefs.useSCPCTypingMode = false
      testHandler.currentLM.syncPrefs()
      testHandler.currentLM.clearUsageLedger()
      clearTestPOM()
      testSession.switchState(.ofAbortion())
      testHandler.clear()
    }
    testLX?.disconnectFactoryDictionary()
    #expect(testLX?.connectToTestFactoryDictionary(textMapData: textMap) == true)
    testHandler.clear()
    testHandler.currentLM.clearUsageLedger()
    testSession.recentCommissions.removeAll()
    testHandler.prefs.assemblerBeamWidth = 4
    testHandler.prefs.halfWidthPunctuationEnabled = false
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.useRearCursorMode = false
    // 隔離 POM 記憶的影響。
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()
    testSession.switchState(.ofAbortion())
    try body(testHandler, testSession)
  }

  /// IH750：「ㄋㄚˇ ㄇㄚ ？」→「哪嗎？」；未接標點時仍為「哪媽」。
  @Test
  func test_IH750_QuestionMarkPrefersParticleWithBeamSearch() throws {
    withParticlePunctuationFixture { testHandler, testSession in
      // 大千：ㄋㄚˇ = s83、ㄇㄚ = a8 + 空格（陰平）。
      typeSentence("s83a8 ")
      #expect(generateDisplayedText() == "哪媽")
      typeSentence("?")
      #expect(testHandler.assembler.actualKeys.last == "_punctuation_?")
      #expect(testHandler.assembler.beamWidth == 4)
      #expect(generateDisplayedText() == "哪嗎？")
      // 語境元圖不得出現在選字窗：問號節點的候選中「？」只出現一次（另有詞庫自帶的半形變體），
      // 九筆「語氣詞＋？」元圖皆不列出。
      let punctuationCandidates = testHandler.assembler.fetchCandidates(at: 3, filter: .endAt)
        .map(\.pair.value)
      #expect(punctuationCandidates.first == "？", "\(punctuationCandidates)")
      #expect(punctuationCandidates.filter { $0 == "？" }.count == 1, "\(punctuationCandidates)")
      // 遞交：使用頻次帳本照常記錄「嗎」，標點（`_` 起首之讀音）則不記錄。
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "哪嗎？")
      #expect(usageCount("ㄇㄚ", "嗎") == 1)
      #expect(usageCount("_punctuation_?", "？") == nil)
    }
  }

  /// IH751：搜尋寬度為 1（傳統 1-best）時，「？」無從回頭影響前驅：仍為「哪媽？」。
  /// 此靶記錄語氣詞元圖對 K-best 組句的依賴。
  @Test
  func test_IH751_QuestionMarkCannotSteerWithBeamWidthOne() throws {
    withParticlePunctuationFixture { testHandler, testSession in
      testHandler.prefs.assemblerBeamWidth = 1
      typeSentence("s83a8 ?")
      #expect(testHandler.assembler.beamWidth == 1)
      #expect(generateDisplayedText() == "哪媽？")
      testSession.switchState(.ofAbortion())

      // 同一個組字器改回 4：偏好於下一次按鍵時同步。
      testHandler.clear()
      testHandler.prefs.assemblerBeamWidth = 4
      typeSentence("s83a8 ?")
      #expect(generateDisplayedText() == "哪嗎？")
      testSession.switchState(.ofAbortion())
    }
  }

  /// IH752：「下巴」(−8.0) 比「下」＋「吧」(−4.0 + −5.2 = −9.2) 強 1.2，語氣詞加分（+1.0）
  /// 不足以拆散它：「ㄒㄧㄚˋ ㄅㄚ ？」仍為「下巴？」。
  @Test
  func test_IH752_ParticleBonusDoesNotBreakStrongerWord() throws {
    withParticlePunctuationFixture { testHandler, testSession in
      // 大千：ㄒㄧㄚˋ = vu84、ㄅㄚ = 18 + 空格（陰平）。
      typeSentence("vu8418 ")
      #expect(generateDisplayedText() == "下巴")
      typeSentence("?")
      #expect(generateDisplayedText() == "下巴？")
      testSession.switchState(.ofAbortion())
    }
  }
}
