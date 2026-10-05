# 唯音（vChewing）繁體注音自動選字與候選排序正確性：研究與實作規劃

- 研究基準：`origin/main` @ `977a05fe`（2026-10-05），worktree 分支 `research/candidate-ranking-accuracy`。
- 使用者回報的三個痛點：
  1. 自動選字常選到不合理的字。
  2. 實際常用的字在候選窗沒有往前排。
  3. 「在／再」打錯後刪掉重打，系統仍給同一個錯字，沒有把「刪掉重打」當成修正訊號。
- 本文件先描述現況與根因（含 `file:line` 佐證與真實詞庫數據），再提出分層方案、實作順序與需要決策的事項。

## 一、現況資料流（與本題有關的部分）

```
按鍵 → InputHandler → Homa.Assembler.insertKey → LXFacade.unigramsFor(keyArray)
                                                     ├ 原廠詞庫 unigram（純 unigram，無 bigram）
                                                     ├ 使用者詞／符號／替換／過濾
                                                     └ POM 帶上下文記憶 → 以 bigram／trigram gram 附加
     → Homa.PathFinder（DAG-DP）→ assembledSentence
     → retrievePOMSuggestions(apply:true)（無上下文記憶以 override 套用於游標節點）
選字窗：fetchCandidates（詞長→權重）→ POM 置頂 → 倚天 DOS 單字固定序 → 顯示
使用者選字：consolidateNode → overrideCandidate → makePerceptionIntel → LXPerceptor.memorizePerception
Enter 遞交：commit(text:) → inputHandler.clear()（不留任何紀錄）
```

關鍵檔案（皆在 `Packages/vChewing_OSNeutral_LibVanguard/Sources/`）：

| 元件 | 檔案 |
|---|---|
| DP 尋路 | `Homa/Homa_MainComponents/Homa_PathFinder.swift` |
| 節點計分 | `Homa/Homa_BasicTypes/Homa_Node.swift`（`unigramScore` :188–211、`getScore` :221–293） |
| 候選窗抓取 | `Homa/Homa_MainComponents/Homa_CandidateAPIs_FetchAndApply.swift`（`fetchCandidates` :19–77） |
| 觀測資料 | `Homa/Homa_BasicTypes/Homa_GramInPath.swift`（`makePerceptionIntel` :94–245、`generateKeyForPerception` :368–454） |
| LM 匯流 | `LexiconAssembly/LXFacade.swift`（`unigramsFor` :888–1136） |
| POM | `LexiconAssembly/SubLMs/LXPerceptor.swift`（`calculateWeight` :1206–1256、`fetchSuggestion` :308–366） |
| 選字窗組裝 | `LibVanguard/InputHandler/InputHandler_CoreProtocol.swift`（`generateArrayOfCandidates` :723–798、`retrievePOMSuggestions` :894–986、`consolidateNode` :309–417） |
| 遞交／刪除 | `LibVanguard/InputHandler/InputHandler_HandleStates.swift`（Enter :1076–1135、BackSpace :1143–1298）、`LibVanguard/Session/SessionCoreProtocol.swift` :80–126 |

## 二、研究發現

### 2.1 痛點 1：自動選字選錯

**(F1) 組句模型本質上是純 unigram。** 路徑分數就是各節點 log10 機率的加總（`Homa_PathFinder.swift:84`），沒有長度正規化、沒有轉移機率。原廠詞庫（VanguardLexicon 4.8.6）完全沒有 bigram 資料；`Homa.Gram.previous/anterior` 目前唯一的資料來源是 POM 記憶。詞庫建置端的權重公式為 `log10(e^(len/3−1) · count / norm)`（VanguardLexicon `SubCodes/BaseTypes/Unigram.swift:124–142`），`count` 來自詞頻表，不含任何接續資訊。

**(F2) 「在／再」在詞庫裡幾乎同分。** 以本地建置的真實 `VanguardFactoryDict4Typing.txtMap`（244,209 詞條）查得：

| 讀音鍵 | 詞條與分數 |
|---|---|
| `ㄗㄞˋ` | 在 −5.009、再 −5.012、載 −5.169 |
| `ㄨㄛˇ-ㄗㄞˋ` | 我在 −8.718、我再 −9.32 |
| `ㄗㄞˋ-ㄕˋ` | 在世 −5.131、再世 −6.784、再試 −9.32 |
| `ㄗㄞˋ-ㄅㄚˇ` | 再把 −9.32 |
| `ㄋㄧˇ-ㄗㄞˋ` | 你在 −9.32 |

