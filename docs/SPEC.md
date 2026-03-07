# SPEC.md — ScalpImpulseRetraceEA リポジトリ

> 本ファイルは「何を作るか」「何を満たせばOKか」の正典。
> 新しいチャットでは「SPEC.md を読んだ上で〜して」と指示すれば文脈が揃う。
> 本リポジトリには複数のEA戦略が含まれる。Part 1 が主力EA、Part 2 以降は別戦略。

---

# Part 1: GoldBreakoutFilterEA v2.0（Impulse→Retrace型）

## このシステムが解く問題（WHY）

- M1足のImpulse（急騰/急落）後に発生する「押し（Retrace）」を狙い、構造的に有利な位置でエントリーするスキャルピングEA
- 最速層（23.6/38.2の1回目タッチ）を追わず、**「Impulse完了確認 → 2回目タッチ → 反転確定」**の3段階で期待値を安定化する
- 設計上は FX / GOLD / CRYPTO の3市場を想定し、市場特性ごとにパラメータと許可レンジを分離する
- **現時点の実装はGOLD向け**。FX/CRYPTOはMarketProfile追加で対応予定（ロジック構造は共通）

---

## 対象ユーザーとユースケース（WHAT）

- **対象**: MT5でスキャルピングを行う個人トレーダー
- **ユースケース**: EAをチャートにアタッチし、自動でImpulse検出 → 押し待ち → エントリー → 決済を行う
- **運用形態**: VPS上での24時間稼働を想定。手動介入はInput変更（EnableTrading OFF等）のみ

---

## 主要ビジネスルール・制約

### 1. 対象市場と押し帯（RetraceBand）

| 市場 | MarketMode | 押し帯 |
|------|-----------|--------|
| FX | `FX` (USDJPY, EURUSD, GBPJPY等) | 50 主軸。38.2はOptional（初期OFF）。61.8は不使用 |
| GOLD | `GOLD` (XAUUSD) | 50 メイン。条件付きで50〜61.8（DeepBand） |
| CRYPTO | `CRYPTO` (BTCUSD, ETHUSD等) | 50〜61.8 常時ON。38.2はOptional（初期OFF） |

MarketMode = AUTO の場合、Symbol名から自動判定。判定不能時はFX扱い（安全側）。
**※ 現時点の実装ではMarketMode Inputは未実装。GOLD固定でInitMarketProfile()をロードする。FX/CRYPTO対応時にInput化予定。**

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

- TrendDir = FLAT → Reject
- ImpulseDir != TrendDir → Reject（逆張り禁止）

#### EMA Cross Filter（M15）

- EMA(FastPeriod, Input=20) vs EMA(50, ハードコード) の位置関係でフィルタ
- LONG: emaFast > ema50 / SHORT: emaFast < ema50
- TrendFilterとは独立した追加フィルタ（両方通過が必要）

#### Impulse Exceed Filter（M15）

- ImpulseRangePts / ATR(M15) > ImpulseExceedMax（Input=3.0）で過伸長としてReject
- 過大なImpulseは「すでに走りきった」可能性が高いため弾く

#### Reversal Guard（H1）

| 市場 | 検出対象 |
|------|---------|
| FX | 逆向き大実体 or 逆向きEngulfing |
| GOLD | 逆向きEngulfing + WickReject + 強反転兆候 |
| CRYPTO | 逆向きEngulfing or 逆向き大実体のみ（最小限） |

### 7. エントリー条件（Confirm）

2回目タッチ成立後、M1確定足で判定:

| 市場 | 採用Confirm | 優先順位 | 実装状況 |
|------|-----------|---------|---------|
| FX | Engulfing OR MicroBreak | Engulfing > MicroBreak | 未実装 |
| GOLD | **WickRejection OR MicroBreak** | WickRejection > MicroBreak | **実装済** |
| CRYPTO | MicroBreakのみ | — | 未実装 |

