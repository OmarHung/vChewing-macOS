// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.Node.OverrideType

extension Homa.Node {
  /// 對節點執行的三種不同覆寫操作模式。
  /// - withTopGramScore: 專用於雙元圖的自動選取功能，但效力低於 withSpecified 模式。
  /// 該覆寫行為無法防止其它節點被組句函式所支配。這種情況下就需要用到 overridingScore。
  /// - withSpecified: 強制覆寫節點權重為 overridingScore，
  /// 確保組句函式優先選擇該節點且不受其他節點影響。
  /// 但是這個選項也可以允許搭配過低的 overridingScore 來起到 demote 的效果。
  public enum OverrideType: Int, Codable {
    case withTopGramScore = 1
    case withSpecified = 2
  }
}

// MARK: - Homa.Node

extension Homa {
  public struct Node: Codable {
    // MARK: Lifecycle

    /// 生成一個字詞節點。
    ///
    /// 一個節點由這些內容組成：幅節長度、索引鍵、以及一組元圖。幅節長度就是指這個
    /// 節點在組字器內橫跨了多少個字長。組字器負責構築自身的節點。對於由多個漢字組成
    /// 的詞，組字器會將多個讀音索引鍵合併為一個讀音索引鍵、據此向語言模組請求對應的
    /// 元圖結果陣列。舉例說，如果一個詞有兩個漢字組成的話，那麼讀音也是有兩個、其
    /// 索引鍵也是由兩個讀音組成的，那麼這個節點的幅節長度就是 2。
    ///
    /// - Remark: 除非有必要，否則請盡量不要在 Assembler 外部直接與 Node 互動。
    /// GramInPath 是您理想的可互動物件。
    /// - Parameters:
    ///   - keyArray: 給定索引鍵陣列，不得為空。
    ///   - segLength: 給定幅節長度，一般情況下與給定索引鍵陣列內的索引鍵數量一致。
    ///   - grams: 給定元圖陣列，不得為空。
    internal init(keyArray: [String] = [], grams: [Homa.Gram] = []) {
      self.id = FIUUID()
      self.keyArray4Query = keyArray
      self.grams = grams
      self.allActualKeyArraysCached = Set(grams.map(\.keyArray))
      self.currentOverrideType = nil
    }

    /// 以指定字詞節點生成拷貝（識別碼全新）。
    internal init(node: Self) {
      self.id = FIUUID()
      self.overridingScore = node.overridingScore
      self.keyArray4Query = node.keyArray4Query
      self.allActualKeyArraysCached = node.allActualKeyArraysCached
      self.grams = node.grams
      self.currentOverrideType = node.currentOverrideType
      self.isExplicitlyOverridden = node.isExplicitlyOverridden
      self.currentGramIndex = node.currentGramIndex
    }

    // MARK: Public

    /// 節點的唯一識別符。
    public let id: FIUUID

    /// 一個用以覆寫權重的數值。該數值之高足以改變組句函式對該節點的讀取結果。這裡用
    /// 「0」可能看似足夠了，但仍會使得該節點的覆寫狀態有被組句函式忽視的可能。比方說
    /// 要針對索引鍵「a b c」複寫的資料值為「A B C」，使用大寫資料值來覆寫節點。這時，
    /// 如果這個獨立的 c 有一個可以拮抗權重的詞「bc」的話，可能就會導致組句函式的算法
    /// 找出「A->bc」的組句途徑（尤其是當 A 和 B 使用「0」作為複寫數值的情況下）。這樣
    /// 一來，「A-B」就不一定始終會是組句函式的青睞結果了。所以，這裡一定要用大於 0 的
    /// 數（比如野獸常數），以讓「c」更容易單獨被選中。
    public internal(set) var overridingScore: Double = 114_514

    /// 事先假設的索引鍵陣列，可能不完全。
    public private(set) var keyArray4Query: [String]
    /// 所有真實索引鍵陣列的快取。
    public private(set) var allActualKeyArraysCached: Set<[String]>
    /// 該節點目前的覆寫狀態種類。
    public private(set) var currentOverrideType: OverrideType?
    /// 是否為使用者明確覆寫（explicit override）、而非出於自動機制進行的複寫。
    public private(set) var isExplicitlyOverridden: Bool = false

