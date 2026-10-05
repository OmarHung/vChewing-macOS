// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - 刪除重打修正之硬性上限

/// 刪除重打修正：遞交之後，最多只認列幾次（以字元計）在空狀態下放行給客體的 BackSpace。
///
/// 超過此數即視為使用者在做別的事（例如整段改寫），帳本作廢。
public let kMaxRetypeCorrectionDeletions = 3

/// 刪除重打修正：自遞交起算之時間窗（秒）。
///
/// 每次 BackSpace、以及開始重打的第一個按鍵，都必須落在遞交後的這段時間之內；逾時即作廢。
public let kRetypeCorrectionWindowSeconds: TimeInterval = 10

// MARK: - RecentCommitLedger

/// 最近一次遞交之帳本（刪除重打修正偵測用；OS-independent）。
///
/// 情境：使用者打「ㄗㄞˋ」想要「在」，組字器卻給了「再」；使用者遞交之後才發現，於是在客體內按
/// BackSpace 刪掉、再重打一次「ㄗㄞˋ」——若什麼都不記，第二次的條件與第一次完全相同，必然又是「再」。
///
/// 本帳本只保留最近一次遞交，狀態機如下：
/// 1. **已遞交**（`record`）：遞交時快照組句結果、客體識別碼與時間戳。
/// 2. **刪除中**：在空狀態下、輸入法放行給客體的 BackSpace 會遞增 `record.deletedCharCount`。
///    條件：同一客體、時間窗之內、且遞交之後沒有出現任何其他按鍵；上限為
///    `kMaxRetypeCorrectionDeletions` 與已遞交之字元總數。
/// 3. **待命**（`armed`）：刪除至少一個字元之後、使用者開始組字時，把被刪掉的字元對回「尾端的整個節點」；
///    若刪除切在多字節點的中間則作廢。之後只要重打的讀音仍是被刪讀音的前綴，就維持待命。
///
/// 任何其他按鍵、時間窗逾時、客體變更、組字區被清空或中止，皆令帳本作廢。
/// 實際的回應動作（組字時改選次佳候選、候選窗把被否決的值移到最後、遞交時學習）由
/// `InputHandlerProtocol` 的擴充（`InputHandler_RetypeCorrection.swift`）負責。
///
/// - Note: 後續可考慮的加強（本階段不做）：透過 IMK 的 `clientAttributedSubstring` 驗證客體游標前的文字
///   確實已不含被刪掉的字元；此舉需擴充 `SessionClientProxy`。
public struct RecentCommitLedger {
  // MARK: Lifecycle

