// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import HomaSharedTestComponents
import Testing

@testable import Homa

// MARK: - HomaTestsRoot.HomaTests_BeamSearch

extension HomaTestsRoot {
  /// K-best 組句（`Homa.Assembler.beamWidth`）。
  ///
  /// 傳統 1-best DP 每個位置只保留一條最佳路徑，後方節點的語境元圖無從影響前方近乎同分的取捨。
  /// 這組測試釘住：
  /// - K ≥ 2 時，後方節點的雙元圖／三元圖能讓近乎同分的前驅勝出；K = 1 時維持舊行為。
  /// - K = 1 與傳統 1-best DP（本檔內的參考實作）逐位元一致。
  /// - 使用者明確覆寫（`.withSpecified`）在 K = 4 時仍然凌駕一切。
  /// - `mostRecentPathScore` 等於回傳路徑上各元圖分數之和。
  /// - 組句後最佳路徑上的節點選取與組句結果一致，且再組一次結果不變。
  struct HomaTests_BeamSearch: HomaTestSuite {
    /// 「ㄇㄚ」的「媽」(−5) 略勝「嗎」(−5.05)；「？」帶有「前文為嗎」的雙元圖（+1）。
    static let particleCorpus = """
    ㄋㄚˇ 哪 -5
    ㄇㄚ 媽 -5
    ㄇㄚ 嗎 -5.05
    ㄇㄚ 抹 -6
    ㄋㄚˇ-ㄇㄚ 拿碼 -11
    _punctuation_? ？ 0
    _punctuation_? ？ 1 嗎
    """

    /// 傳統 1-best DP 的參考實作（即 K-best 引入之前的 `PathFinder.run`），供逐位元比對。
    /// 於組態的硬拷貝上執行，不改動組字器本身。
    static func referenceOneBest(
      _ assembler: Homa.Assembler
    )
      -> (values: [String], probabilities: [Double], score: Double) {
      var config = assembler.config.hardCopy
      let keyCount = config.keys.count
      guard !config.segments.isEmpty else { return ([], [], Double(Int32.min)) }
      var dp = [Double](repeating: Double(Int32.min), count: keyCount + 1)
      var parent = [(gram: Homa.Gram, segLength: Int)?](repeating: nil, count: keyCount + 1)
      dp[0] = 0
      for i in 0 ..< keyCount {
        guard dp[i] > Double(Int32.min) else { continue }
        for (length, nextNode) in config.segments[i] {
          guard let nextGram = nextNode.currentGram else { continue }
          let nextPos = i + length
          guard nextPos <= keyCount else { continue }
          let previousCurrent = parent[i]?.gram.current ?? ""
          let anteriorCurrent: String = {
            guard let parentInfo = parent[i], parentInfo.segLength > 0 else { return "" }
            let previousStart = i - parentInfo.segLength
            guard previousStart >= 0 else { return "" }
            return parent[previousStart]?.gram.current ?? ""
          }()
          let rareFloor = assembler.rarePhrasePerSyllableFloor.map {
            Homa.RarePhraseFloor(
              rarityThreshold: assembler.rarityThreshold, perSyllableFloor: $0, segLength: length
            )
          }
          var nodeCopy = nextNode
          let newScore = dp[i] + nodeCopy.getScore(
            previous: previousCurrent, anterior: anteriorCurrent, rareFloor: rareFloor
          )
          if newScore > dp[nextPos] {
            dp[nextPos] = newScore
            parent[nextPos] = (nodeCopy.currentGram ?? nextGram, length)
          }
        }
      }
      var reversed: [Homa.Gram] = []
      var currentPos = keyCount
      while currentPos > 0, let parentInfo = parent[currentPos] {
        reversed.append(parentInfo.gram)
        currentPos -= parentInfo.segLength
      }
      config.segments.removeAll()
      let path = Array(reversed.reversed())
      return (path.map(\.current), path.map(\.probability), dp[keyCount])
    }

    /// 依組句結果逐一取出最佳路徑上的節點。
    static func nodesOnPath(_ assembler: Homa.Assembler) -> [Homa.Node?] {
      var position = 0
      return assembler.assembledSentence.map { gramInPath in
        let segLength = gramInPath.keyArray.count
        defer { position += segLength }
        return assembler.segments[position][segLength]
      }
    }

