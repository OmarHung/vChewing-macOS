// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension Homa.Assembler {
  /// 組句函式，會以 DAG (Directed Acyclic Graph) 動態規劃演算法更新當前組字器的 assembledSentence。
  ///
  /// 此演算法使用動態規劃在有向無環圖中尋找具有最優評分的路徑，從而確定最合適的詞彙組合。
  /// DAG 演算法相對於 Dijkstra 演算法更簡潔，記憶體使用量更少。
  /// 每個位置保留至多 `beamWidth` 條候選路徑（K-best），詳見 `beamWidth`。
  ///
  /// - Returns: 組句結果（已選字詞陣列）。
  @discardableResult
  public func assemble() -> [Homa.GramInPath] {
    var finalScore = Double(Int32.min)
    let result = Homa.PathFinder.run(
      config: &config,
      beamWidth: beamWidth,
      rarityThreshold: rarityThreshold,
      rarePhrasePerSyllableFloor: rarePhrasePerSyllableFloor,
      finalScore: &finalScore
    )
    mostRecentPathScore = finalScore
    assembledSentence = result
    return assembledSentence
  }
}

// MARK: - Homa.PathFinder

extension Homa {
  enum PathFinder {
    // MARK: Internal

    /// 組句工具，會以 DAG 動態規劃演算法（K-best／beam search）更新當前組字器的 assembledSentence。
    ///
    /// **狀態**：每個位置 `i` 保留至多 `beamWidth` 條「抵達 `i` 的部分路徑」，依分數遞減排列。
    /// 每條路徑記錄：累計分數、末節點所選元圖（以元圖索引表示）、末節點幅節長度、
    /// 回溯指標（前一個位置與其槽位）、末節點詞值、以及前驅節點詞值。
    ///
    /// **轉移**：對位置 `i` 的每條路徑、以及自 `i` 起始的每個節點，以「該路徑末節點詞值」為
    /// `previous`、「該路徑前驅節點詞值」為 `anterior` 為節點計分（與既有 1-best 語義相同，只是
    /// 改為沿**各自的**路徑取值），並把結果放入位置 `i + 幅節長度` 的桶中。
    /// 對未被覆寫的節點，另把該節點其餘的高分單元圖詞值（至多 `beamWidth - 1` 個）視為
    /// 獨立狀態一併放入：同一節點內近乎同分的同音字（如「嗎」與「媽」）因此可以並存，
    /// 讓後方節點的語境元圖（例如「嗎」後接「？」）有機會反過來決定前方的取捨。
    ///
    /// **去重**：同一桶內「末節點詞值」與「前驅節點詞值」皆相同的兩條路徑，對後續計分而言
    /// 完全等價（後續只看得到這兩個值），只保留分數較高者，以免分詞方式不同但結果相同的
    /// 路徑擠掉真正不同的前驅。
    ///
    /// **寫回**：節點為 Struct，計分時的語境選取（`getScore` 的副作用）只發生在拷貝上。
    /// 遍歷結束、回溯出最佳路徑之後，最佳路徑上的節點改指回溯所得的元圖；其餘曾被遍歷的節點
    /// （覆寫者除外）一律退回首個單元圖——它們最後一次計分時所採用的語境未必屬於最終路徑。
    ///
    /// `beamWidth == 1` 時不派生同節點的替代詞值、且同分時保留先到者，結果與傳統 1-best DP 逐位元一致。
    /// - Parameters:
    ///   - config: 組字器組態（inout，以便在遍歷結束後就地寫回節點的元圖選取狀態）。
    ///   - beamWidth: 每個位置保留的候選路徑數上限（小於 1 者視為 1），詳見 `Homa.Assembler.beamWidth`。
    ///   - rarityThreshold: 零頻兜底詞的分數門檻，詳見 `Homa.Assembler.rarityThreshold`。
    ///   - rarePhrasePerSyllableFloor: 零頻兜底詞每音節的代價（`nil` 表示停用），詳見
    ///     `Homa.Assembler.rarePhrasePerSyllableFloor`。
    ///   - finalScore: 寫出本次 DP 的整句最佳路徑總分（不可達時為 `Double(Int32.min)`）。
    /// - Returns: 組句結果（已選字詞陣列）。
    @discardableResult
    static func run(
      config: inout Homa.Config,
      beamWidth: Int,
      rarityThreshold: Double = -.infinity,
      rarePhrasePerSyllableFloor: Double? = nil,
      finalScore: inout Double
    )
      -> [Homa.GramInPath] {
      guard !config.segments.isEmpty else {
        finalScore = Double(Int32.min)
        return []
      }

      let keyCount = config.keys.count
      let width = Swift.max(1, beamWidth)
      // 同節點替代詞值的派生數上限（`beamWidth == 1` 時為 0，即傳統 1-best）。
      let alternativeLimit = width - 1

      var table = BeamTable(positionCount: keyCount + 1, width: width)
      // 詞值駐留表：路徑狀態只存詞值的整數代號，去重時比對整數、複製狀態時也不必增減字串引用計數。
      // 代號 0 固定為空字串（起始狀態的詞值）。
      var valueTable = [""]
      var valueIDs = ["": 0]
      func intern(_ value: String) -> Int {
        if let existing = valueIDs[value] { return existing }
        let newID = valueTable.count
        valueTable.append(value)
        valueIDs[value] = newID
        return newID
      }

      // 記錄 DP 遍歷過的節點座標，於遍歷結束後統一寫回選取狀態。
      // 寫回延後到遍歷結束、段字典為唯一引用之時，避免「for-in 遍歷段字典的同時、
      // 透過下標寫回同一字典」所觸發的寫時複製（COW）。
      var visitedNodes = [(position: Int, segLength: Int)]()
      visitedNodes.reserveCapacity(keyCount * config.maxSegLength)

      // DAG 動態規劃主循環
      for i in 0 ..< keyCount {
        let stateCount = table.counts[i]
        guard stateCount > 0 else { continue } // 只處理可達的位置

        // 遍歷從位置 i 開始的所有可能節點
        for (length, nextNode) in config.segments[i] {
          guard let nextGram = nextNode.currentGram else { continue }

          let nextPos = i + length
          guard nextPos <= keyCount else { continue }
          visitedNodes.append((i, length))

          // 詞庫給零頻詞條的兜底分數是固定值、不隨音節數縮放，於是一個從未出現過的長詞
          // 與一個從未出現過的短詞領到相同分數。DP 累加對數機率、節點越少總分越高，這類
          // 長的零頻詞便會系統性地擊敗逐字組合。此處為其補上長度縮放：要求一個零頻的 n
          // 音節詞至少付出 n 個中等常用字的代價。單音節元圖不受影響。
          // 縮放只作用於節點的單元圖分數（於 `getScore` 內套用）：語境元圖（POM 記憶等）
          // 與使用者明確覆寫的分數不在此列。幅節長度以段字典鍵為準（理由同下方回溯）。
          let rareFloor = rarePhrasePerSyllableFloor.map {
            Homa.RarePhraseFloor(
              rarityThreshold: rarityThreshold, perSyllableFloor: $0, segLength: length
            )
          }

          // 同節點替代詞值：僅限未覆寫的節點（覆寫即使用者或系統已釘選，不得另生分身）。
          // 多取一個，供逐路徑略過「與主選取同值」者之後仍有 `alternativeLimit` 個可用。
          let alternativeIndices: [Int] = alternativeLimit > 0 && !nextNode.isOverridden
            ? nextNode.beamAlternativeUnigramIndices(limit: alternativeLimit + 1)
            : []
          // 節點不含任何語境元圖時，其計分與前驅的詞值無關（只取決於前驅是否為空）：
          // 只算一次、供各路徑共用，以免 K 條路徑重複掃描整個元圖陣列。
          let hasContextualGrams = nextNode.hasContextualGrams
          let contextualIndices: [Int] = hasContextualGrams && !alternativeIndices.isEmpty
            ? nextNode.contextualGramIndices
            : []
          var cachedExpansion: (previousIsEmpty: Bool, expansion: NodeExpansion, valueIDs: [Int])?

          for slot in 0 ..< stateCount {
            let state = table.states[i * width + slot]
            // 前驅取自**這條路徑**的末節點；三元圖的前驅之二取自這條路徑的前驅節點。
            // 代號 0 即空字串，故「前驅為空」等價於 `valueID == 0`。
            let previousIsEmpty = state.valueID == 0

            let expansion: NodeExpansion
            // 主選取與各替代詞值的駐留代號（順序同 `[primary] + alternatives`）。
            let choiceValueIDs: [Int]
            if let cachedExpansion, cachedExpansion.previousIsEmpty == previousIsEmpty {
              expansion = cachedExpansion.expansion
              choiceValueIDs = cachedExpansion.valueIDs
            } else {
              let previousCurrent = valueTable[state.valueID]
              let anteriorCurrent = valueTable[state.previousValueID]
              expansion = expand(
                node: nextNode,
                fallbackGram: nextGram,
                previous: previousCurrent,
                anterior: anteriorCurrent,
                rareFloor: rareFloor,
                alternativeIndices: alternativeIndices,
                alternativeLimit: alternativeLimit,
                contextualIndices: contextualIndices
              )
              var newValueIDs = [intern(expansion.primary.value)]
              newValueIDs.reserveCapacity(expansion.alternatives.count + 1)
              for alternative in expansion.alternatives {
                newValueIDs.append(intern(alternative.value))
              }
              choiceValueIDs = newValueIDs
              if !hasContextualGrams {
                cachedExpansion = (previousIsEmpty, expansion, newValueIDs)
              }
            }

            table.insert(
              BeamState(
                score: state.score + expansion.primary.score,
                gramIndex: expansion.primary.gramIndex,
                segLength: length,
                backPosition: i,
                backSlot: slot,
                valueID: choiceValueIDs[0],
                previousValueID: state.valueID
              ),
              at: nextPos
            )
            for (offset, alternative) in expansion.alternatives.enumerated() {
              table.insert(
                BeamState(
                  score: state.score + alternative.score,
                  gramIndex: alternative.gramIndex,
                  segLength: length,
                  backPosition: i,
                  backSlot: slot,
                  valueID: choiceValueIDs[offset + 1],
                  previousValueID: state.valueID
                ),
                at: nextPos
              )
            }
          }
        }
      }

      // 回溯構建最佳路徑（自終點桶的首條路徑開始）。
      var resultReversed: [Homa.GramInPath] = []
      // 最佳路徑上各節點的起點與幅節長度、及其所選元圖索引（供寫回）。
      var pathSelections: [(position: Int, segLength: Int, gramIndex: Int)] = []
      if table.counts[keyCount] > 0 {
        finalScore = table.states[keyCount * width].score
        var currentPos = keyCount
        var currentSlot = 0
        while currentPos > 0 {
          let state = table.states[currentPos * width + currentSlot]
          guard state.segLength > 0 else { break }
          // 幅節長度以段字典鍵為準：gram.keyArray 的長度可能與格位幅節長度
          // 不一致（如前綴匹配回傳的更長 gram），回溯時不得依賴後者。
          let startPos = currentPos - state.segLength
          guard let node = config.segments[startPos][state.segLength],
                node.grams.indices.contains(state.gramIndex)
          else { break }
          resultReversed.append(
            .init(gram: node.grams[state.gramIndex], isExplicit: node.isExplicitlyOverridden)
          )
          pathSelections.append((startPos, state.segLength, state.gramIndex))
          currentPos = state.backPosition
          currentSlot = state.backSlot
        }
      } else {
        finalScore = Double(Int32.min)
      }

      // 統一寫回節點狀態（此時遍歷已結束，段字典為唯一引用，不觸發 COW 複製）。
      // 先將遍歷過、但不在最佳路徑上的節點退回首個單元圖（覆寫者除外），再讓最佳路徑上的
      // 節點改指回溯所得的元圖。
      var pathSegLengthAt = [Int](repeating: 0, count: keyCount + 1)
      for selection in pathSelections {
        pathSegLengthAt[selection.position] = selection.segLength
      }
      for entry in visitedNodes where pathSegLengthAt[entry.position] != entry.segLength {
        config.segments[entry.position][entry.segLength]?.resetContextualSelectionUnlessOverridden()
      }
      for selection in pathSelections {
        config.segments[selection.position][selection.segLength]?.selectGramForPath(at: selection.gramIndex)
      }

      return resultReversed.reversed()
    }

