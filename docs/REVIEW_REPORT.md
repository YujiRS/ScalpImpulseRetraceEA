# MQL5 コードレビュー報告書

> **レビュー日**: 2026-03-11
> **対象**: リポジトリ内の全6EA（GoldBreakoutFilterEA / FXRetracePulseEA / CryptoImpulseRetraceEA / RoleReversalEA / CloseByCrossEA / CloseByFlatRangeEA）
> **参照仕様**: SPEC.md / DECISIONS.md (ADR-001〜ADR-021)

---

## サマリー

| EA | Critical | Warning | Suggestion |
|----|----------|---------|------------|
| GoldBreakoutFilterEA | 5 | 13 | 9 |
| FXRetracePulseEA | 6 | 10 | 9 |
| CryptoImpulseRetraceEA | 6 | 10 | 7 |
| RoleReversalEA | 5 | 10 | 8 |
| CloseByCrossEA | 3 | 2 | 2 |
| CloseByFlatRangeEA | 1 | 4 | 5 |

**全EA共通で検出された問題パターン（横断的課題）:**

1. **ClosePosition 失敗時のState不整合** — 全4メインEAで共通。決済OrderSend失敗→COOLDOWN遷移→ポジション孤立
2. **UseLimitEntry が実質成行注文** — GOLD/FX/CRYPTOで共通。TRADE_ACTION_DEAL を使用しており指値ではない
3. **ModifySL 後に g_sl が更新されない** — GOLD/FXで確認。建値移動後のRR計算・パネル表示が不正
4. **GetMAValue/GetATRValue が毎回ハンドル生成・解放** — 全3メインEAで共通。パフォーマンス劣化
5. **Process_IMPULSE_CONFIRMED にバーガードなし** — GOLD/FX/CRYPTOで共通。毎Tick実行される
6. **NormalizeDouble(rawLot, 8) の桁数不適切** — 全4メインEAで共通。ブローカーによるINVALID_VOLUMEリスク
7. **FibEngine.mqh が廃止済みだが残存** — GOLD/CRYPTOで確認。二重CalculateFibLevels定義のリスク
8. **Magic Number が 0 ハードコード** — FX/RoleReversalで確認。複数EA同時稼働で注文帰属が不可能

---

## 1. GoldBreakoutFilterEA

### Critical

| ID | 概要 | ファイル |
|----|------|---------|
| GOLD-C1 | FibEngine.mqh が廃止済みだが残存。CalculateFibLevels の二重定義リスク | FibEngine.mqh |
| GOLD-C2 | ClosePosition の OrderSend 失敗時に State が COOLDOWN に遷移しポジション孤立 | Execution.mqh:229 |
| GOLD-C3 | 証拠金維持率チェックで addMargin == 0 のゼロ除算リスク | Execution.mqh:134 |
| GOLD-C4 | GetATR_M1_Long / GetMAValue / GetATRValue が毎回ハンドル生成・解放 | Constants.mqh:351-406 |
| GOLD-C5 | ModifySL 後に g_sl が更新されず、建値移動後の risk 計算が誤る | Execution.mqh:624 |

### Warning

| ID | 概要 | ファイル |
|----|------|---------|
| GOLD-W1 | ImpulseRange を body(実体)で判定。仕様は High-Low の可能性 → 要確認 | ImpulseDetector.mqh:17 |
| GOLD-W2 | Process_IMPULSE_CONFIRMED にバーガードなし（毎Tick実行） | GoldBreakoutFilterEA.mq5:471 |
| GOLD-W3 | ClosePosition で request.magic 未設定 | Execution.mqh:204 |
| GOLD-W4 | FreezeCancel が OnTick と Process_MA_PULLBACK_WAIT で二重チェック | GoldBreakoutFilterEA.mq5:594,929 |
| GOLD-W5 | RefreshSRLevels_Gold が OnTick から毎Tick呼ばれる（g_newBar 外） | GoldBreakoutFilterEA.mq5:948 |
| GOLD-W6 | DetectSRLevels_Gold で count=0 リセットのみ。配列の古いデータが残る | SRDetector.mqh:31 |
| GOLD-W7 | CalculateSLTP で GetATR_M1(0)（未確定足）を使用 | RiskManager.mqh:120 |
| GOLD-W8 | CalcRiskPercentLot の NormalizeDouble(rawLot, 8) が lotStep と不整合 | RiskManager.mqh:202 |
| GOLD-W9 | CreateMABounceVisualization の DIR_LONG/SHORT ブランチが同一処理 | MABounceEngine.mqh:275 |
| GOLD-W10 | CheckFreezeCancel が未確定足(shift=0)を参照。仕様との整合確認要 | ImpulseDetector.mqh:172 |
| GOLD-W11 | Process_ENTRY_PLACED で PositionSelectByTicket 失敗時のタイムアウトなし | GoldBreakoutFilterEA.mq5:708 |
| GOLD-W12 | GetExitEMA でエラー時に 0.0 を返す（EMPTY_VALUE を使うべき） | Execution.mqh:239 |
| GOLD-W13 | DumpImpulseSummary が毎回ファイルを開閉 | Logger.mqh:121 |