    /// 節點覆寫狀態。
    public var overrideStatus: Homa.NodeOverrideStatus {
      get {
        .init(
          overridingScore: overridingScore,
          currentOverrideType: currentOverrideType,
          isExplicitlyOverridden: isExplicitlyOverridden,
          currentUnigramIndex: currentGramIndex
        )
      }
      set {
        overridingScore = newValue.overridingScore
        isExplicitlyOverridden = newValue.isExplicitlyOverridden
        // 防範 GramIndex 溢出，如果溢出則重設覆寫狀態
        if newValue.currentUnigramIndex >= 0, newValue.currentUnigramIndex < grams.count {
          currentOverrideType = newValue.currentOverrideType
          currentGramIndex = newValue.currentUnigramIndex
        } else {
          reset()
        }
      }
    }

    /// 當前候選字詞的真實完整索引鍵陣列。
    public var keyArray: [String] { currentGram?.keyArray ?? keyArray4Query }

    /// 元圖陣列。
    public private(set) var grams: [Homa.Gram] {
      didSet {
        allActualKeyArraysCached = Set(grams.map(\.keyArray))
      }
    }

    /// 當前該節點所指向的（元圖陣列內的）元圖索引位置。
    public private(set) var currentGramIndex: Int = 0 {
      didSet { currentGramIndex = max(min(grams.count - 1, currentGramIndex), 0) }
    }
  }
}

// MARK: - Homa.Node + Hashable

extension Homa.Node: Hashable {
  /// 預設雜湊函式。
  /// - Parameter hasher: 目前物件的雜湊碼。
  public func hash(into hasher: inout Hasher) {
    // 與 `==` 的「內容等值、排除 ID」語義保持一致：ID 僅作為節點的身分標記
    // （新建節點 / copy 生成全新 ID、值拷貝共享 ID），不參與等值與雜湊，
    // 以免違反 Hashable 契約（相等物件必須具有相同雜湊值）。
    hasher.combine(overridingScore)
    hasher.combine(keyArray4Query)
    hasher.combine(grams)
    hasher.combine(currentOverrideType)
    hasher.combine(isExplicitlyOverridden)
    hasher.combine(currentGramIndex)
    hasher.combine(allActualKeyArraysCached)
  }
}

// MARK: - Homa.Node + Equatable

extension Homa.Node: Equatable {
  public static func == (lhs: Homa.Node, rhs: Homa.Node) -> Bool {
    // 基於功能內容的等價性比較，排除 ID 字段
    lhs.overridingScore == rhs.overridingScore &&
      lhs.keyArray4Query == rhs.keyArray4Query &&
      lhs.grams == rhs.grams &&
      lhs.currentOverrideType == rhs.currentOverrideType &&
      lhs.currentGramIndex == rhs.currentGramIndex &&
      lhs.isExplicitlyOverridden == rhs.isExplicitlyOverridden &&
      lhs.allActualKeyArraysCached == rhs.allActualKeyArraysCached
  }
}

extension Homa.Node {
  /// 幅節長度。
  public var segLength: Int { keyArray.count }

  /// 該節點當前狀態所展示的鍵值配對。
  public var currentPair: Homa.CandidatePair? {
    guard let currentGram else { return nil }
    return .init(keyArray: currentGram.keyArray, value: currentGram.current)
  }

  /// 生成自身的拷貝（識別碼全新）。
  public var copy: Homa.Node { .init(node: self) }

  /// 檢查當前節點是否「讀音字長與候選字字長不一致」。
  public var isReadingMismatched: Bool {
    guard let value else { return false }
    return keyArray.count != value.count
  }

  /// 該節點是否處於被覆寫的狀態。
  public var isOverridden: Bool { currentOverrideType != nil }

  /// 給出該節點內部元圖陣列內目前被索引位置所指向的元圖。
  public var currentGram: Homa.Gram? {
    grams.isEmpty ? nil : grams[currentGramIndex]
  }

  /// 給出該節點內部元圖陣列內目前被索引位置所指向的元圖的資料值。
  public var value: String? { currentGram?.current }

