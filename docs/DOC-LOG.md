# EA\_LogSpec\_v202603（DOC-LOG）

## 0\. 位置づけ（正典宣言）

本書 **EA\_LogSpec\_v202603（DOC-LOG）** は、GoldBreakoutFilterEA における **ログ仕様の唯一の正典**である。

- 対象：Eventログ（実行ログ）／ImpulseSummary（解析ログ）  
- 本書で定義する：列定義、命名規則、出力条件、RejectStage語彙、拡張方針（後方互換）  
- 本書で定義しない：ロジック仕様、状態遷移仕様、トレード判断仕様（それらは DOC-CORE 側）

以後、ログ仕様に関する改定・疑義は **DOC-LOG のみ**で行う（重複定義禁止）。

---

## 1\. ログ体系の全体像

本EAのログは以下の2系統で構成される。

1) **Eventログ（実行ログ）**  
   状態遷移やイベント（Impulse検出／Touch／Confirm／Entry／Reject 等）を **時系列で追跡**するためのログ。  
     
2) **ImpulseSummary（解析ログ）**  
   1Impulse=1行で、通過率・詰まり箇所・RejectStage分布等の **統計集計**を行うためのログ。

両者は TradeUUID により同一Impulseへ紐づく。

---

## 2\. Eventログ仕様（実行ログ）

### 2.1 出力形式（TSV固定列）

形式：TSV（タブ区切り・ヘッダ行あり・1行1イベント）

列（固定）：

- Time  
- Symbol  
- MarketMode  
- State  
- TradeUUID  
- Event  
- StartAdjusted  
- DeepBandON  
- ImpulseATR  
- StartPrice  
- EndPrice  
- BandLower  
- BandUpper  
- TouchCount  
- FreezeCancelCount  
- ConfirmType  
- EntryType  
- EntryPrice  
- SL  
- TP  
- SpreadPts  
- SlippagePts  
- FillDeviationPts  
- Result  
- RejectReason  
- Extra

### 2.2 出力イベント分類

ログ分類：

- LOG\_STATE（State遷移ログ）  
- LOG\_IMPULSE（Impulse検出・追従ログ）  
- LOG\_TOUCH（Touch1/Touch2/Leaveなど）  
- LOG\_CONFIRM（Confirm成立・失効）  
- LOG\_ENTRYEXIT（エントリー・決済）  
- LOG\_REJECT（Reject理由）

Event は原則、状態遷移時の reason と一致する。

### 2.3 重要フラグ

- StartAdjusted：Impulse起点が補正されたか（true/false）  
- DeepBandON：GOLDでDeepBandが有効か（true/false）

### 2.4 出力レベル

LogLevel により出力範囲を制御する。

- NORMAL：最低限  
- DEBUG：詳細（Dump系trueで補助列出力）  
- ANALYZE：ImpulseSummaryログ出力（第3章）

### 2.5 ログファイル命名規則（固定）

`GbfEA_{RunId}_{Symbol}.tsv`

- RunId は実行日を表す `YYYYMMDD` とする（固定）  
- プレフィックス `GbfEA_` と拡張子 `.tsv` は固定

例：`GbfEA_20260223_USDJPY.tsv`

### 2.6 列拡張方針（後方互換）

- 列追加は **末尾に限定**する（既存列順は固定）  
- Extra列に `key=value;key=value` を追記する方式は許容（推奨）

### 2.7 TradeUUID生成ルール（固定）

Impulse検出時に一意なIDを生成し、以後そのImpulseに紐づく全ログに同じTradeUUIDを付与する。

### 2.8 FreezeCancelCount

FreezeCancelCount は FreezeCancel の発生回数を示す。

---

## 3\. ImpulseSummary仕様（解析ログ）

ImpulseSummaryログは、1Impulse=1行で集計用に出力する。

### 3.1 出力条件

- LogLevel=ANALYZE のときに出力  
- TradeUUID が空の場合は出力しない

### 3.2 ファイル命名規則

`GbfEA_SUMMARY_{RunId}_{Symbol}.tsv`

- RunId は 2.5 と同一の `YYYYMMDD` を使用する（固定）  
- プレフィックス `GbfEA_` と拡張子 `.tsv` は固定

例：`GbfEA_SUMMARY_20260223_USDJPY.tsv`

### 3.3 出力形式（TSV固定列順）

ImpulseSummary の列順は **実ファイル（TSV）順**に固定する。  
列追加は **末尾追加のみ**許可する（既存列順の変更は禁止）。

固定列（TSV順）：

