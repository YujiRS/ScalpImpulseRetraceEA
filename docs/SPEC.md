# SPEC.md — ScalpImpulseRetraceEA リポジトリ

> 本ファイルは「何を作るか」「何を満たせばOKか」の正典。
> 新しいチャットでは「SPEC.md を読んだ上で〜して」と指示すれば文脈が揃う。
> 本リポジトリには複数のEA戦略が含まれる。Part 1 が主力EA、Part 2 以降は別戦略。
> Part 3: RoleReversalEA（5分足ロールリバーサル×MTF分析）を追加。

---

# Part 1: Impulse→Retrace スキャルピングEA（3市場）

## このシステムが解く問題（WHY）

- M1足のImpulse（急騰/急落）後に発生する「押し（Retrace）」を狙い、構造的に有利な位置でエントリーするスキャルピングEA
- 最速層（23.6/38.2の1回目タッチ）を追わず、**「Impulse完了確認 → 2回目タッチ → 反転確定」**の3段階で期待値を安定化する
- FX / GOLD / CRYPTO の3市場に対応。共通アーキテクチャ（状態遷移・モジュール構成）は同一だが、市場ごとに独立EAとして実装

### EA一覧

| EA名 | 対象市場 | バージョン | 特徴 |
|------|---------|-----------|------|
| GoldBreakoutFilterEA | GOLD (XAUUSD) | v2.0 | DeepBand条件付き61.8 / Level3 Freeze / WickRejection Confirm |
| FXRetracePulseEA | FX (USDJPY等) | v2.0 | M5 Slope Filter / OptionalBand38 / Engulfing Confirm |
| CryptoImpulseRetraceEA | CRYPTO (BTCUSD等) | v1.0 | FlatFilter / EMA21/50 Cross / MicroBreak(Lookback型) Confirm |

---

## 対象ユーザーとユースケース（WHAT）

- **対象**: MT5でスキャルピングを行う個人トレーダー
- **ユースケース**: 市場ごとのEAを該当チャートにアタッチし、自動でImpulse検出 → 押し待ち → エントリー → 決済を行う
- **運用形態**: VPS上での24時間稼働を想定。手動介入はInput変更（EnableTrading OFF等）のみ

---

## 主要ビジネスルール・制約

### 1. 対象市場と押し帯（RetraceBand）

| 市場 | EA名 | 押し帯 |
|------|------|--------|
| FX | FXRetracePulseEA | 50 主軸。38.2はOptional（Input: OptionalBand38）。61.8は不使用 |
| GOLD | GoldBreakoutFilterEA | 50 メイン。条件付きで50〜61.8（DeepBand） |
| CRYPTO | CryptoImpulseRetraceEA | 50〜61.8 常時ON |

### 2. 状態遷移（ステートマシン）

```
IDLE → IMPULSE_FOUND → IMPULSE_CONFIRMED → FIB_ACTIVE → TOUCH_1
  → TOUCH_2_WAIT_CONFIRM → ENTRY_PLACED → IN_POSITION → COOLDOWN → IDLE
```

| StateID | State | 意味 |
|---------|-------|------|
| 0 | IDLE | 監視中 |
| 1 | IMPULSE_FOUND | Impulse認定済 |
| 2 | IMPULSE_CONFIRMED | Impulse完了確定（Freeze成立） |
| 3 | FIB_ACTIVE | Fib凍結＆押し待ち |
| 4 | TOUCH_1 | 1回目タッチ（エントリー禁止） |
| 5 | TOUCH_2_WAIT_CONFIRM | 2回目タッチ＋反転条件待ち |
| 6 | ENTRY_PLACED | 注文発行済 |
| 7 | IN_POSITION | 保有中 |
| 8 | COOLDOWN | 再エントリー抑制中 |

**StateIDは変更禁止。**

主要な遷移ルール:
- IMPULSE_CONFIRMED → IDLE: RiskGateFail（取引価値なし判定）。ただし LogLevel=ANALYZE 時は下記SoftGateへ
- IMPULSE_CONFIRMED → FIB_ACTIVE: RiskGatePass（Fib算出・凍結）
- TOUCH_2_WAIT_CONFIRM → ENTRY_PLACED: Confirm成立
- TOUCH_2_WAIT_CONFIRM → IDLE: ConfirmTimeLimitExpired
- **SoftGate（LogLevel=ANALYZE専用）**: RiskGateFail発生時にIDLE遷移せず、g_riskGateSoftPass=trueのまま後続ロジックを継続。Confirm到達時にRISK_GATE_SOFT_BLOCKでRejectしIDLEへ遷移（エントリーはしないが、どこまで進んだかを記録する分析用機能）
- COOLDOWN → IDLE: CooldownDuration（3本、ハードコード）経過で遷移

### 3. Impulse検出・確定

#### Impulse認定
- 単足基準。ImpulseRangePts >= ATR(M1) × ImpulseATRMult で認定

#### 起点補正（条件付き）
両方成立時のみ:
- 前足がImpulse方向と逆色
- 前足実体 <= ATR(M1) × SmallBodyRatio

