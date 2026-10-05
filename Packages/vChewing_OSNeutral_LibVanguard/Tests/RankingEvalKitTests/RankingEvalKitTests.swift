// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Testing

@testable import RankingEvalKit

// MARK: - RankingEvalTSVTests

@Suite
struct RankingEvalTSVTests {
  @Test
  func parsesCasesAndSkipsCommentsAndBlankLines() {
    let text = """
    # header comment
    我再試一次\tㄨㄛˇ ㄗㄞˋ ㄕˋ ㄧ ㄘˋ

      # indented comment
    他已經在公司了\tㄊㄚ ㄧˇ ㄐㄧㄥ ㄗㄞˋ ㄍㄨㄥ ㄙ ㄌㄜ˙\r
    """
    let parsed = RankingEvalTSV.parse(text, source: "seed.tsv")
    #expect(parsed.issues.isEmpty)
    #expect(parsed.cases.count == 2)
    #expect(parsed.cases[0] == RankingEvalCase(
      source: "seed.tsv",
      lineNumber: 2,
      expected: "我再試一次",
      readings: ["ㄨㄛˇ", "ㄗㄞˋ", "ㄕˋ", "ㄧ", "ㄘˋ"]
    ))
    #expect(parsed.cases[1].lineNumber == 5)
    #expect(parsed.cases[1].readings.last == "ㄌㄜ˙")
  }

  @Test
  func toleratesRepeatedSpacesBetweenReadings() {
    let parsed = RankingEvalTSV.parse("你好\tㄋㄧˇ   ㄏㄠˇ ", source: "x")
    #expect(parsed.issues.isEmpty)
    #expect(parsed.cases.first?.readings == ["ㄋㄧˇ", "ㄏㄠˇ"])
  }

  @Test
  func reportsMalformedLines() {
    let text = """
    沒有分隔字元 ㄇㄟˊ
    字數不符\tㄗˋ ㄕㄨˋ
    \tㄎㄨㄥ
    空讀音\t
    """
    let parsed = RankingEvalTSV.parse(text, source: "bad.tsv")
    #expect(parsed.cases.isEmpty)
    #expect(parsed.issues.map(\.lineNumber) == [1, 2, 3, 4])
    #expect(parsed.issues[0].message.contains("TAB"))
    #expect(parsed.issues[1].message.contains("differs"))
  }
}

// MARK: - RankingEvalMetricsTests

@Suite
struct RankingEvalMetricsTests {
  @Test
  func exactMatch() {
    let result = RankingEvalMetrics.compare(expected: "我再試一次", actual: "我再試一次")
    #expect(result.isExactMatch)
    #expect(!result.isLengthMismatch)
    #expect(result.correctCharCount == 5)
    #expect(result.diffPositions.isEmpty)
  }

  @Test
  func positionWiseDifferences() {
    let result = RankingEvalMetrics.compare(expected: "我再試一次", actual: "我在是一次")
    #expect(!result.isExactMatch)
    #expect(result.correctCharCount == 3)
    #expect(result.diffPositions == [1, 2])
    #expect(RankingEvalMetrics.diffMarkerLine(charCount: 5, diffPositions: result.diffPositions) == "　＾＾　　")
  }

  @Test
  func lengthMismatchCountsAsAllWrong() {
    let result = RankingEvalMetrics.compare(expected: "我再試", actual: "我再試一")
    #expect(result.isLengthMismatch)
    #expect(result.correctCharCount == 0)
    #expect(result.diffPositions == [0, 1, 2])
  }

  @Test
  func summaryAggregatesAccuracyAndMissingReadings() {
    let passCase = RankingEvalCase(source: "s", lineNumber: 1, expected: "我再", readings: ["ㄨㄛˇ", "ㄗㄞˋ"])
    let failCase = RankingEvalCase(source: "s", lineNumber: 2, expected: "再試", readings: ["ㄗㄞˋ", "ㄕˋ"])
    let skipCase = RankingEvalCase(source: "s", lineNumber: 3, expected: "嗯", readings: ["ㄣ˙"])
    let results = [
      RankingEvalCaseResult(
        evalCase: passCase,
        actual: "我再",
        segments: ["我", "再"],
        comparison: RankingEvalMetrics.compare(expected: "我再", actual: "我再"),
        missingReadings: [],
        unreachablePositions: []
      ),
      RankingEvalCaseResult(
        evalCase: failCase,
        actual: "在是",
        segments: ["在", "是"],
        comparison: RankingEvalMetrics.compare(expected: "再試", actual: "在是"),
        missingReadings: [],
        unreachablePositions: [1]
      ),
      RankingEvalCaseResult(
        evalCase: skipCase,
        actual: nil,
        segments: nil,
        comparison: nil,
        missingReadings: ["ㄣ˙"],
        unreachablePositions: []
      ),
    ]
    let summary = RankingEvalSummary(results: results)
    #expect(summary.totalCases == 3)
    #expect(summary.evaluatedCases == 2)
    #expect(summary.skippedCases == 1)
    #expect(summary.correctSentences == 1)
    #expect(summary.totalChars == 4)
    #expect(summary.correctChars == 2)
    #expect(summary.sentenceAccuracy == 0.5)
    #expect(summary.charAccuracy == 0.5)
    #expect(summary.missingReadingOccurrences == 1)
    #expect(summary.distinctMissingReadings == ["ㄣ˙"])
    #expect(summary.casesWithUnreachableChars == 1)
  }

