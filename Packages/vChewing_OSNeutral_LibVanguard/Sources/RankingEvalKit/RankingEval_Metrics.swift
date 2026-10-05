// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - RankingEvalComparison

/// 單句比對結果。
public struct RankingEvalComparison: Codable, Hashable, Sendable {
  // MARK: Lifecycle

  public init(isExactMatch: Bool, isLengthMismatch: Bool, correctCharCount: Int, diffPositions: [Int]) {
    self.isExactMatch = isExactMatch
    self.isLengthMismatch = isLengthMismatch
    self.correctCharCount = correctCharCount
    self.diffPositions = diffPositions
  }

  // MARK: Public

  public let isExactMatch: Bool
  /// 實際結果與預期字數不同：此時整句一律視為全錯。
  public let isLengthMismatch: Bool
  public let correctCharCount: Int
  /// 預期句子中與實際結果不同的字位（0 起算）。
  public let diffPositions: [Int]
}

// MARK: - RankingEvalMetrics

public enum RankingEvalMetrics {
  /// 逐字位比對預期與實際結果。
  ///
  /// 字數不同時無法逐位比對，故該句的正確字數記為 0、所有字位皆標為不同。
  public static func compare(expected: String, actual: String) -> RankingEvalComparison {
    let expectedChars = Array(expected)
    let actualChars = Array(actual)
    guard expectedChars.count == actualChars.count else {
      return RankingEvalComparison(
        isExactMatch: false,
        isLengthMismatch: true,
        correctCharCount: 0,
        diffPositions: Array(expectedChars.indices)
      )
    }
    let diffPositions = expectedChars.indices.filter { expectedChars[$0] != actualChars[$0] }
    return RankingEvalComparison(
      isExactMatch: diffPositions.isEmpty,
      isLengthMismatch: false,
      correctCharCount: expectedChars.count - diffPositions.count,
      diffPositions: diffPositions
    )
  }

  /// 產生與漢字等寬（全形）的標記列，用於在終端機中對齊標示不同的字位。
  public static func diffMarkerLine(charCount: Int, diffPositions: [Int]) -> String {
    let marked = Set(diffPositions)
    return String((0 ..< charCount).map { marked.contains($0) ? "＾" : "　" })
  }

  /// 以 4 位小數四捨五入的比率；分母為 0 時回傳 0。
  public static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
    guard denominator > 0 else { return 0 }
    let raw = Double(numerator) / Double(denominator)
    return (raw * 10_000).rounded() / 10_000
  }
}

// MARK: - RankingEvalCaseResult

/// 單筆案例的評測結果。
public struct RankingEvalCaseResult: Codable, Hashable, Sendable {
  // MARK: Lifecycle

  public init(
    evalCase: RankingEvalCase,
    actual: String?,
    segments: [String]?,
    comparison: RankingEvalComparison?,
    missingReadings: [String],
    unreachablePositions: [Int]
  ) {
    self.source = evalCase.source
    self.lineNumber = evalCase.lineNumber
    self.expected = evalCase.expected
    self.readings = evalCase.readings
    self.actual = actual
    self.segments = segments
    self.comparison = comparison
    self.missingReadings = missingReadings
    self.unreachablePositions = unreachablePositions
  }

  // MARK: Public

  public let source: String
  public let lineNumber: Int
  public let expected: String
  public let readings: [String]
  /// 實際組句結果；因讀音不在辭典中而跳過時為 nil。
  public let actual: String?
  /// 實際組句的分詞（各節點的值）。
  public let segments: [String]?
  public let comparison: RankingEvalComparison?
  /// 原廠辭典查無的讀音（有任一者即跳過該案例）。
  public let missingReadings: [String]
  /// 預期字並非其讀音之候選的字位：通常代表句子集的讀音標錯，而非組句錯誤。
  public let unreachablePositions: [Int]

  public var isSkipped: Bool { comparison == nil }
  public var isPassed: Bool { comparison?.isExactMatch ?? false }
}

// MARK: - RankingEvalSummary

public struct RankingEvalSummary: Codable, Hashable, Sendable {
  // MARK: Lifecycle

  public init(results: [RankingEvalCaseResult]) {
    let evaluated = results.filter { !$0.isSkipped }
    let missingOccurrences = results.flatMap(\.missingReadings)
    self.totalCases = results.count
    self.evaluatedCases = evaluated.count
    self.skippedCases = results.count - evaluated.count
    self.correctSentences = evaluated.filter(\.isPassed).count
    self.totalChars = evaluated.reduce(0) { $0 + $1.expected.count }
    self.correctChars = evaluated.reduce(0) { $0 + ($1.comparison?.correctCharCount ?? 0) }
    self.lengthMismatchCases = evaluated.filter { $0.comparison?.isLengthMismatch ?? false }.count
    self.casesWithUnreachableChars = results.filter { !$0.unreachablePositions.isEmpty }.count
    self.missingReadingOccurrences = missingOccurrences.count
    self.distinctMissingReadings = Array(Set(missingOccurrences)).sorted()
    self.sentenceAccuracy = RankingEvalMetrics.ratio(correctSentences, evaluatedCases)
    self.charAccuracy = RankingEvalMetrics.ratio(correctChars, totalChars)
  }

  // MARK: Public

  public let totalCases: Int
  public let evaluatedCases: Int
  public let skippedCases: Int
  public let correctSentences: Int
  public let totalChars: Int
  public let correctChars: Int
  public let lengthMismatchCases: Int
  public let casesWithUnreachableChars: Int
  public let missingReadingOccurrences: Int
  public let distinctMissingReadings: [String]
  public let sentenceAccuracy: Double
  public let charAccuracy: Double
}

// MARK: - RankingEvalRunInfo

/// 評測執行條件（寫入 JSON 以便比對不同次執行）。刻意不含時間戳，讓兩次結果可直接 diff。
public struct RankingEvalRunInfo: Codable, Hashable, Sendable {
  // MARK: Lifecycle

  public init(lexiconFileName: String, lexiconByteSize: Int, inputFiles: [String], options: [String: String]) {
    self.lexiconFileName = lexiconFileName
    self.lexiconByteSize = lexiconByteSize
    self.inputFiles = inputFiles
    self.options = options
  }

  // MARK: Public

  public let lexiconFileName: String
  public let lexiconByteSize: Int
  public let inputFiles: [String]
  public let options: [String: String]
}

// MARK: - RankingEvalReport

public struct RankingEvalReport: Codable, Hashable, Sendable {
  // MARK: Lifecycle

  public init(runInfo: RankingEvalRunInfo, results: [RankingEvalCaseResult], parseIssues: [RankingEvalParseIssue]) {
    self.runInfo = runInfo
    self.summary = RankingEvalSummary(results: results)
    self.results = results
    self.parseIssues = parseIssues
  }

  // MARK: Public

  public let runInfo: RankingEvalRunInfo
  public let summary: RankingEvalSummary
  public let results: [RankingEvalCaseResult]
  public let parseIssues: [RankingEvalParseIssue]
}