| 市場 | SmallBodyRatio |
|------|---------------|
| FX | 0.35 |
| GOLD | 0.40 |
| CRYPTO | 0.45 |

#### Freeze（Impulse完了確定）— 市場別

| 市場 | Freeze条件 | CancelWindowBars | Cancel閾値 |
|------|-----------|------------------|-----------|
| FX | 更新停止 + 反対色足（Level2） | 2 | Frozen100を1tick超更新 |
| GOLD | 更新停止 + 反対色足 + 内部回帰ATR(M1)×0.15以上（Level3） | 3 | Frozen100をSpread×2以上突破 |
| CRYPTO | 更新停止 + 反対色足（Level2） | 1 | Frozen100を0.1%以上更新 |

### 4. 押し帯（Fib）運用

- Fib参照レベル: 38.2 / 50 / 61.8 / 78.6
- Freeze確定後にのみ有効。確定後は再計算しない（凍結）

#### BandWidthPts算出（唯一の定義）

| 市場 | 算出式 | 確定タイミング |
|------|--------|---------------|
| FX | 現在Spread × 2.0 | IMPULSE_CONFIRMED→FIB_ACTIVE遷移時 |
| GOLD | ATR(M1) × 0.05 | Freeze時点 |
| CRYPTO | ATR(M1) × 0.08 | Freeze時点 |

同一TradeUUID内で固定。Input変更不可（MarketProfile内部定義のみ）。

#### GOLD DeepBand ON条件
```
DeepBandON = (G1 OR G2) AND (C1 OR C2 OR C3)

G1: ATR(M1,14)/ATR(M1,50) >= VolExpansionRatio=1.5（ボラ拡大）
G2: ImpulseRangePts >= ATR(M1) × OverextensionMult=2.5（過伸長）
C1: SessionFlag = RiskOn（NY前半等）
C2: 直近スイープ痕跡あり
C3: スプレッド通常域
```

### 5. タッチ判定

- **侵入**: Long: Low <= BandUpper / Short: High >= BandLower
- **1回目タッチ**: エントリー禁止（例外なし）
- **離脱（Leave）**: 帯から十分離れたことで成立

| 市場 | LeaveDistance | LeaveMinBars |
|------|-------------|-------------|
| FX | BandWidthPts × 1.5 | 1 |
| GOLD | BandWidthPts × 1.5 | 1 |
| CRYPTO | BandWidthPts × 1.2 | 1 |

- **2回目タッチ**: 1回目記録済 + 離脱成立 + 再侵入
- **リセット**: RetouchTimeLimitBars超過 / 構造破綻 / 明確離脱後ResetMinBars経過

| 市場 | RetouchTimeLimitBars | ResetMinBars | ConfirmTimeLimitBars |
|------|---------------------|-------------|---------------------|
| FX | 35 | 10 | 6 |
| GOLD | 30 | 8 | 5 |
| CRYPTO | 25 | 6 | 4 |

### 6. 順張りフィルタ（上位足方向）

**判定タイミング**: IMPULSE_FOUND確定時に1回だけ。同一TradeUUID内で再評価しない。

#### Primary Trend（M15）

| 市場 | 方式 | 詳細 |
|------|------|------|
| FX | EMA50傾き | SlopeMin（ATR比率）で判定 |
| GOLD | EMA50傾き + 強制FLAT条件 | ATRFloor未満 or 高安混在で強制FLAT |
| CRYPTO | EMA21 vs EMA50 + EMA50傾き | 両方成立でトレンド方向判定 |

- TrendDir = FLAT → Reject（**FXのみ例外: M5 Slope FilterがSTRONGなら通過可能**）
- ImpulseDir != TrendDir → Reject（逆張り禁止）

#### 市場固有の追加フィルタ

| フィルタ | GOLD | FX | CRYPTO |
|---------|------|-----|--------|
| EMA Cross Filter（M15） | EMA20 vs EMA50 (Input) | — | EMA21 vs EMA50 |
| Impulse Exceed Filter（M15） | ImpulseExceedMax=3.0 | — | — |
| M5 Slope Filter | — | M5 EMA傾き STRONG/MID/FLAT判定 | — |
| FlatFilter（M5） | — | — | OFF/FlatGuard/FlatMatch (Input) |

- **EMA Cross Filter**: EMA位置関係でフィルタ。LONG: emaFast > ema50 / SHORT: emaFast < ema50。TrendFilterとは独立（両方通過が必要）
- **Impulse Exceed Filter**: ImpulseRangePts / ATR(M15) > Max で過伸長Reject
- **M5 Slope Filter（FX固有）**: M5 EMA傾きがSTRONG + 方向一致でのみ通過。TrendDir=FLATでもM5 Slopeが強ければ通過可能（GOLD/CRYPTOと異なる）
- **FlatFilter（CRYPTO固有）**: M5レンジでフラット検出。FlatGuard=フラット中はReject、FlatMatch=ブレイク方向一致を要求

#### Reversal Guard（H1）

