// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Testing

@testable import LexiconAssembly
@testable import LibVanguard

// MARK: - 使用頻次帳本（遞交時記錄、候選窗前移）

/// 使用頻次帳本與輸入調度模組的整合：
/// - 每次遞交組字區內容時，組句結果的每個字詞（標點與讀音錯配之節點除外）都記錄一次；
/// - 候選窗在 POM 置頂與倚天固定序（基底順序）之後，於同詞長群組內把常用候選往前移；
/// - 「固定順序」、逐字選字模式、以及偏好設定關閉時，皆不做前移；偏好設定關閉時亦不記錄。
extension LibVanguardTestsRoot.InputHandlerTests {
  /// 以只含「ㄗㄞˋ：在、再」「ㄒㄧㄢˋ：現」「ㄒㄧㄢˋ-ㄗㄞˋ：現在、限載」的迷你原廠辭典進行測試。
  /// 倚天固定序預設開啟。結束時還原測試用核心辭典與相關偏好設定。
  func withUsageLedgerFixture(
    _ body: (MockInputHandler, MockSession, _ eTenSequence: [String]) throws -> ()
  ) rethrows {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()
    let eTenSequence = uniqueSingleIdeographicValues(
      testHandler.currentLM.lxQuerier.supplementalValues(for: "ㄗㄞˋ", strategy: .configuredLookup)
    )
    guard eTenSequence.count >= 3, eTenSequence.prefix(3) == ["在", "再", "載"] else {
      Issue.record("倚天中文 DOS 序列表測試資料不符預期：ㄗㄞˋ → \(eTenSequence)")
      return
    }
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let textMap = makeTypingTextMap([
      ("ㄒㄧㄢˋ", [(value: "現", probability: -5.1, typeID: factoryTypeID)]),
      (
        "ㄒㄧㄢˋ-ㄗㄞˋ",
        [
          (value: "現在", probability: -4.0, typeID: factoryTypeID),
          (value: "限載", probability: -6.0, typeID: factoryTypeID),
        ]
      ),
      (
        "ㄗㄞˋ",
        [
          (value: "在", probability: -5.004, typeID: factoryTypeID),
          (value: "再", probability: -5.007, typeID: factoryTypeID),
        ]
      ),
    ])
    defer {
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testHandler.prefs.candidateUsageLedgerEnabled = true
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      testHandler.prefs.enforceETenDOSCandidateSequence = true
      testHandler.prefs.useSCPCTypingMode = false
      testHandler.currentLM.syncPrefs()
      testHandler.currentLM.clearUsageLedger()
      clearTestPOM()
      testSession.switchState(.ofAbortion())
      testHandler.clear()
    }
    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testHandler.clear()
    testHandler.currentLM.clearUsageLedger()
    testHandler.prefs.candidateUsageLedgerEnabled = true
    testHandler.prefs.enforceETenDOSCandidateSequence = true
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.useRearCursorMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    testHandler.currentLM.syncPrefs()
    testSession.switchState(.ofAbortion())
    testSession.recentCommissions.removeAll()
    try body(testHandler, testSession, eTenSequence)
  }

  /// 清空組字器後，依序插入給定讀音並切換至 `.ofInputting` 狀態。
  func composeReadings(_ readings: [String], handler: MockInputHandler, session: MockSession) {
    session.switchState(.ofAbortion())
    handler.clear()
    readings.forEach { reading in
      #expect(throws: Never.self) { try handler.assembler.insertKey(reading) }
    }
    _ = handler.assembler.assemble()
    session.switchState(handler.generateStateOfInputting())
  }

  /// 以 Enter 遞交組字區內容。
  func commitByEnter(handler: MockInputHandler) {
    #expect(handler.triageInput(event: KBEvent.KeyEventData.dataEnterReturn.asEvent))
  }

  /// 帳本內某筆帳目之原始次數（直接讀取帳本，不受偏好開關影響）。
  func usageCount(_ readingKey: String, _ value: String) -> Int? {
    testHandler?.currentLM.lxUsageLedger.entry(readingKey: readingKey, value: value)?.count
  }

