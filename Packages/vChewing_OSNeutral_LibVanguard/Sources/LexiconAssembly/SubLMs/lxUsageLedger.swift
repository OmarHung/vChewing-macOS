// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Shared
import SwiftExtension

// MARK: - LXAssembly.LXUsageLedger

extension LXAssembly {
  /// 使用頻次帳本：長期、逐使用者地統計「實際遞交過的字詞」。
  ///
  /// 與漸退記憶模組（POM）的分工：
  /// - POM 記住的是「修正」（使用者在某個上下文裡把預設結果改成了什麼），壽命約 8 天；
  /// - 本帳本記住的是「實際常用」——不論是否顯式選字，每次遞交的每個字詞都會被計數一次，
  ///   並以 `kHalfLifeInSeconds`（180 天）的半衰期緩慢衰減。
  ///
  /// 鍵為「讀音鍵＋詞值」：讀音鍵係以 `-` 串接的讀音（例：`ㄗㄞˋ`、`ㄨㄛˇ-ㄗㄞˋ`）。
  /// 讀音任一段以 `_` 開頭者（標點、符號等）與空詞值一律不記錄。
  ///
  /// 容量：以「讀音鍵＋詞值」的組合數計，預設 `kDefaultCapacity`（8,192）筆；超出時淘汰最久未使用者（LRU）。
  ///
  /// 本帳本目前**只**影響候選窗排序，不注入 `unigramsFor`（亦即不影響組句 DP）。
  /// 讓帳本參與組句是刻意留待後續階段評估的工作；屆時須把 `generation` 併入
  /// `LXFacade.currentGramCacheFingerprint`，否則檢索快取不會隨帳本更新而失效。
  ///
  /// **取鎖紀律**：所有可變狀態皆以單一 `lock` 保護；磁碟 I/O、JSON 編解碼與任何回呼一律在鎖外執行。
  public final class LXUsageLedger {
    // MARK: Lifecycle

    public init(capacity: Int = LXUsageLedger.kDefaultCapacity, dataURL: URL? = nil) {
      self.mutCapacity = max(capacity, 1)
      self.mutDataURL = dataURL
    }

    // MARK: Public

    /// 單筆帳目。
    public struct Entry: Hashable, Sendable {
      /// 累計遞交次數。
      public let count: Int
      /// 最近一次遞交的時間戳（Unix 秒）。
      public let lastUsed: Double
    }

    /// 衰減半衰期：180 天。
    ///
    /// 取值理由：POM 的 8 天壽命負責「最近的修正」，本帳本則反映以「月」計的長期習慣；
    /// 180 天讓一年前常用、此後再未用過的字詞只剩約四分之一的權重，而持續使用的字詞
    /// 因每次遞交都會刷新 `lastUsed` 而幾乎不衰減。
    public static let kHalfLifeInSeconds: Double = 180 * 86_400
    /// 預設容量（「讀音鍵＋詞值」組合數）。
    public static let kDefaultCapacity: Int = 8_192
    /// 持久化快照的格式版本。
    public static let kSnapshotVersion: Int = 1
    /// 讀音鍵的段落分隔符（與 `LXFacade` 的 keyChain 一致）。
    public static let kReadingSeparator: Character = "-"

    /// 帳目內容的世代計數器：每次內容變更時遞增。
    public var generation: Int {
      lock.withLock { mutGeneration }
    }

    /// 是否有尚未落盤的變更。
    public var isDirty: Bool {
      lock.withLock { mutIsDirty }
    }

    /// 目前的帳目筆數（「讀音鍵＋詞值」組合數）。
    public var entryCount: Int {
      lock.withLock { mutEntryCount }
    }

    /// 預設的儲存位置。
    public var dataURL: URL? {
      get { lock.withLock { mutDataURL } }
      set { lock.withLock { mutDataURL = newValue } }
    }