| 市場 | 検出対象 |
|------|---------|
| FX | 逆向き大実体 or 逆向きEngulfing |
| GOLD | 逆向きEngulfing + WickReject + 強反転兆候 |
| CRYPTO | 逆向きEngulfing or 逆向き大実体のみ（最小限） |

### 7. エントリー条件（Confirm）

2回目タッチ成立後、M1確定足で判定:

| 市場 | 採用Confirm | 優先順位 |
|------|-----------|---------|
| FX | Engulfing OR MicroBreak（フラクタル型） | Engulfing > MicroBreak |
| GOLD | WickRejection OR MicroBreak（フラクタル型） | WickRejection > MicroBreak |
| CRYPTO | MicroBreak（Lookback型、直近3本）のみ | — |

- **WickRejection（GOLD）**: ヒゲ比率 >= WickRatioMin（0.55）。帯内での反発をヒゲ長で確認
- **Engulfing（FX）**: 確定足実体が直前足実体を包む
- **MicroBreak フラクタル型（FX/GOLD）**: 左右2本の極値（i=3〜20範囲で探索）をブレイク
- **MicroBreak Lookback型（CRYPTO）**: 直近3本の高安（High[2..4]/Low[2..4]）をブレイク。フラクタルより簡素で速い

**同一Impulse内の最大エントリー回数: 1回（固定）。**

### 8. 注文方式

- 基本: 指値（Limit）
- Market Fallback: オプション
- ガード: MaxSpreadPts / MaxSlippagePts / MaxFillDeviationPts

### 9. 決済仕様

サーバーTP = 0（指値TPを使用しない）。EMAクロスで決済。

#### Exit優先順位（固定）

1. **構造破綻（Fib0）**: ImpulseStart終値割れ/超え → 即時成行決済
2. **時間撤退**: Entry後 TimeExitBars 本以上保有 かつ 損益 ≤ 0 → 成行決済
3. **建値移動**: RR >= 1.0 → SLをエントリー価格に移動（決済ではない）
4. **EMAクロス決済**: EMA(Fast) と EMA(Slow) の逆クロス → 確認後に成行決済

#### EMAクロス決済パラメータ（M1固定）

| パラメータ | 値 |
|-----------|-----|
| ExitMAFastPeriod | 13 |
| ExitMASlowPeriod | 21 |
| ExitConfirmBars | 1 |

### 10. RiskGate（取引価値判定）

IMPULSE_CONFIRMED → FIB_ACTIVE遷移直前に1回評価。

RiskGateFail条件:
1. 値幅不足（RangePtsがSpreadPts・帯幅・Leave距離に対して不足）→ range <= 2.0 points で即Fail

BandDominanceRatio（帯幅/値幅比）はRISK_GATE_FAILログに記録されるが、現時点ではReject条件としては使用していない（分析用）。

### 11. EntryGate（注文直前の最終判定）

- ~~MinRR_EntryGate: 廃止（CHANGE-008）。記録用のみ~~
- MinRangeCostMult: 期待値幅 < Spread × MinRangeCostMult でエントリー禁止

### 12. 無効条件（構造破綻）

| 優先順位 | 条件 | 挙動 |
|---------|------|------|
| 1 | 0/100外突破、GOLD 78.6終値、FX 61.8終値突破 | 即IDLE |
| 2 | RetouchTimeLimit超過 | 即IDLE |
| 3 | ConfirmTimeLimit超過 | 即IDLE |
| 4 | Spread/Slippage超過 | エントリー禁止のみ（State維持） |

---

## スコープ外（やらないこと）

- 逆張りエントリー（順張りのみ）
- 1回目タッチでのエントリー
- 同一Impulse内での複数エントリー（1 Impulse = 1 Trade）
- 日またぎポジション管理（本EAのスコープ外）
- 経済指標カレンダー連携
- 複数通貨ペア間の相関分析
- 裁量介入による市場別Confirm変更

---

## 入出力定義

### 入力（Input）

> 3EA共通のInput構成。市場固有Inputはサフィックス `_GOLD` / `_FX` / `_CRYPTO` で区別。

#### 共通Input（全EA共通）