### Suggestion

| ID | 概要 |
|----|------|
| GOLD-S1 | SPEC.md の Confirm 優先順位が旧 Fib 2-Touch 時代のまま（ADR-017 未反映） |
| GOLD-S2 | SPEC.md の BandWidthPts 定義が ATR(M1)×0.05 のまま（ADR-017 では HTF ATR×BandMult） |
| GOLD-S3 | EMA Cross Filter の Slow=EMA50 ハードコードにコメントなし |
| GOLD-S4 | g_cooldownDuration=3 がグローバル変数（定数 or MarketProfile 推奨） |
| GOLD-S5 | 構造無効チェック後の統計記録が30行以上で可読性低下（別関数切り出し推奨） |
| GOLD-S6 | SMA ハンドルが ANALYZE 以外でも常に生成される |
| GOLD-S7 | CountSRTouches_Gold が毎回 iATR ハンドルを生成（g_atrHandleM15 を使うべき） |
| GOLD-S8 | PanelDeleteAll の OBJ_LABEL 型フィルタとサブウィンドウ指定の不整合 |
| GOLD-S9 | SPEC.md の状態遷移図が旧 Fib 2-Touch 時代のまま |

---

## 2. FXRetracePulseEA

### Critical

| ID | 概要 | ファイル |
|----|------|---------|
| FX-C1 | Process_IMPULSE_CONFIRMED にバーガードなし。BandWidthPts が毎Tick再計算され仕様違反 | FXRetracePulseEA.mq5:480 |
| FX-C2 | ENTRY_PLACED → IN_POSITION でポジション未約定時にタイムアウトなし | FXRetracePulseEA.mq5:818 |
| FX-C3 | UseLimitEntry=true でも TRADE_ACTION_DEAL（成行）で発注。仕様「指値」と不一致 | Execution.mqh:83 |
| FX-C4 | ClosePosition の OrderSend 失敗時に State 遷移してポジション孤立 | Execution.mqh:204 |
| FX-C5 | ModifySL 後に g_sl が更新されずパネル表示・RR計算が不正 | Execution.mqh:581 |
| FX-C6 | FillDeviationExceeded で ClosePosition 後に g_ticket=0 リセット → ポジション追跡喪失 | Execution.mqh:185 |

### Warning

| ID | 概要 | ファイル |
|----|------|---------|
| FX-W1 | GetMAValue/GetATRValue が毎回ハンドル生成・解放 | Constants.mqh:335 |
| FX-W2 | TrendFilter データ取得失敗を FLAT 扱い → M5 Slope STRONG でもReject | EntryEngine.mqh:191 |
| FX-W3 | M5 Slope Filter の MID 判定が仕様と不一致（STRONG のみ通過） | EntryEngine.mqh:315 |
| FX-W4 | BandWidthPts が瞬間 Bid/Ask 差を使用（高スプレッド時に帯幅異常） | MarketProfile.mqh:31 |
| FX-W5 | CalcRiskPercentLot の NormalizeDouble(rawLot, 8) | RiskManager.mqh:183 |
| FX-W6 | MinRR_EntryGate の RR 計算コードが残存（廃止済みだがコメントなし） | FXRetracePulseEA.mq5:779 |
| FX-W7 | Process_ENTRY_PLACED の 21MA チェックが約定タイミングとずれる可能性 | FXRetracePulseEA.mq5:828 |
| FX-W8 | PanelSetLine が ObjectCreate の戻り値を無視 | Visualization.mqh:159 |
| FX-W9 | g_freezeCancelCount の二重管理（OnTick と Process_FIB_ACTIVE） | FXRetracePulseEA.mq5:1013,587 |
| FX-W10 | 証拠金維持率チェックで addMargin が微小値の場合に newLevel が異常に大きくなる | Execution.mqh:132 |