  /// IH720：遞交即記錄組句結果；中止、遞交讀音則不記錄。
  @Test
  func test_IH720_CommitRecordsAssembledGrams() throws {
    withUsageLedgerFixture { testHandler, testSession, _ in
      // 以實際按鍵打「ㄗㄞˋ」（大千：y94），Enter 遞交預設的「在」。
      typeSentence("y94")
      #expect(generateDisplayedText() == "在")
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.joined() == "在")
      #expect(usageCount("ㄗㄞˋ", "在") == 1)
      #expect(usageCount("ㄗㄞˋ", "再") == nil)

      // 選「再」之後遞交：記錄「再」。
      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "再"), explicitlyChosen: true)
      testSession.switchState(testHandler.generateStateOfInputting())
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "再")
      #expect(usageCount("ㄗㄞˋ", "再") == 1)
      #expect(usageCount("ㄗㄞˋ", "在") == 1)

      // 多字詞以整個詞記錄（讀音鍵以 `-` 串接）。
      composeReadings(["ㄒㄧㄢˋ", "ㄗㄞˋ"], handler: testHandler, session: testSession)
      #expect(testHandler.assembler.assembledSentence.values == ["現在"])
      commitByEnter(handler: testHandler)
      #expect(usageCount("ㄒㄧㄢˋ-ㄗㄞˋ", "現在") == 1)

      // 「自帶組字內容之狀態切至 `.ofEmpty`」亦屬遞交（例如切換客體時），照樣記錄。
      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      testSession.switchState(.ofEmpty())
      #expect(testSession.recentCommissions.last == "在")
      #expect(usageCount("ㄗㄞˋ", "在") == 2)

      // 中止：不記錄。
      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      testSession.switchState(.ofAbortion())
      #expect(usageCount("ㄗㄞˋ", "在") == 2)

      // 遞交讀音（而非組句結果）：不記錄。
      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      #expect(testHandler.handleEnter(input: KBEvent.KeyEventData.dataEnterReturn.asEvent, readingOnly: true))
      #expect(testSession.recentCommissions.last != "在")
      #expect(usageCount("ㄗㄞˋ", "在") == 2)
    }
  }

  /// IH721：「再」遞交數次之後，倚天固定序之下「再」亦排在「在」之前；多字詞仍在單字之前，
  /// 且同詞長群組之內亦依使用頻次前移。
  @Test
  func test_IH721_UsagePromotesWithinSameLengthGroup() throws {
    withUsageLedgerFixture { testHandler, testSession, eTenSequence in
      // 關閉 POM，以排除 POM 置頂對本案的影響。
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
      testHandler.currentLM.syncPrefs()

      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      #expect(testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value) == eTenSequence)

      (0 ..< 3).forEach { _ in
        composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
        testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "再"), explicitlyChosen: true)
        testSession.switchState(testHandler.generateStateOfInputting())
        commitByEnter(handler: testHandler)
      }
      #expect(usageCount("ㄗㄞˋ", "再") == 3)

      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      // 帳本只影響候選窗，不影響組句。
      #expect(testHandler.assembler.assembledSentence.values == ["在"])
      let singles = testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value)
      #expect(
        singles == ["再"] + eTenSequence.filter { $0 != "再" },
        "常用的「再」須排在倚天序之前，其餘維持倚天序。Got: \(singles)"
      )

      // 多字詞情境：「限載」用過、「現在」沒用過 ⇒ 二字詞群組內「限載」在前；單字群組內「再」在前。
      testHandler.currentLM.recordUsage(
        [(keyArray: ["ㄒㄧㄢˋ", "ㄗㄞˋ"], value: "限載")],
        timestamp: Date().timeIntervalSince1970
      )
      composeReadings(["ㄒㄧㄢˋ", "ㄗㄞˋ"], handler: testHandler, session: testSession)
      #expect(testHandler.assembler.assembledSentence.values == ["現在"])
      let mixed = testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value)
      #expect(
        mixed == ["限載", "現在", "再"] + eTenSequence.filter { $0 != "再" },
        "多字詞須在單字之前，各詞長群組內依使用頻次前移。Got: \(mixed)"
      )
    }
  }

  /// IH722：POM 置頂的單字恆優先於使用頻次前移的單字。
  @Test
  func test_IH722_POMPromotionOutranksUsagePromotion() throws {
    withUsageLedgerFixture { testHandler, testSession, eTenSequence in
      let now = Date().timeIntervalSince1970
      (0 ..< 5).forEach { _ in
        testHandler.currentLM.recordUsage([(keyArray: ["ㄗㄞˋ"], value: "載")], timestamp: now)
      }
      testHandler.currentLM.memorizePerception(
        (ngramKey: "()&()&(ㄗㄞˋ,再)", candidate: "再"),
        timestamp: now
      )
      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      let candidateValues = testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value)
      #expect(
        candidateValues == ["再", "載"] + eTenSequence.filter { !["再", "載"].contains($0) },
        "POM 置頂者居首、使用頻次前移者次之、其餘維持倚天序。Got: \(candidateValues)"
      )
    }
  }

  /// IH723：偏好設定關閉時，既不記錄、也不前移。
  @Test
  func test_IH723_PrefOffDisablesRecordingAndPromotion() throws {
    withUsageLedgerFixture { testHandler, testSession, eTenSequence in
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
      testHandler.currentLM.syncPrefs()
      let now = Date().timeIntervalSince1970
      (0 ..< 3).forEach { _ in
        testHandler.currentLM.recordUsage([(keyArray: ["ㄗㄞˋ"], value: "載")], timestamp: now)
      }
      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      // 前置條件：啟用時「載」確實前移。
      #expect(testHandler.generateArrayOfCandidates(fixOrder: false).first?.value == "載")

      testHandler.prefs.candidateUsageLedgerEnabled = false
      testHandler.currentLM.syncPrefs()
      #expect(!testHandler.currentLM.isUsageLedgerEnabled)
      #expect(testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value) == eTenSequence)

      testSession.switchState(.ofAbortion())
      typeSentence("y94")
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "在")
      #expect(usageCount("ㄗㄞˋ", "在") == nil)
      #expect(usageCount("ㄗㄞˋ", "載") == 3)
    }
  }

  /// IH724：「固定順序」與逐字選字模式維持既有行為（不做使用頻次前移）。
  @Test
  func test_IH724_FixOrderAndSCPCIgnoreUsage() throws {
    withUsageLedgerFixture { testHandler, testSession, eTenSequence in
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
      testHandler.currentLM.syncPrefs()
      let now = Date().timeIntervalSince1970
      (0 ..< 3).forEach { _ in
        testHandler.currentLM.recordUsage([(keyArray: ["ㄗㄞˋ"], value: "載")], timestamp: now)
      }
      composeReadings(["ㄗㄞˋ"], handler: testHandler, session: testSession)
      #expect(testHandler.generateArrayOfCandidates(fixOrder: false).first?.value == "載")
      #expect(testHandler.generateArrayOfCandidates(fixOrder: true).map(\.value) == eTenSequence)

      testHandler.prefs.useSCPCTypingMode = true
      testHandler.currentLM.syncPrefs()
      #expect(testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value) == eTenSequence)
    }
  }
}