    /// 判斷給定的讀音鍵與詞值是否可被記錄。
    public static func isRecordable(readingKey: String, value: String) -> Bool {
      guard !readingKey.isEmpty, !value.isEmpty else { return false }
      return !readingKey.split(separator: kReadingSeparator).contains { $0.isEmpty || $0.hasPrefix("_") }
    }

    /// 以半衰期計算衰減後的有效次數：`count × 0.5^(age / halfLife)`。
    public static func decayedCount(count: Int, lastUsed: Double, now: Double) -> Double {
      guard count > 0 else { return 0 }
      let age = max(0, now - lastUsed)
      return Double(count) * pow(0.5, age / kHalfLifeInSeconds)
    }

    public func setCapacity(_ capacity: Int) {
      lock.withLock {
        mutCapacity = max(capacity, 1)
        evictIfNeeded()
      }
    }

    /// 記錄一次遞交。
    /// - Returns: 帳本是否因此而有變更（不可記錄的輸入會被略過）。
    @discardableResult
    public func record(readingKey: String, value: String, timestamp: Double) -> Bool {
      record([(readingKey: readingKey, value: value)], timestamp: timestamp)
    }

    /// 批次記錄一次遞交中的多個字詞。
    /// - Returns: 帳本是否因此而有變更。
    @discardableResult
    public func record(_ pairs: [(readingKey: String, value: String)], timestamp: Double) -> Bool {
      let validPairs = pairs.filter { Self.isRecordable(readingKey: $0.readingKey, value: $0.value) }
      guard !validPairs.isEmpty, timestamp.isFinite else { return false }
      lock.withLock {
        validPairs.forEach { pair in
          let existing = mutEntries[pair.readingKey]?[pair.value]
          if existing == nil { mutEntryCount += 1 }
          let oldCount = existing?.entry.count ?? 0
          let newEntry = Entry(
            count: oldCount < Int.max ? oldCount + 1 : oldCount,
            lastUsed: max(existing?.entry.lastUsed ?? timestamp, timestamp)
          )
          mutEntries[pair.readingKey, default: [:]][pair.value] = .init(
            entry: newEntry, sequence: nextSequence()
          )
        }
        evictIfNeeded()
        markMutated()
      }
      return true
    }

    /// 取得單筆帳目（未衰減的原始資料）。
    public func entry(readingKey: String, value: String) -> Entry? {
      lock.withLock { mutEntries[readingKey]?[value]?.entry }
    }

    /// 取得單筆帳目在 `now` 時刻的有效次數。
    public func effectiveCount(readingKey: String, value: String, now: Double) -> Double {
      guard let entry = entry(readingKey: readingKey, value: value) else { return 0 }
      return Self.decayedCount(count: entry.count, lastUsed: entry.lastUsed, now: now)
    }

    /// 取得某讀音鍵底下所有詞值的有效次數，依有效次數降冪排列（同分者依詞值排序以求穩定）。
    public func usageRanking(
      for readingKey: String,
      now: Double = Date().timeIntervalSince1970
    )
      -> [(value: String, effectiveCount: Double)] {
      let bucket: [String: Slot] = lock.withLock { mutEntries[readingKey] ?? [:] }
      return bucket.compactMap { value, slot -> (value: String, effectiveCount: Double)? in
        let score = Self.decayedCount(count: slot.entry.count, lastUsed: slot.entry.lastUsed, now: now)
        guard score > 0 else { return nil }
        return (value, score)
      }.sorted {
        $0.effectiveCount != $1.effectiveCount ? $0.effectiveCount > $1.effectiveCount : $0.value < $1.value
      }
    }

    /// 清空記憶體中的帳目。
    public func clearData() {
      lock.withLock {
        mutEntries.removeAll()
        mutEntryCount = 0
        markMutated()
      }
    }

    /// 同時清空記憶體與磁碟上的帳目（磁碟上會留下一份空白快照）。
    public func clearData(withURL fileURL: URL? = nil) {
      clearData()
      saveData(toURL: fileURL, force: true)
    }