單字層級兩者差 0.003，等於擲硬幣；而「我在」比「我再」高 0.6，「在世」比「再試」高 4.2，所以「我再試一次」這類句子在沒有上下文模型時系統性偏向「在」。這不是 bug，是模型能力上限。

**(F3) 零頻兜底詞條大量存在且壓過單字組合。** 真實詞庫分數分佈：

| 統計 | 值 |
|---|---|
| 詞條數 | 240,482 |
| 最低／最高 | −9.465／−2.314 |
| p1、p10 | 皆 −9.32（地板值） |
| 落在 −9.32 的詞條 | 29,408（約 12%） |

兩個中等常用單字相加約 −10 ～ −11，一個 −9.32 的「字典有收、語料沒用例」雙字詞反而勝出（例如「你在」−9.32 吞掉「你／再」）。使用者在 `feature/demote-zero-frequency-entries` 分支已針對此做過兩件事（候選窗沉底門檻 −9.2、PathFinder 零頻詞每音節 −6.0 縮放），但該分支基於舊佈局且尚未合併到 `origin/main`。

**(F4) POM 上下文記憶是「全有全無」的開關。** POM 分數落在約 (−0.114, 0]（`LXPerceptor.swift:1206–1256`），而詞庫在 −3 ～ −9；`Node.getScore` 一旦找到 previous 相符的記憶就以其機率「取代」unigram（`Homa_Node.swift:272–283`），不是插值。結果：記憶在 8 天視窗內永遠壓倒詞庫，視窗一過就消失，次數與新舊幾乎不影響結果。

**(F5) 上下文鍵綁死在「整詞分詞」。** 記憶鍵為 `(讀音,值)&(讀音,值)&(讀音,值)` 的整詞節點（`Homa_GramInPath.swift:368–454`）；查詢時 `gram.previous == previous` 必須與 DP 最佳路徑前驅節點的「整個詞值」逐字相等（`Homa_Node.swift:237`）。前一個詞換了分法（檔案 vs 檔／案、分不清 vs 不）就查不到。這正是先前「你再把／清楚」案例的根因（見記憶 `pom-alternatekeys-context-asymmetry`）。

**(F6) DP 只保留每個位置的一條最佳前驅。** 需要靠 bigram 才能勝出的路徑可能在 bigram 被檢查前就被剪掉（`Homa_PathFinder.swift:74–93`，程式註解自稱「近似」）。

**(F7) 潛在 bug：`parent[nextPos]` 存的是 `getScore` 之前取的 `nextGram`。** `Homa_PathFinder.swift:68, 92`：若 `getScore` 內部 `adoptGramForContext` 把節點切到另一個值，當次回溯出來的句子仍是舊值，下一次 `assemble()` 才對。現有測試（`HomaTests_ContextualGrams`、IH709）只涵蓋新舊值相同的情形。需先寫測試重現再修。

**(F8) `Gram.backoff` 從未被讀取。** `Homa_Gram.swift:77` 有欄位，但 Homa／LexiconAssembly／LibVanguard 都沒有用，表示當初預留的 Katz backoff 式平滑從未實作。

### 2.2 痛點 2：常用字沒有往前排

**(F9) 候選窗沒有任何「使用頻次」訊號。** `fetchCandidates` 排序鍵是 `(segLength, weight, joinedKey)` 全降冪（`Homa_CandidateAPIs_FetchAndApply.swift:74–76`），`weight` 就是詞庫原始分數。遞交、選字都不會回寫任何計數。使用者詞權重只有手動 boost／nerf 會改（`UserPhraseImpl.swift:243–299`）。

**(F10) 倚天 DOS 固定序預設開啟，並覆蓋單字排序。** `kEnforceETenDOSCandidateSequence` 預設 `true`（`UserDef.swift:724`）。`generateArrayOfCandidates` 先把 POM 建議置頂，接著只要單字候選同屬一個讀音，就重排成 `longerSegments + dedupe(倚天序列 + 原單字)`（`InputHandler_CoreProtocol.swift:768–787`）。因為倚天序列排在前面，**POM 置頂的單字會被推回倚天位置，詞庫頻率排序也被捨棄**。測試 `IH112` 明示「enforcement still reorders candidates」。倚天 `ㄗㄞˋ` 序列為「在再載」（`lxPlainBopomofo_RawData.swift:1068`），所以不論怎麼學，「再」在單字窗內都排第二。這是痛點 2 最直接的原因，而且本機設定未改過此值（即為預設 true）。