    // MARK: Private

    /// 節點在某條路徑之後所能給出的一個選擇：元圖索引、該節點的分數、詞值。
    private struct NodeChoice {
      let gramIndex: Int
      let score: Double
      let value: String
    }

    /// 節點在某條路徑之後的全部選擇：主選取（與 1-best 相同的 `getScore` 結果）與同節點替代詞值。
    private struct NodeExpansion {
      let primary: NodeChoice
      let alternatives: [NodeChoice]
    }

    /// 一條抵達某位置的部分路徑。
    private struct BeamState {
      static let placeholder = BeamState(
        score: Double(Int32.min), gramIndex: -1, segLength: 0, backPosition: -1, backSlot: -1,
        valueID: 0, previousValueID: 0
      )

      /// 累計分數。
      var score: Double
      /// 末節點所選元圖於該節點元圖陣列內的索引。
      var gramIndex: Int
      /// 末節點的幅節長度（起始狀態為 0）。
      var segLength: Int
      /// 回溯指標：前一個位置。
      var backPosition: Int
      /// 回溯指標：前一個位置的桶內槽位。
      var backSlot: Int
      /// 末節點詞值的駐留代號（該詞值即後續節點計分時的 `previous`）。
      var valueID: Int
      /// 前驅節點詞值的駐留代號（該詞值即後續節點計分時的 `anterior`）。
      var previousValueID: Int
    }

