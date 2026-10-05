// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - 使用頻次帳本（記錄端）

extension InputHandlerProtocol {
  /// 使用頻次帳本在目前情境下是否生效（記錄與候選窗前移共用此閘）。
  ///
  /// 限於：偏好設定啟用、非磁帶模式、且目前的打字方式為唯音原廠注拼（內碼、羅馬數字等打字方式不看讀音鍵）。
  var isUsageLedgerInEffect: Bool {
    prefs.candidateUsageLedgerEnabled
      && !prefs.cassetteEnabled
      && currentTypingMethod == .vChewingFactory
  }

  /// 在組字區內容即將被遞交（且組字器即將被清空）之前，將組句結果記入使用頻次帳本。
  ///
  /// 由 `SessionCoreProtocol.switchState(_:)` 於 `.ofCommitting`（以及「自帶組字內容之狀態切至
  /// `.ofEmpty`」）時、在 `clear()` 之前呼叫——這是所有遞交路徑共用的匯流點（含逐字選字模式的
  /// 逐字遞交、狂打模式、中英混打之遞交、`commitComposition()` 之強制遞交等）。
  ///
  /// 只有在「實際遞交的文字」確實包含組字器的組句結果時才記錄：
  /// 遞交讀音（Ctrl+Cmd+Enter 等）、帶注音標記之遞交、以空格分隔之遞交、關聯詞語、符號表等
  /// 遞交內容並非組句結果的情形一律不記錄。中止（`.ofAbortion`）亦不記錄。
  /// - Parameter committedText: 實際遞交出去的文字。
  public func recordUsageLedgerOnCommit(committedText: String) {
    guard isUsageLedgerInEffect, !committedText.isEmpty else { return }
    let sentence = assembler.assembledSentence
    guard !sentence.isEmpty else { return }
    // 刻意直接比對組句結果的詞值（而非呼叫 `committableDisplayText`），以免在遞交途中觸發狂打前方預覽等額外運算。
    let assembledText = sentence.values.joined()
    guard !assembledText.isEmpty, committedText.contains(assembledText) else { return }
    recordUsageLedger(pairs: usageLedgerPairs(from: sentence))
  }

  /// 自組句結果中挑出可記入使用頻次帳本的字詞：略過標點（讀音以 `_` 開頭）、
  /// 讀音與字長不一致的節點、以及空詞值。
  func usageLedgerPairs(from sentence: [Homa.GramInPath]) -> [(keyArray: [String], value: String)] {
    sentence.compactMap { gramInPath -> (keyArray: [String], value: String)? in
      let keyArray = gramInPath.keyArray
      let value = gramInPath.value
      guard !keyArray.isEmpty, !value.isEmpty else { return nil }
      guard !gramInPath.isReadingMismatched, value.count == keyArray.count else { return nil }
      guard !keyArray.contains(where: { $0.isEmpty || $0.hasPrefix("_") }) else { return nil }
      return (keyArray, value)
    }
  }

  /// 將給定的字詞記入使用頻次帳本（受 `isUsageLedgerInEffect` 把守）。
  func recordUsageLedger(pairs: [(keyArray: [String], value: String)]) {
    guard isUsageLedgerInEffect, !pairs.isEmpty else { return }
    currentLM.recordUsage(
      pairs,
      timestamp: Date().timeIntervalSince1970,
      saveCallback: usageLedgerSaveCallback
    )
  }
}

// MARK: - 使用頻次帳本（候選窗排序端）

extension InputHandlerProtocol {
  /// 依使用頻次帳本，在「同詞長群組」內把常用候選往前移。
  ///
  /// 排序規則（穩定排序）：
  /// 1. 詞長降冪（維持「多字詞先於單字」的既有語義）；
  /// 2. 同詞長之內，`pinned`（目前為 POM 建議置頂之候選）優先，彼此維持原有相對順序；
  /// 3. 其餘候選中，有效使用次數 > 0 者依有效次數降冪排在前面；
  /// 4. 有效使用次數為 0 者維持原有（基底）順序——倚天固定序生效時即倚天序，否則為詞庫頻率序。
  ///
  /// 若整個候選清單皆無使用紀錄，則原樣返回（零行為變化）。
  /// 每個讀音鍵只查詢帳本一次。
  /// - Parameters:
  ///   - candidates: 已套用 POM 置頂與倚天固定序之後的候選清單。
  ///   - pinned: 須維持在各自詞長群組之首的候選。
  /// - Returns: 套用使用頻次前移之後的候選清單。
  func promoteCandidatesByUsage(
    _ candidates: [Homa.CandidatePair],
    pinned: [Homa.CandidatePair]
  )
    -> [Homa.CandidatePair] {
    guard candidates.count > 1 else { return candidates }
    let now = Date().timeIntervalSince1970
    var usageByReading: [[String]: [String: Double]] = [:]
    var hasAnyUsage = false
    for keyArray in candidates.map(\.keyArray) where usageByReading[keyArray] == nil {
      let ranking = currentLM.usageRanking(keyArray: keyArray, now: now)
      usageByReading[keyArray] = Dictionary(
        ranking.map { ($0.value, $0.effectiveCount) },
        uniquingKeysWith: { max($0, $1) }
      )
      hasAnyUsage = hasAnyUsage || !ranking.isEmpty
    }
    guard hasAnyUsage else { return candidates }
    let pinnedSet = Set(pinned)
    func usage(of pair: Homa.CandidatePair) -> Double {
      usageByReading[pair.keyArray]?[pair.value] ?? 0
    }
    return candidates.stableSort { lhs, rhs in
      if lhs.keyArray.count != rhs.keyArray.count {
        return lhs.keyArray.count > rhs.keyArray.count
      }
      let (lhsPinned, rhsPinned) = (pinnedSet.contains(lhs), pinnedSet.contains(rhs))
      if lhsPinned != rhsPinned { return lhsPinned }
      if lhsPinned { return false } // 皆為置頂候選：維持原有相對順序。
      return usage(of: lhs) > usage(of: rhs)
    }
  }
}
