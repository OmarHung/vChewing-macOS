// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import LXAssemblyMaterials4Tests
import Shared
import Testing

import HomaSharedTestComponents
@testable import LexiconAssembly
@testable import LibVanguard
@testable import Tekkon

// 候選序與讀音過濾／查詢：倚天排列之候選序強制、CNS 讀音過濾、拼音去調前綴查詢。

// MARK: - IH.CandidateOrder

extension LibVanguardTestsRoot.InputHandlerTests {
  @Test("IH-CandidateOrder-001 ETen exclusive candidates append at tail without reordering")
  func test_IH_CandidateOrder_001_ETenExclusiveCandidatesAppendAtTailWithoutReordering() throws {
    guard let testHandler else {
      Issue.record("testHandler is nil.")
      return
    }
    clearTestPOM()

    let reading = "ㄅㄛ"
    let eTenSequence = uniqueSingleIdeographicValues(
      testHandler.currentLM.lxQuerier.supplementalValues(for: reading, strategy: .configuredLookup)
    )
    guard eTenSequence.count >= 4 else {
      Issue.record("倚天中文 DOS 序列表測試資料不足：\(reading)")
      return
    }
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let factoryValues = [eTenSequence[1], eTenSequence[0]]
    let expectedValues = factoryValues + eTenSequence.filter { !factoryValues.contains($0) }
    let textMapKey = "ㄅㄛ"
    let textMap = makeTypingTextMap([
      (
        textMapKey,
        factoryValues.enumerated().map {
          (value: $0.element, probability: -5 - Double($0.offset), typeID: factoryTypeID)
        }
      ),
    ])

    defer {
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testHandler.clear()
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testHandler.clear()
    testHandler.prefs.enforceETenDOSCandidateSequence = false
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    #expect(throws: Never.self) { try testHandler.assembler.insertKey(reading) }

    let candidateValues = testHandler.generateArrayOfCandidates().map(\.value)
    #expect(candidateValues == expectedValues)
  }

  @Test("IH-CandidateOrder-002 ETen sequence enforcement still reorders candidates")
  func test_IH_CandidateOrder_002_ETenSequenceEnforcementStillReordersCandidates() throws {
    guard let testHandler else {
      Issue.record("testHandler is nil.")
      return
    }
    clearTestPOM()

    let reading = "ㄅㄛ"
    let eTenSequence = uniqueSingleIdeographicValues(
      testHandler.currentLM.lxQuerier.supplementalValues(for: reading, strategy: .configuredLookup)
    )
    guard eTenSequence.count >= 4 else {
      Issue.record("倚天中文 DOS 序列表測試資料不足：\(reading)")
      return
    }
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let factoryValues = [eTenSequence[1], eTenSequence[0]]
    let textMapKey = "ㄅㄛ"
    let textMap = makeTypingTextMap([
      (
        textMapKey,
        factoryValues.enumerated().map {
          (value: $0.element, probability: -5 - Double($0.offset), typeID: factoryTypeID)
        }
      ),
    ])

    defer {
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testHandler.clear()
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testHandler.clear()
    testHandler.prefs.enforceETenDOSCandidateSequence = true
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    #expect(throws: Never.self) { try testHandler.assembler.insertKey(reading) }

    let candidateValues = testHandler.generateArrayOfCandidates().map(\.value)
    #expect(candidateValues == eTenSequence)
  }

  @Test("IH-CandidateOrder-003 ETen sequence enforcement with zai4 preserves zai4 zai order")
  func test_IH_CandidateOrder_003_ETenSequenceEnforcementWithZai4PreservesZai4ZaiOrder() throws {
    guard let testHandler else {
      Issue.record("testHandler is nil.")
      return
    }
    clearTestPOM()

    let reading = "ㄗㄞˋ"
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let textMap = makeTypingTextMap([
      (
        reading,
        [
          (value: "在", probability: -5.004, typeID: factoryTypeID),
          (value: "再", probability: -5.007, typeID: factoryTypeID),
        ]
      ),
    ])

    defer {
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testHandler.clear()
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testHandler.clear()
    testHandler.prefs.enforceETenDOSCandidateSequence = true
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    #expect(throws: Never.self) { try testHandler.assembler.insertKey(reading) }

    let candidateValues = testHandler.generateArrayOfCandidates().map(\.value)
    let zaiIndex = candidateValues.firstIndex(of: "在")
    let zai4Index = candidateValues.firstIndex(of: "再")
    guard let zaiIndex, let zai4Index else {
      Issue.record("Missing expected candidates. Got: \(candidateValues)")
      return
    }
    #expect(zaiIndex < zai4Index, "Expected 在 to precede 再, but got: \(candidateValues)")
  }

  @Test("IH-CandidateOrder-004 Filter non-CNS readings still allows selecting demoted single kanji")
  func test_IH_CandidateOrder_004_FilterNonCNSReadingsStillAllowsSelectingDemotedSingleKanji() throws {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()

    let textMap = makeTypingTextMap([
      (
        "ㄅㄛ",
        [
          (value: "玻", probability: -5, typeID: 6),
          (value: "播", probability: -4.5, typeID: 6),
          (value: "玻", probability: -11, typeID: 7),
        ]
      ),
    ])

    defer {
      testHandler.prefs.filterNonCNSReadingsForCHTInput = false
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testHandler.currentLM.syncPrefs()
      testSession.resetInputHandler(forceComposerCleanup: true)
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testSession.resetInputHandler(forceComposerCleanup: true)
    testHandler.prefs.filterNonCNSReadingsForCHTInput = true
    testHandler.prefs.enforceETenDOSCandidateSequence = false
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    #expect(throws: Never.self) { try testHandler.assembler.insertKey("ㄅㄛ") }

    let candidateValues = testHandler.generateArrayOfCandidates().map(\.value)
    guard let conformingIndex = candidateValues.firstIndex(of: "玻") else {
      Issue.record("Missing conforming candidate: 玻. Candidates: \(candidateValues)")
      return
    }
    guard let demotedIndex = candidateValues.firstIndex(of: "播") else {
      Issue.record("Missing demoted candidate: 播. Candidates: \(candidateValues)")
      return
    }
    #expect(demotedIndex > conformingIndex)

    testSession.switchState(testHandler.generateStateOfCandidates())
    guard let selectedIndex = testSession.state.candidates.firstIndex(where: { $0.value == "播" }) else {
      Issue.record("Candidate state is missing 播. Candidates: \(testSession.state.candidates.map(\.value))")
      return
    }
    testSession.candidatePairSelectionConfirmed(at: selectedIndex)
    #expect(generateDisplayedText() == "播")
  }

  @Test("IH-CandidateOrder-005 Pinyin toneless query uses stem partial match")
  func test_IH_CandidateOrder_005_PinyinTonelessQueryUsesStemPartialMatch() throws {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()

    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let customTone2Value = "伯測"
    let customTone4Value = "播測"
    let textMap = makeTypingTextMap([
      ("ㄅㄛˊ", [(value: customTone2Value, probability: -5, typeID: factoryTypeID)]),
      ("ㄅㄛˋ", [(value: customTone4Value, probability: -4.5, typeID: factoryTypeID)]),
    ])

    defer {
      testHandler.prefs.keyboardParser = KeyboardParser.ofStandard.rawValue
      testHandler.ensureKeyboardParser()
      testHandler.prefs.useSCPCTypingMode = false
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      testHandler.currentLM.setOptions { config in
        config.partialMatchEnabled = false
      }
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testSession.resetInputHandler(forceComposerCleanup: true)
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testSession.resetInputHandler(forceComposerCleanup: true)
    testHandler.prefs.keyboardParser = KeyboardParser.ofHanyuPinyin.rawValue
    testHandler.ensureKeyboardParser()
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    typeSentence("bo ")

    let candidateValues = Set(testHandler.generateArrayOfCandidates().map(\.value))
    #expect(candidateValues.contains(customTone2Value))
    #expect(candidateValues.contains(customTone4Value))
    #expect(!testHandler.currentLM.config.partialMatchEnabled)
  }

  @Test("IH-CandidateOrder-006 Pinyin explicit tone keeps full match")
  func test_IH_CandidateOrder_006_PinyinExplicitToneKeepsFullMatch() throws {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()

    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let customTone2Value = "伯測"
    let customTone4Value = "播測"
    let textMap = makeTypingTextMap([
      ("ㄅㄛˊ", [(value: customTone2Value, probability: -5, typeID: factoryTypeID)]),
      ("ㄅㄛˋ", [(value: customTone4Value, probability: -4.5, typeID: factoryTypeID)]),
    ])

    defer {
      testHandler.prefs.keyboardParser = KeyboardParser.ofStandard.rawValue
      testHandler.ensureKeyboardParser()
      testHandler.prefs.useSCPCTypingMode = false
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      testHandler.currentLM.setOptions { config in
        config.partialMatchEnabled = false
      }
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testSession.resetInputHandler(forceComposerCleanup: true)
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testSession.resetInputHandler(forceComposerCleanup: true)
    testHandler.prefs.keyboardParser = KeyboardParser.ofHanyuPinyin.rawValue
    testHandler.ensureKeyboardParser()
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    typeSentence("bo4")

    let candidateValues = testHandler.generateArrayOfCandidates().map(\.value)
    #expect(candidateValues.contains(customTone4Value))
    #expect(!candidateValues.contains(customTone2Value))
    #expect(!testHandler.currentLM.config.partialMatchEnabled)
  }

  @Test("IH-CandidateOrder-007 Pinyin toneless query does not match longer syllable stem")
  func test_IH_CandidateOrder_007_PinyinTonelessQueryDoesNotMatchLongerSyllableStem() throws {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()

    let customTone2Value = "時測"
    let customTone4Value = "世測"
    let customLongerStemValue = "衰測"
    let customGrams: [Homa.Gram] = [
      .init(keyArray: ["ㄕˊ"], value: customTone2Value, score: -5),
      .init(keyArray: ["ㄕˋ"], value: customTone4Value, score: -4.5),
      .init(keyArray: ["ㄕㄨㄞ"], value: customLongerStemValue, score: -4.2),
    ]

    defer {
      testHandler.currentLM.clearTemporaryData(isFiltering: false)
      testHandler.prefs.keyboardParser = KeyboardParser.ofStandard.rawValue
      testHandler.ensureKeyboardParser()
      testHandler.prefs.useSCPCTypingMode = false
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      testSession.resetInputHandler(forceComposerCleanup: true)
    }

    customGrams.forEach {
      testHandler.currentLM.insertTemporaryData(unigram: $0, isFiltering: false)
    }
    testSession.resetInputHandler(forceComposerCleanup: true)
    testHandler.prefs.keyboardParser = KeyboardParser.ofHanyuPinyin.rawValue
    testHandler.ensureKeyboardParser()
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = false
    testHandler.currentLM.syncPrefs()

    typeSentence("shi ")

    let candidateValues = Set(testHandler.generateArrayOfCandidates().map(\.value))
    #expect(candidateValues.contains(customTone2Value))
    #expect(candidateValues.contains(customTone4Value))
    #expect(!candidateValues.contains(customLongerStemValue))
    #expect(!testHandler.currentLM.config.partialMatchEnabled)
  }

  @Test("IH-CandidateOrder-008 Pinyin continuous stem auto chops leading readings")
  func test_IH_CandidateOrder_008_PinyinContinuousStemAutoChopsLeadingReadings() throws {
    guard let testHandler, let testSession else {
      Issue.record("testHandler and testSession at least one of them is nil.")
      return
    }
    clearTestPOM()

    let customShiValue = "世測"
    let customJieValue = "界測"
    let customDaValue = "大測"
    let customGrams: [Homa.Gram] = [
      .init(keyArray: ["ㄕˋ"], value: customShiValue, score: 9),
      .init(keyArray: ["ㄐㄧㄝˋ"], value: customJieValue, score: 8.5),
      .init(keyArray: ["ㄉㄚˋ"], value: customDaValue, score: 8),
    ]

    defer {
      testHandler.currentLM.clearTemporaryData(isFiltering: false)
      testHandler.prefs.keyboardParser = KeyboardParser.ofStandard.rawValue
      testHandler.ensureKeyboardParser()
      testSession.resetInputHandler(forceComposerCleanup: true)
    }

    customGrams.forEach {
      testHandler.currentLM.insertTemporaryData(unigram: $0, isFiltering: false)
    }
    testSession.resetInputHandler(forceComposerCleanup: true)
    testHandler.prefs.keyboardParser = KeyboardParser.ofHanyuPinyin.rawValue
    testHandler.ensureKeyboardParser()

    typeSentence("shijiedaz")

    #expect(generateDisplayedText() == customShiValue + customJieValue + customDaValue)
    #expect(testHandler.assembler.keys.count == 3)
    #expect(testHandler.composer.getInlineCompositionForDisplay(isHanyuPinyin: true) == "z")
    #expect(!testHandler.currentLM.config.partialMatchEnabled)
  }

  /// IH-CandidateOrder-009：倚天 DOS 固定序只是單字候選的「基底順序」，POM 學習結果須疊加其上。
  ///
  /// 舊行為：POM 先把「再」置頂，倚天重排卻以「倚天序列＋原單字」重建單字群組，
  /// 把「再」推回倚天位置（ㄗㄞˋ 永遠是「在再載…」），學習結果在選字窗內完全看不到。
  @Test("IH-CandidateOrder-009 ETen sequence enforcement keeps POM-promoted single on top")
  func test_IH_CandidateOrder_009_ETenSequenceEnforcementKeepsPOMPromotedSingleOnTop() throws {
    guard let testHandler else {
      Issue.record("testHandler is nil.")
      return
    }
    clearTestPOM()

    let reading = "ㄗㄞˋ"
    let eTenSequence = uniqueSingleIdeographicValues(
      testHandler.currentLM.lxQuerier.supplementalValues(for: reading, strategy: .configuredLookup)
    )
    guard eTenSequence.count >= 3, eTenSequence.prefix(2) == ["在", "再"] else {
      Issue.record("倚天中文 DOS 序列表測試資料不符預期：\(reading) → \(eTenSequence)")
      return
    }
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let textMap = makeTypingTextMap([
      (
        reading,
        [
          (value: "在", probability: -5.004, typeID: factoryTypeID),
          (value: "再", probability: -5.007, typeID: factoryTypeID),
        ]
      ),
    ])

    defer {
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      clearTestPOM()
      testHandler.clear()
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testHandler.clear()
    testHandler.prefs.enforceETenDOSCandidateSequence = true
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    testHandler.currentLM.syncPrefs()

    #expect(throws: Never.self) { try testHandler.assembler.insertKey(reading) }
    #expect(testHandler.assembler.assemble().values == ["在"])

    // 無 POM 記憶：倚天序維持不變（等同 IH-CandidateOrder-002 之情境）。
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value) == eTenSequence)

    // 寫入一筆「ㄗㄞˋ → 再」之記憶（格式同使用者於選字窗選「再」時所寫入者）。
    testHandler.currentLM.memorizePerception(
      (ngramKey: "()&()&(ㄗㄞˋ,再)", candidate: "再"),
      timestamp: Date().timeIntervalSince1970
    )

    let candidateValues = testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value)
    let expectedValues = ["再"] + eTenSequence.filter { $0 != "再" }
    #expect(
      candidateValues == expectedValues,
      "POM 置頂之單字須凌駕倚天序，其餘維持倚天序。Got: \(candidateValues)"
    )

    // 固定候選順序（fixOrder）時不讀取 POM：維持倚天序。
    #expect(testHandler.generateArrayOfCandidates(fixOrder: true).map(\.value) == eTenSequence)

    // 逐字選字模式略過 POM：維持倚天序。
    testHandler.prefs.useSCPCTypingMode = true
    defer { testHandler.prefs.useSCPCTypingMode = false }
    #expect(testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value) == eTenSequence)
  }

  /// IH-CandidateOrder-010：倚天固定序＋POM 置頂之下，多字詞候選仍排在所有單字候選之前。
  @Test("IH-CandidateOrder-010 ETen sequence with POM promotion keeps longer segments first")
  func test_IH_CandidateOrder_010_ETenSequenceWithPOMPromotionKeepsLongerSegmentsFirst() throws {
    guard let testHandler else {
      Issue.record("testHandler is nil.")
      return
    }
    clearTestPOM()

    let reading = "ㄗㄞˋ"
    let eTenSequence = uniqueSingleIdeographicValues(
      testHandler.currentLM.lxQuerier.supplementalValues(for: reading, strategy: .configuredLookup)
    )
    guard eTenSequence.count >= 3, eTenSequence.prefix(2) == ["在", "再"] else {
      Issue.record("倚天中文 DOS 序列表測試資料不符預期：\(reading) → \(eTenSequence)")
      return
    }
    let factoryTypeID: Int32 = testHandler.currentLM.isCHS ? 5 : 6
    let textMap = makeTypingTextMap([
      (
        "ㄒㄧㄢˋ",
        [(value: "現", probability: -5.1, typeID: factoryTypeID)]
      ),
      (
        "ㄒㄧㄢˋ-ㄗㄞˋ",
        [(value: "現在", probability: -4.0, typeID: factoryTypeID)]
      ),
      (
        reading,
        [
          (value: "在", probability: -5.004, typeID: factoryTypeID),
          (value: "再", probability: -5.007, typeID: factoryTypeID),
        ]
      ),
    ])

    defer {
      LXAssembly.LXFacade.disconnectFactoryDictionary()
      #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: LXATestsData.textMapTestCoreLXData))
      testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
      clearTestPOM()
      testHandler.clear()
    }

    LXAssembly.LXFacade.disconnectFactoryDictionary()
    #expect(LXAssembly.LXFacade.connectToTestFactoryDictionary(textMapData: textMap))
    testHandler.clear()
    testHandler.prefs.enforceETenDOSCandidateSequence = true
    testHandler.prefs.useSCPCTypingMode = false
    testHandler.prefs.useRearCursorMode = false
    testHandler.prefs.fetchSuggestionsFromPerceptionOverrideModel = true
    testHandler.currentLM.syncPrefs()

    #expect(throws: Never.self) { try testHandler.assembler.insertKey("ㄒㄧㄢˋ") }
    #expect(throws: Never.self) { try testHandler.assembler.insertKey(reading) }
    #expect(testHandler.assembler.assemble().values == ["現在"])

    // 以注入之 POM 建議模擬「此處學過『再』」（多字詞節點之語境鍵無法直接寫入單字記憶）。
    var suggestion = LXAssembly.OverrideSuggestion()
    suggestion.candidates = [(keyArray: [reading], value: "再", probability: -0.1, previous: nil)]
    suggestion.overrideCursor = 1
    testHandler.currentLM.lxPerceptor.testInjectedSuggestion = suggestion

    let candidateValues = testHandler.generateArrayOfCandidates(fixOrder: false).map(\.value)
    let expectedValues = ["現在", "再"] + eTenSequence.filter { $0 != "再" }
    #expect(
      candidateValues == expectedValues,
      "多字詞須在前、POM 置頂之單字次之、其餘維持倚天序。Got: \(candidateValues)"
    )
  }
}
