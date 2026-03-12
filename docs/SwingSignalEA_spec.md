# SwingSignalEA 仕様書

## 概要

MetaTrader 5 用 MQL5 EA。M5 EMA クロスをトリガーとし、H1 EMA の位置関係で方向をフィルタする。
Exit は H1 Swing High/Low を TP + ATR トレーリングストップのハイブリッド方式。
H1 レジーム消滅時は即撤退。

**設計思想**: GC_DC_SwingNotifier と RoleReversalEA の設計検討を経て構築。
M5 の Swing フィルタは不要（H1 フィルタが構造的方向性を担保）。

---

## タイムフレーム

| TF | 用途 |
|---|---|
| M5 | 主軸。EMA クロスによるトリガー、SL/ATR 計算 |
| H1 | 方向フィルタ（EMA 位置関係）、Swing High/Low（TP 目標） |

---

## エントリーロジック

### 1. H1 方向フィルタ（レジーム判定）

H1 EMA の**位置関係のみ**で方向を決定。クロスの「発生」は不要。

| 条件 | レジーム |
|---|---|
| `H1 EMA_Fast[1] > H1 EMA_Slow[1]` | ロング |
| `H1 EMA_Fast[1] < H1 EMA_Slow[1]` | ショート |
| `H1 EMA_Fast[1] == H1 EMA_Slow[1]` | エントリー不可 |

- `[1]` = H1 の最新確定足
- Swing フィルタ: 不要
- スロープチェック: 不要

### 2. M5 トリガー（EMA クロス）

確定足ベース（リペイント防止）。

| シグナル | shift[2] | shift[1] |
|---|---|---|
| ゴールデンクロス（GC） | `EMA_Fast < EMA_Slow` | `EMA_Fast > EMA_Slow` |
| デッドクロス（DC） | `EMA_Fast > EMA_Slow` | `EMA_Fast < EMA_Slow` |

- `shift[0]`（未確定足）は判定対象外

### 3. 方向性フィルター（M5 スロープ）

M5 クロス発生時点で、両 EMA のスロープが同方向であること。

| GC | DC |
|---|---|
| `SlopeFast > 0 かつ SlopeSlow > 0` | `SlopeFast < 0 かつ SlopeSlow < 0` |

```
SlopeFast = EMA_Fast[1] - EMA_Fast[2]
SlopeSlow = EMA_Slow[1] - EMA_Slow[2]
```

ゼロちょうどは不成立。

### 4. エントリー条件（すべて AND）

**ロングエントリー:**
1. H1 EMA_Fast[1] > H1 EMA_Slow[1]（H1 ロングレジーム）
2. M5 で GC 発生（確定足ベース）
3. M5 SlopeFast > 0 かつ SlopeSlow > 0（方向性フィルター）
4. 取引時間帯内
5. スプレッド ≦ MaxSpreadPoints（0 = 無制限）
6. 同方向ポジション未保有

**ショートエントリー**: 上記の逆条件。

### 5. エントリー執行

- 成行注文（`TRADE_ACTION_DEAL`）
- SL/TP は注文時に設定
- ロットサイズ: 固定ロット or リスク%ベース（input で選択）
- Filling モードはシンボルの `SYMBOL_FILLING_MODE` から自動判定

---

## イグジットロジック

4 つの Exit 条件があり、**いずれか先に成立した条件**で決済。

### Exit 1: TP 到達（H1 Swing High/Low）

エントリー時に H1 Swing High/Low を TP として設定。

- ロング TP: エントリー価格より上方の最も近い H1 Swing High
- ショート TP: エントリー価格より下方の最も近い H1 Swing Low

**Swing 定義（Fractal 方式）:**
- Swing High: 中央足の High が左右 `H1_SwingStrength` 本すべての High より**厳密に**高い
- Swing Low: 中央足の Low が左右 `H1_SwingStrength` 本すべての Low より**厳密に**低い

**フォールバック:**
- H1 Swing が見つからない場合: `SL × MinRR` を TP に使用
- TP までの距離が `SL × MinRR` 未満の場合: `SL × MinRR` を TP に使用（最低 R:R 保証）

**検出範囲:** H1 の直近 `H1_SwingMaxAge` 本
**エントリー時固定**: ポジション保有中に新しい Swing が検出されても TP は変更しない

### Exit 2: ATR トレーリングストップ

```
トレーリング距離 = ATR(ATR_Period, PERIOD_M5)[1] × TrailATR_Multi
```

- ロング: `新SL候補 = 最高値 - トレーリング距離` → 現在の SL より高ければ更新
- ショート: `新SL候補 = 最安値 + トレーリング距離` → 現在の SL より低ければ更新
- 最高値/最安値はポジション保有中の M5 確定足ベースで追跡
- SL の引き上げ（引き下げ）のみ。逆方向への変更はしない
- 新しい M5 バー確定時にのみ判定
- ATR 値はトレーリング判定時の最新値を毎回取得

