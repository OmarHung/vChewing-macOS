// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Testing

@testable import LexiconAssembly
@testable import LibVanguard

// MARK: - RetypeCorrectionFakeClock

/// 刪除重打修正測試用的假時鐘。
final class RetypeCorrectionFakeClock {
  var now: TimeInterval = 1_000_000

  func advance(by seconds: TimeInterval) {
    now += seconds
  }
}

// MARK: - 刪除重打修正

/// 刪除重打修正：遞交之後在空狀態下按 BackSpace 刪掉尾端的字、緊接著重打同樣的讀音，
/// 即視為「上次自動選的字是錯的」——本次組字改選次佳候選、候選窗把被否決的值移到最後、
/// 遞交時學習（寫入 POM；若錯字源自 POM 記憶則清除之）。
extension LibVanguardTestsRoot.InputHandlerTests {
  /// 以只含「ㄗㄞˋ：在、再」「ㄒㄧㄢˋ：現、線」「ㄒㄧㄢˋ-ㄗㄞˋ：現在、限載」的迷你原廠辭典進行測試。
  /// 帳本改用假時鐘；結束時還原測試用核心辭典、帳本與相關偏好設定。
  func withRetypeCorrectionFixture(
    _ body: (MockInputHandler, MockSession, RetypeCorrectionFakeClock) throws -> ()
  ) rethrows {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let textMap = makeTypingTextMap([
      (
        "ㄒㄧㄢˋ",
        [
          (value: "現", probability: -5.1, typeID: factoryTypeID),
          (value: "線", probability: -5.2, typeID: factoryTypeID),
        ]
      ),
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
    let clock = RetypeCorrectionFakeClock()
    defer {
      testLX?.disconnectFactoryDictionary()
      #expect(testLX?.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData) == true)
      testHandler.prefs.retypeCorrectionDetectionEnabled = true
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      testHandler.prefs.useSCPCTypingMode = false
      testHandler.currentLM.syncPrefs()
      testHandler.currentLM.clearUsageLedger()
      clearTestPOM()
      testSession.clientBundleIdentifier = ""
      testSession.switchState(.ofAbortion())
      testHandler.clear()
      testHandler.recentCommitLedger = RecentCommitLedger()
    }
    testLX?.disconnectFactoryDictionary()
    #expect(testLX?.connectToTestFactoryDictionary(textMapData: textMap) == true)
    testHandler.clear()
    testHandler.currentLM.clearUsageLedger()
    testHandler.prefs.retypeCorrectionDetectionEnabled = true
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.useRearCursorMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    testHandler.currentLM.syncPrefs()
    testSession.clientBundleIdentifier = "org.vChewing.tests.ClientA"
    testSession.switchState(.ofAbortion())
    testSession.recentCommissions.removeAll()
    testHandler.recentCommitLedger = RecentCommitLedger(clock: { clock.now })
    try body(testHandler, testSession, clock)
  }

  /// 在空狀態下按一次 BackSpace（輸入法須放行給客體）。
  func pressBackSpaceInEmptyState(handler: MockInputHandler, session: MockSession) {
    #expect(session.state.type == .ofEmpty)
    #expect(!handler.triageInput(event: KBEvent.KeyEventData.backspaceEvent.asEvent))
  }

  /// 打「ㄗㄞˋ」（大千：y94）、以 Enter 遞交預設的「在」。
  func commitDefaultZai4(handler: MockInputHandler, session: MockSession) {
    typeSentence("y94")
    #expect(generateDisplayedText() == "在")
    commitByEnter(handler: handler)
    #expect(session.recentCommissions.last == "在")
    #expect(handler.recentCommitLedger.record?.nodes.map(\.value) == ["在"])
  }

  /// IH730：遞交「在」→ 空狀態下按 BackSpace → 重打「ㄗㄞˋ」：組字區改給「再」（遞交之前）。
  /// IH731（同一流程之續）：再以 Enter 遞交，則「再」寫入恰好一筆 POM 記憶（cnt = 1），且解除待命。
  @Test
  func test_IH730_IH731_RetypeSubstitutesAndCommitLearns() throws {
    withRetypeCorrectionFixture { testHandler, testSession, clock in
      commitDefaultZai4(handler: testHandler, session: testSession)
      #expect(storedPOMOverrides(for: "再").isEmpty)

      clock.advance(by: 1)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      #expect(testHandler.recentCommitLedger.record?.deletedCharCount == 1)

      clock.advance(by: 1)
      typeSentence("y94")
      #expect(generateDisplayedText() == "再", "重打之後須改給次佳候選。")
      #expect(testHandler.recentCommitLedger.armed?.targets.first?.substitutedValue == "再")
      // 自動改選不得標記為顯式選字。
      #expect(testHandler.assembler.assembledSentence.first?.isExplicit == false)

      // IH731：遞交即隱式確認。
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "再")
      let memories = storedPOMOverrides(for: "再")
      #expect(memories.count == 1, "隱式確認須寫入恰好一筆記憶。Got: \(memories)")
      #expect(memories.first?.count == 1)
      #expect(storedPOMOverrides(for: "在").isEmpty)
      #expect(testHandler.recentCommitLedger.armed == nil)
      // 本次遞交成為新的紀錄。
      #expect(testHandler.recentCommitLedger.record?.nodes.map(\.value) == ["再"])
    }
  }

  /// IH732：遞交與 BackSpace 之間出現任何其他按鍵，帳本即作廢、不改選。
  @Test
  func test_IH732_OtherKeyBetweenCommitAndBackSpaceResets() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      commitDefaultZai4(handler: testHandler, session: testSession)
      _ = testHandler.triageInput(event: KBEvent.KeyEventData.dataArrowLeft.asEvent)
      #expect(testHandler.recentCommitLedger.isIdle)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      #expect(testHandler.recentCommitLedger.isIdle)
      typeSentence("y94")
      #expect(generateDisplayedText() == "在")
    }
  }

  /// IH733：逾時（遞交後 11 秒才按 BackSpace；或刪除之後逾時才開始重打）不改選。
  @Test
  func test_IH733_TimeWindowExpiry() throws {
    withRetypeCorrectionFixture { testHandler, testSession, clock in
      commitDefaultZai4(handler: testHandler, session: testSession)
      clock.advance(by: 11)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      #expect(testHandler.recentCommitLedger.isIdle)
      typeSentence("y94")
      #expect(generateDisplayedText() == "在")

      // 刪除在時間窗內、開始重打時已逾時：同樣不改選。
      testSession.switchState(.ofAbortion())
      commitDefaultZai4(handler: testHandler, session: testSession)
      clock.advance(by: 2)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      #expect(testHandler.recentCommitLedger.record?.deletedCharCount == 1)
      clock.advance(by: 9)
      typeSentence("y94")
      #expect(generateDisplayedText() == "在")
      #expect(testHandler.recentCommitLedger.isIdle)
    }
  }

  /// IH734：刪掉兩個字（尾端兩個單字節點）並重打兩者：兩個區間都重新評估，
  /// 但只有「當前值恰為被否決之值」的區間才改選。
  @Test
  func test_IH734_TwoTrailingNodesOnlyRejectedSpansSubstituted() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      typeSentence("y94vu04")
      #expect(generateDisplayedText() == "在現")
      // 第二個字顯式改為「線」之後遞交「在線」。
      testHandler.consolidateNode(candidate: (["ㄒㄧㄢˋ"], "線"), explicitlyChosen: true)
      testSession.switchState(testHandler.generateStateOfInputting())
      #expect(generateDisplayedText() == "在線")
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "在線")
      let committedNodes = testHandler.recentCommitLedger.record?.nodes
      #expect(committedNodes?.map(\.value) == ["在", "線"])
      #expect(committedNodes?.map(\.isExplicit) == [false, true])
      // 排除「線」之 POM 記憶對重打的影響，令第二個區間重打後回到預設的「現」。
      clearTestPOM()

      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      #expect(testHandler.recentCommitLedger.record?.deletedCharCount == 2)

      typeSentence("y94vu04")
      #expect(generateDisplayedText() == "再現", "只有仍為被否決之值（在）的區間才改選。")
      let targets = testHandler.recentCommitLedger.armed?.targets ?? []
      #expect(targets.map(\.rejectedValue) == ["在", "線"])
      #expect(targets.map(\.range) == [0 ..< 1, 1 ..< 2])
      #expect(targets.map(\.substitutedValue) == ["再", nil])
    }
  }

  /// IH735：刪除切在多字節點的中間（「現在」只刪掉「在」）：作廢、不改選。
  @Test
  func test_IH735_DeletionCuttingMultiCharNodeDisarms() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      typeSentence("vu04y94")
      #expect(generateDisplayedText() == "現在")
      commitByEnter(handler: testHandler)
      #expect(testHandler.recentCommitLedger.record?.nodes.map(\.value) == ["現在"])

      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      #expect(testHandler.recentCommitLedger.record?.deletedCharCount == 1)
      typeSentence("y94")
      #expect(testHandler.recentCommitLedger.isIdle)
      #expect(generateDisplayedText() == "在")
    }
  }

  /// IH736：客體變更（BackSpace 之後、重打之前換了客體）：不改選。
  @Test
  func test_IH736_DifferentClientHasNoEffect() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      commitDefaultZai4(handler: testHandler, session: testSession)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      testSession.clientBundleIdentifier = "org.vChewing.tests.ClientB"
      typeSentence("y94")
      #expect(generateDisplayedText() == "在")
      #expect(testHandler.recentCommitLedger.isIdle)

      // 於另一個客體按 BackSpace 亦不累計。
      testSession.switchState(.ofAbortion())
      testSession.clientBundleIdentifier = "org.vChewing.tests.ClientA"
      commitDefaultZai4(handler: testHandler, session: testSession)
      testSession.clientBundleIdentifier = "org.vChewing.tests.ClientB"
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      #expect(testHandler.recentCommitLedger.isIdle)
    }
  }

  /// IH737：隱藏偏好關閉時：不記錄、不改選。
  @Test
  func test_IH737_PrefOffHasNoEffect() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      testHandler.prefs.retypeCorrectionDetectionEnabled = false
      typeSentence("y94")
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "在")
      #expect(testHandler.recentCommitLedger.isIdle)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      typeSentence("y94")
      #expect(generateDisplayedText() == "在")
      #expect(testHandler.recentCommitLedger.isIdle)
    }
  }

  /// IH738：逐字選字模式不啟用。
  @Test
  func test_IH738_SCPCModeHasNoEffect() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      testHandler.prefs.useSCPCTypingMode = true
      typeSentence("y94")
      #expect(testSession.state.type == .ofCandidates)
      testSession.candidatePairSelectionConfirmed(at: 0)
      #expect(testSession.recentCommissions.last == "在")
      #expect(testHandler.recentCommitLedger.isIdle)

      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      typeSentence("y94")
      #expect(testHandler.recentCommitLedger.isIdle)
      #expect(testSession.state.type == .ofCandidates)
      #expect(testSession.state.candidates.first?.value == "在")
    }
  }

  /// IH739：被否決之值源自 POM 建議：修正成立（遞交）之後，那筆記憶被清除，並改記新的值。
  @Test
  func test_IH739_RejectedPOMSuggestionIsBleached() throws {
    withRetypeCorrectionFixture { testHandler, testSession, clock in
      // 先讓 POM 學到「再」（顯式選字）。
      typeSentence("y94")
      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "再"), explicitlyChosen: true)
      testSession.switchState(testHandler.generateStateOfInputting())
      commitByEnter(handler: testHandler)
      #expect(storedPOMOverrides(for: "再").count == 1)

      // 再打一次「ㄗㄞˋ」：POM 自動給「再」；遞交之後，帳本須記得它源自 POM 記憶。
      clock.advance(by: 30)
      typeSentence("y94")
      #expect(generateDisplayedText() == "再", "前置條件：POM 須自動給出「再」。")
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "再")
      let pomMemory = testHandler.recentCommitLedger.record?.nodes.last?.pomMemory
      #expect(pomMemory?.candidate == "再")
      #expect(pomMemory.map { key in storedPOMOverrides(for: "再").contains { $0.key == key.ngramKey } } == true)

      // 刪掉重打：改給「在」；遞交之後，「再」的記憶被清除，改記「在」。
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      typeSentence("y94")
      #expect(generateDisplayedText() == "在")
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "在")
      #expect(storedPOMOverrides(for: "再").isEmpty, "導致錯字的 POM 記憶須被清除。")
      #expect(storedPOMOverrides(for: "在").map(\.count) == [1])
    }
  }

  /// IH740：待命期間，候選窗把被否決之值移到單字群組之末（其餘維持倚天序；使用頻次前移不得把它拉回來）。
  @Test
  func test_IH740_CandidateWindowDemotesRejectedValue() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      testHandler.prefs.enforceETenDOSCandidateSequence = true
      let eTenSequence = uniqueSingleIdeographicValues(
        testHandler.currentLM.lxQuerier.supplementalValues(for: "ㄗㄞˋ", strategy: .configuredLookup)
      )
      guard eTenSequence.prefix(2) == ["在", "再"] else {
        Issue.record("倚天中文 DOS 序列表測試資料不符預期：ㄗㄞˋ → \(eTenSequence)")
        return
      }
      commitDefaultZai4(handler: testHandler, session: testSession)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      typeSentence("y94")
      #expect(generateDisplayedText() == "再")
      let candidateValues = testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value)
      #expect(
        candidateValues == eTenSequence.filter { $0 != "在" } + ["在"],
        "被否決之值須排在單字群組之末。Got: \(candidateValues)"
      )
      // 「固定順序」不受影響。
      #expect(testHandler.generateArrayOfCandidates(fixOrder: true).first?.value == "在")

      // 解除待命之後回復正常排序。
      testSession.switchState(.ofAbortion())
      typeSentence("y94")
      #expect(testHandler.recentCommitLedger.isIdle)
      #expect(testHandler.generateArrayOfCandidates(fixOrder: false).last?.value != "在")
    }
  }

  /// IH741：重打了不同的讀音：解除待命。
  @Test
  func test_IH741_RetypingDifferentReadingDisarms() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      commitDefaultZai4(handler: testHandler, session: testSession)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      typeSentence("v")
      #expect(testHandler.recentCommitLedger.armed != nil, "開始組字即進入待命。")
      typeSentence("u04")
      #expect(generateDisplayedText() == "現")
      #expect(testHandler.recentCommitLedger.isIdle)
      typeSentence("y94")
      #expect(generateDisplayedText() == "現在")
      #expect(testHandler.recentCommitLedger.isIdle)
    }
  }

  /// IH742：重打之後顯式選了被否決之值本身（使用者堅持原值）：了結、不學習、不再改選。
  @Test
  func test_IH742_ExplicitlyChoosingRejectedValueSettles() throws {
    withRetypeCorrectionFixture { testHandler, testSession, _ in
      commitDefaultZai4(handler: testHandler, session: testSession)
      pressBackSpaceInEmptyState(handler: testHandler, session: testSession)
      typeSentence("y94")
      #expect(generateDisplayedText() == "再")
      testHandler.consolidateNode(candidate: (["ㄗㄞˋ"], "在"), explicitlyChosen: true)
      testSession.switchState(testHandler.generateStateOfInputting())
      #expect(generateDisplayedText() == "在")
      #expect(testHandler.recentCommitLedger.armed == nil)
      commitByEnter(handler: testHandler)
      #expect(testSession.recentCommissions.last == "在")
      #expect(storedPOMOverrides(for: "再").isEmpty)
    }
  }
}