  /// 給出目前的最高權重單元圖當中的權重值。該結果可能會受節點覆寫狀態所影響。
  /// - Parameter rareFloor: 零頻兜底詞的長度縮放規則（可選），僅作用於單元圖分數。
  private func unigramScore(rareFloor: Homa.RarePhraseFloor?) -> Double {
    guard !grams.isEmpty else { return 0 }
    // 單次線性掃描、只取陣列順序上的第一個單元圖機率，不建立任何一次性 filter 陣列。
    var firstUnigramProbability: Double?
    for gram in grams {
      guard (gram.previous ?? "").isEmpty, (gram.anterior ?? "").isEmpty else { continue }
      firstUnigramProbability = gram.probability
      break
    }
    guard let firstUnigramProbability else { return 0 }
    switch currentOverrideType {
    case .withSpecified: return overridingScore
    case .withTopGramScore: return rareFloor.applied(to: firstUnigramProbability)
    default:
      // 無覆寫狀態時以當前選取之元圖計分；惟當前選取若為**帶語境之元圖**（雙元圖／三元圖），
      // 則語境無從確認（本路徑正是「無前述內容」之情形）⇒ 退回單元圖基線，避免該語境分數
      // 在無語境處生效。該狀態僅可能出自 `getScore(previous:anterior:)` 之自動語境選取
      // （見 `adoptGramForContext(keyArray:value:previous:anterior:)`）。
      if let currentGram, (currentGram.previous ?? "").isEmpty, (currentGram.anterior ?? "").isEmpty {
        return rareFloor.applied(to: currentGram.probability)
      }
      return rareFloor.applied(to: firstUnigramProbability)
    }
  }