### Suggestion

| ID | 概要 |
|----|------|
| FX-S1 | CheckStructureInvalid_Detail が未使用（デッドコード） |
| FX-S2 | STATE_TOUCH_1 への遷移が設計上発生しないのにロジック残存 |
| FX-S3 | request.magic = 0 がハードコード。複数EA同時稼働で識別不可 |
| FX-S4 | GetCurrentSpreadPts の単位（整数ポイント vs 実価格差）が各所で混在 |
| FX-S5 | UpdateFractalMicroLevels が CheckMicroBreak と Process_TOUCH_2 で二重実行 |
| FX-S6 | AcquireLogSlot のロックファイル方式がバックテストで機能しない |
| FX-S7 | GenerateTradeUUID が秒単位のみで衝突リスク |
| FX-S8 | EnableTrading=false の防御チェックが ExecuteEntry にない |
| FX-S9 | PanelDeleteAll の ObjectsTotal と ObjectName の型フィルタ不整合 |

---

## 3. CryptoImpulseRetraceEA

### Critical

| ID | 概要 | ファイル |
|----|------|---------|
| CRYPTO-C1 | Confirm が仕様（MicroBreak Lookback型）と不一致。CloseBounce/WickRejection を使用 | MABounceEngine.mqh:128 |
| CRYPTO-C2 | CheckMADirection の shift 計算不正（shift+2 で1本飛ばし） | MABounceEngine.mqh:112 |
| CRYPTO-C3 | EnableTrading=false でも ExecuteEntry に到達して実注文が発行される | Execution.mqh:52 |
| CRYPTO-C4 | ClosePosition の OrderSend 失敗時にポジション孤立 | Execution.mqh:195 |
| CRYPTO-C5 | UseLimitEntry=true でも実質成行注文（TRADE_ACTION_DEAL） | Execution.mqh |
| CRYPTO-C6 | NormalizeDouble(rawLot, 8) が lotStep と不整合。BTCUSD で INVALID_VOLUME リスク | RiskManager.mqh:181 |

### Warning

| ID | 概要 | ファイル |
|----|------|---------|
| CRYPTO-W1 | GetMAValue/GetATRValue が毎回ハンドル生成・解放 | Constants.mqh:338 |
| CRYPTO-W2 | CheckFreezeCancel が OnTick と Process_MA_PULLBACK_WAIT で二重チェック | CryptoImpulseRetraceEA.mq5:730,504 |
| CRYPTO-W3 | ModifySL で retcode 未確認（OrderSend=true でも retcode!=DONE の場合） | Execution.mqh:391 |
| CRYPTO-W4 | BandWidth 算出が仕様 ATR(M1)×0.08 と不一致（ATR(M5)×0.5）。ADR-017 が上書きか要確認 | MABounceEngine.mqh:99 |
| CRYPTO-W5 | Process_IMPULSE_CONFIRMED にバーガードなし | CryptoImpulseRetraceEA.mq5:398 |
| CRYPTO-W6 | CheckStructureInvalid_Detail で _Point を直接使用。BTCUSD で値が極大化 | RiskManager.mqh:28 |
| CRYPTO-W7 | FibEngine.mqh が廃止済みだが残存。CalculateFibLevels の二重定義リスク | FibEngine.mqh |
| CRYPTO-W8 | スプレッド取得の単位（整数ポイント vs 実価格差）が Logger と Execution で不統一 | Execution.mqh:13, Logger.mqh:259 |
| CRYPTO-W9 | FreezeCancel の g_barsAfterFreeze 更新タイミングが OnTick と Process で不整合 | CryptoImpulseRetraceEA.mq5:731 |
| CRYPTO-W10 | Process_ENTRY_PLACED で PositionSelectByTicket 失敗時のタイムアウトなし | CryptoImpulseRetraceEA.mq5:612 |

### Suggestion