  @Test
  func reportJSONRoundTrips() throws {
    let evalCase = RankingEvalCase(source: "s", lineNumber: 1, expected: "我", readings: ["ㄨㄛˇ"])
    let report = RankingEvalReport(
      runInfo: RankingEvalRunInfo(lexiconFileName: "x.txtMap", lexiconByteSize: 1, inputFiles: ["s"], options: [:]),
      results: [
        RankingEvalCaseResult(
          evalCase: evalCase,
          actual: "握",
          segments: ["握"],
          comparison: RankingEvalMetrics.compare(expected: "我", actual: "握"),
          missingReadings: [],
          unreachablePositions: []
        ),
      ],
      parseIssues: []
    )
    let decoded = try JSONDecoder().decode(RankingEvalReport.self, from: report.encodedJSON())
    #expect(decoded == report)
    #expect(report.renderedText().contains("FAIL s:1"))
  }
}

// MARK: - RankingEvalOptionsTests

@Suite
struct RankingEvalOptionsTests {
  @Test
  func parsesOptions() {
    let outcome = RankingEvalOptions.parse(
      arguments: ["--json", "out.json", "--show-all", "--max-seg-length", "6", "a.tsv", "b.tsv"]
    )
    #expect(outcome == .run(
      RankingEvalOptions(
        inputPaths: ["a.tsv", "b.tsv"],
        jsonOutputPath: "out.json",
        includePassingCases: true,
        maxSegLength: 6
      )
    ))
  }

  @Test
  func parsesRarityOptions() {
    let defaults = RankingEvalOptions.parse(arguments: ["a.tsv"])
    #expect(defaults == .run(RankingEvalOptions(inputPaths: ["a.tsv"])))
    let off = RankingEvalOptions.parse(arguments: ["--rare-floor", "OFF", "a.tsv"])
    #expect(off == .run(RankingEvalOptions(inputPaths: ["a.tsv"], rareFloor: .off)))
    let valued = RankingEvalOptions.parse(
      arguments: ["--rarity-threshold", "-9.5", "--rare-floor", "-5.2", "a.tsv"]
    )
    #expect(valued == .run(
      RankingEvalOptions(inputPaths: ["a.tsv"], rarityThreshold: -9.5, rareFloor: .value(-5.2))
    ))
    #expect(RankingEvalOptions.parse(arguments: ["--rare-floor", "nope", "a.tsv"])
      == .failure("--rare-floor requires a number or `off`."))
    #expect(RankingEvalOptions.parse(arguments: ["--rarity-threshold", "x", "a.tsv"])
      == .failure("--rarity-threshold requires a number."))
  }

  @Test
  func parsesBeamWidthOption() {
    #expect(RankingEvalOptions.parse(arguments: ["--beam-width", "1", "a.tsv"])
      == .run(RankingEvalOptions(inputPaths: ["a.tsv"], beamWidth: 1)))
    #expect(RankingEvalOptions.parse(arguments: ["--beam-width", "0", "a.tsv"])
      == .failure("--beam-width requires a positive integer."))
    #expect(RankingEvalOptions.parse(arguments: ["--beam-width", "x", "a.tsv"])
      == .failure("--beam-width requires a positive integer."))
  }

  @Test
  func rejectsInvalidArguments() {
    #expect(RankingEvalOptions.parse(arguments: []) == .failure("At least one TSV file is required."))
    #expect(RankingEvalOptions.parse(arguments: ["--json"]) == .failure("--json requires a file path."))
    #expect(RankingEvalOptions.parse(arguments: ["--bogus", "a.tsv"]) == .failure("Unknown option: --bogus"))
    #expect(RankingEvalOptions.parse(arguments: ["-h"]) == .showHelp)
  }
}
