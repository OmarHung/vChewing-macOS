// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

extension RankingEvalReport {
  /// 以穩定的鍵序與縮排輸出 JSON，讓不同次執行的結果可直接以 diff 比對。
  public func encodedJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// 終端機用的文字報表。
  /// - Parameter includePassingCases: 是否一併列出通過的案例。
  public func renderedText(includePassingCases: Bool = false) -> String {
    var lines: [String] = []
    lines.append("== vChewing Ranking Eval ==")
    lines.append("Lexicon: \(runInfo.lexiconFileName) (\(runInfo.lexiconByteSize) bytes)")
    lines.append("Inputs : \(runInfo.inputFiles.joined(separator: ", "))")
    let optionText = runInfo.options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    lines.append("Options: \(optionText.joined(separator: ", "))")
    lines.append("")

    if !parseIssues.isEmpty {
      lines.append("-- Parse issues (\(parseIssues.count)) --")
      parseIssues.forEach { issue in
        lines.append("  \(issue.source):\(issue.lineNumber): \(issue.message)")
      }
      lines.append("")
    }

    let failing = results.filter { !$0.isSkipped && !$0.isPassed }
    if !failing.isEmpty {
      lines.append("-- Failing cases (\(failing.count)) --")
      failing.forEach { lines.append(contentsOf: Self.renderCase($0, tag: "FAIL")) }
      lines.append("")
    }

    let skipped = results.filter(\.isSkipped)
    if !skipped.isEmpty {
      lines.append("-- Skipped cases: readings missing from lexicon (\(skipped.count)) --")
      skipped.forEach { result in
        lines.append(
          "  \(result.source):\(result.lineNumber) \(result.expected) missing: \(result.missingReadings.joined(separator: " "))"
        )
      }
      lines.append("")
    }

    let unreachable = results.filter { !$0.unreachablePositions.isEmpty }
    if !unreachable.isEmpty {
      lines.append("-- Expected chars not offered for their reading (check the seed readings) --")
      unreachable.forEach { result in
        let detail = result.unreachablePositions.map { position -> String in
          let char = Array(result.expected)[position]
          return "\(char)@\(position)=\(result.readings[position])"
        }
        lines.append("  \(result.source):\(result.lineNumber) \(result.expected): \(detail.joined(separator: ", "))")
      }
      lines.append("")
    }

    if includePassingCases {
      let passing = results.filter(\.isPassed)
      lines.append("-- Passing cases (\(passing.count)) --")
      passing.forEach { result in
        lines.append("  PASS \(result.source):\(result.lineNumber) \((result.segments ?? []).joined(separator: " "))")
      }
      lines.append("")
    }

    lines.append(contentsOf: summary.renderedLines())
    return lines.joined(separator: "\n")
  }

  // MARK: Private

  private static func renderCase(_ result: RankingEvalCaseResult, tag: String) -> [String] {
    var lines: [String] = []
    lines.append("  \(tag) \(result.source):\(result.lineNumber)")
    lines.append("    expected: \(result.expected)")
    lines.append("    actual  : \(result.actual ?? "")")
    if let comparison = result.comparison {
      if comparison.isLengthMismatch {
        lines.append("    diff    : (length mismatch, counted as all wrong)")
      } else {
        let markers = RankingEvalMetrics.diffMarkerLine(
          charCount: result.expected.count,
          diffPositions: comparison.diffPositions
        )
        lines.append("    diff    : \(markers)")
      }
    }
    lines.append("    segments: \((result.segments ?? []).joined(separator: " "))")
    lines.append("    readings: \(result.readings.joined(separator: " "))")
    return lines
  }
}

extension RankingEvalSummary {
  public func renderedLines() -> [String] {
    [
      "-- Summary --",
      "  Cases total            : \(totalCases)",
      "  Cases evaluated        : \(evaluatedCases)",
      "  Cases skipped          : \(skippedCases) (missing reading occurrences: \(missingReadingOccurrences))",
      "  Sentence accuracy      : \(correctSentences)/\(evaluatedCases) = \(Self.percent(sentenceAccuracy))",
      "  Character accuracy     : \(correctChars)/\(totalChars) = \(Self.percent(charAccuracy))",
      "  Length-mismatch cases  : \(lengthMismatchCases)",
      "  Cases w/ unreachable ch: \(casesWithUnreachableChars)",
    ] + (distinctMissingReadings.isEmpty ? [] : [
      "  Missing readings       : \(distinctMissingReadings.joined(separator: " "))",
    ])
  }

  static func percent(_ value: Double) -> String {
    String(format: "%.2f%%", value * 100)
  }
}