| ID | 概要 |
|----|------|
| CRYPTO-S1 | g_cooldownDuration=3 がハードコード（MarketProfile or Input 推奨） |
| CRYPTO-S2 | g_bandWidthPts と g_maBounceBandWidth が冗長（統一推奨） |
| CRYPTO-S3 | CheckMABounce の htfBarTime 重複チェックの設計意図コメント不足 |
| CRYPTO-S4 | GenerateTradeUUID が秒単位のみ（衝突リスク） |
| CRYPTO-S5 | Process_COOLDOWN のカウントタイミングで実質2本クールダウンになるケース |
| CRYPTO-S6 | PurgeOldMAObjectsExcept の ObjectsTotal が全型列挙（OBJ_RECTANGLE に絞るべき） |
| CRYPTO-S7 | ログファイル名の日付が TimeCurrent() 依存（日またぎで切替） |

---

## 4. RoleReversalEA

### Critical

| ID | 概要 | ファイル |
|----|------|---------|
| RR-C1 | Magic 番号が 0 ハードコード。仕様は 20260307+MagicOffset | RoleReversalEA.mq5:89 |
| RR-C2 | result.deal をポジションチケットとして使用（result.order が正しい） | RoleReversalEA.mq5:1041 |
| RR-C3 | ConfirmBreakout の確認カウントが off-by-one。実質 BO_ConfirmBars-1 本で確定 | RoleReversalEA.mq5:597,679 |
| RR-C4 | CountSRTouches で H1 ATR ハンドルを毎回生成（g_atrH1Handle 未使用） | SRDetector.mqh:127 |
| RR-C5 | RefreshSRLevels で broken_direction/broken_time が復元されない | RoleReversalEA.mq5:527 |

### Warning

| ID | 概要 | ファイル |
|----|------|---------|
| RR-W1 | CopyBuffer/CopyHigh 等の戻り値チェック漏れが多数 | RoleReversalEA.mq5:312, SRDetector.mqh:30 |
| RR-W2 | g_magic=0 による CheckExistingPosition のフィルタ不正 | RoleReversalEA.mq5:1136 |
| RR-W3 | エントリー価格が m5Close[1] 基準だが実約定価格と乖離するリスク | RoleReversalEA.mq5:857 |
| RR-W4 | CalculateLot で MathFloor を二重適用 | RoleReversalEA.mq5:1097 |
| RR-W5 | ロックファイル方式の競合検出が不完全（FILE_WRITE のみ） | Logger.mqh:69 |
| RR-W6 | BREAKOUT_CONFIRMED / ENTRY_READY ステートが switch に存在しない（default: IDLE に落ちる） | RoleReversalEA.mq5:466 |
| RR-W7 | ManagePosition の ResetState() が COOLDOWN を即 IDLE に上書きする | RoleReversalEA.mq5:1117 |
| RR-W8 | Visualization の ObjectsTotal/ObjectName の型フィルタ不整合 | Visualization.mqh:201 |
| RR-W9 | RR_WriteLog で sl/tp/srLevel の 0 判定が「未設定」判定として不正確 | Logger.mqh:191 |
| RR-W10 | SRDetector のスウィング検出で CopyHigh 戻り値未チェック → 境界外アクセスリスク | SRDetector.mqh:42 |

### Suggestion

| ID | 概要 |
|----|------|
| RR-S1 | ScanForBreakout で CopyHigh/CopyLow を Bullish/Bearish で重複実行 |
| RR-S2 | ConfirmEngine の各検出関数が毎回 CopyOpen/High/Low/Close を実行 |
| RR-S3 | BREAKOUT_CONFIRMED / ENTRY_READY の存在意義を再検討（削除 or 実装） |
| RR-S4 | CalculateLot の Print が LogLevel に関係なく毎エントリー実行 |
| RR-S5 | EnablePush のデフォルトが仕様(false)と実装(true)で不一致 |
| RR-S6 | SR_MinTouches 入力パラメータが実際のフィルタリングに未使用 |
| RR-S7 | LoadStateFromTFChange の tolerance が ATR×0.1 固定（SR_MergeTolerance と不整合） |
| RR-S8 | ClearSavedState の brk_* 削除が連番欠番で打ち切り（break→continue 推奨） |

---

## 5. CloseByCrossEA

### Critical

| ID | 概要 | ファイル |
|----|------|---------|
| CBC-C1 | PositionExists() が PositionGetTicket ループ（PositionSelectByTicket に統一すべき） | CloseByCrossEA.mq5:116 |
| CBC-C2 | Filling Mode 自動判定が未実装（ブローカーによりFOK非対応で全決済失敗） | CloseByCrossEA.mq5 OnInit |
| CBC-C3 | OnInit エラー時に INIT_SUCCEEDED を返す（INIT_FAILED が適切） | CloseByCrossEA.mq5:194 |