    /// 各位置的路徑桶，以單一扁平陣列存放（位置 p 的第 k 條路徑位於 `states[p * width + k]`），
    /// 避免逐位置配置小陣列。
    private struct BeamTable {
      // MARK: Lifecycle

      init(positionCount: Int, width: Int) {
        self.width = width
        self.states = .init(repeating: .placeholder, count: positionCount * width)
        self.counts = .init(repeating: 0, count: positionCount)
        // 起始狀態：位置 0、分數 0、無前驅。
        states[0] = BeamState(
          score: 0, gramIndex: -1, segLength: 0, backPosition: -1, backSlot: -1, valueID: 0, previousValueID: 0
        )
        counts[0] = 1
      }

      // MARK: Internal

      let width: Int
      private(set) var states: [BeamState]
      /// 各位置的有效路徑數。
      private(set) var counts: [Int]

      /// 把一條候選路徑放入位置 `position` 的桶中：先去重，再依分數插入，超出 `width` 者捨棄。
      /// 同分時保留先到者（與 1-best 的「嚴格大於才更新」一致）。
      mutating func insert(_ candidate: BeamState, at position: Int) {
        let base = position * width
        var count = counts[position]
        // 桶已滿且不優於末位：即使桶內有重複者，其分數也不低於末位，可直接捨棄。
        if count == width, candidate.score <= states[base + count - 1].score { return }
        for slot in 0 ..< count {
          guard states[base + slot].valueID == candidate.valueID,
                states[base + slot].previousValueID == candidate.previousValueID
          else { continue }
          guard candidate.score > states[base + slot].score else { return }
          // 移除較差的重複者，再走一般插入流程。
          var cursor = slot
          while cursor < count - 1 {
            states[base + cursor] = states[base + cursor + 1]
            cursor += 1
          }
          count -= 1
          break
        }
        var insertAt = count
        while insertAt > 0, candidate.score > states[base + insertAt - 1].score {
          insertAt -= 1
        }
        guard insertAt < width else {
          counts[position] = count
          return
        }
        let newCount = Swift.min(count + 1, width)
        var cursor = newCount - 1
        while cursor > insertAt {
          states[base + cursor] = states[base + cursor - 1]
          cursor -= 1
        }
        states[base + insertAt] = candidate
        counts[position] = newCount
      }
    }

