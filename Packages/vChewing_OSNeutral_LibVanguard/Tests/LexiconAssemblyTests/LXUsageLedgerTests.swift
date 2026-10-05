// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Testing

@testable import LexiconAssembly

private let baseTimestamp: Double = 1_700_000_000
private let dayInSeconds: Double = 86_400

// MARK: - LXUsageLedgerTests

/// 使用頻次帳本（`LXAssembly.LXUsageLedger`）與其 `LXFacade` 介面之測試。
@Suite(.serialized)
struct LXUsageLedgerTests {
  // MARK: Internal

  /// 記錄：同一「讀音鍵＋詞值」重複記錄會累加次數、並更新最近使用時間。
  @Test
  func testRecordIncrementsCount() {
    let ledger = LXAssembly.LXUsageLedger()
    #expect(ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: baseTimestamp))
    #expect(ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: baseTimestamp + 10))
    #expect(ledger.record(readingKey: "ㄗㄞˋ", value: "在", timestamp: baseTimestamp + 20))

    #expect(ledger.entry(readingKey: "ㄗㄞˋ", value: "再") == .init(count: 2, lastUsed: baseTimestamp + 10))
    #expect(ledger.entry(readingKey: "ㄗㄞˋ", value: "在") == .init(count: 1, lastUsed: baseTimestamp + 20))
    #expect(ledger.entryCount == 2)
    #expect(ledger.isDirty)

    // 時間戳不得倒退。
    ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: baseTimestamp)
    #expect(ledger.entry(readingKey: "ㄗㄞˋ", value: "再") == .init(count: 3, lastUsed: baseTimestamp + 10))

