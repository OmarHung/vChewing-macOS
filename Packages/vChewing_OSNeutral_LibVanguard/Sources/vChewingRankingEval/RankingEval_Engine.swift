// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Homa
import LexiconAssembly
import RankingEvalKit

// MARK: - RankingEvalEngine

/// 以原廠辭典驅動 `Homa.Assembler` 組句的評測引擎。
///
/// 查詢路徑與 `InputHandler` 完全相同（`lxQuerier.grams(for:)`／`lxQuerier.hasGrams(for:)`），
/// 唯不載入任何使用者資料：使用者片語、濾除表、語彙置換皆為空，漸退記憶（POM）亦停用，
/// 故所得即為「原廠辭典 + DAG-DP」的基線表現。
struct RankingEvalEngine {
  // MARK: Lifecycle

  init(
    maxSegLength: Int,
    rarityThreshold: Double? = nil,
    rareFloor: RankingEvalOptions.RareFloorSetting = .assemblerDefault,
    beamWidth: Int? = nil
  ) {
    self.maxSegLength = maxSegLength
    self.rarityThreshold = rarityThreshold
    self.rareFloor = rareFloor
    self.beamWidth = beamWidth
    self.facade = LXAssembly.LXFacade(isCHS: false, pomDataURL: nil)
    facade.setOptions { config in
      // 以下對齊 `LXFacade.syncPrefs()` 在出廠預設偏好下的結果。
      config.isCNSEnabled = false
      config.isSymbolEnabled = true
      config.isSCPCEnabled = false
      config.isCassetteEnabled = false
      config.isPhraseReplacementEnabled = false
      config.filterNonCNSReadings = false
      config.filterFactoryKanjisOfNonCurrentInputMode = false
      config.allowRescoringSingleKanjiCandidates = false
      config.alwaysSupplyETenDOSUnigrams = true
      config.partialMatchEnabled = false
      // 基線不得受使用者記憶影響。
      config.fetchSuggestionsFromPerceptionOverrideModel = false
      config.bypassUserPhrasesData = false
    }
  }

  // MARK: Internal

  let maxSegLength: Int
  let rarityThreshold: Double?
  let rareFloor: RankingEvalOptions.RareFloorSetting
  /// nil 表示沿用組字器預設值。
  let beamWidth: Int?

  /// 實際生效的組態（含組字器參數的最終值），寫入報表以便比對。
  var optionsDescription: [String: String] {
    let probe = makeAssembler(querier: facade.lxQuerier)
    return [
      "chs": "false",
      "cns": "false",
      "symbols": "true",
      "etenDOSUnigrams": "true",
      "pom": "disabled",
      "userPhrases": "empty",
      "maxSegLength": probe.maxSegLength.description,
      "rarityThreshold": probe.rarityThreshold.description,
      "rarePhrasePerSyllableFloor": probe.rarePhrasePerSyllableFloor?.description ?? "off",
      "beamWidth": probe.beamWidth.description,
    ]
  }

  func evaluate(_ evalCase: RankingEvalCase) -> RankingEvalCaseResult {
    let querier = facade.lxQuerier
    let missingReadings = evalCase.readings.filter { reading in
      // 以 `_` 起首者（如標點 `_punctuation_?`）不在核心辭典內，改以完整查詢路徑確認。
      guard !reading.hasPrefix("_") else { return !querier.hasGrams(for: [reading]) }
      return facade.factoryCoreUnigramsFor(key: reading, keyArray: [reading]).isEmpty
    }
    let unreachablePositions = unreachablePositions(of: evalCase)
    guard missingReadings.isEmpty else {
      return RankingEvalCaseResult(
        evalCase: evalCase,
        actual: nil,
        segments: nil,
        comparison: nil,
        missingReadings: missingReadings,
        unreachablePositions: unreachablePositions
      )
    }

    let assembler = makeAssembler(querier: querier)
    var rejectedReadings: [String] = []
    for reading in evalCase.readings {
      do {
        try assembler.insertKey(reading)
      } catch {
        rejectedReadings.append(reading)
      }
    }
    guard rejectedReadings.isEmpty else {
      return RankingEvalCaseResult(
        evalCase: evalCase,
        actual: nil,
        segments: nil,
        comparison: nil,
        missingReadings: rejectedReadings,
        unreachablePositions: unreachablePositions
      )
    }

    let segments = assembler.assemble().map(\.value)
    let actual = segments.joined()
    return RankingEvalCaseResult(
      evalCase: evalCase,
      actual: actual,
      segments: segments,
      comparison: RankingEvalMetrics.compare(expected: evalCase.expected, actual: actual),
      missingReadings: [],
      unreachablePositions: unreachablePositions
    )
  }

  // MARK: Private

  private let facade: LXAssembly.LXFacade

  private func makeAssembler(querier: LXAssembly.LXFacade.LXQuerier) -> Homa.Assembler {
    let assembler = Homa.Assembler(
      gramQuerier: { querier.grams(for: $0) },
      gramAvailabilityChecker: { querier.hasGrams(for: $0) }
    )
    assembler.maxSegLength = maxSegLength
    if let rarityThreshold {
      assembler.rarityThreshold = rarityThreshold
    }
    switch rareFloor {
    case .assemblerDefault: break
    case .off: assembler.rarePhrasePerSyllableFloor = nil
    case let .value(floor): assembler.rarePhrasePerSyllableFloor = floor
    }
    if let beamWidth {
      assembler.beamWidth = beamWidth
    }
    return assembler
  }

  /// 找出「預期字不在其讀音的單字候選中」的字位，用以提示句子集讀音可能標錯。
  private func unreachablePositions(of evalCase: RankingEvalCase) -> [Int] {
    let querier = facade.lxQuerier
    let expectedChars = Array(evalCase.expected)
    return evalCase.readings.indices.filter { index in
      let expectedChar = String(expectedChars[index])
      let reading = evalCase.readings[index]
      return !querier.grams(for: [reading]).contains { $0.current == expectedChar }
    }
  }
}
