// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - 刪除重打修正（閘門與記錄端）

/// 「刪除重打」修正：使用者遞交之後在客體內按 BackSpace 刪掉尾端的字、緊接著重打同樣的讀音，
/// 即視為「上次自動選的字是錯的」。狀態機見 `RecentCommitLedger`；本檔負責與輸入調度模組的接線：
/// - 遞交時（`SessionCoreProtocol.switchState(_:)` 之匯流點）快照組句結果；
/// - 每次分診按鍵之後觀察按鍵（`triageInput(event:)`）以累計刪除、進入或解除待命；
/// - 組字時（`retrievePOMSuggestions(apply: true)` 之後）把被否決的值改成次佳候選；
/// - 候選窗把被否決的值移到同詞長群組之末；
/// - 遞交或顯式選字時學習（寫入 POM、或清除導致錯字的那筆 POM 記憶）。
extension InputHandlerProtocol {
  /// 刪除重打修正在目前情境下是否生效。
  ///
  /// 限於：隱藏偏好啟用、非逐字選字模式、非磁帶模式、唯音原廠注拼、且非狂打模式
  /// （狂打的 trail／重切分與本處之覆寫語義衝突）。
  var isRetypeCorrectionInEffect: Bool {
    prefs.retypeCorrectionDetectionEnabled
      && !prefs.useSCPCTypingMode
      && !prefs.cassetteEnabled
      && currentTypingMethod == .vChewingFactory
      && !isFuriousTypingModeEffective
  }

  /// 當前客體之識別碼（無會話時為空字串）。
  var retypeCorrectionClientID: String {
    session?.clientBundleIdentifier ?? ""
  }

  /// 帳本作廢（客體變更、輸入法啟用／停用等場合）。
  public func resetRetypeCorrectionLedger() {
    recentCommitLedger.reset()
  }

  /// 在組字區內容即將被遞交（且組字器即將被清空）之前呼叫：
  /// 先處理待命中的修正（隱式確認之學習），再把本次遞交記入帳本。
  ///
  /// 由 `SessionCoreProtocol.switchState(_:)` 於 `.ofCommitting` 時、在 `clear()` 之前呼叫。
  /// 只有「實際遞交的文字」以組句結果結尾時才記錄（否則字元數無從對回節點）；
  /// 其餘遞交（標點、空白、遞交讀音、空字串等）一律令帳本作廢。
  /// - Parameter committedText: 實際遞交出去的文字。
  public func recordRecentCommitForRetypeCorrection(committedText: String) {
    guard isRetypeCorrectionInEffect, !committedText.isEmpty else {
      recentCommitLedger.registerUnrecordableCommit()
      return
    }
    let sentence = assembler.assembledSentence
    let assembledText = sentence.values.joined()
    guard !assembledText.isEmpty, committedText.hasSuffix(assembledText) else {
      recentCommitLedger.registerUnrecordableCommit()
      return
    }
    confirmRetypeCorrectionOnCommit(sentence: sentence)
    recentCommitLedger.registerCommit(
      nodes: makeCommittedNodesForRetypeCorrection(from: sentence),
      clientID: retypeCorrectionClientID
    )
  }

  /// 將組句結果轉為帳本快照。尾端（最多 `kMaxRetypeCorrectionDeletions` 個字元）之節點另行查詢：
  /// 其詞值是否正是某筆 POM 記憶的建議；若是，記下該筆記憶，以便修正成立時清除之。
  func makeCommittedNodesForRetypeCorrection(
    from sentence: [Homa.GramInPath]
  )
    -> [RecentCommitLedger.CommittedNode] {
    let totalCharCount = sentence.map(\.value.count).reduce(0, +)
    let shouldQueryPOM = prefs.fetchSuggestionsFromPerceptionOverrideModel
    let now = Date().timeIntervalSince1970
    var keyOffset = 0
    var charOffset = 0
    return sentence.map { gramInPath in
      defer {
        keyOffset += gramInPath.keyArray.count
        charOffset += gramInPath.value.count
      }
      let keyArray = gramInPath.keyArray
      let value = gramInPath.value
      let isEligible = !keyArray.isEmpty && !value.isEmpty
        && !gramInPath.isReadingMismatched && value.count == keyArray.count
        && !keyArray.contains(where: { $0.isEmpty || $0.hasPrefix("_") })
      var pomMemory: RecentCommitLedger.POMMemoryTarget?
      let isWithinDeletableTail = totalCharCount - charOffset <= kMaxRetypeCorrectionDeletions
      if isEligible, shouldQueryPOM, isWithinDeletableTail {
        let suggestion = currentLM.fetchPOMSuggestion(
          assembledResult: sentence,
          cursor: keyOffset,
          timestamp: now
        )
        if let ngramKey = suggestion.matchedNGramKey,
           suggestion.candidates.contains(where: { $0.value == value }) {
          pomMemory = .init(ngramKey: ngramKey, candidate: value)
        }
      }
      return .init(
        keyArray: keyArray,
        value: value,
        isExplicit: gramInPath.isExplicit,
        isEligible: isEligible,
        pomMemory: pomMemory
      )
    }
  }
}