### Warning

| ID | 概要 | ファイル |
|----|------|---------|
| CBC-W1 | CONFIRM_WAIT 中の CheckPositionAlive と TryClose の g_goneCount 二重管理 | CloseByCrossEA.mq5:263 |
| CBC-W2 | g_lastRetryTime の 1秒判定で <= vs < の意図が不明確 | CloseByCrossEA.mq5:256 |

---

## 6. CloseByFlatRangeEA

### Critical

| ID | 概要 | ファイル |
|----|------|---------|
| CBFR-C1 | CLOSE_MAX_RETRY の判定が off-by-one（`>` → `>=` に修正） | CloseByFlatRangeEA.mq5:514 |

### Warning

| ID | 概要 | ファイル |
|----|------|---------|
| CBFR-W1 | GlobalVariable キーに Symbol が含まれず衝突リスク | CloseByFlatRangeEA.mq5:693 |
| CBFR-W2 | CaptureClosePrice が POSITION_PRICE_CURRENT を使用（実約定価格ではない） | CloseByFlatRangeEA.mq5:443 |
| CBFR-W3 | HasFavorableBreakout 後に ATR 取得失敗で g_trailLine=0 → SELL で即 TrailStop 誤発動 | CloseByFlatRangeEA.mq5:1102 |
| CBFR-W4 | LoadState 後に g_posDir が復元されない（ログの Dir 列が空） | CloseByFlatRangeEA.mq5:735 |

### Suggestion

| ID | 概要 |
|----|------|
| CBFR-S1 | ATRPeriod がプリセット ApplyPreset に含まれない |
| CBFR-S2 | TrailATRMult がプリセットでオーバーライドされない |
| CBFR-S3 | ObjectCreate の戻り値未確認 |
| CBFR-S4 | OBJPROP_SELECTABLE=false / OBJPROP_HIDDEN=true 未設定 |
| CBFR-S5 | MessageBox がバックテスト環境でブロックする（MQL_TESTER チェック推奨） |

---

## 仕様書（SPEC.md）の更新が必要な箇所

| # | 内容 | 理由 |
|---|------|------|
| 1 | 状態遷移図を市場別に更新 | GOLD/CRYPTO は MA Bounce 移行済み（ADR-017）だが遷移図が旧 Fib 2-Touch のまま |
| 2 | BandWidthPts 定義表を更新 | GOLD/CRYPTO は HTF ATR × BandMult に変更済みだが表が ATR(M1)×0.05/0.08 のまま |
| 3 | Confirm 優先順位を更新 | GOLD/CRYPTO の Confirm が CloseBounce/WickRejection に変更済みだが旧定義のまま |
| 4 | CRYPTO の Confirm 定義を明確化 | SPEC は MicroBreak Lookback 型、実装は CloseBounce/WickRejection。どちらが正か要判断 |
| 5 | ImpulseRangePts の定義を明確化 | body（実体）か Range（High-Low）か未定義 |
| 6 | FreezeCancel の監視単位を明確化 | Tick 単位かバー確定単位かが SPEC で不明確 |

---

## 最優先対応リスト（全EA横断）

以下は **資金に直結する問題** のため最優先で修正すべき項目:

| 優先 | ID | EA | 概要 |
|------|----|----|------|
| 1 | 共通 | GOLD/FX/CRYPTO | ClosePosition 失敗時の State 不整合（ポジション孤立） |
| 2 | GOLD-C5, FX-C5 | GOLD/FX | ModifySL 後に g_sl 未更新（建値移動後の risk 誤算） |
| 3 | RR-C2 | RoleReversal | result.deal をポジションチケットとして使用 |
| 4 | RR-C7 | RoleReversal | COOLDOWN が ResetState() で即 IDLE に上書き |
| 5 | CRYPTO-C3 | CRYPTO | EnableTrading=false でも実注文が発行される |
| 6 | CBC-C2 | CloseByCross | Filling Mode 未設定（全決済失敗リスク） |
| 7 | CBFR-W3 | CloseByFlatRange | ATR 取得失敗で SELL の TrailStop 即発動 |
| 8 | RR-C3 | RoleReversal | BO_ConfirmBars の off-by-one |
| 9 | CRYPTO-C2 | CRYPTO | CheckMADirection の shift+2 飛ばし |
| 10 | 共通 | GOLD/FX/CRYPTO | Process_ENTRY_PLACED のタイムアウトなし |