### Exit 3: 初期 SL

```
ロング SL:   M5 shift[1] の Low  - SL_BufferATR × ATR
ショート SL: M5 shift[1] の High + SL_BufferATR × ATR
ATR = ATR(ATR_Period, PERIOD_M5)[1]
```

- SL 幅が `MaxSL_ATR × ATR` を超える場合 → エントリーしない

### Exit 4: H1 レジーム終了（根拠消滅 → 即撤退）

H1 EMA 位置関係が逆転 → **無条件で即決済**。

- ロング保有中: `H1 EMA_Fast[1] <= H1 EMA_Slow[1]` → 成行決済
- ショート保有中: `H1 EMA_Fast[1] >= H1 EMA_Slow[1]` → 成行決済
- 含み益・含み損に関わらず実行
- SL/TP より優先
- 判定タイミング: 新しい H1 バー確定時（M5 の OnTick 内で H1 バー変化を検出）
- EA が能動的に `TRADE_ACTION_DEAL`（反対売買）で決済

---

## ポジション管理

- マジックナンバーで自ポジションを識別
- 1 シンボルにつき最大 1 ポジション（同方向の重複エントリー禁止）
- 逆方向ポジション保有時の動作は input で選択:
  - `REVERSE_CLOSE_AND_OPEN`: 既存ポジション決済 → 新規エントリー
  - `REVERSE_IGNORE`: 逆シグナルを無視

---

## OnTick 処理フロー

```
1. M5 新バー判定（前回処理バーと比較）→ 新バーでなければ return

2. H1 新バー判定 → 新バーなら:
   a. H1 レジーム判定を更新
   b. ポジション保有中 かつ レジーム終了 → Exit 4 実行（即決済）

3. ポジション保有中:
   → ATR トレーリング SL 更新（Exit 2）
   → TP/SL ヒットは MT5 サーバー側で自動処理（Exit 1, Exit 3）
   → ポジション消滅を検出したら状態リセット

4. ポジション未保有:
   → M5 EMA クロス判定
   → H1 方向フィルタ確認
   → 方向性フィルター確認
   → 時間フィルタ・スプレッドフィルタ
   → H1 Swing 検出 → TP 計算
   → SL 計算 + R:R チェック
   → すべて通過 → エントリー執行
```

---

## Input パラメータ

| グループ | パラメータ | デフォルト | 説明 |
|---|---|---|---|
| G1: Operation | EnableTrading | true | 取引 ON/OFF |
| | LotMode | SS_LOT_FIXED | ロット決定方式 |
| | FixedLot | 0.01 | 固定ロット |
| | RiskPercent | 1.0 | リスク%（有効証拠金の%） |
| | MinMarginLevel | 1500 | エントリー後維持率下限（%, 0=無効） |
| | MagicNumber | 20260312 | マジックナンバー |
| | ReverseMode | REVERSE_CLOSE_AND_OPEN | 逆方向ポジション処理 |
| | InstanceTag | "" | コメント欄タグ |
| G2: M5 EMA | M5_EMA_Fast | 13 | M5 EMA Fast 期間 |
| | M5_EMA_Slow | 21 | M5 EMA Slow 期間 |
| | UseEMA | true | true: EMA / false: SMA |
| G3: H1 EMA | H1_EMA_Fast | 13 | H1 EMA Fast 期間 |
| | H1_EMA_Slow | 21 | H1 EMA Slow 期間 |
| G4: H1 Swing | H1_SwingStrength | 5 | Swing 左右比較本数 |
| | H1_SwingMaxAge | 200 | Swing 検出範囲（H1 bars） |
| G5: Stop Loss | SL_BufferATR | 0.5 | SL バッファ（ATR 倍率） |
| | MaxSL_ATR | 2.0 | 最大 SL 幅（ATR 倍率、超過→エントリー不可） |
| | MinRR | 2.0 | 最低 R:R（TP が近い場合のフォールバック） |
| G6: ATR Trailing | ATR_Period | 14 | ATR 期間 |
| | TrailATR_Multi | 2.0 | トレーリング距離（ATR 倍率） |
| G7: Time Filter | TradeHourStart | 8 | 取引開始時間（サーバー時間） |
| | TradeHourEnd | 21 | 取引終了時間（サーバー時間） |
| G8: Spread Filter | MaxSpreadPoints | 0 | 最大スプレッド（points, 0=無制限） |
| G9: Notification | EnableAlert | true | Alert 通知 |
| | EnablePush | true | Push 通知 |
| | EnableEmail | false | Email 通知 |
| G10: Logging | LogLevel | SS_LOG_ANALYZE | ログレベル |