// MARK: - 刪除重打修正（按鍵觀察端）

extension InputHandlerProtocol {
  /// 新組字區當前每個位置的所有可能讀音。
  var typedReadingsForRetypeCorrection: [[String]] {
    assembler.keys.map(\.allValues)
  }

  /// 輸入調度模組是否持有任何組字內容（組字器或注拼槽／組筆區／緩衝區）。
  var isComposingForRetypeCorrection: Bool {
    !assembler.isEmpty || !isComposerOrCalligrapherEmpty
  }

  /// 每次分診按鍵之後呼叫，推進刪除重打修正之狀態機。
  /// - Parameters:
  ///   - input: 本次按鍵。
  ///   - wasEmptyBefore: 分診之前是否處於空狀態（`.ofEmpty` 且無任何組字內容）。
  ///   - commitGenerationBefore: 分診之前之帳本遞交世代。
  ///   - handled: 本次按鍵是否被輸入法攔截處理。
  func observeKeyForRetypeCorrection(
    _ input: InputSignalProtocol,
    wasEmptyBefore: Bool,
    commitGenerationBefore: UInt,
    handled: Bool
  ) {
    // 本次按鍵造成了遞交：遞交匯流點已處理完畢（新紀錄、或作廢），此處不再干預。
    guard recentCommitLedger.commitGeneration == commitGenerationBefore else { return }
    guard !recentCommitLedger.isIdle else { return }
    guard isRetypeCorrectionInEffect else {
      recentCommitLedger.reset()
      return
    }
    let clientID = retypeCorrectionClientID
    let isComposingNow = isComposingForRetypeCorrection

    // 待命中：組字區被清空、或客體變了，即作廢；否則驗證重打的讀音仍是被刪讀音的前綴。
    // （新組字區內的 BackSpace 照常處理，不計入刪除次數。）
    if let armed = recentCommitLedger.armed {
      guard isComposingNow, armed.clientID == clientID else {
        recentCommitLedger.reset()
        return
      }
      recentCommitLedger.validateTypedReadings(typedReadingsForRetypeCorrection)
      return
    }

    // 已遞交、尚未開始重打。
    let isPlainBackSpace = input.isBackSpace && input.commonKeyModifierFlags.isEmpty
    if wasEmptyBefore, !handled, isPlainBackSpace {
      recentCommitLedger.registerDeletion(clientID: clientID)
      return
    }
    let hasPendingDeletions = (recentCommitLedger.record?.deletedCharCount ?? 0) > 0
    if wasEmptyBefore, handled, isComposingNow, hasPendingDeletions {
      if recentCommitLedger.armIfPending(clientID: clientID) {
        recentCommitLedger.validateTypedReadings(typedReadingsForRetypeCorrection)
      }
      return
    }
    // 其他任何按鍵：作廢。
    recentCommitLedger.reset()
  }
}

// MARK: - 刪除重打修正（組字回應端）