    /// (1) K ≥ 2：「？」的「前文為嗎」雙元圖讓近乎同分的「嗎」勝過「媽」；K = 1 時「媽」仍勝出
    /// （「？」計分時，前驅早已定案為「媽」）——此即舊有之限制。
    @Test("[Homa] BeamSearch: Trailing Bigram Lets Near-Tied Predecessor Win")
    func testTrailingBigramLetsNearTiedPredecessorWin() throws {
      let mockLX = TestLX(rawData: Self.particleCorpus)
      let readings = ["ㄋㄚˇ", "ㄇㄚ", "_punctuation_?"]

      let oneBest = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 1)
      try readings.forEach { try oneBest.insertKey($0) }
      #expect(oneBest.assemble().values == ["哪", "媽", "？"])

      for width in [2, 4, 8] {
        let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: width)
        try readings.forEach { try assembler.insertKey($0) }
        let result = assembler.assemble()
        #expect(result.values == ["哪", "嗎", "？"], "beamWidth = \(width)")
        #expect(result.last?.gram.previous == "嗎")
      }

      // 不以語氣詞收尾時（沒有後接的「？」），兩者皆維持詞庫首選「媽」。
      let noPunctuation = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) })
      try ["ㄋㄚˇ", "ㄇㄚ"].forEach { try noPunctuation.insertKey($0) }
      #expect(noPunctuation.assemble().values == ["哪", "媽"])
    }

    /// (1') 前驅之別亦可在分詞層級：兩條路徑的末節點是不同幅節長度的節點。
    @Test("[Homa] BeamSearch: Trailing Bigram Picks Between Segmentations")
    func testTrailingBigramPicksBetweenSegmentations() throws {
      // 「好嗎」(−9.0) 與「豪」＋「馬」(−4.5 + −4.45 = −8.95) 近乎同分；「？」接「好嗎」（尾字為嗎）時加分。
      let mockLX = TestLX(rawData: """
      ㄏㄠˇ 豪 -4.5
      ㄇㄚˇ 馬 -4.45
      ㄏㄠˇ-ㄇㄚˇ 好嗎 -9.0
      _punctuation_? ？ 0
      _punctuation_? ？ 1 嗎
      """)
      let readings = ["ㄏㄠˇ", "ㄇㄚˇ", "_punctuation_?"]
      let oneBest = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 1)
      try readings.forEach { try oneBest.insertKey($0) }
      #expect(oneBest.assemble().values == ["豪", "馬", "？"])

      let beam = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 4)
      try readings.forEach { try beam.insertKey($0) }
      #expect(beam.assemble().values == ["好嗎", "？"])
      #expect(beam.mostRecentPathScore == -9.0 + 1.0)
    }

    /// (2) K = 1 與傳統 1-best DP 逐位元一致（組句結果、各元圖分數、路徑總分）；
    /// 並確認既有測試所釘的組句結果在 K = 1 與 K = 4 皆成立。
    @Test("[Homa] BeamSearch: Width One Matches Classic One-Best DP")
    func testWidthOneMatchesClassicOneBestDP() throws {
      let cases: [(corpus: String, readings: String, expected: [String]?)] = [
        (
          HomaTests.strLXSampleDataLitch,
          "chao1 shang1 da4 qian2 tian1 wei2 zhi3 hai2 zai5 mai4 nai3 ji1",
          ["超商", "大前天", "為止", "還", "在", "賣", "荔枝"]
        ),
        (
          HomaTests.strLXSampleDataTechGuarden + "\n" + HomaTests.strLXSampleDataLitch,
          "da4 qian2 tian1 zai5 ke1 ji4 gong1 yuan2 chao1 shang1",
          ["大前天", "在", "科技", "公園", "超商"]
        ),
        (
          HomaTests.strLXSampleDataHutao,
          "you1 die2 neng2 liu2 yi4 lv3 fang1",
          ["幽蝶", "能", "留意", "呂方"]
        ),
        (
          HomaTests.strLXSampleDataTrailblazing,
          "jiu4 shi4 yan2 zhe5 qian2 ren2 wei4 jin4 de5 dao4 lu4",
          nil
        ),
        (
          HomaTests.strLXSampleDataTrailblazing,
          "cong2 lai2 bu4 you2 ta1 ren2 pu1 jiu4",
          nil
        ),
        (Self.particleCorpus, "ㄋㄚˇ ㄇㄚ _punctuation_?", ["哪", "媽", "？"]),
      ]
      for testCase in cases {
        let mockLX = TestLX(rawData: testCase.corpus)
        let readings = testCase.readings.split(separator: " ").map(String.init)
        let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 1)
        try readings.forEach { try assembler.insertKey($0) }
        let reference = Self.referenceOneBest(assembler)
        let result = assembler.assemble()
        #expect(result.values == reference.values, "\(testCase.readings)")
        #expect(result.map(\.score) == reference.probabilities, "\(testCase.readings)")
        #expect(assembler.mostRecentPathScore == reference.score, "\(testCase.readings)")
        if let expected = testCase.expected {
          #expect(result.values == expected, "\(testCase.readings)")
        }
        // 語料不含能改變前驅取捨的語境元圖時，K = 4 與 K = 1 結果相同。
        guard testCase.corpus != Self.particleCorpus else { continue }
        let beam = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 4)
        try readings.forEach { try beam.insertKey($0) }
        #expect(beam.assemble().values == result.values, "\(testCase.readings)")
        #expect(beam.mostRecentPathScore >= assembler.mostRecentPathScore, "\(testCase.readings)")
      }
    }

    /// (3) K = 4 時，使用者明確覆寫（`.withSpecified`）仍然凌駕語境加分。
    @Test("[Homa] BeamSearch: Explicit Override Still Wins")
    func testExplicitOverrideStillWins() throws {
      let mockLX = TestLX(rawData: Self.particleCorpus)
      let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 4)
      try ["ㄋㄚˇ", "ㄇㄚ", "_punctuation_?"].forEach { try assembler.insertKey($0) }
      #expect(assembler.assemble().values == ["哪", "嗎", "？"])

      try assembler.overrideCandidate(
        .init(keyArray: ["ㄇㄚ"], value: "媽"), at: 1, type: .withSpecified, isExplicitlyOverridden: true
      )
      #expect(assembler.assembledSentence.values == ["哪", "媽", "？"])
      #expect(assembler.assembledSentence[1].isExplicit)
      // 覆寫的節點不派生替代詞值：再組一次亦不會繞回「嗎」。
      #expect(assembler.assemble().values == ["哪", "媽", "？"])

      // 覆寫一個詞庫分數更低的候選（抹）亦同。
      try assembler.overrideCandidate(
        .init(keyArray: ["ㄇㄚ"], value: "抹"), at: 1, type: .withSpecified, isExplicitlyOverridden: true
      )
      #expect(assembler.assemble().values == ["哪", "抹", "？"])
    }

    /// (4) `mostRecentPathScore` 等於回傳路徑上各元圖分數之和（含語境元圖的分數）。
    @Test("[Homa] BeamSearch: Path Score Equals Sum Along Returned Path")
    func testPathScoreEqualsSumAlongReturnedPath() throws {
      let corpora: [(String, [String])] = [
        (Self.particleCorpus, ["ㄋㄚˇ", "ㄇㄚ", "_punctuation_?"]),
        (HomaTests.strLXSampleDataHutao, "you1 die2 neng2 liu2 yi4 lv3 fang1".split(separator: " ").map(String.init)),
        (
          HomaTests.strLXSampleDataTrailblazing,
          "zou3 chu1 geng1 yao2 yuan3 de5 ju4 li2".split(separator: " ").map(String.init)
        ),
      ]
      for (corpus, readings) in corpora {
        let mockLX = TestLX(rawData: corpus)
        let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 4)
        try readings.forEach { try assembler.insertKey($0) }
        let result = assembler.assemble()
        let sum = result.map(\.score).reduce(0, +)
        #expect(abs(assembler.mostRecentPathScore - sum) < 1e-9, "\(readings)")
      }
      let mockLX = TestLX(rawData: Self.particleCorpus)
      let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 4)
      try ["ㄋㄚˇ", "ㄇㄚ", "_punctuation_?"].forEach { try assembler.insertKey($0) }
      assembler.assemble()
      #expect(abs(assembler.mostRecentPathScore - (-5 + -5.05 + 1)) < 1e-9)
    }

    /// (5) 寫回：最佳路徑上的節點所選元圖與組句結果一致；不在路徑上的節點退回首個單元圖；
    /// 再組一次結果與分數皆不變（不會來回翻轉）。
    @Test("[Homa] BeamSearch: Node Write-Back Agrees With Assembled Path")
    func testNodeWriteBackAgreesWithAssembledPath() throws {
      let mockLX = TestLX(rawData: Self.particleCorpus)
      let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 4)
      try ["ㄋㄚˇ", "ㄇㄚ", "_punctuation_?"].forEach { try assembler.insertKey($0) }
      let first = assembler.assemble()
      #expect(first.values == ["哪", "嗎", "？"])
      let nodes = Self.nodesOnPath(assembler)
      #expect(nodes.count == first.count)
      for (node, gramInPath) in zip(nodes, first) {
        #expect(node?.currentGram == gramInPath.gram)
      }
      // 「ㄇㄚ」節點目前指向「嗎」（並非首個單元圖），但並未被覆寫。
      #expect(nodes[1]?.isOverridden == false)
      // 不在路徑上的「拿碼」節點維持首個單元圖。
      #expect(assembler.segments[0][2]?.currentGram?.current == "拿碼")
      let firstScore = assembler.mostRecentPathScore

      for _ in 0 ..< 3 {
        #expect(assembler.assemble() == first)
        #expect(assembler.mostRecentPathScore == firstScore)
      }

      // 拿掉「？」之後，「ㄇㄚ」不再有理由選「嗎」：須回到詞庫首選「媽」，且節點同步退回。
      try assembler.dropKey(direction: .rear)
      #expect(assembler.assembledSentence.values == ["哪", "媽"])
      #expect(Self.nodesOnPath(assembler).last??.currentGram?.current == "媽")
      #expect(assembler.assemble().values == ["哪", "媽"])
    }

    /// (6) 三元圖在 K = 4 時照常運作，且能反過來決定前驅：「已」(−1) 略勝「乙」(−1.02)，
    /// 但「丙」帶有「甲、乙」之三元圖（−0.5）。K = 1 時「已」先定案、三元圖無從命中。
    @Test("[Homa] BeamSearch: Trigram Works And Steers Predecessor")
    func testTrigramWorksAndSteersPredecessor() throws {
      let mockLX = TestLX(rawData: """
      ㄐㄧㄚˇ 甲 -1
      ㄧˇ 已 -1
      ㄧˇ 乙 -1.02
      ㄅㄧㄥˇ 餅 -1
      ㄅㄧㄥˇ 丙 -3
      ㄅㄧㄥˇ 丙 -0.5 乙 甲
      """)
      let readings = ["ㄐㄧㄚˇ", "ㄧˇ", "ㄅㄧㄥˇ"]
      let oneBest = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 1)
      try readings.forEach { try oneBest.insertKey($0) }
      #expect(oneBest.assemble().values == ["甲", "已", "餅"])

      let beam = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) }, beamWidth: 4)
      try readings.forEach { try beam.insertKey($0) }
      let result = beam.assemble()
      #expect(result.values == ["甲", "乙", "丙"])
      #expect(result.last?.gram.anterior == "甲")
      #expect(abs(beam.mostRecentPathScore - (-1 + -1.02 + -0.5)) < 1e-9)

      // 既有三元圖語料（`HomaTests_Trigram`）在 K = 4 時結果不變。
      let plainLX = TestLX(rawData: """
      ㄐㄧㄚˇ 甲 -1
      ㄧˇ 乙 -1
      ㄅㄧㄥˇ 餅 -1
      ㄅㄧㄥˇ 丙 -3
      ㄅㄧㄥˇ 丙 -0.5 乙 甲
      """)
      let plain = Homa.Assembler(gramQuerier: { plainLX.queryGrams($0) }, beamWidth: 4)
      try readings.forEach { try plain.insertKey($0) }
      #expect(plain.assemble().values == ["甲", "乙", "丙"])
    }

    /// 搜尋寬度的預設值、下限，以及 `copy` 的傳遞。
    @Test("[Homa] BeamSearch: Width Default, Clamp And Copy")
    func testWidthDefaultClampAndCopy() {
      let mockLX = TestLX(rawData: Self.particleCorpus)
      let assembler = Homa.Assembler(gramQuerier: { mockLX.queryGrams($0) })
      #expect(assembler.beamWidth == Homa.Assembler.defaultBeamWidth)
      #expect(Homa.Assembler.defaultBeamWidth == 4)
      assembler.beamWidth = 0
      #expect(assembler.beamWidth == 1)
      assembler.beamWidth = 6
      #expect(assembler.copy.beamWidth == 6)
      #expect(Homa.Assembler(gramQuerier: { _ in [] }, beamWidth: -3).beamWidth == 1)
    }
  }
}