- **WickRejection**: ヒゲ比率 >= WickRatioMin（GOLD: 0.55）。帯内での反発をヒゲ長で確認
- **MicroBreak**: フラクタル型（左右2本の極値ブレイク）
- **Engulfing**: 定義はコード内に存在するが、GOLD Confirm評価では呼び出されていない（ReversalGuardでのみ使用）

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

> ※ 現時点の実装はGOLD専用のため、サフィックスは全て `_GOLD`。FX/CRYPTO対応時に市場別Input追加予定。

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
| G1 | TrendSlopeMult_GOLD | 0.07 | EMA50傾き閾値（ATR比率） |
| G1 | TrendATRFloorPts_GOLD | 80.0 | ATR下限（強制FLAT判定） |
| G1 | ReversalGuard_Enable | true | H1反転ガード |
| G1 | ReversalEngulfing_Enable | true | Engulfing検出 |
| G1 | ReversalBigBodyMult_GOLD | 1.0 | 大実体判定倍率 |
| G1 | ReversalWickReject_Enable_GOLD | true | WickReject検出 |
| G1 | ReversalWickRatioMin_GOLD | 0.60 | WickReject閾値 |
| G1 | EMACrossFilter_Enable_GOLD | true | EMA Cross Filter |
| G1 | EMACrossFilter_FastPeriod_GOLD | 20 | Fast EMA期間（Slow=50はハードコード） |
| G1 | ImpulseExceed_Enable_GOLD | true | 過伸長フィルタ |
| G1 | ImpulseExceed_MaxATR_GOLD | 3.0 | ATR(M15)×この値超でReject |
| G1:表示 | EnableFibVisualization | true | Fib描画ON/OFF |
| G1 | EnableStatusPanel | true | ステータスパネル表示 |
| G2:安全弁 | MaxSpreadMode | ADAPTIVE | FIXED/ADAPTIVE |
| G2 | SpreadMult_GOLD | 2.5 | Adaptive倍率 |
| G2 | InputMaxSlippagePts | 0 | 0→内部デフォルト5.0 |
| G2 | InputMaxFillDeviationPts | 0 | 0→内部デフォルト8.0 |
| G2 | InputMaxSpreadPts | 0 | FIXED時の上限（0=無効） |
| G2:EntryGate | MinRR_EntryGate_GOLD | 0.6 | ※現在は記録用のみ |
| G2 | MinRangeCostMult_GOLD | 2.5 | |
| G2 | SLATRMult_GOLD | 0.8 | |
| G2 | TPExtRatio_GOLD | 0.382 | RangeCost評価用のみ |
| G3:戦略 | ConfirmModeOverride | false | Confirm条件上書き |
| G4:検証 | DumpStateOnChange | true | 状態変化ログ |
| G4 | DumpRejectReason | true | Reject理由ログ |
| G4 | DumpFibValues | true | Fib値ログ |
| G4 | DumpMarketProfile | true | Profile出力 |
| G4 | LogStateTransitions | true | 状態遷移ログ |
| G4 | LogImpulseEvents | true | Impulseイベントログ |
| G4 | LogTouchEvents | true | タッチイベントログ |
| G4 | LogConfirmEvents | true | Confirmイベントログ |
| G4 | LogEntryExit | true | Entry/Exitログ |
| G4 | LogRejectReason | true | Reject理由ログ |
| G4 | LogMAConfluence | true | MA合流ログ |

### 出力

- **Eventログ（TSV）**: 状態遷移・Reject等を時系列で記録。`GbfEA_{RunId}_{Symbol}.tsv`
- **ImpulseSummary（TSV）**: 1 Impulse = 1行の統計集計用。ANALYZE時のみ。`GbfEA_SUMMARY_{RunId}_{Symbol}.tsv`
- **チャート描画**: Fibレベル + 押し帯の矩形表示（EnableFibVisualization で制御）
- **通知**: IMPULSE_FOUND時（TrendFilter/ImpulseExceedFilter通過後）のみ。Alert/Push/Mail/Sound（各Input制御）