---

## ENUM 定義

```
ENUM_SS_LOT_MODE:  SS_LOT_FIXED(0), SS_LOT_RISK_PERCENT(1)
ENUM_REVERSE_MODE: REVERSE_CLOSE_AND_OPEN(0), REVERSE_IGNORE(1)
ENUM_SS_LOG_LEVEL: SS_LOG_OFF(0), SS_LOG_NORMAL(1), SS_LOG_ANALYZE(2)
```

---

## 通知メッセージ

### エントリー
```
[SS_ENTRY] BUY  2026.03.12 14:05 | XAUUSD | 2700.00 | SL=2695.00 | TP=2730.00 | Lot=0.01
```

### Exit
```
[SS_EXIT] BUY  2026.03.12 16:30 | XAUUSD | 2720.00 | Profit=+200points | Reason=ATR_TRAIL
```

ExitReason 語彙: `TP_HIT`, `SL_HIT`, `ATR_TRAIL`, `H1_REGIME_END`, `REVERSE`, `EXTERNAL`

---

## ログ仕様

### 設計思想

ログの目的は **パラメータ最適化の材料** を提供すること。単なるトレード履歴（ブローカーで取得可能）ではなく、**判断時点のコンテキスト** を記録する。

- **Signal Log**: 全 M5 クロスシグナルの判断スナップショット（「なぜ入らなかったか」の完全記録）
- **Trade Log**: トレードライフサイクル全体を1行で記録（MFE/MAE による SL/TP 最適化）

### LogLevel

| 値 | 名前 | 出力 |
|---|---|---|
| 0 | SS_LOG_OFF | ファイル出力なし |
| 1 | SS_LOG_NORMAL | Trade Log のみ |
| 2 | SS_LOG_ANALYZE | Trade Log + Signal Log（デフォルト） |

### Signal Log（ANALYZE 時）

M5 EMA クロス発生ごとに1行。全フィルターの値と判定結果を記録。

**ファイル名**: `MQL5/Files/SS_SIGNAL_<YYYYMMDD>_<Symbol>[_<InstanceTag>].tsv`

**カラム（30列）:**

| # | カラム | 型 | 説明 |
|---|---|---|---|
| 1 | Time | datetime | シグナル発生時刻 |
| 2 | Symbol | string | 銘柄 |
| 3 | Dir | string | `BUY` / `SELL` |
| 4 | Outcome | string | 判定結果（Outcome 語彙参照） |
| 5 | Price | double | シグナル時の Ask/Bid |
| 6 | ATR | double | M5 ATR(14) 値 |
| 7 | SpreadPts | int | スプレッド（points） |
| 8 | M5Fast | double | M5 EMA Fast 値 |
| 9 | M5Slow | double | M5 EMA Slow 値 |
| 10 | M5CrossGap | double | \|M5Fast - M5Slow\|（クロス強度） |
| 11 | M5SlopeFast | double | EMA Fast スロープ（shift[1] - shift[2]） |
| 12 | M5SlopeSlow | double | EMA Slow スロープ |
| 13 | H1Regime | string | `LONG` / `SHORT` / `NEUTRAL` |
| 14 | H1Fast | double | H1 EMA Fast 値 |
| 15 | H1Slow | double | H1 EMA Slow 値 |
| 16 | SL | double | 算出 SL 価格（0=未算出） |
| 17 | TP | double | 算出 TP 価格（0=未算出） |
| 18 | SL_DistPts | double | SL 距離（points） |
| 19 | TP_DistPts | double | TP 距離（points） |
| 20 | RR | double | Reward:Risk 比 |
| 21 | SwingTP | double | H1 Swing TP 生値（0=見つからず） |
| 22 | FallbackUsed | bool | 1=MinRR フォールバック使用 |
| 23 | Lot | double | 算出ロット |
| 24 | ServerHour | int | サーバー時刻（時） |
| 25 | PassRegime | bool | H1 レジームフィルター通過 |
| 26 | PassSlope | bool | M5 スロープフィルター通過 |
| 27 | PassTime | bool | 時間フィルター通過 |
| 28 | PassSpread | bool | スプレッドフィルター通過 |
| 29 | PassSLWidth | bool | SL 幅チェック通過 |
| 30 | PassMargin | bool | 証拠金チェック通過 |

**Outcome 語彙（固定）:**