| グループ | 項目 | 初期値 | 備考 |
|---------|------|--------|------|
| G1:運用 | EnableTrading | true | false時はロジック稼働・ログ出力のみ |
| G1 | UseLimitEntry | true | |
| G1 | UseMarketFallback | true | |
| G1 | LotMode | FIXED | FIXED/RISK_PERCENT |
| G1 | FixedLot | 0.01 | |
| G1 | RiskPercent | 1.0 | RISK_PERCENT時のみ使用 |
| G1 | LogLevel | NORMAL | NORMAL/DEBUG/ANALYZE |
| G1 | RunId | 1 | ログ命名用（int） |
| G1 | LongDisableAbove | 0 | 指定レート以上でLong禁止（0=無効） |
| G1 | ShortDisableBelow | 0 | 指定レート以下でShort禁止（0=無効） |
| G1:通知 | EnableDialogNotification | true | MT5端末Alert |
| G1 | EnablePushNotification | true | MT5 Push通知 |
| G1 | EnableMailNotification | false | メール通知 |
| G1 | EnableSoundNotification | false | サウンド通知 |
| G1 | SoundFileName | "alert.wav" | |
| G1:Exit | ExitMAFastPeriod | 13 | EMAクロス決済Fast |
| G1 | ExitMASlowPeriod | 21 | EMAクロス決済Slow |
| G1 | ExitConfirmBars | 1 | クロス確認本数 |
| G1:フィルタ | TrendFilter_Enable | true | M15トレンドフィルタ |
| G1 | ReversalGuard_Enable | true | H1反転ガード |
| G1:表示 | EnableFibVisualization | true | Fib描画ON/OFF |
| G1 | EnableStatusPanel | true | ステータスパネル表示 |
| G2:安全弁 | MaxSpreadMode | ADAPTIVE | FIXED/ADAPTIVE |
| G2 | InputMaxSlippagePts | 0 | 0→市場別デフォルト |
| G2 | InputMaxFillDeviationPts | 0 | 0→市場別デフォルト |
| G2 | InputMaxSpreadPts | 0 | FIXED時の上限（0=無効） |
| G4:検証 | DumpStateOnChange〜LogRejectReason | true | 各種ログ制御（11項目） |

#### 市場固有Input

| 項目 | GOLD | FX | CRYPTO |
|------|------|-----|--------|
| TrendSlopeMult | 0.07 | 0.05 | 0.07 |
| TrendATRFloorPts | 80.0 | — | — |
| ReversalEngulfing_Enable | true | true | — |
| ReversalBigBodyMult | 1.0 | 0.9 | 1.0 |
| ReversalWickReject_Enable | true | — | — |
| ReversalWickRatioMin | 0.60 | — | — |
| EMACrossFilter_Enable | true | — | —（TrendFilter内蔵） |
| EMACrossFilter_FastPeriod | 20 | — | — |
| ImpulseExceed_Enable | true | — | — |
| ImpulseExceed_MaxATR | 3.0 | — | — |
| SpreadMult | 2.5 | 2.0 | 3.0 |
| MinRR_EntryGate | 0.6 | 0.7 | 0.5 |
| MinRangeCostMult | 2.5 | 2.5 | 2.0 |
| SLATRMult | 0.8 | 0.7 | 0.7 |
| TPExtRatio | 0.382 | 0.382 | 0.382 |
| OptionalBand38 | — | false | — |
| ConfirmModeOverride | false | — | — |
| FlatFilterMode | — | — | OFF (OFF/FlatGuard/FlatMatch) |
| FlatRangeLookback | — | — | 8 |
| FlatRangeATRMult | — | — | 2.5 |
| LogMAConfluence | true | true | — |

### 出力

- **Eventログ（TSV）**: 状態遷移・Reject等を時系列で記録。`{EA_NAME}_{RunId}_{Symbol}.tsv`
- **ImpulseSummary（TSV）**: 1 Impulse = 1行の統計集計用。ANALYZE時のみ。`{EA_NAME}_SUMMARY_{RunId}_{Symbol}.tsv`
- **チャート描画**: Fibレベル + 押し帯の矩形表示（EnableFibVisualization で制御）
- **通知**: IMPULSE_FOUND時（TrendFilter/ImpulseExceedFilter通過後）のみ。Alert/Push/Mail/Sound（各Input制御）

### 主要語彙（RejectStage）

NONE / STRUCTURE_BREAK / NO_TOUCH2 / NO_CONFIRM / TIME_EXIT / TRADING_DISABLED / RANGE_COST_FAIL / SPREAD_BLOCK / RETOUCH_TIMEOUT / TREND_FLAT / TREND_MISMATCH / REVERSAL_GUARD / EMA_CROSS_MISMATCH / EMA_CROSS_NODATA / IMPULSE_EXCEED / RISK_GATE_SOFT_BLOCK

### 主要語彙（FinalState）

EMACross_Exit / StructBreak_Fib0 / TimeExit / EntryGate_RangeCost_Fail / SL_Hit

---

## 市場別パラメータ一覧（MarketProfile内部値）

> 全市場実装済み。値はMarketProfile.mqh内でハードコード（Input化されていないもの）。

| Param | FX | GOLD | CRYPTO |
|-------|-----|------|--------|
| ImpulseATRMult | 1.6 | 1.8 | 2.0 |
| SmallBodyRatio | 0.35 | 0.40 | 0.45 |
| ImpulseMinBars | 1 | 1 | 1 |
| FreezeLevel | Level2 | Level3 | Level2 |
| FreezeCancelWindowBars | 2 | 3 | 1 |
| FreezeCancelMethod | 1tick超 | Spread×2 | 0.1% |
| RetraceBand | 50 (+Opt38) | 50 (+DeepBand条件付61.8) | 50-61.8常時 |
| BandWidthPts算出 | Spread×2.0 | ATR(M1)×0.05 | ATR(M1)×0.08 |
| LeaveDistanceMult | 1.5 | 1.5 | 1.2 |
| LeaveMinBars | 1 | 1 | 1 |
| RetouchTimeLimitBars | 35 | 30 | 25 |
| ResetMinBars | 10 | 8 | 6 |
| ConfirmTimeLimitBars | 6 | 5 | 4 |
| Confirm | Engulfing/MicroBreak | WickReject/MicroBreak | MicroBreak(LB)のみ |
| WickRatioMin | — | 0.55 | — |
| MaxSlippagePts (default) | 2.0 | 5.0 | 8.0 |
| MaxFillDeviationPts (default) | 3.0 | 8.0 | 12.0 |
| TimeExitBars | 10 | 8 | 6 |
| VolExpansionRatio | — | 1.5 | — |
| OverextensionMult | — | 2.5 | — |
| CooldownDuration | 3 | 3 | 3 |
| 固有フィルタ | M5 Slope | EMA Cross + ImpExceed | FlatFilter + EMA Cross |

