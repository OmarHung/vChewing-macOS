// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa

// MARK: - 句末語氣詞與標點的接續元圖

extension LXAssembly.LXFacade {
  /// 「語氣詞後接標點」語境元圖的加分（log10 機率域，與詞庫分數同尺度）。
  ///
  /// 注入 Homa 的語境元圖機率＝「該標點的單元圖分數」＋ `kParticlePunctuationBonus`；
  /// 當組句路徑上標點的前一個詞值是表內語氣詞、或以表內語氣詞結尾（Homa 對單字前文採尾字比對，
  /// 見 `Homa.Node.getScore(previous:anterior:rareFloor:)`）時，標點節點即取得此加分，
  /// 進而讓「以語氣詞收尾」的前驅勝出。
  ///
  /// 校準原則：
  /// - 必須足以翻轉近乎同分的同音字：原廠詞庫中「ㄇㄚ」的「嗎」(−5.118) 與「媽」(−5.175)
  ///   僅差 0.057，「吧」與「把」等亦屬此類。
  /// - 但不得推翻確實強過 1 個對數單位以上的詞庫證據：例如一個整詞比「單字＋語氣詞」高出
  ///   1 以上時，該整詞仍須勝出。
  ///
  /// - Remark: 此加分只能透過 K-best 組句（`Homa.Assembler.beamWidth` ≥ 2）影響前方的取捨；
  ///   傳統 1-best DP 在為標點節點計分時，前驅早已定案。
  static let kParticlePunctuationBonus: Double = 1.0

  /// 各全形標點（以單元圖的**資料值**比對）可接續的句末語氣詞。
  ///
  /// 原廠詞庫中 `_punctuation_?` → 「？」、`_punctuation_!` → 「！」、`_punctuation_;` → 「；」、
  /// `_punctuation_:` → 「：」；逗號與句號則依鍵盤排列落在 `_punctuation_<`、`_punctuation_>`、
  /// `_punctuation_Standard_<`、`_punctuation_ETen26_,` 等鍵名之下，資料值為「，」與「。」。
  /// 故此處以資料值為準、不以鍵名為準。
  static let kParticlesBeforePunctuation: [String: [String]] = [
    // 問句：疑問語氣詞。
    "？": kParticlesBeforeQuestionMark,
    // 感嘆句：感嘆與催促語氣詞。
    "！": kParticlesBeforeExclamationMark,
    // 陳述句、停頓：陳述與緩和語氣詞。
    "。": kParticlesBeforeStatementPunctuation,
    "，": kParticlesBeforeStatementPunctuation,
    "；": kParticlesBeforeStatementPunctuation,
    "：": kParticlesBeforeStatementPunctuation,
  ]

  /// 問號之前常見的疑問語氣詞。
  static let kParticlesBeforeQuestionMark: [String] = [
    "嗎", "呢", "吧", "嘛", "啊", "呀", "哦", "喔", "麼",
  ]

  /// 驚嘆號之前常見的感嘆、催促語氣詞。
  static let kParticlesBeforeExclamationMark: [String] = [
    "啊", "呀", "吧", "啦", "耶", "喔", "哦", "囉", "哇", "呢",
  ]

  /// 句號、逗號、分號、冒號之前常見的陳述、緩和語氣詞。
  static let kParticlesBeforeStatementPunctuation: [String] = [
    "吧", "呢", "啦", "嘛", "啊", "呀", "喔", "哦", "囉",
  ]

  /// 讀音鍵是否為「不帶修飾鍵的全形標點」：恰為單一索引鍵、以 `_punctuation_` 起首，
  /// 且不是符號選單 `_punctuation_list`。
  ///
  /// 半形（`_half_punctuation_`）與帶修飾鍵者（`_ctrl_`、`_alt_`、`_shift_alt_`、`_alt_ctrl_`）
  /// 的鍵名並不以 `_punctuation_` 起首，故自然排除在外。
  static func isPlainPunctuationKey(_ keyArray: [String]) -> Bool {
    guard keyArray.count == 1, let key = keyArray.first else { return false }
    return key.hasPrefix("_punctuation_") && key != "_punctuation_list"
  }

  /// 為全形標點的讀音鍵生成「語氣詞後接標點」的語境元圖（雙元圖）。
  ///
  /// 逐字路徑與聲調桶路徑共用此函式。對每個在表內的標點資料值、每個對應的語氣詞 `p`，
  /// 生成 `Homa.Gram(keyArray:, current: 標點, previous: p, probability: 標點單元圖分數 + 加分)`。
  /// 這些元圖帶有前文條件，故不會出現在選字窗（`fetchCandidates` 只收單元圖）。
  /// - Parameters:
  ///   - keyArray: 讀音索引鍵陣列（非全形標點鍵者一律回傳空陣列）。
  ///   - lexiconUnigrams: 本讀音的單元圖（已依分數遞減排序、尚未附加任何語境元圖）。
  /// - Returns: 要附加於單元圖之後的語境元圖。
  static func punctuationContextGrams(
    keyArray: [String],
    lexiconUnigrams: [Homa.Gram]
  )
    -> [Homa.Gram] {
    guard isPlainPunctuationKey(keyArray) else { return [] }
    var results: [Homa.Gram] = []
    var handledValues: Set<String> = []
    // 單元圖已依分數遞減排序：同一資料值首次出現者即為最高分，以之為基準。
    for unigram in lexiconUnigrams where unigram.isUnigram {
      // 聲調桶路徑可能混有其他讀音鍵的單元圖：只處理本身亦屬全形標點鍵者，並沿用其讀音鍵。
      guard isPlainPunctuationKey(unigram.keyArray) else { continue }
      guard !handledValues.contains(unigram.current) else { continue }
      guard let particles = kParticlesBeforePunctuation[unigram.current] else { continue }
      handledValues.insert(unigram.current)
      let probability = unigram.probability + kParticlePunctuationBonus
      for particle in particles {
        results.append(
          Homa.Gram(
            keyArray: unigram.keyArray,
            current: unigram.current,
            previous: particle,
            probability: probability
          )
        )
      }
    }
    return results
  }
}