**(F11) POM 對候選窗的影響只有「置頂一筆」。** `retrievePOMSuggestions(apply:false)` 回傳的建議過濾後置於最前，再以詞長穩定排序（`InputHandler_CoreProtocol.swift:742–767`）；單字永遠在多字詞之後。`filterPOMAppendables` 會把分數低於原始候選的建議丟掉（`:885`），使用者詞分數 0 時 POM 建議必被丟。

**(F12) 重複確認不會刷新記憶。** `consolidateNode` 若選到的候選恰與現有 POM 建議相同，走 `.withSpecified` 快捷路徑且**不呼叫 memorizePerception**（`InputHandler_CoreProtocol.swift:325–340`）。因此一筆常用記憶自第一次學習起 8 天後必定過期，即使天天在用。反之，開窗後確認「本來就顯示的候選」仍會寫入記憶（`makePerceptionIntel` 不檢查值是否改變）。

**(F13) 其他限制。** 單字使用者詞預設被丟棄（`AllowRescoringSingleKanjiCandidates` 預設 false，本機亦為 0）；POM LRU 容量 500 且所有情境共用；記憶鍵把 head 值包進去，因此每鍵幾乎只有一個候選，`cnt/total ≈ 1`，頻次正規化形同虛設；`alternateKeys` 以 LRU 新舊順序取第一個命中，最近一次選擇壓過長期習慣。

### 2.3 痛點 3：刪掉重打仍給同一個錯字

**(F14) 遞交後不留任何紀錄。** `switchState(.ofCommitting)` → `commit(text:)` → `inputHandler.clear()`（`SessionCoreProtocol.swift:80–126`、`InputHandler_CoreProtocol.swift:241–251`），組字器、讀音、是否為預設選字全部丟掉。沒有 `lastCommit`、undo stack 或 per-client 歷史。

**(F15) 空狀態下的 BackSpace 不被處理。** `handleBackSpace` 在非 `.ofInputting` 時回傳 false（`InputHandler_HandleStates.swift:1154–1157`），事件交給 app 自行刪字；IME 看得到按鍵但不計數。IMK 沒有 `deleteBackward` 回呼，IME 無法得知 app 實際刪了幾個字（可用 `clientAttributedSubstring` 驗證，但 `SessionClientProxy` 尚未暴露該 API）。

**(F16) POM 只有正向證據。** `memorizePerception` 只會 +1（`LXPerceptor.swift:663–714`）；唯一的負向操作是整筆 `bleachSpecifiedSuggestions`。沒有「這個值在這個情境是錯的」的降權 API。

**(F17) Enter 遞交預設選字不學習。** 只有顯式選字才寫 POM（`InputHandler_HandleStates.swift:393–396`）。所以「第二次重打還是給再」是必然：系統對第一次的錯誤一無所知，第二次條件完全相同。

**(F18) 逐字選字模式（SCPC）寫 POM 但永不讀取**（`InputHandler_CoreProtocol.swift:901`、`:744`），而且自動確認的首選會被當成使用者選擇寫入（`HandleCandidate.swift:308–337`），白佔 LRU 名額。

### 2.4 實作期間新增的發現（2026-10-05）

**(F19) 單字 unigram 分數極度壓縮，單字層級幾乎沒有鑑別力。** 真實詞庫 1,662 個單音節讀音鍵的「最高分候選」分佈：p50 −5.231、p90 −5.105、最高 −4.976（的）。來源 `char-kanji-core.txt` 的「頻次」欄最大值 7,700、p90 3,832，顯然是封頂的等級值而非語料頻次：「的」與「在」只差 0.03、「在」與「仔」只差 0.29，真實語料兩者分別相差約 0.6 與 2.6 個數量級。後果：(1) 同音單字的取捨由千分之幾的差距決定，形同隨機；(2) 任何兩個單字相加都落在 −10.1～−10.4，因此任何 −9.32 的零頻雙字詞都穩贏單字組合，也讓「零頻詞每音節下限」這類粗粒度修正無法區分「很像／試過」（該保留）與「你在」（該讓位）。這是資料層的根本問題，修法在 VanguardLexicon 建置端：用真實語料字頻、或由詞表反推字頻（對每個「字＋讀音」加總含它的詞的頻次）重算單字分數。列為 B6，需使用者決定是否動詞庫倉庫。