- Time  
- Symbol  
- MarketMode  
- TradeUUID  
- RangePts  
- BandWidthPts  
- LeaveDistancePts  
- SpreadBasePts  
- FreezeCancelCount  
- Touch1Count  
- LeaveCount  
- Touch2Count  
- ConfirmCount  
- RiskGatePass  
- Touch2Reached  
- ConfirmReached  
- EntryGatePass  
- RR\_Actual  
- RR\_Min  
- RangeCostMult\_Actual  
- RangeCostMult\_Min  
- FinalState  
- RejectStage

（MA Confluence 解析列：存在する場合はこの位置。未評価時は空欄）

- MA\_ConfluenceCount  
- MA\_InBand\_List  
- MA\_InBand\_FibPct  
- MA\_TightHitCount  
- MA\_TightHit\_List  
- MA\_NearBand\_List  
- MA\_NearestDistance  
- MA\_DirectionAligned  
- MA\_Values  
- MA\_Eval\_Price

（STRUCTURE\_BREAK 詳細列：後方互換のため末尾追加）

- StructBreakReason  
- StructBreakPriority  
- StructBreakRefLevel  
- StructBreakRefPrice  
- StructBreakAtPrice  
- StructBreakDistPts  
- StructBreakBarShift

（任意・推奨：向き解釈補助。追加する場合も末尾追加）

- StructBreakSide

（順張り方向フィルタ（上位足方向）／反転回避：後方互換のため末尾追加）

- TrendFilterEnable  
- TrendTF  
- TrendMethod  
- TrendDir  
- TrendSlope  
- TrendSlopeMin  
- TrendATRFloor  
- TrendAligned  
- ReversalGuardEnable
- ReversalTF
- ReversalGuardTriggered
- ReversalReason

（EMA Cross Filter / Impulse Exceed Filter：後方互換のため末尾追加）

- EMACrossFilterEnable
- EMACrossFastVal
- EMACrossSlowVal
- EMACrossDir
- EMACrossAligned
- ImpulseExceedEnable
- ImpulseRangeATR
- ImpulseExceedMax
- ImpulseExceedTriggered

### 3.4 値ルール

- boolは 1/0 で出力  
- 未到達／未評価の列は空欄で出力  
- 文字列列は固定語彙（集計可能な表記）で出力する  
- TrendDir は `LONG / SHORT / FLAT` のいずれか（TrendFilterEnable=1 かつ評価済みの場合）  
- ReversalReason は固定語彙（例：`ENGULFING` / `BIG_BODY` / `WICK_REJECT` / `BIG_BODY_2` 等）。
  未発火時は空欄でよい
- EMACrossDir は `LONG / SHORT / FLAT` のいずれか（EMACrossFilterEnable=1 かつ評価済みの場合）
- ImpulseRangeATR は Impulse Range / ATR(M15) の比率（小数）。未評価時は0  
- **Pts（単位定義）**：Pts系列（RangePts / BandWidthPts / LeaveDistancePts / SpreadBasePts / StructBreakDistPts 等）は  
  **「価格差を Point() で割った値（MT5ポイント数）」**として扱う。  
  したがって \*\*通貨ペアが異なっても比較可能な“point-count”\*\*であり、  
  **価格（例：0.00010）単位ではない**。

### 3.4A StructBreakDistPts の符号規約（固定）

`StructBreakDistPts` は以下の式で定義され、**符号付き**で出力する。

- `StructBreakDistPts = (StructBreakAtPrice - StructBreakRefPrice) / Point`

符号の解釈は **絶対価格軸で統一**し、Dir（Long/Short）に依存しない。

- `StructBreakDistPts < 0`：AtPrice が RefPrice より **下側**（下抜け側）  
- `StructBreakDistPts > 0`：AtPrice が RefPrice より **上側**（上抜け側)  
- `StructBreakDistPts = 0`：同値（実運用では稀）

※ 本規約は「どっちに抜けたか」を統計で判定するための固定仕様であり、解釈時に Dir で符号反転しない。

---

### 3.4B “向き解釈”補助ログ（任意だが推奨）

`StructBreakDistPts` の符号（UNDER/OVER）を集計しやすくするため、以下の補助列を **任意で追加してよい**。

- `StructBreakSide`（文字列）  
  - `UNDER`：StructBreakDistPts \< 0  
  - `OVER`：StructBreakDistPts \> 0  
  - `ON`：StructBreakDistPts \= 0

列追加は後方互換のため **末尾追加**を遵守する（3.3参照）。

### 3.5 RejectStage（語彙定義）

RejectStageは最終停止理由のみを出力する。

最低限の語彙（例）：