  /// 給出目前的最高權元圖當中的權重值（包括雙元圖與三元圖）。該結果可能會受節點覆寫狀態所影響。
  /// - Remark: 這個函式會根據比對到的前述節點內容，來查詢可能的雙元／三元圖資料。
  /// 一旦有比對到相符的雙元／三元圖資料，就會比較其權重與當前節點的權重，並選擇
  /// 權重較高的那個、然後**據此視情況自動修改這個節點的覆寫狀態種類**。
  ///
  /// 前文比對規則（`previous`）：
  /// - 整詞比對：元圖的 `previous` 與前述節點的整個詞值逐字相等。
  /// - 尾字比對：元圖的 `previous` 恰為**單一字元**時，只要前述節點的詞值以該字元**結尾**
  ///   亦算命中（字元以 Swift `Character` 比對，不會切斷組合字元或異體字選擇器）。
  ///   用意是讓前一個詞換了分法（「分不清」vs「不」、「檔案」vs「案」）時語境記憶仍能生效；
  ///   POM 注入端會為多字前文的記憶另派生一筆加分打折的尾字版本，故兩者同時命中時，
  ///   機率較高的整詞元圖勝出。
  /// - `anterior`（三元圖的前驅之二）一律維持整詞比對、不做尾字放寬。
  ///
  /// 採用命中的語境元圖時，以**該元圖自身的** `previous`／`anterior` 定位
  /// （見 `adoptGramForContext(keyArray:value:previous:anterior:)`），故尾字比對同樣能正確選中。
  /// - Parameters:
  ///   - previous: 前述節點內容，用以查詢可能的雙元圖資料。
  ///   - anterior: 前述節點再往前一格的內容，用以查詢可能的三元圖資料（可選）。
  ///   - rareFloor: 零頻兜底詞的長度縮放規則（可選）。僅作用於**單元圖**分數（含與語境
  ///     元圖比較時所用的單元圖基線）；語境元圖（雙元圖／三元圖，例如 POM 記憶注入者）
  ///     與 `.withSpecified` 覆寫分數一律原樣回傳。詳見 `Homa.RarePhraseFloor`。
  /// - Returns: 權重。
  internal mutating func getScore(
    previous: String?,
    anterior: String? = nil,
    rareFloor: Homa.RarePhraseFloor? = nil
  )
    -> Double {
    guard !grams.isEmpty else { return 0 }
    guard let previous, !previous.isEmpty else { return unigramScore(rareFloor: rareFloor) }

    // 單次線性掃描元圖陣列：同步捕捉「陣列順序上的首個單元圖機率」、「前述內容相符的
    // 最高權重雙元圖」與「前驅二位相符的最高權重三元圖」。匹配不與 currentGram 綁定
    // （currentGram 可能因先前未匹配語境而指向 unigram）。
    var firstUnigramProbability: Double?
    var firstUnigramIndex: Int?
    var bestBigram: Homa.Gram?
    var bestTrigram: Homa.Gram?
    for (index, gram) in grams.enumerated() {
      if (gram.previous ?? "").isEmpty, (gram.anterior ?? "").isEmpty, firstUnigramProbability == nil {
        firstUnigramProbability = gram.probability
        firstUnigramIndex = index
      }
      guard Self.contextPreviousMatches(gram.previous, actualPrevious: previous) else { continue }
      // 三元圖：需 exact 匹配前驅二位（anterior 語境存在時才可比對）。
      if let anterior, !anterior.isEmpty, gram.anterior == anterior {
        guard let currentBest = bestTrigram else {
          bestTrigram = gram
          continue
        }
        if gram.probability > currentBest.probability { bestTrigram = gram }
        continue
      }
      // 雙元圖：僅要求 previous 匹配（anterior 非空的三元圖在此語境下不可用）。
      guard (gram.anterior ?? "").isEmpty else { continue }
      guard let currentBest = bestBigram else {
        bestBigram = gram
        continue
      }
      if gram.probability > currentBest.probability { bestBigram = gram }
    }
    // 依序取「三元圖 → 雙元圖」中權重最高者作為加分項。
    var bestBonus: Homa.Gram?
    if let bestTrigram { bestBonus = bestTrigram }
    if let bestBigram, bestBonus == nil || bestBigram.probability > (bestBonus?.probability ?? 0) {
      bestBonus = bestBigram
    }
    // 單元圖基線先經零頻兜底詞的長度縮放（若有）：語境加分是否勝出，應以該節點在 DP 中
    // 實際會拿到的單元圖分數為比較基準。語境元圖本身的機率則不受縮放。
    let unigramBaseline = firstUnigramProbability.map { rareFloor.applied(to: $0) } ?? 0
    switch currentOverrideType {
    case .withSpecified:
      return overridingScore
    case .withTopGramScore:
      // 弱釘選語義（與既有行為一致）：維持既有選取（currentGramIndex 不動）、
      // 以 unigram 基線計分——`withTopGramScore` 只釘「選取了哪個 gram」、不釘分數。
      return unigramBaseline
    default:
      // 有匹配加分且高於 unigram 基線 → 選中 bonus gram；否則將選取指向最佳單元圖
      // （未匹配語境的 top bigram／trigram 不應留駐輸出）。
      if let bestBonus, bestBonus.probability > unigramBaseline {
        do {
          // 語境加分是**當次推導**之結果，不得記成覆寫狀態：`withTopGramScore` 之計分臂
          // 逕以 unigram 基線計分，一旦記上，下一次組句就不會重算加分、該節點隨即退回
          // 無語境之選取（症狀：記憶詞只出現一拍、下一個按鍵即被詞庫長詞取代）。
          try adoptGramForContext(
            keyArray: bestBonus.keyArray,
            value: bestBonus.current,
            previous: bestBonus.previous,
            anterior: bestBonus.anterior
          )
          return bestBonus.probability
        } catch {
          // 覆寫失敗：退回 unigram 基線。
        }
      }
      if let firstUnigramIndex {
        currentGramIndex = firstUnigramIndex
      }
      return unigramBaseline
    }
  }

  /// 判斷語境元圖的前文條件是否與前述節點相符。
  ///
  /// 整詞相等即命中；元圖前文恰為單一字元時，前述節點詞值以該字元結尾亦算命中（尾字比對）。
  /// 詳見 `getScore(previous:anterior:rareFloor:)` 的說明。
  /// - Parameters:
  ///   - gramPrevious: 元圖所記載的前文條件。
  ///   - actualPrevious: DP 最佳路徑上前述節點的詞值。
  @inline(__always)
  internal static func contextPreviousMatches(_ gramPrevious: String?, actualPrevious: String) -> Bool {
    guard let gramPrevious, !gramPrevious.isEmpty else { return false }
    if gramPrevious == actualPrevious { return true }
    // 先以首字元粗篩（成本低），再確認元圖前文確實只有一個字元。
    guard let lastActual = actualPrevious.last, gramPrevious.first == lastActual else { return false }
    return gramPrevious.count == 1
  }

