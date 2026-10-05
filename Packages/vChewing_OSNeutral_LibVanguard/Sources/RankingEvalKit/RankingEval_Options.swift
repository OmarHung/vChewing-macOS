// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - RankingEvalOptions

/// 評測 CLI 的命令列選項。
public struct RankingEvalOptions: Hashable, Sendable {
  // MARK: Lifecycle

  public init(
    inputPaths: [String],
    jsonOutputPath: String? = nil,
    includePassingCases: Bool = false,
    maxSegLength: Int = Self.defaultMaxSegLength,
    rarityThreshold: Double? = nil,
    rareFloor: RareFloorSetting = .assemblerDefault
  ) {
    self.inputPaths = inputPaths
    self.jsonOutputPath = jsonOutputPath
    self.includePassingCases = includePassingCases
    self.maxSegLength = maxSegLength
    self.rarityThreshold = rarityThreshold
    self.rareFloor = rareFloor
  }

  // MARK: Public

  /// 零頻兜底詞每音節代價（`Homa.Assembler.rarePhrasePerSyllableFloor`）的指定方式。
  public enum RareFloorSetting: Hashable, Sendable {
    /// 不指定，沿用組字器的預設值。
    case assemblerDefault
    /// 停用（設為 nil）。
    case off
    /// 指定數值。
    case value(Double)
  }

  public enum ParseOutcome: Hashable, Sendable {
    case run(RankingEvalOptions)
    case showHelp
    case failure(String)
  }

  /// 原廠辭典 TextMap 路徑所用的環境變數名稱（路徑不得寫死或簽入）。
  public static let txtMapEnvironmentKey = "VCHEWING_EVAL_TXTMAP"
  /// 與 `UserDef.kMaxCandidateLength` 的出廠預設值一致。
  public static let defaultMaxSegLength = 10

  public static let usage = """
  Usage: vChewingRankingEval [options] <cases.tsv> [<more.tsv> ...]

  Environment:
    \(txtMapEnvironmentKey)   Path to VanguardFactoryDict4Typing.txtMap (required).

  Options:
    --json <path>            Also write the full report as JSON (stable key order, diff-friendly).
    --show-all               List passing cases as well.
    --max-seg-length <n>     Assembler max segment length (default: \(defaultMaxSegLength)).
    --rarity-threshold <x>   Override Homa.Assembler.rarityThreshold (default: assembler default).
    --rare-floor <x|off>     Override Homa.Assembler.rarePhrasePerSyllableFloor; `off` sets it to nil
                             (default: assembler default).
    -h, --help               Show this help.

  TSV format: one case per line, `expected_sentence<TAB>reading1 reading2 ...`;
  lines starting with `#` are comments.
  """

  public let inputPaths: [String]
  public let jsonOutputPath: String?
  public let includePassingCases: Bool
  public let maxSegLength: Int
  /// nil 表示沿用組字器預設值。
  public let rarityThreshold: Double?
  public let rareFloor: RareFloorSetting

  public static func parse(arguments: [String]) -> ParseOutcome {
    var inputPaths: [String] = []
    var jsonOutputPath: String?
    var includePassingCases = false
    var maxSegLength = defaultMaxSegLength
    var rarityThreshold: Double?
    var rareFloor = RareFloorSetting.assemblerDefault
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "-h", "--help":
        return .showHelp
      case "--show-all":
        includePassingCases = true
      case "--json":
        guard let path = iterator.next(), !path.isEmpty else {
          return .failure("--json requires a file path.")
        }
        jsonOutputPath = path
      case "--max-seg-length":
        guard let rawValue = iterator.next(), let value = Int(rawValue), value > 0 else {
          return .failure("--max-seg-length requires a positive integer.")
        }
        maxSegLength = value
      case "--rarity-threshold":
        guard let rawValue = iterator.next(), let value = Double(rawValue), value.isFinite else {
          return .failure("--rarity-threshold requires a number.")
        }
        rarityThreshold = value
      case "--rare-floor":
        guard let rawValue = iterator.next() else {
          return .failure("--rare-floor requires a number or `off`.")
        }
        if rawValue.lowercased() == "off" {
          rareFloor = .off
        } else if let value = Double(rawValue), value.isFinite {
          rareFloor = .value(value)
        } else {
          return .failure("--rare-floor requires a number or `off`.")
        }
      default:
        guard !argument.hasPrefix("-") else {
          return .failure("Unknown option: \(argument)")
        }
        inputPaths.append(argument)
      }
    }
    guard !inputPaths.isEmpty else {
      return .failure("At least one TSV file is required.")
    }
    return .run(
      RankingEvalOptions(
        inputPaths: inputPaths,
        jsonOutputPath: jsonOutputPath,
        includePassingCases: includePassingCases,
        maxSegLength: maxSegLength,
        rarityThreshold: rarityThreshold,
        rareFloor: rareFloor
      )
    )
  }
}
