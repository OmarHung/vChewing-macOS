// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

extension LXAssembly.LXFacade {
  /// 使用頻次帳本的世代計數器（每次帳目變更時遞增）。
  ///
  /// 帳本目前不參與 `unigramsFor`，故本計數器**刻意未**併入 `currentGramCacheFingerprint`。
  /// 日後若讓帳本影響組句（DP），務必一併把本計數器加進該指紋。
  public var usageLedgerGeneration: Int {
    lxUsageLedger.generation
  }

  /// 將一次遞交中的字詞記入使用頻次帳本。
  /// - Parameters:
  ///   - pairs: 遞交的字詞（讀音陣列＋詞值）。讀音任一段以 `_` 開頭者與空詞值會被略過。
  ///   - timestamp: 遞交時刻（Unix 秒）。
  ///   - saveCallback: 存檔回呼（供宿主做防抖存檔）；為 `nil` 時直接寫入預設位置。
  public func recordUsage(
    _ pairs: [(keyArray: [String], value: String)],
    timestamp: Double,
    saveCallback: (() -> ())? = nil
  ) {
    guard isUsageLedgerEnabled else { return }
    let ledgerPairs = pairs.map {
      (readingKey: $0.keyArray.joined(separator: String(LXAssembly.LXUsageLedger.kReadingSeparator)), value: $0.value)
    }
    guard lxUsageLedger.record(ledgerPairs, timestamp: timestamp) else { return }
    saveCallback?() ?? lxUsageLedger.saveData()
  }

  /// 取得某讀音底下各詞值的有效使用次數（已衰減），依有效次數降冪排列。
  /// 停用帳本時回傳空陣列。
  public func usageRanking(
    keyArray: [String],
    now: Double = Date().timeIntervalSince1970
  )
    -> [(value: String, effectiveCount: Double)] {
    guard isUsageLedgerEnabled, !keyArray.isEmpty else { return [] }
    return lxUsageLedger.usageRanking(
      for: keyArray.joined(separator: String(LXAssembly.LXUsageLedger.kReadingSeparator)),
      now: now
    )
  }

  public func loadUsageLedger(fromURL fileURL: URL? = nil) {
    lxUsageLedger.loadData(fromURL: fileURL)
  }

  public func saveUsageLedger(toURL fileURL: URL? = nil) {
    lxUsageLedger.saveData(toURL: fileURL)
  }

  public func clearUsageLedger(withURL fileURL: URL? = nil) {
    lxUsageLedger.clearData(withURL: fileURL)
  }
}
