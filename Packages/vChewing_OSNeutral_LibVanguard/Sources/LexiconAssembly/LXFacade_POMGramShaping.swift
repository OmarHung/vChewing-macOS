// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa

// MARK: - POM 語境記憶的元圖塑形（B2 分級加分、B3 字級退避）

extension LXAssembly.LXFacade {
  /// `LXPerceptor.perceptionsFor(headReading:timestamp:matchMode:)` 的回傳元素型別。
  typealias POMPerceptionEntry = (
    headReading: String,
    previous: String?,
    anterior: String?,
    candidate: String,
    probability: Double
  )

  /// POM 語境記憶所能給予的最大加分（log10 機率域，與詞庫分數同尺度）。
  ///
  /// 注入 Homa 的語境元圖機率＝「同讀音、同資料值的詞庫單元圖分數」＋ `kPOMContextBonusMax × w`，
  /// 其中 `w ∈ [0, 1]` 為記憶強度（POM 權重相對於 `LXPerceptor.kWeightMultiplier` 的比值，
  /// 已含次數與新舊兩個因子）。
  ///
  /// 校準依據（原廠詞庫：每個讀音的首選單字都落在 −5.0 至 −5.3 之間、雙音節詞介於 −3 至 −9.32）。
  /// 原則：使用者剛在**同一語境**下做過的糾正，對一般「整詞 vs. 逐字」的分數差距須於第一次選字即生效。
  /// - 錨定案例（IH708／IH709）：「這個檔案是怎樣出現的」，詞庫長詞「檔案室」(−5.856) 勝過
  ///   「檔案」＋「是」(−4.234＋−5.004＝−9.238)，差距 3.38。使用者選一次「是」之後，重打即須得到
  ///   「檔案是」。
  /// - 選過一次的新鮮記憶 `w ≈ 0.65` ⇒ 加分約 +3.9：可翻轉 ~3.9 以內的差距——涵蓋上述 3.38，
  ///   以及所有近乎同分的單字（如「在」−5.009 與「再」−5.012）與零頻競爭詞（「你在」−9.32）。
  /// - 重複選擇時 `w` 逐步升高，加分最多到 +6.0；差距超過 6 的詞庫證據不會僅憑語境記憶翻轉。
  /// - 新舊衰減照舊適用：`w` 含年齡因子，記憶越舊加分越少，屆滿有效期（預設 8 天）即不再注入。
  /// - 尾字退避元圖（B3）較弱：加分再乘 `kPOMCharLevelBackoffFactor`（新鮮約 +3.1、上限 +4.8）。
  /// - 記憶時戳不早於查詢時戳時（亦即剛選完字、同一時刻即查詢），`LXPerceptor.calculateWeight`
  ///   回傳 −1.0，換算後 `w` 截頂為 1、給予全額加分。此為刻意行為：剛做的糾正應立即完整生效。
  ///
  /// 過去的作法是直接以 POM 權重（約落在 (−0.1145, 0]）當作語境元圖機率，而 Homa 一旦匹配到
  /// 語境元圖便以其機率「取代」單元圖分數，於是任何仍在有效期內的記憶都會無條件壓倒詞庫
  /// （−3 至 −9），形同全有全無的開關。
  static let kPOMContextBonusMax: Double = 6.0

  /// 字級退避元圖（B3）的加分折減係數。
  ///
  /// 整詞前文（例如「分不清」）的記憶另會派生一筆只以前文尾字（「清」）為條件的元圖，
  /// 供前一個詞換了分法時仍能命中（Homa 對單字前文採尾字比對，見
  /// `Homa.Node.getScore(previous:anterior:rareFloor:)`）。尾字語境比整詞語境更寬鬆、
  /// 誤命中的機會較高，故其加分打八折；同時這也保證兩者同時命中時整詞元圖勝出。
  static let kPOMCharLevelBackoffFactor: Double = 0.8

  /// 將 POM 記憶的權重換算為 `[0, 1]` 之間的記憶強度。
  static func pomMemoryStrength(of pomProbability: Double) -> Double {
    let multiplier = LXAssembly.LXPerceptor.kWeightMultiplier
    guard multiplier > 0 else { return 0 }
    return Swift.min(1, Swift.max(0, -pomProbability / multiplier))
  }

  /// 把帶語境的 POM 記憶塑形為要注入 Homa 的語境元圖（雙元圖／三元圖）。
  ///
  /// 逐字路徑與聲調桶路徑共用此函式，以確保兩者的計分規則一致。
  /// - Parameters:
  ///   - perceptions: 已通過呼叫端把關（帶語境、資料值確實屬於本讀音）的記憶。
  ///   - lexiconUnigrams: 本讀音的詞庫單元圖（已排序、尚未附加任何 POM 元圖），
  ///     用以查詢每筆記憶之資料值的基準分數。
  /// - Returns: 塑形後的語境元圖；同一 (keyArray, value, previous, anterior) 只保留機率最高者。
  static func shapePOMContextualGrams(
    _ perceptions: [POMPerceptionEntry],
    lexiconUnigrams: [Homa.Gram]
  )
    -> [Homa.Gram] {
    guard !perceptions.isEmpty else { return [] }
    // 基準分數：優先比對「讀音＋資料值」，查無時（例如聲調桶路徑的跨調記憶）再退回只比對資料值。
    // 單元圖陣列已依分數遞減排序，故每個鍵首次出現者即為最高分。
    var baseByReadingAndValue: [String: Double] = [:]
    var baseByValue: [String: Double] = [:]
    for unigram in lexiconUnigrams where unigram.isUnigram {
      let readingKey = "\(unigram.keyArray.joined(separator: "-"))\t\(unigram.current)"
      if baseByReadingAndValue[readingKey] == nil { baseByReadingAndValue[readingKey] = unigram.probability }
      if baseByValue[unigram.current] == nil { baseByValue[unigram.current] = unigram.probability }
    }

    var results: [Homa.Gram] = []
    var indexByIdentity: [String: Int] = [:]
    func insertKeepingHigher(_ gram: Homa.Gram) {
      let identity = [
        gram.keyArray.joined(separator: "-"), gram.current, gram.previous ?? "", gram.anterior ?? "",
      ].joined(separator: "\t")
      if let existingIndex = indexByIdentity[identity] {
        if gram.probability > results[existingIndex].probability { results[existingIndex] = gram }
        return
      }
      indexByIdentity[identity] = results.count
      results.append(gram)
    }

    for pom in perceptions {
      guard pom.previous != nil || pom.anterior != nil else { continue }
      let readingKey = "\(pom.headReading)\t\(pom.candidate)"
      guard let base = baseByReadingAndValue[readingKey] ?? baseByValue[pom.candidate] else { continue }
      let keyArray = pom.headReading.split(separator: "-").map(String.init)
      let bonus = kPOMContextBonusMax * pomMemoryStrength(of: pom.probability)
      insertKeepingHigher(
        Homa.Gram(
          keyArray: keyArray,
          current: pom.candidate,
          previous: pom.previous,
          anterior: pom.anterior,
          probability: base + bonus
        )
      )
      // 字級退避：多字前文另派生一筆「前文尾字」版本。
      guard let previous = pom.previous, previous.count >= 2, let lastChar = previous.last else { continue }
      insertKeepingHigher(
        Homa.Gram(
          keyArray: keyArray,
          current: pom.candidate,
          previous: String(lastChar),
          anterior: pom.anterior,
          probability: base + bonus * kPOMCharLevelBackoffFactor
        )
      )
    }
    return results
  }
}
