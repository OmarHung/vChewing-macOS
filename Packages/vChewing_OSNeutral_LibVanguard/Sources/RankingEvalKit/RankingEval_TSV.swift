// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - RankingEvalCase

/// 離線組句評測的單筆案例：已知正解句子與其逐字讀音。
public struct RankingEvalCase: Codable, Hashable, Sendable {
  // MARK: Lifecycle

  public init(source: String, lineNumber: Int, expected: String, readings: [String]) {
    self.source = source
    self.lineNumber = lineNumber
    self.expected = expected
    self.readings = readings
  }

  // MARK: Public

  /// 來源檔名（僅供報表辨識，不含路徑）。
  public let source: String
  /// 來源檔內的行號（1 起算）。
  public let lineNumber: Int
  /// 預期的組句結果（僅漢字）。
  public let expected: String
  /// 逐字讀音，數量與 `expected` 的字數相同。
  public let readings: [String]
}

// MARK: - RankingEvalParseIssue

/// TSV 解析時遇到的無效行。
public struct RankingEvalParseIssue: Codable, Hashable, Sendable {
  // MARK: Lifecycle

  public init(source: String, lineNumber: Int, message: String, rawLine: String) {
    self.source = source
    self.lineNumber = lineNumber
    self.message = message
    self.rawLine = rawLine
  }

  // MARK: Public

  public let source: String
  public let lineNumber: Int
  public let message: String
  public let rawLine: String
}

// MARK: - RankingEvalTSV

/// 評測句子集的 TSV 解析器。
///
/// 格式：每行一筆 `預期句子<TAB>讀音1 讀音2 ...`。
/// - 讀音以半形空白分隔，須與辭典索引鍵完全一致（一聲不標、輕聲用 `˙`）。
/// - 以 `#` 開頭的行為註解；空白行忽略。
/// - 讀音數量必須等於預期句子的字數（本評測僅收純漢字句子）。
public enum RankingEvalTSV {
  public static func parse(
    _ text: String,
    source: String
  )
    -> (cases: [RankingEvalCase], issues: [RankingEvalParseIssue]) {
    var cases: [RankingEvalCase] = []
    var issues: [RankingEvalParseIssue] = []
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (index, rawSubstring) in lines.enumerated() {
      let lineNumber = index + 1
      let rawLine = String(rawSubstring)
      let trimmed = rawLine.trimmingSpacesAndTabs()
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      switch parseLine(rawLine) {
      case let .success(parsed):
        cases.append(
          RankingEvalCase(
            source: source,
            lineNumber: lineNumber,
            expected: parsed.expected,
            readings: parsed.readings
          )
        )
      case let .failure(error):
        issues.append(
          RankingEvalParseIssue(
            source: source,
            lineNumber: lineNumber,
            message: error.message,
            rawLine: rawLine
          )
        )
      }
    }
    return (cases, issues)
  }

  // MARK: Internal

  struct LineError: Error {
    let message: String
  }

  static func parseLine(_ rawLine: String) -> Result<(expected: String, readings: [String]), LineError> {
    let columns = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    guard columns.count == 2 else {
      return .failure(LineError(message: "Missing TAB separator between sentence and readings."))
    }
    let expected = String(columns[0]).trimmingSpacesAndTabs()
    let readings = columns[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard !expected.isEmpty else {
      return .failure(LineError(message: "Expected sentence is empty."))
    }
    guard !readings.isEmpty else {
      return .failure(LineError(message: "Readings column is empty."))
    }
    guard expected.count == readings.count else {
      return .failure(
        LineError(
          message: "Character count (\(expected.count)) differs from reading count (\(readings.count))."
        )
      )
    }
    return .success((expected, readings))
  }
}

extension String {
  fileprivate func trimmingSpacesAndTabs() -> String {
    let isPadding: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
    guard let first = firstIndex(where: { !isPadding($0) }),
          let last = lastIndex(where: { !isPadding($0) })
    else { return "" }
    return String(self[first ... last])
  }
}