    /// 以給定前驅為節點計分，給出主選取與至多 `alternativeLimit` 個同節點替代詞值。
    private static func expand(
      node: Homa.Node,
      fallbackGram: Homa.Gram,
      previous: String,
      anterior: String,
      rareFloor: Homa.RarePhraseFloor?,
      alternativeIndices: [Int],
      alternativeLimit: Int,
      contextualIndices: [Int]
    )
      -> NodeExpansion {
      var nodeCopy = node
      let score = nodeCopy.getScore(previous: previous, anterior: anterior, rareFloor: rareFloor)
      // 元圖須取**計分之後**的 `nodeCopy.currentGram`：`getScore` 會依語境移動
      // `currentGramIndex`（命中雙元圖／三元圖時改指該元圖，未命中時退回單元圖），
      // 計分前取得的 `fallbackGram` 可能是另一個值，回溯出的句子便會與路徑分數不一致。
      let primaryValue = (nodeCopy.currentGram ?? fallbackGram).current
      let primary = NodeChoice(gramIndex: nodeCopy.currentGramIndex, score: score, value: primaryValue)
      guard !alternativeIndices.isEmpty else { return NodeExpansion(primary: primary, alternatives: []) }
      var alternatives: [NodeChoice] = []
      alternatives.reserveCapacity(alternativeLimit)
      for unigramIndex in alternativeIndices {
        guard alternatives.count < alternativeLimit else { break }
        let value = node.grams[unigramIndex].current
        guard value != primaryValue else { continue }
        let scored = node.beamAlternativeScore(
          unigramIndex: unigramIndex,
          contextualGramIndices: contextualIndices,
          previous: previous,
          anterior: anterior,
          rareFloor: rareFloor
        )
        alternatives.append(NodeChoice(gramIndex: scored.gramIndex, score: scored.score, value: value))
      }
      return NodeExpansion(primary: primary, alternatives: alternatives)
    }
  }
}