- NONE
- STRUCTURE\_BREAK
- NO\_TOUCH2
- NO\_CONFIRM
- TIME\_EXIT
- TRADING\_DISABLED
- RANGE\_COST\_FAIL
- ~~RR\_FAIL~~（CHANGE-008 により廃止。MinRRチェック無効化のため発火しない。語彙自体は後方互換のため保持）
- SPREAD\_BLOCK
- RETOUCH\_TIMEOUT
- TREND\_FLAT
- TREND\_MISMATCH
- REVERSAL\_GUARD
- EMA\_CROSS\_MISMATCH
- EMA\_CROSS\_NODATA
- IMPULSE\_EXCEED

（※語彙追加時は後方互換を守る：既存語彙の意味変更は禁止）

### 3.5A FinalState（語彙定義）

FinalStateはImpulse終了時の最終状態を示す。
ポジション決済時は以下の語彙を使用する。

- EMACross\_Exit：EMAクロス決済（CHANGE-008）
- StructBreak\_Fib0：構造破綻（ImpulseStart終値割れ/超え）
- TimeExit：時間撤退（TimeExitBars超過かつ損益≤0）
- EntryGate\_RangeCost\_Fail：EntryGate RangeCost未達
- SL\_Hit：SLヒット（サーバーSL）

（※語彙追加時は後方互換を守る：既存語彙の意味変更は禁止）

### 3.6 MA Confluence 解析列の説明（列順は3.3が正典）

本節は MA Confluence 系列の **列の意味と評価タイミング**を説明する。  
ImpulseSummary の **列順（TSV順）の正典は 3.3** とし、本節は列順を規定しない。

- MA\_ConfluenceCount  
- MA\_InBand\_List  
- MA\_InBand\_FibPct  
- MA\_TightHitCount  
- MA\_TightHit\_List  
- MA\_NearBand\_List  
- MA\_NearestDistance  
- MA\_DirectionAligned  
- MA\_Values  
- MA\_Eval\_Price

設計思想：

- MA解析は IMPULSE\_CONFIRMED 到達時点で評価する  
- 未到達の場合は空欄を出力する

---

## 4\. Inputs（ログ制御に関するもののみ）

本章は「ログ仕様として必要な入力」だけを記載する。  
運用・戦略・安全弁の入力は DOC-CORE 側を正とする。

### 4.1 Inputグループ構成（表示順）

【G1：運用（普段触る）】

- LogLevel（default: NORMAL）  
- RunId（default: 01）※ログ命名用

【G4：検証・デバッグ（普段触らない）】

- DumpStateOnChange（default: true）  
- DumpRejectReason（default: true）  
- DumpFibValues（default: true）  
- DumpMarketProfile（default: true）  
- LogStateTransitions（default: true）  
- LogImpulseEvents（default: true）  
- LogTouchEvents（default: true）  
- LogConfirmEvents（default: true）  
- LogEntryExit（default: true）  
- LogRejectReason（default: true）

---

# 付録A：旧EA\_Scalping\_v202603からの原文移植（参照用・編集禁止）

ここには、旧 `EA_Scalping_v202603` から移植したログ関連章の“原文”を貼り付ける。  
本文の編集・再整理は自由だが、原文移植ブロック自体は「履歴・参照用」として保持する。  
原文移植ブロック内の文言・章番号・列順は原則変更しない（編集禁止）。

---

## A-1. 旧 `12.1 Inputグループ構成（表示順）`（原文移植）

【G1：運用（普段触る）】

* EnableTrading（default: true）※エントリー可否制御（false時はロジック稼働・ログ出力のみ）  
* MarketMode（default: AUTO）  
* UseLimitEntry（default: true）  
* UseMarketFallback（default: true）  
* LotMode（default: FIXED）  
  * FIXED：固定Lot  
  * RISK\_PERCENT：口座％リスク型（将来実装）  
* FixedLot（default: 0.01）  
* LogLevel（default: NORMAL）  
* RunId（default: 01）         ※ログ命名用

【G2：安全弁（事故防止）】

* MaxSpreadMode（default: ADAPTIVE）  
* SpreadMult\_FX（default: 2.0）  
* SpreadMult\_GOLD（default: 2.5）  
* SpreadMult\_CRYPTO（default: 3.0）  
* MaxSlippagePts（default: 変数だが市場別テーブル初期値を採用）  
* MaxFillDeviationPts（default: 変数だが市場別テーブル初期値を採用）

【G3：戦略（基本触らない）】

* OptionalBand38（default: OFF）  
* ConfirmModeOverride（default: OFF） ※OFF時は市場別仕様（第7章）に従う

【G4：検証・デバッグ（普段触らない）】

* DumpStateOnChange（default: true）  
* DumpRejectReason（default: true）  
* DumpFibValues（default: true）  
* DumpMarketProfile（default: true）  
* LogStateTransitions（default: true）  
* LogImpulseEvents（default: true）  
* LogTouchEvents（default: true）  
* LogConfirmEvents（default: true）  
* LogEntryExit（default: true）  
* LogRejectReason（default: true）