**(F20) 零頻詞 DP 下限在真實資料上淨負面。** 以 D1 評測集（65 句）實測：下限 −6.0／音節使 44/65 → 43/65，翻錯「很像→很向」「試過→是過」，沒有修好任何一句。故本分支把 DP 下限改為預設關閉（機制保留、可選加），候選窗零頻沉底維持開啟。

**(F7 已證實並修復)** PathFinder `parent[nextPos]` 存的是計分前的 gram：以 mock 詞庫重現「乙＋丙／餅」雙向案例（採用語境 gram 後句子仍顯示舊值；語境失效後仍顯示舊語境值），修為記錄計分後的 `currentGram`，新增 `HomaTests_PathFinderParentGram.swift`。

## 三、改善方案

分四個工作包：A（候選窗排序）、B（自動選字）、C（刪除重打偵測）、D（評測與測試基礎設施）。每項標註對應發現、改動範圍、風險。

### A. 候選窗排序（直接解痛點 2）

**A1. 倚天固定序與學習結果的優先關係（F10）** — 必做、低成本。
- 方案：在 `generateArrayOfCandidates` 中把倚天重排視為「基底順序」，POM 置頂與使用頻次前移在倚天重排**之後**套用；或者讓倚天序只在「沒有任何學習訊號」時生效。
- 也要討論是否把 `kEnforceETenDOSCandidateSequence` 預設改為 false（讓詞庫頻率決定單字順序）。這是行為改變，需使用者定奪；建議至少確保 POM 置頂不被倚天覆蓋。
- 測試：擴充 `IH112*`：有 POM 記憶時單字置頂仍成立。

**A2. 使用頻次計數（F9、F13）** — 核心新功能。
- 新增 OS-independent 的 `lxUsageLedger`（LexiconAssembly 子模組）：遞交時對 `assembledSentence` 每個 `GramInPath` 記錄 `(readingKey, value) → (count, lastUsed)`，不分是否顯式選字（這才是「我實際常用」）。用慢衰減（半衰期以月計）或不衰減，與 POM 的 8 天短期記憶分工。
- 持久化：沿用 `PerceptionPersistor` 的 snapshot+journal 模式，獨立檔案 `vChewing_usage-ledger-{chs,cht}.dat`，在 `LXMgr_Utilities.swift` 同處註冊路徑。
- 消費端一：候選窗。`fetchCandidates` 回傳後、倚天重排後，以 `bonus = β·log10(1+count)` 對同詞長群組內重排（維持詞長優先，避免破壞「敲三音想要三字詞」的既有語義）。
- 消費端二（可選、受 flag 控制）：在 `unigramsFor` 對 unigram 分數加 `min(γ, β·log10(1+count))` 的小幅 bonus，讓常用字在 DP 中也略佔優（補強痛點 1，但要防止壓過長詞）。
- 風險：隱私（檔案存使用者打字統計，與 POM 同級）、容量（以讀音鍵×值為鍵，上限例如 20k 筆 LRU）。

**A3. POM 寫入規則修正（F12）** — 必做、低成本。
- `consolidateNode` 的 POM 快捷路徑也要 `memorizePerception`（刷新 timestamp／cnt）。
- 只在「選取值與先前組句結果不同」時才寫入新記憶；確認既有候選僅刷新。可在 `consolidateNode` 以 `preservedSentenceBeforeConsolidation` 比對，或在 `makePerceptionIntel` 回傳 `isValueChanged`。
- 測試：`POMBasicTests`／`InputHandlerTests_Cases1` 新增「重複確認延長壽命」「確認預設不新增鍵」。

**A4. 移植 `feature/demote-zero-frequency-entries` 的候選窗沉底（F3）** — 已有實作與測試，需改路徑到新佈局（`Homa_CandidateAPIs_FetchAndApply.swift`、`Homa_Assembler.swift`、`HomaTests_RarePhraseScoring.swift`）。

### B. 自動選字（痛點 1）