### 主要語彙（RejectStage）

NONE / STRUCTURE_BREAK / NO_TOUCH2 / NO_CONFIRM / TIME_EXIT / TRADING_DISABLED / RANGE_COST_FAIL / SPREAD_BLOCK / RETOUCH_TIMEOUT / TREND_FLAT / TREND_MISMATCH / REVERSAL_GUARD / EMA_CROSS_MISMATCH / EMA_CROSS_NODATA / IMPULSE_EXCEED / RISK_GATE_SOFT_BLOCK

### 主要語彙（FinalState）

EMACross_Exit / StructBreak_Fib0 / TimeExit / EntryGate_RangeCost_Fail / SL_Hit

---

## 市場別パラメータ一覧

> FX/CRYPTO列は設計値（DOC-CORE由来）。実装済みはGOLDのみ。

| Param | FX（設計） | GOLD（実装済） | CRYPTO（設計） |
|-------|-----------|---------------|---------------|
| ImpulseATRMult | 1.6 | **1.8** | 2.0 |
| SmallBodyRatio | 0.35 | **0.40** | 0.45 |
| ImpulseMinBars | 1 | **1** | 1 |
| FreezeCancelWindowBars | 2 | **3** | 1 |
| RetraceBand | 50 | **50/条件で50-61.8** | 50-61.8 |
| BandWidthPts算出 | Spread×2.0 | **ATR(M1)×0.05** | ATR(M1)×0.08 |
| LeaveDistanceMult | 1.5 | **1.5** | 1.2 |
| LeaveMinBars | 1 | **1** | 1 |
| RetouchTimeLimitBars | 35 | **30** | 25 |
| ResetMinBars | 10 | **8** | 6 |
| ConfirmTimeLimitBars | 6 | **5** | 4 |
| WickRatioMin | — | **0.55** | — |
| MaxSlippagePts (default) | 2 | **5.0** | 8 |
| MaxFillDeviationPts (default) | 3 | **8.0** | 12 |
| TimeExitBars | 10 | **8** | 6 |
| SpreadMult (Input) | 2.0 | **2.5** | 3.0 |
| SLATRMult (Input) | 0.7 | **0.8** | 0.7 |
| MinRangeCostMult (Input) | 2.5 | **2.5** | 2.0 |
| TPExtRatio (Input) | 0.382 | **0.382** | 0.382 |
| VolExpansionRatio | — | **1.5** | — |
| OverextensionMult | — | **2.5** | — |
| CooldownDuration | — | **3** | — |

---

## 受け入れ条件

1. 全StateID（0〜8）の遷移が仕様通りに動作する
2. 1回目タッチでエントリーが発生しない
3. 離脱未成立の再侵入を2回目タッチとしてカウントしない
4. 同一Impulse内で2回以上のエントリーが発生しない
5. Freeze後にFibレベルが再計算されない
6. MarketProfile のパラメータがGOLD向けに正しくロードされる（将来: MarketMode切替時に市場別値がロードされる）
7. RiskGateFail時にIDLEへ正しく遷移する（LogLevel=ANALYZE時はSoftGate経由）
8. 順張りフィルタで逆張りImpulseがRejectされる
9. EMAクロス決済が確定足ベースで正しく動作する
10. ログ（Event / ImpulseSummary）が仕様の列順・語彙で出力される
11. 通知がIMPULSE_FOUND時のみ発火する

---

## 未解決・要確認事項

1. **CloseByCrossEA / CloseByFlatRangeEA との関係**: 別EAの決済ロジック仕様がdocs内に存在。本EAのスコープとの関係が未整理
2. **ADAPTIVE SpreadBasePts の更新タイミング**: 「IMPULSE_FOUND発生時のみ」と規定されているが、長時間Impulseが発生しない場合のスプレッド基準の鮮度が要確認
3. **FX/CRYPTO MarketProfile未実装**: 設計値はDOC-COREに存在するが、実装・検証はこれから

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