---

## A-2. 旧 `13.1〜13.9.6`（原文移植）

## 13.1 出力形式（TSV固定列：拡張版）

形式：TSV（タブ区切り・ヘッダ行あり・1行1イベント）

Time  
Symbol  
MarketMode  
State  
TradeUUID  
Event  
StartAdjusted  
DeepBandON  
ImpulseATR  
StartPrice  
EndPrice  
BandLower  
BandUpper  
TouchCount  
FreezeCancelCount  
ConfirmType  
EntryType  
EntryPrice  
SL  
TP  
SpreadPts  
SlippagePts  
FillDeviationPts  
Result  
RejectReason  
Extra

---

## 13.2 出力イベント分類（Stateベース）

ログ分類：

* LOG\_STATE（State遷移ログ）  
* LOG\_IMPULSE（Impulse検出・追従ログ）  
* LOG\_TOUCH（Touch1/Touch2/Leaveなど）  
* LOG\_CONFIRM（Confirm成立・失効）  
* LOG\_ENTRYEXIT（エントリー・決済）  
* LOG\_REJECT（Reject理由）

Eventは原則、状態遷移時の理由（reason=）と一致する。

---

## 13.3 重要フラグ

* StartAdjusted：Impulse起点が補正されたか（true/false）  
* DeepBandON：GOLDでDeepBandが有効か（true/false）

---

## 13.4 出力レベル

LogLevel により出力範囲を制御する。

* NORMAL：最低限  
* DEBUG：詳細（Dump系trueで補助列出力）  
* ANALYZE：ImpulseSummaryログ出力（第13.9）

---

## 13.5 ログファイル命名規則（固定）

`GbfEA_{RunId}_{Symbol}.tsv`

例： `GbfEA_01_USDJPY.tsv`

---

## 13.6 列拡張方針（後方互換）

列追加は末尾に限定する（過去の列順は固定）。

Extra列に `key=value;key=value` を追記する方式は許容（推奨）。

---

## 13.7 TradeUUID生成ルール（固定）

Impulse検出時に一意なIDを生成し、以後そのImpulseに紐づく全ログに同じTradeUUIDを付与する。

---

## 13.8 FreezeCancelCount（定義およびログ上の扱い）

FreezeCancelCount は FreezeCancel の発生回数を示す。

---

## 13.9 ImpulseSummaryログ（ANALYZE専用）

ImpulseSummaryログは、1Impulse=1行で集計用に出力する。

---

### 13.9.1 出力条件

* LogLevel=ANALYZE のときに出力  
* TradeUUID が空の場合は出力しない

---

### 13.9.2 ファイル命名規則

`GbfEA_SUMMARY_{Symbol}.tsv`

---

### 13.9.3 出力形式（TSV固定列順）

Time  
Symbol  
MarketMode  
TradeUUID  
RangePts  
BandWidthPts  
LeaveDistancePts  
SpreadBasePts  
FreezeCancelCount  
Touch1Count  
LeaveCount  
Touch2Count  
ConfirmCount  
RiskGatePass  
Touch2Reached  
ConfirmReached  
EntryGatePass  
RR\_Actual  
RR\_Min  
RangeCostMult\_Actual  
RangeCostMult\_Min  
FinalState  
RejectStage

---

### 13.9.4 値ルール

* boolは 1/0 で出力  
* 未到達の列は空欄で出力

---

### 13.9.5 RejectStage（固定Enum）

RejectStageは最終停止理由のみを出力する。

* NONE  
* STRUCTURE\_BREAK  
* NO\_TOUCH2  
* NO\_CONFIRM  
* TIME\_EXIT  
* TRADING\_DISABLED  
* RANGE\_COST\_FAIL  
* RR\_FAIL  
* SPREAD\_BLOCK
* TREND\_FLAT
* TREND\_MISMATCH
* REVERSAL\_GUARD
* EMA\_CROSS\_MISMATCH
* EMA\_CROSS\_NODATA
* IMPULSE\_EXCEED

---

### 13.9.6 MA Confluence 解析列

MA\_ConfluenceCount  
MA\_InBand\_List  
MA\_InBand\_FibPct  
MA\_TightHitCount  
MA\_TightHit\_List  
MA\_NearBand\_List  
MA\_NearestDistance  
MA\_DirectionAligned  
MA\_Values  
MA\_Eval\_Price

---

### 13.9.6 設計思想

* MA解析は IMPULSE\_CONFIRMED 到達時点で評価する  
* 未到達の場合は空欄を出力する