---

## 受け入れ条件

1. 全StateID（0〜8）の遷移が仕様通りに動作する
2. 1回目タッチでエントリーが発生しない
3. 離脱未成立の再侵入を2回目タッチとしてカウントしない
4. 同一Impulse内で2回以上のエントリーが発生しない
5. Freeze後にFibレベルが再計算されない
6. 各EAのMarketProfileパラメータが正しくロードされる
7. RiskGateFail時にIDLEへ正しく遷移する（LogLevel=ANALYZE時はSoftGate経由）
8. 順張りフィルタで逆張りImpulseがRejectされる
9. EMAクロス決済が確定足ベースで正しく動作する
10. ログ（Event / ImpulseSummary）が仕様の列順・語彙で出力される
11. 通知がIMPULSE_FOUND時のみ発火する

---

## 未解決・要確認事項

1. **CloseByCrossEA / CloseByFlatRangeEA との関係**: 別EAの決済ロジック仕様がdocs内に存在。本EA群のスコープとの関係が未整理
2. **ADAPTIVE SpreadBasePts の更新タイミング**: 「IMPULSE_FOUND発生時のみ」と規定されているが、長時間Impulseが発生しない場合のスプレッド基準の鮮度が要確認

---
---

# Part 2: GOLD ブレイクアウト×モメンタム継続 ハイブリッド戦略（Draft）

> GoldBreakoutFilterEA（Part 1）とは**完全に別コンセプト**の戦略。
> Part 1 が「Impulse後の押しを拾う」のに対し、本戦略は「レンジブレイクで乗り、モメンタムが続く限りホールドする」。
> 独立した新規EAとして設計する（Part 1 のコードベースは流用しない）。

## このシステムが解く問題（WHY）

- 「走り出すと続く」GOLDの特性を活かし、Asianセッションで形成されたレンジのブレイクアウトでエントリーし、モメンタムが続く限りATRトレーリングでホールドする
- 低勝率（40〜50%）を高RR（1:2〜1:5）で補う構造

## 全体フロー

```
Asian Session  →  London/NY Open  →  Breakout  →  Hold  →  Exit
[レンジ形成]     [ブレイク監視]     [エントリー]  [継続判定]  [決済]
```

## 主要ビジネスルール

### Phase 1: Range Build（レンジ形成）
- 期間: Asianセッション（サーバー時間 RangeStartHour〜RangeEndHour、Input化）
- 足: M15
- レンジ品質フィルタ: RangeWidth < ATR(H1,14)×0.3 → Skip / RangeWidth > ATR(H1,14)×1.5 → Skip

### Phase 2: Breakout Watch（ブレイク監視）
- M15足のCloseがRangeHigh/RangeLowを超えた時点でブレイク成立
- 追加フィルタ: Body比率 >= 50%、超過距離 >= Spread×2
- **1日1方向ルール**: 最初のブレイク方向のみ有効（往復ビンタ防止）

### Phase 3: Entry
- ブレイク足Close確定時に成行エントリー
- SL = レンジ反対側 - ATR(M15)×0.3
- ロット = リスク固定型（口座残高 × RiskPercent% / SL距離）

### Phase 4: Hold / Trail
- ATRベーストレーリング: TrailDistance = ATR(M15,14) × TrailMult
- 建値移動: 含み益 >= ATR(M15)×1.0 で SL をエントリー価格+Spreadに移動
- 更新タイミング: M15足確定時のみ（ティックごとではない）

### Phase 5: Exit
1. トレーリングSLヒット（メイン出口）
2. セッション終了（NY Close = サーバー23:00で強制決済、持ち越し禁止）
3. 逆方向ブレイク（ATR×2超の逆行足）

### リスク管理
- MaxTradesPerDay = 1
- MaxDailyLoss = 口座残高の3%
- スプレッドフィルタ: Median(15min)×3.0超でエントリー禁止

### 上位足フィルタ（オプション・初期OFF）
- H1 EMA50傾きでトレンド方向フィルタ（まずブレイクアウト単体の性能を検証してから有効化）

## 入力パラメータ（案）