**B1. 移植零頻詞長度縮放（F3）** — `PathFinder`／`Node.getScore` 對低於 `rarityThreshold` 的 gram 改用 `perSyllableFloor × segLength`。同樣來自既有分支，含測試。

**B2. POM 上下文分數改為插值而非取代（F4）** — 中成本。
- 把 `Node.getScore` 的「bonus gram 機率取代 unigram」改為 `unigramBaseline(該值) + λ·w(cnt, age)`，其中 w ∈ [0,1] 來自 `calculateWeight` 的 `freqFactor·ageFactor`，λ 校準到「一次選擇足以翻轉同分單字（差 < 1），但不足以翻轉差 4 以上的詞庫證據」，重複選擇可逐步提高。
- 這等於把 `7e3f2477`（已在 main 的 log-linear interpolation 思路）套到 POM gram 上，並讓 `Gram.backoff`／cnt 真正參與。
- 需同步調整 `LXFacade.unigramsFor` 注入 POM gram 時的 probability（目前直接塞 POM 分數）。
- 測試：`HomaTests_ContextualGrams`、`POMJoinedTests` AC01–04 需重新校準期望值。

**B3. 上下文鍵的字級退避（F5）** — 中成本。
- 記憶寫入時除整詞鍵外，另存「previous 詞的尾字」版本；查詢時 `getScore` 若整詞 previous 不中，改以 previous 的最後一個字比對（字級 bigram）。
- 可解「分不清／不」「檔案／檔」這類分詞不對稱。需在 `Homa.Gram` 比對處（`Homa_Node.swift:237`）加入 suffix match，或在 LXFacade 注入時同時產生兩種 previous 的 gram。
- 風險：誤命中增加，需配合 B2 的平滑而非硬取代。

**B4. 修 PathFinder parent 記錄時機（F7）** — 先寫測試重現「adopt 後值不同」案例，再把 `parent[nextPos]` 改存 `nodeCopy.currentGram`。

**B6. 重算單字 unigram 分數（F19）** — 資料層、需動 VanguardLexicon 倉庫。
- 由詞表反推字頻：對每個「字＋讀音」加總所有含該字（該讀音位置）的詞條頻次，與既有等級值以可調權重混合，再經原本的 `log10(e^(len/3−1)·count/norm)` 公式；或引入公開語料字頻表。
- 需以 D1 評測集驗證；預期直接改善「是／事」「的／得／地」等單字同音取捨，並讓零頻雙字詞不再穩贏單字組合。

**B5. 原廠 bigram／字級接續先驗（F1、F2）** — 長期。
- 選項 (i)「詞內字對」：從詞庫本身統計「詞內相鄰兩字 (a,b) 的加權頻次」，當 DP 把兩個單字相鄰擺放時，用 P(b|a) 的平滑估計給予小幅 bonus。零外部資料、授權無虞，但只反映詞內接續。
- 選項 (ii) 外部繁中語料訓練字級 bigram，以 TrieKit 已支援的 `value\tprob\ttypeID\tprevious` 行格式注入 txtMap（`TrieTextMap_Core.swift:636, 671`），並讓 `makeFactoryUnigrams` 的 exact 路徑保留 previous（目前 `LXFacade_TextMapExtension.swift:488` 會丟掉）。需評估語料授權與檔案體積。
- 兩者都需要 D1 的離線評測來證明收益。

### C. 「刪掉重打」修正訊號（痛點 3）

**C1. 遞交帳本 `RecentCommitLedger`（F14）** — Session 層、OS-independent。
- 在 `switchState(.ofCommitting)` 之前（`SessionCoreProtocol.swift:93–105`）快照 `assembler.assembledSentence` 的 `[(keyArray, value, isExplicit)]`、`clientBundleIdentifier`、時間戳，只保留最近一筆（或最近幾筆）、數秒 TTL。

**C2. 偵測序列（F15）**
- 在 `.ofEmpty` 收到 BackSpace 且不攔截時，對同一 client 的帳本累計 `deletedCount`（時間窗內、連續）。
- 使用者接著輸入的讀音序列若與帳本尾端被刪掉的 N 個字的讀音完全一致（N = deletedCount），判定為「重打修正」。
- 嚴格條件（降低誤判）：刪除與重打之間沒有其他按鍵；N ≤ 3；時間窗 ≤ 10 秒。

