# FX専用 P2 (A+B) MQL実装プラン

## 変更概要
sim_results_fx_p2.csv の Base filter (PF2.51, WR13%, 5W/33L) を再現する。

## 変更1: Touch1 即エントリー（Touch2 廃止）
**ファイル**: `GoldBreakoutFilterEA.mq5`

- `Process_FIB_ACTIVE()` で Touch1 検出時、STATE_TOUCH_1 をスキップして
  直接 STATE_TOUCH_2_WAIT_CONFIRM へ遷移（Confirm 待ちへ直行）
- STATE_TOUCH_1 は FX では到達しなくなる（デッドコード化、削除はしない）
- 条件: `g_resolvedMarketMode == MARKET_MODE_FX` のとき限定

```
// 現行: Touch1 → STATE_TOUCH_1（Leave待ち→Touch2）→ STATE_TOUCH_2_WAIT_CONFIRM
// 変更: Touch1 → STATE_TOUCH_2_WAIT_CONFIRM（直接Confirm待ち）
```

## 変更2: pre-entry StructBreak 無効化（FX）
**ファイル**: `GoldBreakoutFilterEA.mq5`

- `Process_FIB_ACTIVE()` 内の `CheckStructureInvalid_Detail()` を FX では無効化
- `Process_TOUCH_2_WAIT_CONFIRM()` 内も同様
- SL は post-entry の ATR ベース SL（既存の CalculateSLTP）で管理
- 既存 SL 計算 `g_sl = g_impulseStart ± ATR * 0.7` は変更なし（sim と同一）

```mql5
// FIB_ACTIVE / TOUCH_2_WAIT_CONFIRM 内:
if(g_resolvedMarketMode != MARKET_MODE_FX)  // FX以外のみStructBreak
{
   if(CheckStructureInvalid_Detail(...)) { ... }
}
```

## 変更3: M5 slope フィルター追加
**ファイル**: `EntryEngine.mqh`, `Constants.mqh`, `GoldBreakoutFilterEA.mq5`

sim の Base filter = M5 SMA(21) slope を STRONG のみ通過。

### 3a. Constants.mqh に M5 slope 分類追加
```mql5
enum ENUM_M5_SLOPE { M5_SLOPE_FLAT, M5_SLOPE_MID, M5_SLOPE_STRONG };
```

### 3b. OnInit() に M5 SMA(21) + ATR(M5,14) ハンドル作成

### 3c. EntryEngine.mqh に EvaluateM5SlopeFilter() 追加
- SMA(21) の slope = SMA21[1] - SMA21[2] on M5
- threshold = ATR(M5,14) * 0.03（FX FlatThreshold）
- FLAT: |slope| < threshold
- MID: threshold <= |slope| < 2*threshold
- STRONG: |slope| >= 2*threshold
- 方向一致チェック: slope > 0 → LONG, slope < 0 → SHORT
- **Base filter: STRONG かつ方向一致のみ PASS**

### 3d. Process_IDLE() の EvaluateTrendFilterAndGuard 後に M5 フィルター評価
- M15 が PASS (FLAT含む) → M5 評価
- M5 が PASS → IMPULSE_FOUND へ
- M5 が NG → reject + DumpImpulseSummary

## 変更4: M15 フィルター reject-only 化
**ファイル**: `EntryEngine.mqh`

- `EvaluateTrendFilterAndGuard()` の FX ブロック:
  - 現行: FLAT → reject（return false, "TREND_FLAT"）
  - 変更: FLAT → **pass**（return true → M5 フィルターへ進む）
  - MISMATCH → 引き続き reject（"TREND_MISMATCH" → sim では "M15_COUNTER"）
- ReversalGuard は維持（H1 大陰線/大陽線ブロック）

```mql5
// FX のみ: FLAT は通過（M5 slope で制御する）
if(g_resolvedMarketMode == MARKET_MODE_FX && trendDir == "FLAT")
{
   // M5 slope に委ねる → return true
   g_stats.TrendAligned = 0;
   return true;
}
```

## 変更5: FX 専用化
**ファイル**: `MarketProfile.mqh` or `GoldBreakoutFilterEA.mq5`

- GOLD/CRYPTO モード時は OnInit() で警告ログ出力
- エントリーロジック自体は動く（壊さない）が、M5 フィルターの
  パラメータは FX 用のみチューニング済み
- 実質的に「FX以外では未検証」扱い

## 修正順序
1. Constants.mqh（M5 slope enum 追加）
2. EntryEngine.mqh（M15 FLAT 通過 + M5 slope フィルター関数）
3. GoldBreakoutFilterEA.mq5:
   - OnInit: M5 ハンドル追加
   - Process_IDLE: M5 フィルター呼び出し
   - Process_FIB_ACTIVE: Touch1→直接Confirm待ち（FX）
   - Process_FIB_ACTIVE / Process_TOUCH_2_WAIT_CONFIRM: StructBreak無効化（FX）
   - OnDeinit: M5 ハンドル解放
4. コンパイル確認

## 触らないもの
- RiskManager.mqh（SL計算は既存のまま使う）
- FibEngine.mqh（Touch/Leave ロジック自体は残す。FX では到達しなくなるだけ）
- Execution.mqh, Logger.mqh, Visualization.mqh
- DOC-CORE.md（後回し）
