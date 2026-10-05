// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import LexiconAssembly
import RankingEvalKit

// MARK: - RankingEvalCLI

/// 離線組句評測 CLI：以真實原廠辭典對已知正解句子組句，計算句正確率與字正確率。
@main
enum RankingEvalCLI {
  static func main() {
    exit(run(arguments: Array(CommandLine.arguments.dropFirst())))
  }

  // MARK: Private

  private enum ExitCode {
    static let success: Int32 = 0
    static let usageError: Int32 = 64
    static let ioError: Int32 = 66
    static let lexiconError: Int32 = 69
  }

  private static func run(arguments: [String]) -> Int32 {
    let options: RankingEvalOptions
    switch RankingEvalOptions.parse(arguments: arguments) {
    case .showHelp:
      print(RankingEvalOptions.usage)
      return ExitCode.success
    case let .failure(message):
      printError(message)
      printError(RankingEvalOptions.usage)
      return ExitCode.usageError
    case let .run(parsed):
      options = parsed
    }

    let envKey = RankingEvalOptions.txtMapEnvironmentKey
    guard let txtMapPath = ProcessInfo.processInfo.environment[envKey], !txtMapPath.isEmpty else {
      printError("Environment variable \(envKey) is not set; point it to VanguardFactoryDict4Typing.txtMap.")
      return ExitCode.usageError
    }

    var allCases: [RankingEvalCase] = []
    var allIssues: [RankingEvalParseIssue] = []
    for path in options.inputPaths {
      let url = URL(fileURLWithPath: path)
      guard let data = FileManager.default.contents(atPath: url.path),
            let text = String(data: data, encoding: .utf8)
      else {
        printError("Cannot read UTF-8 text from: \(path)")
        return ExitCode.ioError
      }
      let parsed = RankingEvalTSV.parse(text, source: url.lastPathComponent)
      allCases += parsed.cases
      allIssues += parsed.issues
    }

    guard let lexiconByteSize = connectLexicon(path: txtMapPath) else {
      printError("Failed to load TextMap lexicon from \(envKey): \(txtMapPath)")
      return ExitCode.lexiconError
    }
    defer { LXAssembly.LXFacade.disconnectFactoryDictionary() }

    let engine = RankingEvalEngine(
      maxSegLength: options.maxSegLength,
      rarityThreshold: options.rarityThreshold,
      rareFloor: options.rareFloor
    )
    let results = allCases.map(engine.evaluate)
    let report = RankingEvalReport(
      runInfo: RankingEvalRunInfo(
        lexiconFileName: URL(fileURLWithPath: txtMapPath).lastPathComponent,
        lexiconByteSize: lexiconByteSize,
        inputFiles: options.inputPaths.map { URL(fileURLWithPath: $0).lastPathComponent },
        options: engine.optionsDescription
      ),
      results: results,
      parseIssues: allIssues
    )
    print(report.renderedText(includePassingCases: options.includePassingCases))

    if let jsonPath = options.jsonOutputPath {
      do {
        try report.encodedJSON().write(to: URL(fileURLWithPath: jsonPath), options: .atomic)
        print("\nJSON report written to: \(jsonPath)")
      } catch {
        printError("Failed to write JSON report to \(jsonPath): \(error.localizedDescription)")
        return ExitCode.ioError
      }
    }
    return ExitCode.success
  }

  /// 同步載入原廠辭典；成功時回傳檔案大小（位元組）。
  private static func connectLexicon(path: String) -> Int? {
    LXAssembly.LXFacade.asyncLoadingUserData = false
    // 已停用非同步載入，故本呼叫返回時載入即已完成，直接檢查載入狀態即可。
    LXAssembly.LXFacade.connectFactoryDictionary(textMapPath: path)
    guard LXAssembly.LXFacade.isFactoryDictionaryLoaded else { return nil }
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
  }

  private static func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