**C3. 回應動作**
- 組字時：對命中的節點把上次遞交的值做一次性降權（`overrideCandidate(.withSpecified, score: 原分數 − δ)` 或在 `unigramsFor` 注入一次性負 bonus），讓次佳候選自然浮現；候選窗把上次的值移到最後。只影響本次組字，`clear()` 後失效。
- 若使用者最終顯式選了 V′，照正常路徑寫 POM（此時上下文已正確），並以新增的 `LXPerceptor.demotePerception(ngramKey, candidate)`（F16，cnt −1 或標記負權重）記錄「V 在此情境是錯的」。
- 若使用者再次 Enter 遞交了次佳候選 V′（未開窗），視為隱式確認，也寫一筆 POM（這是目前 F17 所缺的「預設遞交不學習」的有限補強，僅在修正情境下啟用）。

**C4. 守門與選項**
- 新 UserDef `kRetypeCorrectionDetectionEnabled`（預設建議 true，但先以隱藏 flag 上線觀察）。
- 可選加強：透過 `clientAttributedSubstring` 驗證 app 游標前文字確實已不含被刪字，需擴 `SessionClientProxy`（`SessionClientProxy.swift:13–30`）。
- SCPC 模式不啟用（每字獨立遞交，語義不同）；同時順手修 F18（SCPC 不寫 POM）。

### D. 評測與測試基礎設施

**D1. 離線組句評測 harness。**
- 以本地建置的真實 txtMap（VanguardLexicon：`swift run -c release VCDataBuilder vanguardTextMap`，產物約 13.9 MB）載入 `LXFacade`，對一組「已知正解」句子用 revlookup 產生讀音，跑 `assemble()` 計算句正確率與字正確率，輸出 before／after。
- 句子集來源：使用者提供的常打句子（最貼近痛點），加上少量公開繁中文本。
- 放在 `DevLab/` 或新增 `vChewingSharedCLI` 子命令；txtMap 路徑由環境變數指定，不簽入。
- 這是 B2／B3／B5 任何參數校準的前提。

**D2. 測試現況與限制。**
- Homa 測試可在本機跑（`swift test --build-system native --filter HomaTests`）。
- LibVanguard／LexiconAssembly 測試依賴 `LXAssemblyMaterials4Tests/TestData.swift` 的 `#bundle` 巨集，本機僅有 Command Line Tools、無 `FoundationMacros`，**無法編譯**（2026-10-05 實測 `error: fatalError`）。需 Xcode，或在本機暫時以 `Bundle.module` 替代（不可簽入）。
- `test_IH400_MixedAlnumKanjiInputTest_Izanami`（`InputHandlerTests_Cases4.swift:203`）在本機於**未改動的 HEAD 快照**上即穩定失敗（同一組參數：ai／Dachen、cOS／Dachen、cOS／ETen、ello／Dachen），與本分支改動無關；`IH528` 偶發。暫列為既有問題，另案追查。
- **整個套件一次並行跑（不加 `--filter`）會隨機失敗**（IH101／IH103／test210、或 IH4xx／IH5xx 混打系列），在未改動的 HEAD 快照上兩次重跑皆如此、失敗集合每次不同。成因：LexiconAssembly 測試以 `LXFacade.connectToTestFactoryDictionary` 切換**靜態共用**的測試詞庫，各測試目標在同一行程內並行時互相干擾。請一律逐目標（`--filter '^HomaTests\.'` 等）跑，或加 `--no-parallel`。
- 既有相關測試：`HomaTests_ContextualGrams`、`HomaTests_Trigram`、`POMNGramSourceTests`、`POMJoinedTests`、`InputHandlerTests_POMContextMemory`（IH707–709）、`IH111/IH112/IH112B`（倚天序）。

## 四、建議實作順序

| 階段 | 內容 | 預期效果 | 風險 |
|---|---|---|---|
| 0 | D1 評測 harness；移植 A4、B1（既有分支） | 建立量化基線；零頻詞不再亂入 | 低 |
| 1 | A1（倚天序不覆蓋學習結果）、A3（POM 刷新／不重複寫入） | 常用字開始真的往前排、記憶不會 8 天就忘 | 低；A1 若改預設需使用者同意 |
| 2 | A2 使用頻次帳本（先只影響候選窗，再評估 DP bonus）、B4 | 長期習慣反映在排序 | 中：持久化、容量 |
| 3 | B2 POM 插值、B3 字級退避 | 一次選字可翻轉同分字、分詞不對稱可容忍 | 中：需重校準既有測試 |
| 4 | C1–C4 刪除重打偵測 | 直接解痛點 3 | 中高：誤判；先隱藏 flag |
| 5 | B5 字級接續先驗／外部 bigram | 根本提升自動選字 | 高：資料、體積、授權 |