    /// 將帳目以 JSON 快照寫入磁碟。
    /// - Parameters:
    ///   - fileURL: 可選的儲存路徑，覆寫預設位置。
    ///   - force: 即使沒有尚未落盤的變更也照寫。
    public func saveData(toURL fileURL: URL? = nil, force: Bool = false) {
      // 先在鎖內取快照，I/O 一律在鎖外進行。
      let snapshot: (url: URL, entries: [SnapshotEntry], generation: Int)? = lock.withLock {
        guard let url = fileURL ?? mutDataURL else { return nil }
        guard force || mutIsDirty else { return nil }
        let entries = mutEntries.flatMap { readingKey, bucket in
          bucket.map { value, slot in
            SnapshotEntry(k: readingKey, v: value, c: slot.entry.count, t: slot.entry.lastUsed)
          }
        }
        return (url, entries, mutGeneration)
      }
      guard let snapshot else { return }
      let sortedEntries = snapshot.entries.sorted {
        $0.t != $1.t ? $0.t > $1.t : ($0.k, $0.v) < ($1.k, $1.v)
      }
      do {
        let encoder = JSONEncoder()
        if #available(macOS 10.13, *) {
          encoder.outputFormatting = .sortedKeys
        }
        let data = try encoder.encode(Snapshot(version: Self.kSnapshotVersion, entries: sortedEntries))
        try data.write(to: snapshot.url, options: .atomic)
      } catch {
        vCLMLog("UsageLedger Error: Unable to save data. Details: \(error)")
        return
      }
      lock.withLock {
        // 寫檔期間若又有新的變更，則保留髒旗標，待下次存檔。
        if mutGeneration == snapshot.generation { mutIsDirty = false }
      }
    }

    /// 從磁碟載入帳目（取代記憶體中的現有帳目）。
    ///
    /// 檔案不存在時視為空帳本；格式版本不相容或檔案毀損時保留記憶體現狀並記錄日誌；
    /// 個別不合規的帳目（缺欄位、型別錯誤、讀音以 `_` 開頭、次數非正、時間戳非有限值）會被略過。
    public func loadData(fromURL fileURL: URL? = nil) {
      guard let url = fileURL ?? dataURL else { return }
      guard FileManager.default.fileExists(atPath: url.path) else {
        loadData(from: [])
        lock.withLock { mutIsDirty = false }
        return
      }
      do {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(LossySnapshot.self, from: data)
        guard decoded.version == Self.kSnapshotVersion else {
          vCLMLog("UsageLedger Error: Unsupported snapshot version \(decoded.version).")
          return
        }
        loadData(from: decoded.entries.compactMap(\.value))
        lock.withLock { mutIsDirty = false }
      } catch {
        vCLMLog("UsageLedger Error: Unable to load data. Details: \(error)")
      }
    }

    // MARK: Internal

    /// 快照中的單筆帳目（欄位名稱刻意縮短以節省磁碟空間）。
    struct SnapshotEntry: Codable, Hashable {
      /// 讀音鍵。
      let k: String
      /// 詞值。
      let v: String
      /// 次數。
      let c: Int
      /// 最近一次使用的時間戳。
      let t: Double
    }

    /// 僅供測試：本類別的鎖目前是否被取用（用以斷言「回呼與 I/O 一律在鎖外執行」）。
    var isLockHeld: Bool {
      let acquired = lock.try()
      if acquired { lock.unlock() }
      return !acquired
    }

