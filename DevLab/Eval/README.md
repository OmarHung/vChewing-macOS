# 離線組句評測（Ranking Eval）

以**真實原廠辭典**對一組「已知正解」句子做 DAG-DP 自動組句，計算句正確率與字正確率，作為
`DevLab/CandidateRanking_Accuracy_Research_And_Plan.md` §3.D1 所述各項排序改進的前後對照基準。

評測工具為 `Packages/vChewing_OSNeutral_LibVanguard` 內的可執行靶 `vChewingRankingEval`：

- 查詢路徑與 `InputHandler` 相同（`LXFacade.lxQuerier.grams(for:)`／`hasGrams(for:)` 餵給
  `Homa.Assembler`），組字器幅節長度上限預設為 10（同 `kMaxCandidateLength` 出廠值）。
- 辭典選項對齊出廠偏好：繁體、不啟用 CNS、啟用符號、倚天 DOS 單字補充開啟。
- **不載入任何使用者資料**：使用者片語、濾除表、語彙置換皆為空，漸退記憶（POM）停用。
  因此結果反映的是「原廠辭典＋組字引擎」本身的表現。

## 檔案

| 檔案 | 說明 |
|---|---|
| `ranking-eval-seed.tsv` | 開發者撰寫的種子句子集（65 句），集中測試已知易錯字。請勿任意修改，以利前後比較。 |
| `ranking-eval-user.tsv` | 使用者自己的常打句子（初始為空，僅有格式說明）。 |
| `baseline-2026-10-05.md` | 本次建立的基線數字與失敗案例摘要。 |
| `baseline-2026-10-05.json` | 同一次執行的完整 JSON 報表，可與之後的執行結果直接 diff。 |

TSV 格式：每行 `預期句子<TAB>讀音1 讀音2 ...`；`#` 開頭為註解。讀音須與辭典索引鍵一致
（一聲不標、輕聲「˙」置於音節末、不套用變調）。標點可直接寫其索引鍵（如 `_punctuation_?` → 「？」、
`_punctuation_>` → 「。」），以 `_` 起首的讀音改以完整查詢路徑確認是否存在。

## 1. 建置原廠辭典（txtMap）

辭典來自外部倉庫 vChewing-VanguardLexicon（版本以 `Packages/vChewing_MainAssembly4Darwin/Package.swift`
所釘選者為準）。txtMap 為暫時構建產物，**不得簽入本倉庫**。

```sh
git clone https://atomgit.com/vChewing/vChewing-VanguardLexicon.git <任意工作目錄>/VanguardLexicon
cd <任意工作目錄>/VanguardLexicon
swift run -c release VCDataBuilder vanguardTextMap
# 產物：Build/Release/vanguard-textmap/VanguardFactoryDict4Typing.txtMap（約 13.9 MB）
```

## 2. 指定辭典路徑

辭典路徑一律由環境變數指定，程式內不寫死任何路徑：

```sh
export VCHEWING_EVAL_TXTMAP=<任意工作目錄>/VanguardLexicon/Build/Release/vanguard-textmap/VanguardFactoryDict4Typing.txtMap
```

## 3. 執行評測

於倉庫根目錄執行（`--scratch-path` 可自訂；僅安裝 Command Line Tools 時亦可建置）：

```sh
cd Packages/vChewing_OSNeutral_LibVanguard
swift run -c release vChewingRankingEval \
  ../../DevLab/Eval/ranking-eval-seed.tsv ../../DevLab/Eval/ranking-eval-user.tsv \
  --json /tmp/ranking-eval.json
```

選項：

- `--json <路徑>`：另存完整 JSON 報表（鍵序固定、不含時間戳，可直接 diff）。
- `--show-all`：一併列出通過的案例與其分詞。
- `--max-seg-length <n>`：組字器幅節長度上限（預設 10）。
- `--rarity-threshold <x>`：覆寫 `Homa.Assembler.rarityThreshold`（零頻兜底詞的分數門檻）；
  未指定時沿用組字器預設值。
- `--rare-floor <x|off>`：覆寫 `Homa.Assembler.rarePhrasePerSyllableFloor`（零頻兜底詞每音節的代價，
  多音節且分數不高於門檻者，其分數至多為「本值×音節數」）；`off` 表示停用（設為 nil）。
  未指定時沿用組字器預設值。
- `--beam-width <n>`：覆寫 `Homa.Assembler.beamWidth`（組句時每個位置保留的候選路徑數；`1` 即傳統
  1-best DP）。未指定時沿用組字器預設值。

報表的 `Options` 列（JSON 為 `runInfo.options`）記錄的是**實際生效**的組字器參數，
包括 `rarityThreshold`、`rarePhrasePerSyllableFloor` 與 `beamWidth`，因此可據以確認每次執行的條件。

掃描參數範例：

```sh
for floor in off -6.0 -5.2 -4.8; do
  swift run -c release vChewingRankingEval --rare-floor "$floor" \
    --json "/tmp/ranking-eval-floor$floor.json" ../../DevLab/Eval/ranking-eval-seed.tsv
done
```

與基線比較：

```sh
diff <(jq '.summary' ../../DevLab/Eval/baseline-2026-10-05.json) <(jq '.summary' /tmp/ranking-eval.json)
diff <(jq -r '.results[] | "\(.lineNumber)\t\(.actual)"' ../../DevLab/Eval/baseline-2026-10-05.json) \
     <(jq -r '.results[] | "\(.lineNumber)\t\(.actual)"' /tmp/ranking-eval.json)
```

單元測試（TSV 解析與指標計算；僅 Command Line Tools 的機器需加上 Testing.framework 相關旗標）：

```sh
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --build-system native -Xswiftc -DVCHEWING_TESTS_NO_BUNDLE_MACRO \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  -Xswiftc -F -Xswiftc $FW -Xlinker -F -Xlinker $FW -Xlinker -rpath -Xlinker $FW \
  --filter RankingEval
```

## 4. 解讀輸出

文字報表依序列出：

- **Parse issues**：格式錯誤的行（缺 TAB、讀音數與字數不符等），這些行不計入評測。
- **Failing cases**：組句結果與預期不同的案例。`diff` 列以全形「＾」標出錯字位置；
  `segments` 為組字器實際採用的分詞，可用來判斷錯誤是「選錯字」還是「分錯詞」。
  字數不同時標記為 length mismatch，該句字正確數記為 0。
- **Skipped cases**：含原廠辭典查無之讀音的案例，整句跳過並另計
  （`missing reading occurrences`）。通常代表讀音拼錯，請先修正句子集。
- **Expected chars not offered for their reading**：預期字並不在該讀音的候選中，
  幾乎可以確定是句子集讀音標錯（例如破音字選錯音），而非組句錯誤。
- **Summary**：
  - `Sentence accuracy`：整句完全正確的比例（分母為實際評測的案例數）。
  - `Character accuracy`：逐字位比對的正確字數比例（字數不同的句子全數記錯）。

注意：部分案例（如以「她」「它」為主詞的句子）單憑讀音在語意上無法判定，基線的
「他」並不算真正的錯誤；比較前後版本時應關注**變化**，而非追求 100%。

結束碼：0 表示評測完成（不論正確率高低）；64 為參數錯誤或未設定環境變數；66 為檔案讀寫錯誤；
69 為辭典載入失敗。