## 五、需要使用者決策的事項

1. **倚天 DOS 固定序**是否維持預設開啟？若維持，A1 只保證「學習結果可凌駕倚天序」；若關閉，單字改以詞庫頻率排序，與舊習慣不同。
2. **使用頻次**是獨立帳本（建議，職責清楚、可獨立清除）還是併入 POM？
3. **刪除重打偵測**的嚴格度（N 上限、時間窗）與是否預設開啟。
4. **外部語料**：是否接受在 VanguardLexicon 加入字級 bigram 資料（體積、授權、建置時間）。
5. 評測句子集：是否願意提供一批常打句子作為 D1 基準。

## 六、附錄：本次研究用到的環境

- 真實詞庫建置：shallow clone `vChewing-VanguardLexicon`，`swift run -c release VCDataBuilder vanguardTextMap`；txtMap `KEY_LINE_MAP` 的 `start` 欄加 13 才是實際行號。
- 本機偏好值（`defaults read org.atelierInmu.inputmethod.vChewing`）：`FetchSuggestionsFromPerceptionOverrideModel=1`、`UseFixedCandidateOrderOnSelection=0`、`ConsolidateContextOnCandidateSelection=1`、`AllowRescoringSingleKanjiCandidates=0`、`EnforceETenDOSCandidateSequence` 未設（即預設 true）、`UseSCPCTypingMode=0`。
- 使用者既有分支 `feature/demote-zero-frequency-entries`（主 worktree）：`6f1da431`、`983428a0`、`d1345add`，基於舊套件佈局，需移植。

## 七、實作狀態（2026-10-05，分支 `research/candidate-ranking-accuracy`，尚未 commit）