    let ranking = ledger.usageRanking(for: "ㄗㄞˋ", now: baseTimestamp + 20)
    #expect(ranking.map(\.value) == ["再", "在"])
    #expect(ledger.usageRanking(for: "ㄗㄞ", now: baseTimestamp).isEmpty)
  }

  /// 衰減：有效次數＝次數 × 0.5^(距最近使用之時間／半衰期)，半衰期為 180 天。
  @Test
  func testEffectiveCountDecaysWithHalfLife() {
    #expect(LXAssembly.LXUsageLedger.kHalfLifeInSeconds == 180 * dayInSeconds)
    let ledger = LXAssembly.LXUsageLedger()
    (0 ..< 4).forEach { _ in
      ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: baseTimestamp)
    }
    func effective(afterDays days: Double) -> Double {
      ledger.effectiveCount(readingKey: "ㄗㄞˋ", value: "再", now: baseTimestamp + days * dayInSeconds)
    }
    #expect(abs(effective(afterDays: 0) - 4) < 1e-9)
    #expect(abs(effective(afterDays: 180) - 2) < 1e-9)
    #expect(abs(effective(afterDays: 360) - 1) < 1e-9)
    // 時鐘倒退（now 早於最近使用時間）不得放大次數。
    #expect(abs(effective(afterDays: -30) - 4) < 1e-9)
    #expect(ledger.effectiveCount(readingKey: "ㄗㄞˋ", value: "在", now: baseTimestamp) == 0)

    // 排序以衰減後的有效次數為準：舊而多者可被新而少者超越。
    ledger.record(readingKey: "ㄗㄞˋ", value: "在", timestamp: baseTimestamp + 400 * dayInSeconds)
    ledger.record(readingKey: "ㄗㄞˋ", value: "在", timestamp: baseTimestamp + 400 * dayInSeconds)
    let ranking = ledger.usageRanking(for: "ㄗㄞˋ", now: baseTimestamp + 400 * dayInSeconds)
    #expect(ranking.map(\.value) == ["在", "再"])
  }

  /// 容量：超出時淘汰最久未使用者（重複記錄會刷新其新近度）。
  @Test
  func testLRUEvictionDropsLeastRecentlyUsed() {
    let ledger = LXAssembly.LXUsageLedger(capacity: 3)
    ledger.record(readingKey: "ㄚ", value: "啊", timestamp: baseTimestamp)
    ledger.record(readingKey: "ㄅㄚ", value: "八", timestamp: baseTimestamp + 1)
    ledger.record(readingKey: "ㄘㄚ", value: "擦", timestamp: baseTimestamp + 2)
    // 刷新「啊」：此時最久未使用者為「八」。
    ledger.record(readingKey: "ㄚ", value: "啊", timestamp: baseTimestamp + 3)
    ledger.record(readingKey: "ㄉㄚ", value: "大", timestamp: baseTimestamp + 4)

    #expect(ledger.entryCount == 3)
    #expect(ledger.entry(readingKey: "ㄅㄚ", value: "八") == nil)
    #expect(ledger.entry(readingKey: "ㄚ", value: "啊")?.count == 2)
    #expect(ledger.entry(readingKey: "ㄘㄚ", value: "擦") != nil)
    #expect(ledger.entry(readingKey: "ㄉㄚ", value: "大") != nil)

    // 縮小容量亦即時淘汰。
    ledger.setCapacity(1)
    #expect(ledger.entryCount == 1)
    #expect(ledger.entry(readingKey: "ㄉㄚ", value: "大") != nil)
    #expect(LXAssembly.LXUsageLedger().record(readingKey: "ㄚ", value: "啊", timestamp: 0))
    #expect(LXAssembly.LXUsageLedger.kDefaultCapacity == 8_192)
  }

  /// 標點／符號（讀音以 `_` 開頭）、空詞值、空讀音一律不記錄。
  @Test
  func testPunctuationAndEmptyValuesAreSkipped() {
    let ledger = LXAssembly.LXUsageLedger()
    #expect(!ledger.record(readingKey: "_punctuation_,", value: "，", timestamp: baseTimestamp))
    #expect(!ledger.record(readingKey: "ㄗㄞˋ-_punctuation_,", value: "再，", timestamp: baseTimestamp))
    #expect(!ledger.record(readingKey: "ㄗㄞˋ", value: "", timestamp: baseTimestamp))
    #expect(!ledger.record(readingKey: "", value: "再", timestamp: baseTimestamp))
    #expect(!ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: .nan))
    #expect(ledger.entryCount == 0)
    #expect(!ledger.isDirty)

    // 批次記錄：只略過不合規者。
    let changed = ledger.record(
      [(readingKey: "_punctuation_,", value: "，"), (readingKey: "ㄨㄛˇ-ㄗㄞˋ", value: "我再")],
      timestamp: baseTimestamp
    )
    #expect(changed)
    #expect(ledger.entryCount == 1)
    #expect(ledger.entry(readingKey: "ㄨㄛˇ-ㄗㄞˋ", value: "我再")?.count == 1)
  }

  /// JSON 快照往返：內容、次數、時間戳皆須保持；存檔後清除髒旗標。
  @Test
  func testJSONRoundTrip() throws {
    let url = makeTempURL("roundtrip")
    defer { try? FileManager.default.removeItem(at: url) }
    let ledger = LXAssembly.LXUsageLedger(dataURL: url)
    ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: baseTimestamp)
    ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: baseTimestamp + 5)
    ledger.record(readingKey: "ㄨㄛˇ-ㄗㄞˋ", value: "我再", timestamp: baseTimestamp + 1)
    ledger.saveData()
    #expect(!ledger.isDirty)
    #expect(FileManager.default.fileExists(atPath: url.path))

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(json?["version"] as? Int == LXAssembly.LXUsageLedger.kSnapshotVersion)
    #expect((json?["entries"] as? [[String: Any]])?.count == 2)

    let reloaded = LXAssembly.LXUsageLedger()
    reloaded.loadData(fromURL: url)
    #expect(reloaded.entryCount == 2)
    #expect(!reloaded.isDirty)
    #expect(reloaded.entry(readingKey: "ㄗㄞˋ", value: "再") == .init(count: 2, lastUsed: baseTimestamp + 5))
    #expect(reloaded.entry(readingKey: "ㄨㄛˇ-ㄗㄞˋ", value: "我再") == .init(count: 1, lastUsed: baseTimestamp + 1))

    // 未變更時不重寫檔案。
    try FileManager.default.removeItem(at: url)
    reloaded.saveData(toURL: url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  /// 載入驗證：不合規的個別帳目被略過，其餘照常載入；重複帳目合併；格式版本不符則整份不載入。
  @Test
  func testMalformedEntriesAreIgnoredOnLoad() throws {
    let url = makeTempURL("malformed")
    defer { try? FileManager.default.removeItem(at: url) }
    let json = """
    {"version":1,"entries":[
      {"k":"ㄗㄞˋ","v":"再","c":3,"t":1700000000},
      {"k":"ㄗㄞˋ","v":"再","c":2,"t":1700000100},
      {"k":"ㄗㄞˋ","v":"在","c":"many","t":1700000000},
      {"k":"ㄗㄞˋ","v":"載"},
      {"k":"_punctuation_,","v":"，","c":9,"t":1700000000},
      {"k":"ㄗㄞˋ","v":"","c":1,"t":1700000000},
      {"k":"ㄗㄞˋ","v":"崽","c":0,"t":1700000000},
      {"k":"ㄗㄞˋ","v":"仔","c":-4,"t":1700000000},
      "garbage",
      {"k":"ㄨㄛˇ","v":"我","c":1,"t":1700000000}
    ]}
    """
    try json.write(to: url, atomically: true, encoding: .utf8)
    let ledger = LXAssembly.LXUsageLedger()
    ledger.loadData(fromURL: url)
    #expect(ledger.entryCount == 2)
    #expect(ledger.entry(readingKey: "ㄗㄞˋ", value: "再") == .init(count: 5, lastUsed: 1_700_000_100))
    #expect(ledger.entry(readingKey: "ㄨㄛˇ", value: "我")?.count == 1)

    // 不相容的格式版本：保留記憶體現狀，不載入。
    try #"{"version":99,"entries":[{"k":"ㄅㄚ","v":"八","c":1,"t":1}]}"#
      .write(to: url, atomically: true, encoding: .utf8)
    ledger.loadData(fromURL: url)
    #expect(ledger.entryCount == 2)
    #expect(ledger.entry(readingKey: "ㄅㄚ", value: "八") == nil)

    // 毀損的檔案：同樣保留現狀。
    try "{ not json".write(to: url, atomically: true, encoding: .utf8)
    ledger.loadData(fromURL: url)
    #expect(ledger.entryCount == 2)

    // 不存在的檔案：視為空帳本。
    try FileManager.default.removeItem(at: url)
    ledger.loadData(fromURL: url)
    #expect(ledger.entryCount == 0)
  }

  /// 清除：記憶體清空，磁碟上留下一份空白快照。
  @Test
  func testClearDataWipesMemoryAndDisk() throws {
    let url = makeTempURL("clear")
    defer { try? FileManager.default.removeItem(at: url) }
    let ledger = LXAssembly.LXUsageLedger(dataURL: url)
    ledger.record(readingKey: "ㄗㄞˋ", value: "再", timestamp: baseTimestamp)
    ledger.saveData()
    let generationBeforeClear = ledger.generation

    ledger.clearData(withURL: url)
    #expect(ledger.entryCount == 0)
    #expect(ledger.usageRanking(for: "ㄗㄞˋ", now: baseTimestamp).isEmpty)
    #expect(ledger.generation != generationBeforeClear)
    #expect(!ledger.isDirty)

    let reloaded = LXAssembly.LXUsageLedger()
    reloaded.record(readingKey: "ㄅㄚ", value: "八", timestamp: baseTimestamp)
    reloaded.loadData(fromURL: url)
    #expect(reloaded.entryCount == 0)
  }

  /// `LXFacade` 介面：讀音陣列以 `-` 串接為讀音鍵；停用時不記錄亦不提供排序；
  /// 存檔回呼在帳本的鎖外執行；帳本變更不影響 POM 世代計數器。
  @Test
  func testFacadeSurface() {
    let facade = LXAssembly.LXFacade()
    let pomGenerationBefore = LXAssembly.LXFacade.pomGeneration
    var saveCallbackCount = 0
    var lockHeldDuringCallback = false
    facade.recordUsage(
      [(keyArray: ["ㄨㄛˇ", "ㄗㄞˋ"], value: "我再"), (keyArray: ["_punctuation_,"], value: "，")],
      timestamp: baseTimestamp,
      saveCallback: {
        saveCallbackCount += 1
        lockHeldDuringCallback = facade.lxUsageLedger.isLockHeld
      }
    )
    #expect(saveCallbackCount == 1)
    #expect(!lockHeldDuringCallback)
    #expect(facade.lxUsageLedger.entry(readingKey: "ㄨㄛˇ-ㄗㄞˋ", value: "我再")?.count == 1)
    #expect(facade.usageRanking(keyArray: ["ㄨㄛˇ", "ㄗㄞˋ"], now: baseTimestamp).map(\.value) == ["我再"])
    #expect(LXAssembly.LXFacade.pomGeneration == pomGenerationBefore)

    // 只含不可記錄之字詞：不觸發存檔回呼。
    facade.recordUsage([(keyArray: ["_punctuation_,"], value: "，")], timestamp: baseTimestamp) {
      saveCallbackCount += 1
    }
    #expect(saveCallbackCount == 1)

    // 停用。
    facade.isUsageLedgerEnabled = false
    facade.recordUsage([(keyArray: ["ㄗㄞˋ"], value: "再")], timestamp: baseTimestamp) {
      saveCallbackCount += 1
    }
    #expect(saveCallbackCount == 1)
    #expect(facade.lxUsageLedger.entry(readingKey: "ㄗㄞˋ", value: "再") == nil)
    #expect(facade.usageRanking(keyArray: ["ㄨㄛˇ", "ㄗㄞˋ"], now: baseTimestamp).isEmpty)

    // 重新啟用後，既有帳目仍在。
    facade.isUsageLedgerEnabled = true
    #expect(facade.usageRanking(keyArray: ["ㄨㄛˇ", "ㄗㄞˋ"], now: baseTimestamp).count == 1)
    facade.clearUsageLedger()
    #expect(facade.usageRanking(keyArray: ["ㄨㄛˇ", "ㄗㄞˋ"], now: baseTimestamp).isEmpty)
  }

  // MARK: Private

  private func makeTempURL(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("vChewing_test_usage_ledger_\(name)_\(UUID().uuidString).json")
  }
}
