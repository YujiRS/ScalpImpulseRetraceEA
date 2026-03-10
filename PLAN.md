# Implementation Plan: S/R Target Exit for GOLD

## 概要
RoleReversalEA の H1 Swing High/Low → S/R レベル検出ロジックを GoldBreakoutFilterEA に導入。
最も近い有効 S/R レベルを「サーバーTP」として設定し、EMA クロスはフォールバックとして維持。

## シミュレーション結果（根拠）
- GOLD skip_atr=0.5: Conv比 +5,985 pips 改善
- SR_TP ヒット時: WR=100%, P&L中央値 +857 pips, bars中央値=23
- FX/CRYPTO では逆効果 → GOLD 限定

## 設計判断

### Exit 優先順位（変更後）
1. **構造破綻（Fib0）** — 変更なし
2. **時間撤退** — 変更なし
3. **建値移動** — 変更なし
4. **S/R Target TP** — **NEW**: H1 S/R レベルに到達 → 成行決済
5. **EMAクロス決済 / FlatRange** — フォールバック（変更なし）

S/R TP は EMA クロスより優先順位が高い。S/R に到達すれば即決済。
到達しなければ従来通り EMA クロスで決済（フォールバック）。

### S/R 検出タイミング
- OnInit で H1 S/R レベルを検出、配列に格納
- H1 新バー発生ごとに再検出（RefreshInterval=12）
- SRDetector.mqh を GoldBreakoutFilterEA/ 配下に新規作成（RoleReversalEA からロジック移植、依存関係なし）

### S/R ターゲット選定ロジック
- エントリー時（STATE_ENTRY_PLACED → STATE_IN_POSITION 遷移時）に選定
- ポジション方向の「直近 S/R レベル」を探す
- ただし ATR(H1,14) × SR_SkipATRMult 圏内のレベルはスキップ → その先を採用
- 有効な S/R レベルがない場合 → g_srTargetTP = 0（フォールバック: EMA クロスのみ）

### サーバー TP
- 現行: g_tp = 0（常時）
- 変更後: g_tp = g_srTargetTP（S/R レベルが見つかった場合のみ）
  - サーバーTP として設定するため、ブローカー側で自動決済される
  - EA 側でも ManagePosition 内で到達チェック（二重安全）

### 新規 Input パラメータ（G1:Exit グループ）
```
input bool   SR_Exit_Enable       = true;   // S/Rターゲット Exit ON/OFF
input double SR_SkipATRMult       = 0.5;    // S/Rスキップ閾値 ATR × this
input int    SR_SwingLookback     = 7;      // H1 Swing検出 Lookback
input double SR_MergeATRMult      = 0.5;    // S/Rレベル統合 ATR × this
input int    SR_MinTouches        = 2;      // S/Rレベル最小タッチ回数
input int    SR_MaxAgeBars        = 200;    // S/Rレベル最大年齢（H1 bars）
input int    SR_RefreshInterval   = 12;     // S/R再検出間隔（H1 bars）
```

## 実装ファイル

### 1. 新規: `src/Experts/GoldBreakoutFilterEA/SRDetector.mqh`
- SRLevel_Gold 構造体定義（RoleReversalEAの同名structと衝突回避）
- DetectSRLevels_Gold(): H1 Swing High/Low → S/R 検出 + マージ + タッチカウント
- FindSRTarget_Gold(): 方向別の直近有効レベル探索（skip zone 考慮）
- RefreshSRLevels_Gold(): H1 新バー時の再検出ラッパー

### 2. 変更: `src/Experts/GoldBreakoutFilterEA.mq5`
- Input 追加（SR_Exit_Enable 等）
- グローバル変数追加（g_srTargetTP, g_srLevels[], g_srCount, g_srLastRefreshBarTime, g_atrHandleH1）
- OnInit: H1 ATR ハンドル作成 + S/R 初期検出
- OnTick: H1 新バーチェック → RefreshSRLevels_Gold()
- Process_ENTRY_PLACED: S/R ターゲット選定 → g_srTargetTP 設定
- ResetAllState: g_srTargetTP = 0

### 3. 変更: `src/Experts/GoldBreakoutFilterEA/RiskManager.mqh`
- CalculateSLTP(): SR_Exit_Enable && g_srTargetTP > 0 の場合、g_tp = g_srTargetTP

### 4. 変更: `src/Experts/GoldBreakoutFilterEA/Execution.mqh`
- ManagePosition(): 建値移動の後、モード分岐（P4/P5）の前に S/R TP チェック追加
  - LONG: close1 >= g_srTargetTP → ClosePosition("SR_TP")
  - SHORT: close1 <= g_srTargetTP → ClosePosition("SR_TP")

### 5. 変更: `docs/SPEC.md`
- §9 決済仕様に S/R Target TP を追加

### 6. 変更: `docs/DECISIONS.md`
- ADR-019: S/R Target Exit 追加（GOLD限定）の意思決定を記録

## 実装順序
1. SRDetector.mqh 作成
2. GoldBreakoutFilterEA.mq5 に Input + グローバル変数 + 初期化 + リフレッシュ追加
3. RiskManager.mqh: CalculateSLTP に S/R TP 反映
4. Execution.mqh: ManagePosition に S/R TP チェック追加
5. SPEC.md / DECISIONS.md 更新
6. コミット＆プッシュ