extension InputHandlerProtocol {
  /// 在 POM 自動套用之後呼叫（`retrievePOMSuggestions(apply: true)`）：
  /// 對每個「讀音已重打完整、且組字器當前在該區間給出的值恰為被否決之值 V」的對象，
  /// 改選次佳候選 V′（`.withSpecified`、非顯式覆寫、不強制重新分詞）。
  ///
  /// 每個對象只挑選一次 V′；其後若該區間又變回 V（例如被 POM 再度套用），則以同一個 V′ 重新覆寫。
  /// 使用者在該區間顯式選字者不予干涉。沒有替代候選者不做任何事。
  func applyRetypeCorrectionIfArmed() {
    let hasPendingDeletions = (recentCommitLedger.record?.deletedCharCount ?? 0) > 0
    guard recentCommitLedger.armed != nil || hasPendingDeletions else { return }
    guard isRetypeCorrectionInEffect else {
      recentCommitLedger.reset()
      return
    }
    guard recentCommitLedger.armIfPending(clientID: retypeCorrectionClientID) else { return }
    guard recentCommitLedger.validateTypedReadings(typedReadingsForRetypeCorrection) else { return }
    guard var armed = recentCommitLedger.armed else { return }
    var sentence = assembler.assembledSentence
    for index in armed.targets.indices {
      let target = armed.targets[index]
      guard !target.isSettled, target.range.upperBound <= assembler.length else { continue }
      guard let hit = sentence.findGram(at: target.range.lowerBound),
            hit.range == target.range,
            hit.gram.keyArray == target.node.keyArray,
            !hit.gram.isExplicit,
            hit.gram.value == target.rejectedValue
      else { continue }
      guard let replacement = target.substitutedValue
        ?? pickRetypeCorrectionAlternative(for: target)
      else {
        armed.targets[index].isSettled = true // 沒有替代候選：此後不再嘗試。
        continue
      }
      let succeeded = assembler.overrideCandidate(
        .init(keyArray: target.node.keyArray, value: replacement),
        at: target.range.lowerBound,
        overrideType: .withSpecified,
        isExplicitlyOverridden: false,
        enforceRetokenization: false
      )
      guard succeeded else { continue }
      armed.targets[index].substitutedValue = replacement
      sentence = assembler.assembledSentence
    }
    recentCommitLedger.armed = armed
  }

  /// 為給定對象挑選替代值：取該區間起點之候選（`.beginAt`）中、讀音相同且詞值不是 V 者。
  /// 使用頻次帳本生效時，優先挑選其中使用次數最多者；否則取候選順序中的第一個。
  func pickRetypeCorrectionAlternative(
    for target: RecentCommitLedger.CorrectionTarget
  )
    -> String? {
    let alternatives = assembler.fetchCandidates(at: target.range.lowerBound, filter: .beginAt)
      .map(\.pair)
      .filter { $0.keyArray == target.node.keyArray && $0.value != target.rejectedValue }
      .map(\.value)
    guard let firstAlternative = alternatives.first else { return nil }
    guard isUsageLedgerInEffect else { return firstAlternative }
    let usage = Dictionary(
      currentLM.usageRanking(keyArray: target.node.keyArray).map { ($0.value, $0.effectiveCount) },
      uniquingKeysWith: { Swift.max($0, $1) }
    )
    let bestUsage = alternatives.map { usage[$0] ?? 0 }.max() ?? 0
    guard bestUsage > 0 else { return firstAlternative }
    return alternatives.first { (usage[$0] ?? 0) == bestUsage } ?? firstAlternative
  }

  /// 候選窗：待命期間，把被否決之值移到其詞長群組之末（其餘候選之相對順序不變）。
  ///
  /// 「詞長群組之末」指同詞長之最後一個候選之後（罕見詞沉底之類的既有排序因此不受影響）。
  func demoteRejectedCandidatesForRetypeCorrection(
    _ candidates: [Homa.CandidatePair]
  )
    -> [Homa.CandidatePair] {
    guard isRetypeCorrectionInEffect, let armed = recentCommitLedger.armed else { return candidates }
    let rejectedPairs = armed.targets.filter { !$0.isSettled }.map {
      Homa.CandidatePair(keyArray: $0.node.keyArray, value: $0.rejectedValue)
    }
    var result = candidates
    for rejected in rejectedPairs {
      guard let currentIndex = result.firstIndex(where: {
        $0.keyArray == rejected.keyArray && $0.value == rejected.value
      }) else { continue }
      let pair = result.remove(at: currentIndex)
      let groupEnd = result.lastIndex { $0.keyArray.count == pair.keyArray.count }
        .map { $0 + 1 } ?? result.endIndex
      result.insert(pair, at: groupEnd)
    }
    return result
  }
}

// MARK: - 刪除重打修正（學習端）