  // MARK: K-best 組句（beam search）專用

  /// 依單元圖機率遞減，給出至多 `limit` 個「詞值互異」的單元圖索引（同分時依陣列順序）。
  ///
  /// 供 `Homa.PathFinder` 把同一節點內的其他高分詞值派生為獨立的組句狀態，
  /// 讓近乎同分的同音字（如「嗎」與「媽」）得以並存、交由後方節點的語境決定取捨。
  /// 只掃描一次元圖陣列並維護一個長度至多為 `limit` 的有序小陣列，不建立排序後的拷貝。
  internal func beamAlternativeUnigramIndices(limit: Int) -> [Int] {
    guard limit > 0, !grams.isEmpty else { return [] }
    var picked: [Int] = []
    picked.reserveCapacity(limit + 1)
    for (index, gram) in grams.enumerated() {
      guard Self.isContextFree(gram) else { continue }
      let probability = gram.probability
      // 已有同值者：機率較高（或同分而較早出現）者已在名單內，略過。
      if picked.contains(where: { grams[$0].current == gram.current }) { continue }
      var insertAt = picked.count
      while insertAt > 0, probability > grams[picked[insertAt - 1]].probability {
        insertAt -= 1
      }
      guard insertAt < limit else { continue }
      picked.insert(index, at: insertAt)
      if picked.count > limit { picked.removeLast() }
    }
    return picked
  }

  /// 是否含有任何帶語境之元圖（雙元圖／三元圖）。
  internal var hasContextualGrams: Bool {
    grams.contains { !Self.isContextFree($0) }
  }

  /// 所有帶語境之元圖（雙元圖／三元圖）的索引。
  internal var contextualGramIndices: [Int] {
    grams.indices.filter { !Self.isContextFree(grams[$0]) }
  }

  /// 為同節點的替代詞值計分：取「該單元圖分數（套用零頻縮放）」與「同值且語境相符之元圖
  /// 機率」兩者中的較高者。語境比對規則與 `getScore(previous:anterior:rareFloor:)` 一致。
  /// 本函式不改動節點狀態（替代詞值只存在於組句狀態中，回溯後才寫回）。
  /// - Parameters:
  ///   - unigramIndex: 替代詞值所在的單元圖索引。
  ///   - contextualGramIndices: 預先算好的 `contextualGramIndices`（避免逐路徑重算）。
  ///   - previous: 這條路徑上前述節點的詞值。
  ///   - anterior: 這條路徑上前述節點再往前一格的詞值。
  ///   - rareFloor: 零頻兜底詞的長度縮放規則（僅作用於單元圖分數）。
  /// - Returns: 勝出之元圖的索引及其分數。
  internal func beamAlternativeScore(
    unigramIndex: Int,
    contextualGramIndices: [Int],
    previous: String,
    anterior: String,
    rareFloor: Homa.RarePhraseFloor?
  )
    -> (gramIndex: Int, score: Double) {
    let unigram = grams[unigramIndex]
    var best = (gramIndex: unigramIndex, score: rareFloor.applied(to: unigram.probability))
    guard !previous.isEmpty else { return best }
    for index in contextualGramIndices {
      let gram = grams[index]
      guard gram.current == unigram.current, gram.probability > best.score else { continue }
      guard Self.contextPreviousMatches(gram.previous, actualPrevious: previous) else { continue }
      let gramAnterior = gram.anterior ?? ""
      // 三元圖須前驅二位相符；雙元圖則不得帶前驅二位條件。
      guard gramAnterior.isEmpty || (!anterior.isEmpty && gramAnterior == anterior) else { continue }
      best = (index, gram.probability)
    }
    return best
  }