```
ENTRY              -- 全フィルター通過、エントリー執行
REJECT_REGIME      -- H1 レジーム不一致
REJECT_SLOPE       -- M5 スロープフィルター不成立
REJECT_TIME        -- 取引時間外
REJECT_SPREAD      -- スプレッド超過
REJECT_SAME_POS    -- 同方向ポジション保有中
REJECT_REVERSE_IGN -- 逆方向ポジション保有中（REVERSE_IGNORE 設定）
REJECT_ATR         -- ATR 取得不可
REJECT_SL_CALC     -- SL 算出不可
REJECT_SL_WIDE     -- SL 幅が MaxSL_ATR × ATR 超過
REJECT_NO_TP       -- TP 算出不可
REJECT_NO_LOT      -- ロット算出不可
REJECT_MARGIN      -- 証拠金不足
REJECT_SEND        -- OrderSend 失敗
```

### Trade Log（NORMAL 以上）

ポジション完結ごとに1行。Entry→Exit のライフサイクルを記録。

**ファイル名**: `MQL5/Files/SS_TRADE_<YYYYMMDD>_<Symbol>[_<InstanceTag>].tsv`

**カラム（20列）:**

| # | カラム | 型 | 説明 |
|---|---|---|---|
| 1 | EntryTime | datetime | エントリー時刻 |
| 2 | ExitTime | datetime | 決済時刻 |
| 3 | Symbol | string | 銘柄 |
| 4 | Dir | string | `BUY` / `SELL` |
| 5 | EntryPrice | double | 約定価格 |
| 6 | ExitPrice | double | 決済価格 |
| 7 | Lot | double | ロット |
| 8 | SL_Initial | double | 初期 SL |
| 9 | SL_Final | double | 最終 SL（トレーリング後） |
| 10 | TP | double | TP 価格 |
| 11 | ProfitPts | double | 損益（points） |
| 12 | ProfitMoney | double | 損益（口座通貨） |
| 13 | HoldBarsM5 | int | 保有 M5 バー数 |
| 14 | ExitReason | string | 決済理由（ExitReason 語彙参照） |
| 15 | TrailCount | int | トレーリング SL 更新回数 |
| 16 | ATR_Entry | double | エントリー時 ATR |
| 17 | SpreadEntry | int | エントリー時スプレッド |
| 18 | H1Regime_Entry | string | エントリー時 H1 レジーム |
| 19 | MFE_Pts | double | 最大有利到達幅（points） |
| 20 | MAE_Pts | double | 最大不利到達幅（points） |

**ExitReason 語彙（固定）:**

```
TP_HIT          -- TP 到達
SL_HIT          -- 初期 SL ヒット
ATR_TRAIL       -- トレーリング SL ヒット
H1_REGIME_END   -- H1 レジーム消滅
REVERSE         -- 逆方向シグナルによるドテン
EXTERNAL        -- 外部決済（手動等）
```

### 解析ユースケース

| 分析目的 | 使用ログ | 着目カラム |
|---|---|---|
| フィルター通過率 | Signal Log | PassRegime〜PassMargin の集計 |
| 時間帯別勝率 | Signal Log + Trade Log | ServerHour × Outcome / ExitReason |
| SL/TP 最適化 | Trade Log | MFE_Pts / MAE_Pts / ProfitPts |
| スロープ閾値検討 | Signal Log | M5SlopeFast/Slow × Outcome |
| スプレッド影響 | Signal Log | SpreadPts × Outcome |
| トレーリング効果 | Trade Log | TrailCount / SL_Initial vs SL_Final |
| クロス強度と勝率 | Signal Log + Trade Log | M5CrossGap × 結果 |
| H1 Swing TP 有効性 | Signal Log + Trade Log | SwingTP / FallbackUsed × ProfitPts |

### リスタート時の制約

EA 再起動時、以下の Trade Log カラムは復元不可能（0 で記録）:
- `ATR_Entry`, `SpreadEntry`: エントリー時のスナップショットが消失
- `TrailCount`: トレーリング更新回数がリセット
- `SL_Initial`: 現在の SL で近似（トレーリング済みの場合は正確でない）

---

## 実装上の注意点

1. `iMA()` / `iATR()` ハンドルは `OnInit()` でキャッシュ
2. バッファ取得失敗時は安全に `return`
3. テスター環境では Push・メール通知を無効化
4. M5 新バー確定時のみシグナル判定
5. H1 レジーム判定は H1 新バー確定時に実行
6. `SymbolInfoDouble(_Symbol, SYMBOL_POINT)` で価格変換
7. OrderSend 失敗時はリトライせずエラーログ出力
8. `#property strict` 付与
9. ATR トレーリング SL 修正は `TRADE_ACTION_SLTP`
10. H1 レジーム終了時の決済は `TRADE_ACTION_DEAL`（反対売買）
11. Risk% モードは FreeMargin 上限チェック含む
12. Filling モードは `SYMBOL_FILLING_MODE` から自動判定
13. TF 切替時のステート保存は不要

---

## ファイル構成

```
src/Experts/SwingSignalEA.mq5  -- 単一ファイル
```