| パラメータ | 型 | Default | 説明 |
|-----------|-----|---------|------|
| RangeStartHour | int | 0 | レンジ開始（サーバー時間） |
| RangeEndHour | int | 7 | レンジ終了 |
| TradeStartHour | int | 7 | トレード開始 |
| TradeEndHour | int | 20 | 新規エントリー締切 |
| ForceCloseHour | int | 23 | 強制決済時刻 |
| RiskPercent | double | 1.0 | 1トレードリスク（%） |
| TrailMult | double | 1.5 | トレーリング距離 = ATR × この値 |
| BreakevenATRMult | double | 1.0 | 建値移動トリガー |
| MinRangeATRMult | double | 0.3 | 最小レンジ幅 |
| MaxRangeATRMult | double | 1.5 | 最大レンジ幅 |
| SLBufferATRMult | double | 0.3 | SLバッファ |
| MaxSpreadMult | double | 3.0 | スプレッドフィルタ倍率 |
| MaxTradesPerDay | int | 1 | 1日最大トレード数 |
| MaxDailyLossPct | double | 3.0 | 1日最大損失（%） |
| UseH1TrendFilter | bool | false | H1トレンドフィルタON/OFF |

## 受け入れ条件

1. Asianレンジが正しく検出される（RangeHigh/RangeLow）
2. レンジ品質フィルタが機能する（極端なレンジをSkip）
3. M15 Close確定でのみブレイクが判定される
4. 1日1方向ルールが守られる
5. ATRトレーリングがM15確定時のみ更新される
6. NY Close（ForceCloseHour）で強制決済される

## 未解決・要確認事項

1. サーバー時間の扱い: XMTrading GMT+2/GMT+3 前提だが、ブローカー移行時にInput調整で対応可能か
2. 重要指標フィルタ（FOMC, NFP, CPI等）: 将来拡張として検討中。MQL5の経済カレンダーAPIで対応可能
3. 想定パフォーマンス（勝率40-50%, RR 1:2〜1:5）の実データでの検証が未実施

---
---

# Part 3: RoleReversalEA — 5分足ロールリバーサル×MTF分析

> Part 1（Impulse→Retrace）/ Part 2（ブレイクアウト×モメンタム）とは**完全に別コンセプト**の戦略。
> H1のサポレジ転換（Role Reversal）を5分足でエントリーする、N字波動の「初押し・初戻り」を狙うEA。
> 独立した新規EAとして設計。

## このシステムが解く問題（WHY）

- H1で意識される水平線（S/R）をブレイク後、**元のレジスタンスがサポートに転換（またはその逆）する地点**で、5分足のプライスアクション確認付きでエントリーする
- 「含み損勢力の救済注文（建値決済）」と「新規追随勢力の参入」が同一価格帯で衝突する構造的優位性を利用
- H1の利幅ターゲット × M5のタイトなSLで、数学的に高いリスクリワード比（1:2以上）を確保

## 対象ユーザーとユースケース（WHAT）

- **対象**: MT5で5分足ベースのスイング寄りスキャルピングを行うトレーダー
- **対象市場**: GOLD / FX / CRYPTO（市場を問わないユニバーサル設計。単一EA）
- **運用形態**: VPS上での稼働を想定。London/NYセッション限定

---

## 主要ビジネスルール・制約

### 1. MTF階層構造

| 時間足 | 役割 | 監視項目 |
|--------|------|---------|
| H1 | 環境認識（マクロ） | 主要S/Rの特定。Swing High/Low検出 |
| M15 | 方向性確認（メゾ） | EMA50とCloseの位置関係でトレンド方向フィルタ |
| M5 | 執行（ミクロ） | ブレイクアウト検出、プルバック監視、EMA25確認、Confirm判定 |

### 2. 状態遷移（ステートマシン）

```
IDLE → BREAKOUT_DETECTED → BREAKOUT_CONFIRMED → WAITING_PULLBACK
  → (Confluence確認) → IN_POSITION → COOLDOWN → IDLE
```

| StateID | State | 意味 |
|---------|-------|------|
| 0 | IDLE | 待機中。S/Rブレイクアウトを監視 |
| 1 | BREAKOUT_DETECTED | M5終値がS/Rレベルを横断。確認中 |
| 2 | BREAKOUT_CONFIRMED | 連続N本のClose確認でブレイク確定 |
| 3 | WAITING_PULLBACK | ブレイクしたレベルへの価格回帰を待機 |
| 4 | PULLBACK_AT_LEVEL | レベル到達。コンフルエンス条件確認中 |
| 5 | ENTRY_READY | 全条件成立。エントリー可能 |
| 6 | IN_POSITION | ポジション保有中（SL/TPで自動決済） |
| 7 | COOLDOWN | クールダウン（1本後にIDLE） |

### 3. H1 S/R検出

- **方式**: Swing High/Low検出（各方向N本の比較）
- **SwingLookback**: 7本（各側。H1 = 7時間分）— パラメータスイープで最適化済
- **マージ**: 近接レベルをATR × MergeTolerance で統合（重複排除）
- **タッチカウント**: マージ後にH1バーでの接触回数を集計
- **最大年齢**: MaxAge（H1バー数）超過のレベルは無視
- **リフレッシュ**: SR_RefreshInterval（12 H1バー = 12時間）ごとに再検出。broken/used状態は引き継ぎ