  /// 元圖是否不帶語境條件（`previous` 與 `anterior` 皆為 nil 或空字串；與 `getScore` 的判準一致）。
  @inline(__always)
  internal static func isContextFree(_ gram: Homa.Gram) -> Bool {
    (gram.previous ?? "").isEmpty && (gram.anterior ?? "").isEmpty
  }

  /// 讓節點改指組句回溯所得的元圖（僅移動 `currentGramIndex`，不改動覆寫狀態）。
  internal mutating func selectGramForPath(at index: Int) {
    guard grams.indices.contains(index) else { return }
    currentGramIndex = index
  }

  /// 未被覆寫的節點退回首個單元圖。
  ///
  /// 用於組句結束後、不在最佳路徑上的節點：它們最後一次計分時所採用的語境元圖（或同節點
  /// 替代詞值）未必屬於最終路徑，故退回無語境之選取——與 `getScore` 在語境不符時的行為一致。
  internal mutating func resetContextualSelectionUnlessOverridden() {
    guard currentOverrideType == nil else { return }
    guard let firstUnigramIndex = grams.firstIndex(where: Self.isContextFree) else { return }
    currentGramIndex = firstUnigramIndex
  }

  /// 重設該節點的覆寫狀態、及其內部的元圖索引位置指向。
  internal mutating func reset() {
    currentGramIndex = 0
    currentOverrideType = nil
    isExplicitlyOverridden = false
  }

  /// 置換掉該節點內的元圖陣列資料。
  /// 如果此時影響到了 currentUnigramIndex 所指的內容的話，則將其重設為 0。
  /// - Parameter source: 新的元圖陣列資料，必須不能為空（否則必定崩潰）。
  internal mutating func syncingGrams(from source: [Homa.Gram]) {
    let oldCurrentValue = grams[currentGramIndex].current
    grams = source
    // 保險，請按需啟用。
    // if unigrams.isEmpty { unigrams.append(.init(value: key, score: -114.514)) }
    currentGramIndex = max(min(grams.count - 1, currentGramIndex), 0)
    let newCurrentValue = grams[currentGramIndex].current
    if oldCurrentValue != newCurrentValue { reset() }
  }

  /// 指定要覆寫的元圖資料值、以及覆寫行為種類。
  /// - Parameters:
  ///   - keyArray: 給定索引鍵陣列。
  ///   - value: 給定的元圖資料值。
  ///   - previous: 前述資料。
  ///   - anterior: 前述資料再往前一格（三元圖用，可選）。
  ///   - type: 覆寫行為種類。
  /// - Returns: 複寫成功的 Gram。
  @discardableResult
  internal mutating func selectOverrideGram(
    keyArray: [String]?,
    value: String,
    previous: String? = nil,
    anterior: String? = nil,
    type: Homa.Node.OverrideType
  ) throws
    -> Homa.Gram {
    for (i, gram) in grams.enumerated() {
      if let keyArray, keyArray != gram.keyArray { continue }
      if value != gram.current { continue }
      if let previous, !previous.isEmpty, previous != gram.previous { continue }
      if let anterior, !anterior.isEmpty, anterior != gram.anterior { continue }
      currentGramIndex = i
      currentOverrideType = type
      if overridingScore < 114_514 {
        overridingScore = 114_514
      }
      return gram
    }
    throw Homa.Exception.nothingOverriddenAtNode
  }

  /// 依語境選定該節點要展示的元圖（僅移動 `currentGramIndex`），**不改動覆寫狀態**。
  ///
  /// 供組句函式於「語境加分（bigram／trigram）命中」時使用。語境加分是**當次推導**之結果，
  /// 必須於每次組句時重新推導；記成 `.withTopGramScore` 覆寫狀態的話，下一次組句即改走該臂
  /// 之「以 unigram 基線計分」語義、加分不再重算，該節點遂退回無語境之選取。
  /// - Parameters:
  ///   - keyArray: 給定索引鍵陣列。
  ///   - value: 給定的元圖資料值。
  ///   - previous: 前述資料。
  ///   - anterior: 前述資料再往前一格（三元圖用，可選）。
  /// - Returns: 選定成功的 Gram。
  @discardableResult
  internal mutating func adoptGramForContext(
    keyArray: [String]?,
    value: String,
    previous: String? = nil,
    anterior: String? = nil
  ) throws
    -> Homa.Gram {
    for (i, gram) in grams.enumerated() {
      if let keyArray, keyArray != gram.keyArray { continue }
      if value != gram.current { continue }
      if let previous, !previous.isEmpty, previous != gram.previous { continue }
      if let anterior, !anterior.isEmpty, anterior != gram.anterior { continue }
      currentGramIndex = i
      return gram
    }
    throw Homa.Exception.nothingOverriddenAtNode
  }
}