  public init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
    self.clock = clock
  }

  // MARK: Public

  /// 被遞交的節點快照。
  public struct CommittedNode: Hashable, Sendable {
    // MARK: Lifecycle

    public init(
      keyArray: [String],
      value: String,
      isExplicit: Bool,
      isEligible: Bool,
      pomMemory: POMMemoryTarget? = nil
    ) {
      self.keyArray = keyArray
      self.value = value
      self.isExplicit = isExplicit
      self.isEligible = isEligible
      self.pomMemory = pomMemory
    }

    // MARK: Public

    public let keyArray: [String]
    public let value: String
    /// 是否為使用者顯式選字的結果。
    public let isExplicit: Bool
    /// 可否作為修正對象（標點、`_` 開頭之讀音、讀音錯配、字數與讀音數不符者皆否）。
    public let isEligible: Bool
    /// 若該節點之詞值係由 POM 建議所致，此處記下該筆記憶，以便修正成立時清除之。
    public let pomMemory: POMMemoryTarget?
  }

  /// 一筆 POM 記憶之定位（記憶鍵＋候選）。
  public struct POMMemoryTarget: Hashable, Sendable {
    // MARK: Lifecycle

    public init(ngramKey: String, candidate: String) {
      self.ngramKey = ngramKey
      self.candidate = candidate
    }

    // MARK: Public

    public let ngramKey: String
    public let candidate: String
  }

  /// 最近一次遞交之紀錄。
  public struct CommitRecord: Sendable {
    public let nodes: [CommittedNode]
    public let clientID: String
    public let timestamp: TimeInterval
    /// 遞交之後、在空狀態下放行給客體的 BackSpace 次數（以字元計）。
    public internal(set) var deletedCharCount: Int = 0

    public var totalCharCount: Int { nodes.map(\.value.count).reduce(0, +) }
  }

  /// 待命中的單一修正對象：被刪掉、且正被重打的一個節點。
  public struct CorrectionTarget: Sendable {
    /// 被刪掉（被否決）的節點；其詞值即被否決之值 V。
    public let node: CommittedNode
    /// 該節點在新組字區內所對應的讀音區間（新組字區自 0 起算）。
    public let range: Range<Int>
    /// 已自動改選之替代值 V′（尚未改選者為 `nil`）。
    public internal(set) var substitutedValue: String?
    /// 是否已了結（使用者已顯式選字、或已完成學習）；了結者不再改選、亦不再於候選窗降位。
    public internal(set) var isSettled = false

    public var rejectedValue: String { node.value }
  }

  /// 待命中的修正：被刪掉的尾端節點（依原本順序）。
  public struct ArmedCorrection: Sendable {
    public internal(set) var targets: [CorrectionTarget]
    public let clientID: String

    /// 被刪掉的讀音（依原本順序攤平）。
    public var deletedReadings: [String] { targets.flatMap(\.node.keyArray) }
    /// 是否所有對象皆已了結。
    public var isFullySettled: Bool { targets.allSatisfy(\.isSettled) }
  }

  /// 時鐘（單元測試可注入）。
  public var clock: () -> TimeInterval

  public private(set) var record: CommitRecord?
  public internal(set) var armed: ArmedCorrection?
  /// 每次遞交（無論是否記錄）皆遞增；供按鍵觀察端判斷「本次按鍵是否造成了遞交」。
  public private(set) var commitGeneration: UInt = 0
  /// 每次輸入調度模組分診按鍵時遞增；供會話端判斷「本次按鍵是否繞過了分診」。
  public private(set) var triagedKeyCount: UInt = 0

  /// 帳本是否處於閒置（沒有紀錄、也沒有待命中的修正）。
  public var isIdle: Bool { record == nil && armed == nil }

  /// 記下一次遞交（取代既有紀錄，並解除待命）。
  public mutating func registerCommit(nodes: [CommittedNode], clientID: String) {
    commitGeneration &+= 1
    armed = nil
    record = nodes.isEmpty ? nil : CommitRecord(nodes: nodes, clientID: clientID, timestamp: clock())
  }

  /// 發生了一次無從記錄的遞交（標點、空白、空字串、非組句內容等）：帳本作廢。
  public mutating func registerUnrecordableCommit() {
    commitGeneration &+= 1
    reset()
  }

  /// 帳本作廢。
  public mutating func reset() {
    record = nil
    armed = nil
  }

  /// 僅解除待命（`clear()` 用：遞交之後緊接著的 `clear()` 不得清掉剛記下的紀錄）。
  public mutating func disarm() {
    armed = nil
  }

  /// 在空狀態下、輸入法放行給客體的 BackSpace：試圖累計一次刪除。
  /// - Returns: 是否成功累計；不合條件者帳本作廢並回傳 `false`。
  @discardableResult
  public mutating func registerDeletion(clientID: String) -> Bool {
    guard armed == nil, var currentRecord = record else {
      reset()
      return false
    }
    guard currentRecord.clientID == clientID, isWithinWindow(currentRecord) else {
      reset()
      return false
    }
    let cap = Swift.min(kMaxRetypeCorrectionDeletions, currentRecord.totalCharCount)
    guard currentRecord.deletedCharCount < cap else {
      reset()
      return false
    }
    currentRecord.deletedCharCount += 1
    record = currentRecord
    return true
  }

  /// 使用者開始重打：把刪掉的字元數對回尾端的整個節點，並進入待命。
  /// - Parameter clientID: 當前客體識別碼。
  /// - Returns: 是否成功進入待命；不合條件者帳本作廢並回傳 `false`。
  @discardableResult
  public mutating func armIfPending(clientID: String) -> Bool {
    if armed != nil { return true }
    guard let currentRecord = record, currentRecord.deletedCharCount > 0 else {
      reset()
      return false
    }
    guard currentRecord.clientID == clientID, isWithinWindow(currentRecord) else {
      reset()
      return false
    }
    // 自尾端往前，以字元數對回整個節點；切在多字節點中間者作廢。
    var remaining = currentRecord.deletedCharCount
    var trailingNodes: [CommittedNode] = []
    for node in currentRecord.nodes.reversed() where remaining > 0 {
      remaining -= node.value.count
      trailingNodes.insert(node, at: 0)
    }
    guard remaining == 0, !trailingNodes.isEmpty,
          trailingNodes.allSatisfy(\.isEligible) else {
      reset()
      return false
    }
    var offset = 0
    let targets: [CorrectionTarget] = trailingNodes.map { node in
      defer { offset += node.keyArray.count }
      return CorrectionTarget(node: node, range: offset ..< (offset + node.keyArray.count))
    }
    record = nil
    armed = ArmedCorrection(targets: targets, clientID: currentRecord.clientID)
    return true
  }

  /// 以新組字區當前的讀音（每個位置的所有可能讀音）驗證待命狀態：
  /// 重打的讀音須為被刪讀音的前綴（逐位置比對）；超出被刪讀音長度的部分不予追究。
  /// - Returns: 是否仍維持待命；不符者解除待命並回傳 `false`。
  @discardableResult
  public mutating func validateTypedReadings(_ typedReadings: [[String]]) -> Bool {
    guard let currentArmed = armed else { return false }
    let deleted = currentArmed.deletedReadings
    let comparedCount = Swift.min(deleted.count, typedReadings.count)
    let isPrefix = (0 ..< comparedCount).allSatisfy { typedReadings[$0].contains(deleted[$0]) }
    guard isPrefix else {
      reset()
      return false
    }
    return true
  }

  // MARK: Internal

  mutating func noteTriagedKey() {
    triagedKeyCount &+= 1
  }

  // MARK: Private

  private func isWithinWindow(_ record: CommitRecord) -> Bool {
    let elapsed = clock() - record.timestamp
    return elapsed >= 0 && elapsed <= kRetypeCorrectionWindowSeconds
  }
}