### 4. ブレイクアウト検出（M5）

- **条件**: 前バーCloseがレベル以下（以上）→ 現バーCloseがレベル以上（以下）に横断
- **Body比率**: BreakoutBodyRatio（0.3）以上で有効なブレイク足と判定
- **確認**: BO_ConfirmBars（2本）連続でCloseがレベルの外側にあること
- **M15トレンドフィルタ**: M15 Close vs M15 EMA50。ブレイク方向と不一致ならReject

### 5. プルバック（ロールリバーサル）検出

- **ゾーン定義**: レベル ± ATR(M5) × PB_ZoneATR
- **待機**: PB_MinBars〜PB_MaxBars の間でゾーン到達を監視
- **ゾーン到達判定**:
  - Long: Low ≤ レベル+zone かつ Close ≥ レベル−zone×0.5
  - Short: High ≥ レベル−zone かつ Close ≤ レベル+zone×0.5
- **全戻し判定**: Close がレベルから zone×2 以上逆行 → レベルを破棄（構造破綻）
- **タイムアウト**: PB_MaxBars（120 = 10時間）超過 → レベルを使用済みに

### 6. コンフルエンス条件（プルバック到達後）

4条件すべて成立でエントリー:

1. **EMAトレンド**: EMA(M5,25) が EMA_TrendLookback バー前より方向一致
2. **EMAサポート/レジスタンス**: Long: Low ≥ EMA−zone かつ Close > EMA / Short: High ≤ EMA+zone かつ Close < EMA
3. **Confirmパターン**: 以下のいずれか1つが成立（優先順位順）

| パターン | 条件概要 |
|---------|---------|
| Key Reversal | 直近N本の新安値（新高値）+ 前バーClose超え + 上（下）半分でClose + 方向一致Body |
| Engulfing | 前バー実体を包む逆方向実体。Body比率 ≥ 0.5 |
| Pin Bar | Body/Range ≤ 0.35、反転方向ヒゲ ≥ Body×2、Close位置 0.6以上（0.4以下） |

4. **R:R検証**: SL距離 ≤ ATR × MaxSL_ATR（2.0）かつ TP/SL ≥ MinRR（2.0）

### 7. SL/TP計算

| 項目 | Long | Short |
|------|------|-------|
| SL | シグナル足Low − SL_BufferPoints | シグナル足High + SL_BufferPoints |
| TP (Fixed R:R) | Entry + SL距離 × MinRR | Entry − SL距離 × MinRR |
| TP (次H1レベル) | 次の未ブレイクS/Rレベル（MinRR未満なら固定R:Rにフォールバック） |

### 8. 時間フィルタ

- **執行可能時間**: TradeHourStart（8）〜 TradeHourEnd（21）UTC
- **根拠**: London 08:00-16:00 + NY 13:00-21:00 の合算。アジア時間の低流動性を排除

### 9. 注文方式

- 成行（Market）エントリー
- Filling Mode 自動判定（FOK/IOC/RETURN）
- Deviation: 20 points
- ロット: FIXED または RISK_PERCENT（Equity基準）

### 10. 決済仕様

サーバーSL/TPを注文時に設定。EAによる能動的決済ロジックなし（SL/TPヒットで自動決済）。

---

## 入出力定義

### 入力（Input）

| グループ | 項目 | 初期値 | 備考 |
|---------|------|--------|------|
| G1:運用 | EnableTrading | true | false時はシグナルログのみ |
| G1 | LotMode | FIXED | FIXED/RISK_PERCENT |
| G1 | FixedLot | 0.01 | |
| G1 | RiskPercent | 1.0 | RISK_PERCENT時のみ |
| G1 | LogLevel | NORMAL | NORMAL/DEBUG/ANALYZE |
| G1 | MagicOffset | 0 | Magic = 20260307 + Offset |
| G2:S/R検出 | SR_SwingLookback | 7 | H1スイングの片側本数 |
| G2 | SR_MergeTolerance | 0.5 | ATR比率でのマージ閾値 |
| G2 | SR_MaxAge | 200 | H1バーでの最大年齢 |
| G2 | SR_MinTouches | 2 | 最小タッチ回数 |
| G2 | SR_RefreshInterval | 12 | S/R再検出間隔（H1バー数） |
| G3:ブレイクアウト | BO_BodyRatio | 0.3 | ブレイク足の最小Body比率 |
| G3 | BO_ConfirmBars | 2 | 確認用連続Close本数 |
| G4:プルバック | PB_ZoneATR | 0.5 | ゾーン幅（ATR比率） |
| G4 | PB_MaxBars | 120 | 最大待機（M5バー数） |
| G4 | PB_MinBars | 2 | 最小待機（M5バー数） |
| G5:EMA | EMA_Period | 25 | M5 EMA期間 |
| G5 | EMA_TrendLookback | 3 | EMAトレンド確認バー数 |
| G6:Confirm | KR_Lookback | 5 | Key Reversal参照本数 |
| G6 | KR_BodyMinRatio | 0.3 | Key Reversal最小Body比率 |
| G6 | KR_ClosePosition | 0.45 | Key ReversalのClose位置閾値 |
| G6 | Engulf_BodyMinRatio | 0.5 | Engulfing最小Body比率 |
| G6 | Pin_BodyMaxRatio | 0.35 | Pin Bar最大Body比率 |
| G6 | Pin_WickRatio | 2.0 | Pin Barヒゲ/Body比率 |
| G7:R/R | MinRR | 2.0 | 最小リスクリワード比 |
| G7 | MaxSL_ATR | 2.0 | SL上限（ATR倍率） |
| G7 | SL_BufferPoints | 50 | SLバッファ（points） |
| G7 | UseFixedRR_TP | true | 固定R:R TP使用 |
| G8:時間 | TradeHourStart | 8 | 執行開始（UTC） |
| G8 | TradeHourEnd | 21 | 執行終了（UTC） |
| G9:M15 | M15_TrendFilter | true | M15トレンドフィルタ |
| G9 | M15_EMA_Period | 50 | M15 EMA期間 |
| G10:通知 | EnableAlert | true | MT5 Alert |
| G10 | EnablePush | false | Push通知 |
| G11:表示 | EnableSRLines | true | S/R水平線描画 |
| G11 | EnableStatusPanel | true | ステータスパネル表示 |