// MARK: - Homa.RarePhraseFloor

extension Homa {
  /// 零頻兜底詞在組句評分時的長度縮放規則。
  ///
  /// 詞庫給零頻詞條的兜底分數是固定值、不隨音節數縮放，於是一個從未出現過的長詞與一個
  /// 從未出現過的短詞領到相同分數。DP 累加對數機率、節點越少總分越高，這類長的零頻詞
  /// 便會系統性地擊敗逐字組合。本規則為其補上長度縮放：要求一個零頻的 n 音節詞至少付出
  /// n 個中等常用字的代價。單音節元圖不受影響。
  ///
  /// - Remark: 僅供節點的**單元圖**計分使用（見 `Homa.Node.getScore(previous:anterior:rareFloor:)`）。
  /// 語境元圖（雙元圖／三元圖）是「該語境下確有用例」的證據，不屬於零頻兜底詞；
  /// 使用者明確覆寫的分數亦不應被改寫。參數意涵詳見 `Homa.Assembler.rarityThreshold`
  /// 與 `Homa.Assembler.rarePhrasePerSyllableFloor`。
  struct RarePhraseFloor {
    /// 判定為零頻兜底詞的分數門檻（分數不高於此值者受縮放約束）。
    let rarityThreshold: Double
    /// 每個音節應付出的代價。
    let perSyllableFloor: Double
    /// 節點在軌格中的幅節長度（音節數）。
    let segLength: Int

    /// 對給定的單元圖分數套用長度縮放。
    func apply(to score: Double) -> Double {
      guard segLength > 1, score <= rarityThreshold else { return score }
      return Swift.min(score, perSyllableFloor * Double(segLength))
    }
  }
}

extension Optional where Wrapped == Homa.RarePhraseFloor {
  /// 規則存在時套用之，否則原樣回傳。
  func applied(to score: Double) -> Double {
    switch self {
    case let .some(rule): return rule.apply(to: score)
    case .none: return score
    }
  }
}

// MARK: - Array Extensions.

extension Array where Element == Homa.Node {
  var asGramChain: [Homa.GramInPath] {
    compactMap { node in
      guard let gram = node.currentGram else { return nil }
      return .init(gram: gram, isExplicit: node.isExplicitlyOverridden)
    }
  }
}

// MARK: - Homa.NodeOverrideStatus

extension Homa {
  /// 節點覆寫狀態結構，用於輕量化狀態鏡照。
  public struct NodeOverrideStatus: Codable, Hashable {
    // MARK: Lifecycle

    /// 建構子。
    /// - Parameters:
    ///   - overridingScore: 覆寫分數。
    ///   - currentOverrideType: 當前覆寫類型。
    ///   - currentUnigramIndex: 當前單元圖索引。
    public init(
      overridingScore: Double = 114_514,
      currentOverrideType: Homa.Node.OverrideType? = nil,
      isExplicitlyOverridden: Bool = false,
      currentUnigramIndex: Int = 0
    ) {
      self.overridingScore = overridingScore
      self.currentOverrideType = currentOverrideType
      self.isExplicitlyOverridden = isExplicitlyOverridden
      self.currentUnigramIndex = currentUnigramIndex
    }

    // MARK: Public

    /// 覆寫分數。
    public var overridingScore: Double
    /// 當前覆寫類型。
    public var currentOverrideType: Homa.Node.OverrideType?
    /// 使用者是否明確覆寫（explicit override）。
    public var isExplicitlyOverridden: Bool
    /// 當前單元圖索引。
    public var currentUnigramIndex: Int
  }
}