extension InputHandlerProtocol {
  /// 顯式選字之後呼叫（`consolidateNode(..., explicitlyChosen: true)`）。
  ///
  /// 對每個尚未了結、且該區間已被顯式選字的對象：
  /// - 選的仍是 V：使用者堅持原值，了結、不學習；
  /// - 選的正是自動改選的 V′：留待遞交時一併學習（見 `confirmRetypeCorrectionOnCommit`）；
  /// - 選了別的值：`consolidateNode` 已照常寫入 POM；若 V 係由 POM 建議所致，清除那筆記憶；了結。
  /// - 區間被不同切分的詞覆蓋：了結、不學習。
  func noteExplicitChoiceForRetypeCorrection() {
    guard var armed = recentCommitLedger.armed else { return }
    let sentence = assembler.assembledSentence
    var bleachTargets: [(ngramKey: String, candidate: String)] = []
    for index in armed.targets.indices where !armed.targets[index].isSettled {
      let target = armed.targets[index]
      guard target.range.upperBound <= assembler.length,
            let hit = sentence.findGram(at: target.range.lowerBound),
            hit.gram.isExplicit
      else { continue }
      guard hit.range == target.range, hit.gram.keyArray == target.node.keyArray else {
        armed.targets[index].isSettled = true
        continue
      }
      let chosenValue = hit.gram.value
      if chosenValue == target.substitutedValue { continue }
      if chosenValue != target.rejectedValue, let memory = target.node.pomMemory {
        bleachTargets.append((ngramKey: memory.ngramKey, candidate: memory.candidate))
      }
      armed.targets[index].isSettled = true
    }
    recentCommitLedger.armed = armed.isFullySettled ? nil : armed
    if !bleachTargets.isEmpty {
      currentLM.bleachSpecifiedPOMSuggestions(targets: bleachTargets, saveCallback: pomSaveCallback)
    }
  }

  /// 遞交時之隱式確認：對每個尚未了結、且遞交時該區間仍是自動改選之 V′ 的對象，
  /// - 若 V 係由 POM 建議所致，先清除那筆記憶；
  /// - 再以 `Homa.makePerceptionIntel`（之前＝該區間為 V 的句子、之後＝遞交的句子、游標＝區間起點）
  ///   寫入恰好一筆 POM 記憶（經由與顯式選字相同的寫入閘門）。
  /// 之後解除待命。
  func confirmRetypeCorrectionOnCommit(sentence: [Homa.GramInPath]) {
    guard let armed = recentCommitLedger.armed else { return }
    recentCommitLedger.disarm()
    var bleachTargets: [(ngramKey: String, candidate: String)] = []
    var observations: [Homa.PerceptionIntel] = []
    for target in armed.targets where !target.isSettled {
      guard let substitutedValue = target.substitutedValue,
            let hit = sentence.findGram(at: target.range.lowerBound),
            hit.range == target.range,
            hit.gram.keyArray == target.node.keyArray,
            hit.gram.value == substitutedValue
      else { continue }
      if let memory = target.node.pomMemory {
        bleachTargets.append((ngramKey: memory.ngramKey, candidate: memory.candidate))
      }
      guard let sentenceWithRejectedValue = sentenceReplacingGram(
        in: sentence, at: target.range, withValue: target.rejectedValue
      ) else { continue }
      if let observation = Homa.makePerceptionIntel(
        previouslyAssembled: sentenceWithRejectedValue,
        currentAssembled: sentence,
        cursor: target.range.lowerBound
      ) {
        observations.append(observation)
      }
    }
    // 先清除導致錯字的記憶、再寫入新記憶：兩者恰好同鍵時，新記憶不致被一併清掉。
    if !bleachTargets.isEmpty {
      currentLM.bleachSpecifiedPOMSuggestions(targets: bleachTargets, saveCallback: pomSaveCallback)
    }
    observations.forEach { memorizePOMObservation($0, skipObservation: false) }
  }

  /// 把句子中恰好覆蓋給定區間的節點換成給定詞值（其餘不變）；找不到該節點時回傳 `nil`。
  private func sentenceReplacingGram(
    in sentence: [Homa.GramInPath],
    at range: Range<Int>,
    withValue value: String
  )
    -> [Homa.GramInPath]? {
    var offset = 0
    var replaced = false
    let result = sentence.map { gramInPath -> Homa.GramInPath in
      defer { offset += gramInPath.keyArray.count }
      guard offset == range.lowerBound, gramInPath.keyArray.count == range.count else {
        return gramInPath
      }
      replaced = true
      let gram = gramInPath.gram
      return .init(
        gram: .init(keyArray: gram.keyArray, current: value, probability: gram.probability),
        isExplicit: false
      )
    }
    return replaced ? result : nil
  }
}