### 出力

- **チャート描画**:
  - S/R水平線（Resistance=赤、Support=青、Broken=黄破線、Used=グレー点線）
  - タッチ回数 ≥ 3 で太線描画
  - プルバックゾーン矩形（Long=緑、Short=赤、半透明）
- **ステータスパネル**: 左下に State / Direction / S/R数 / Session / Spread / P&L 等を表示
- **ログ**: Print()ベース。LogLevel=DEBUG以上で詳細出力
- **通知**: エントリー時のみ（Alert / Push）

---

## ファイル構成

| ファイル | 役割 |
|---------|------|
| RoleReversalEA.mq5 | メインEA。State Machine、エントリー/ポジション管理 |
| RoleReversalEA/Constants.mqh | 列挙型（State, Direction, ConfirmPattern）、構造体（SRLevel, TradeRecord） |
| RoleReversalEA/SRDetector.mqh | H1 Swing High/Low検出、マージ、タッチカウント |
| RoleReversalEA/ConfirmEngine.mqh | Key Reversal / Engulfing / Pin Bar 検出 |
| RoleReversalEA/Visualization.mqh | S/R線描画、プルバックゾーン矩形、ステータスパネル |

---

## バックテスト結果（Pythonシミュレーション）

> sim_role_reversal.py による検証。最適化後のパラメータ使用。

| 市場 | 期間 | トレード数 | 勝率 | PF | PnL (pips) | Max DD (pips) |
|------|------|-----------|------|-----|-----------|--------------|
| GOLD | 2025/09-11 (3ヶ月) | 13 | 69% | 3.47 | +6,436 | 1,177 |
| FX (USDJPY) | 2026/02 (2週間) | 5 | 60% | 2.66 | +236 | 142 |
| CRYPTO (BTCUSD) | 2025/12-2026/02 (3ヶ月) | 9 | 33% | 1.24 | +35,550 | 76,820 |

**パラメータスイープ結果（GOLD、81組合せ）**: SwingLookback=7が圧倒的に優位（PF 3.47 vs SL=5の1.20）。

---

## 受け入れ条件

1. H1 Swing High/Lowに基づくS/Rレベルが正しく検出・マージされる
2. M5終値のクロスでブレイクアウトが検出され、N本連続確認で確定する
3. ブレイク後のプルバックがゾーン内到達で検出される
4. コンフルエンス4条件（EMAトレンド、EMAサポート、Confirm、R:R）すべて成立時のみエントリーする
5. 全戻し（構造破綻）時にレベルが正しく破棄される
6. 時間フィルタ（London/NY）が機能し、アジア時間にエントリーが発生しない
7. M15トレンドフィルタがブレイク方向と不一致時にRejectする
8. SL/TPがシグナル足基準で正しく計算され、MinRR以上が確保される
9. S/R水平線・プルバックゾーン・ステータスパネルが正しく描画される
10. S/Rレベルが定期リフレッシュで更新され、broken/used状態が維持される

---

## 未解決・要確認事項

1. **CRYPTOの低勝率**: WR 33%。R:Rで補っているが、パラメータ調整またはCRYPTO固有フィルタの追加を要検討
2. **FXデータ量**: 2週間のみでの検証。統計的有意性に課題。追加データでの検証が必要
3. **サーバー時間の扱い**: TradeHourStart/End はサーバー時間（≒UTC）前提。ブローカーのGMTオフセットによりInput調整が必要
4. **S/R検出の計算コスト**: H1で最大200本のSwing検出を12時間ごとに実行。パフォーマンスへの影響は軽微と想定するが未計測
5. **1レベル1トレード制限**: 現在、各S/Rレベルは1回のRole Reversalトレードで使い切り。再利用の可否は要検討