| 項目 | 狀態 | 備註 |
|---|---|---|
| D1 評測 harness | 完成 | `vChewingRankingEval` 執行檔＋`RankingEvalKit`；`DevLab/Eval/` 內有種子句集（65 句）、README、基線 44/65 句、566/594 字。評測以 `VCHEWING_EVAL_TXTMAP` 指向本地建置的真實詞庫。 |
| D2 本機測試工具鏈 | 完成 | `TestData.swift` 加 `VCHEWING_TESTS_NO_BUNDLE_MACRO` 旁路；完整指令見 `DevLab/Eval/README.md`。`HomaTests_Advanced` 的 Regex 改為不依賴 macOS 13。 |
| A4 候選窗零頻沉底 | 完成（移植） | `rarityThreshold = -9.2` 預設開啟。注意：−9.32 地板帶含「我的、你說、走了、很像」等常用詞，沉底是否恰當待使用者定奪。 |
| B1 DP 零頻下限 | 機制保留、預設關閉 | 評測顯示任何生效的下限都淨負面（F20）；`suggestedRarePhrasePerSyllableFloor = -6.0` 供選用。 |
| A1 倚天序為基底、學習結果可凌駕 | 完成 | `promoteLearnedSingles`；SCPC 與 `fixOrder` 行為不變。測試 IH112C／D。 |
| A3 POM 寫入規則 | 完成 | 重複確認 POM 建議會刷新記憶；確認預設候選不再新增記憶。測試 IH710–712；IH204 D1 期望值更新。 |
| A2 使用頻次帳本 | 完成 | `LXUsageLedger`（半衰期 180 天、LRU 8,192、JSON 快照）；遞交匯流點記錄；候選窗同詞長群組內依有效次數前移；偏好 `CandidateUsageLedgerEnabled`（預設開、含設定介面）；Darwin 端檔案 `vChewing_usage-ledger-{chs,cht}.dat`，隨「清除記憶」一併清除。尚未參與 DP 計分。 |
| B2 POM 分數改插值 | 完成 | `LXFacade_POMGramShaping.swift`：注入分數 = 同值 unigram + 6.0·w（w 由記憶強度推得，一次選字約 +3.9）。校準錨點為 IH708／709「檔案室」差距 3.38。 |
| B3 字級退避 | 完成 | 多字 previous 另注入「尾字」版本（×0.8）；Homa `getScore` 允許單字 previous 以尾字比對。 |
| B4 PathFinder parent gram | 完成（確認為真 bug） | 新測試 `HomaTests_PathFinderParentGram`。 |
| C1–C4 刪除重打偵測 | 完成 | `RecentCommitLedger`＋`InputHandler_RetypeCorrection.swift`：遞交快照→空狀態 BackSpace 計數（≤3、10 秒內、同 client、無其他按鍵）→重打相同讀音時以次佳候選替換、候選窗把被拒值移到同詞長群組尾；Enter 隱式確認寫一筆 POM，若被拒值來自 POM 則移除該筆記憶。隱藏偏好 `RetypeCorrectionDetectionEnabled`（預設開）。狂打、SCPC、磁帶模式不啟用。測試 IH730–742。未實作 `clientAttributedSubstring` 驗證。 |
| B6 詞庫字頻重算 | 已實驗、結果為負、預設關閉 | 在 `~/myprojects/vChewing-VanguardLexicon` 分支 `research/char-frequency-from-phrases`（commit 60240ca5）實作「由詞表反推字頻」三種模式（replace／blend／shift，`VC_CHARFREQ_MODE`），種子集 65 句與保留集 44 句皆變差（最好的 shift γ=0.1 仍掉 3＋2 句）。原因：字在詞表內出現的次數不等於它單用的頻率——吧、又、跟、嗎、裡、就這類虛詞很少在詞條內、被壓低，作、市、根、罷這類構詞字被抬高。詳見該倉庫 `ValueAdds/Specs/CharFrequencyFromPhrases.md`。結論：單字分數必須來自真實語料字頻（外部資料），詞表反推不可行。 |
| B5 原廠 bigram | 未動 | 需外部語料；與 B6 結論一致，資料層改善須引入語料。 |
| Phase 5A K-best 組句（F6） | 完成 | `Homa.Assembler.beamWidth`（預設 4、下限 1，`copy` 一併複製）；`PathFinder` 每位置保留至多 K 條路徑（分數、元圖索引、幅節長度、回溯指標、末節點與前驅詞值），以「末節點詞值＋前驅詞值」去重；未覆寫節點另把同節點其餘高分單元圖（至多 K−1 個）派生為獨立狀態，近乎同分的同音字因此可由後方語境決定。回溯後最佳路徑上的節點改指所得元圖、其餘遍歷過的未覆寫節點退回首個單元圖。K=1 與舊 1-best 逐位元一致（測試內附參考實作比對）。隱藏偏好 `AssemblerBeamWidth`（預設 4、限 1…8），每次按鍵同步。效能：release 約 1.35–1.7 倍；debug 壓力測試約 4 倍。評測 K=1／K=4 皆 44/65 句、566/594 字，逐句結果相同。測試 `HomaTests_BeamSearch`。 |
| Phase 5B 語氣詞＋標點元圖 | 完成 | `LXFacade_PunctuationContextGrams.swift`：`_punctuation_` 起首之單鍵（`_punctuation_list` 除外）依標點資料值（？！。，；：）注入「前文為語氣詞」雙元圖，分數＝標點單元圖＋1.0；兩條查詢路徑皆注入、經 LRU 快取。不入選字窗、不入帳本。須 K≥2 才能回頭影響前驅（IH751 記錄此依賴）。測試 `PunctuationContextGramTests`、IH750–752。注意：真實詞庫中「嗎」(−5.118) 本就略勝「媽」(−5.175)，K=1 已組出「你知道我在哪嗎？」；實際使用時的「哪媽？」應來自使用者資料（POM／帳本／使用者片語）使「媽」領先，本機制可翻轉 1.0 以內的差距。評測工具新增 `--beam-width`，TSV 可直接寫標點索引鍵。 |

評測重跑（所有改動就位、POM 關閉）：44/65 句、566/594 字，與基線一致。

已知測試狀態：`test_IH400` 在未改動的 HEAD 上即失敗（既有問題）；Darwin 套件（MainAssembly4Darwin、SettingsUI）在本機無法編譯（CLT 無 SwiftUI 巨集），其改動僅經人工閱讀檢查。