    /// 以已驗證的快照帳目取代記憶體中的帳目。重複的「讀音鍵＋詞值」會合併（次數相加、時間取較新者）；
    /// 超出容量時保留最近使用者。
    func loadData(from snapshotEntries: [SnapshotEntry]) {
      var merged: [String: [String: Entry]] = [:]
      snapshotEntries.forEach { item in
        guard Self.isRecordable(readingKey: item.k, value: item.v) else { return }
        guard item.c > 0, item.t.isFinite, item.t >= 0 else { return }
        if let existing = merged[item.k]?[item.v] {
          let (sum, overflow) = existing.count.addingReportingOverflow(item.c)
          merged[item.k]?[item.v] = Entry(
            count: overflow ? Int.max : sum, lastUsed: max(existing.lastUsed, item.t)
          )
        } else {
          merged[item.k, default: [:]][item.v] = Entry(count: item.c, lastUsed: item.t)
        }
      }
      // 依最近使用時間由舊到新指派 LRU 序號，令淘汰順序與時間戳一致。
      let ordered = merged.flatMap { readingKey, bucket in
        bucket.map { (readingKey: readingKey, value: $0.key, entry: $0.value) }
      }.sorted {
        $0.entry.lastUsed != $1.entry.lastUsed
          ? $0.entry.lastUsed < $1.entry.lastUsed
          : ($0.readingKey, $0.value) < ($1.readingKey, $1.value)
      }
      lock.withLock {
        mutEntries.removeAll()
        mutEntryCount = 0
        mutSequence = 0
        ordered.forEach { item in
          mutEntries[item.readingKey, default: [:]][item.value] = .init(
            entry: item.entry, sequence: nextSequence()
          )
          mutEntryCount += 1
        }
        evictIfNeeded()
        markMutated()
      }
    }

    // MARK: Private

    /// 記憶體中的帳目槽：帳目本體＋LRU 序號（序號只存在於記憶體中）。
    private struct Slot {
      let entry: Entry
      let sequence: UInt64
    }

    private struct Snapshot: Encodable {
      let version: Int
      let entries: [SnapshotEntry]
    }

    /// 寬鬆解碼的快照：個別帳目解碼失敗時以 `nil` 代之，而非令整份快照解碼失敗。
    private struct LossySnapshot: Decodable {
      let version: Int
      let entries: [LossyEntry]
    }

    private struct LossyEntry: Decodable {
      // MARK: Lifecycle

      init(from decoder: any Decoder) throws {
        self.value = try? SnapshotEntry(from: decoder)
      }

      // MARK: Internal

      let value: SnapshotEntry?
    }

    private let lock = NSLock()
    private var mutCapacity: Int
    private var mutDataURL: URL?
    /// 讀音鍵 → 詞值 → 帳目槽。
    private var mutEntries: [String: [String: Slot]] = [:]
    private var mutEntryCount: Int = 0
    private var mutSequence: UInt64 = 0
    private var mutGeneration: Int = 0
    private var mutIsDirty = false

    /// 取得下一個 LRU 序號（須在鎖內呼叫）。
    private func nextSequence() -> UInt64 {
      mutSequence &+= 1
      return mutSequence
    }

    /// 標記內容已變更（須在鎖內呼叫）。
    private func markMutated() {
      mutGeneration &+= 1
      mutIsDirty = true
    }

    /// 超出容量時淘汰 LRU 序號最小者（須在鎖內呼叫）。
    ///
    /// 每淘汰一筆需線性掃描一次；以預設容量 8,192 而言，每次遞交至多多出一次掃描，代價可忽略。
    private func evictIfNeeded() {
      while mutEntryCount > mutCapacity {
        var victim: (readingKey: String, value: String, sequence: UInt64)?
        for (readingKey, bucket) in mutEntries {
          for (value, slot) in bucket where slot.sequence < (victim?.sequence ?? .max) {
            victim = (readingKey, value, slot.sequence)
          }
        }
        guard let victim else { return }
        mutEntries[victim.readingKey]?.removeValue(forKey: victim.value)
        if mutEntries[victim.readingKey]?.isEmpty ?? false {
          mutEntries.removeValue(forKey: victim.readingKey)
        }
        mutEntryCount -= 1
      }
    }
  }
}
