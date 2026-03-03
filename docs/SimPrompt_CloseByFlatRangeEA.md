# **CloseByFlatRangeEA：Exit戦略シミュレーション＆最適化プロンプト**

---

## **あなたへの依頼**

添付した M1 CSVデータ（`{SYMBOL}__M1_YYYYMMDD_YYYYMMDD.csv`）に対して、
CloseByFlatRangeEA の決済ロジックをPythonでシミュレーションし、
**既存のMAクロス決済（CloseByCrossEA）との比較** → **パラメータ最適化** → **市場別推奨パラメータ** まで一貫して進めてください。

**対象市場**: {FX / GOLD / CRYPTO} （添付CSVのシンボルに合わせて自動判定）

---

## **添付ファイル（全て必須）**

1. **M1 CSVデータ** — シミュレーション対象（カラム: datetime, open, high, low, close, tick_volume）
2. **CloseByFlatRangeEA.mq5** — 新Exit EA（v1.00, Flat+Range決済）
3. **CloseByCrossEA.mq5** — 旧Exit EA（v1.05, SMA13/21クロス決済）— 比較ベースライン
4. **ポジションログCSV**（任意）— ScalpImpulseRetraceEA等のEntry情報。無い場合は合成ポジションを生成する（Phase 1参照）

---

## **背景**

### **なぜ決済ロジックを変えるのか**

CloseByCrossEA（SMA13/SMA21クロス決済）には以下の構造問題がある：

1. **クロス遅延**: SMA13/21のクロスはトレンド転換完了後に発生するため、利益の大半を返してから決済される。特にスキャルピングでは致命的。
2. **偽クロス問題**: レンジ内でSMAが絡み合い、偽クロスが頻発する。1本確認ルールで軽減しているが根本解決にならない。
3. **市場差異への非対応**: FX/GOLD/CRYPTOでMA挙動が大きく異なるが、SMA13/21固定では調整できない。

### **CloseByFlatRangeEAの設計意図**

「トレンド勢い低下（MAフラット化）→ 局所レンジの特定位置で決済」という2段階方式で：
- クロスを待たず「勢い消失」の時点で早期にexit準備に入る
- レンジ内のどこで決済するか（MID/有利端/不利端）を選べる
- 待ちすぎ防止のFailSafe＋5MA補助で逆行リスクを制御

### **検証すべき仮説**

| # | 仮説 | 検証方法 |
|---|------|----------|
| H1 | FlatRangeはCrossより早く決済できる | 両EA決済タイミング比較 |
| H2 | 早期決済により利益残存率（captured P&L / peak P&L）が改善する | Exit効率分析 |
| H3 | FlatSlopeAtrMultが小さすぎるとFlatを検出できず実質Crossより遅くなる | パラメータ感度分析 |
| H4 | ExitTarget=MIDが万能ではなく、市場によってはFAV_EDGEが優位 | ExitTarget別P&L比較 |
| H5 | 5MA AssistはFX/GOLDで有効だが、CRYPTOではノイズで誤発火する | Assist発火率＋P&L影響 |
| H6 | WaitBarsAfterFlatは市場ボラティリティに比例させるべき | FailSafe発火率 vs 逸失利益 |

---

## **実行手順**

### **Phase 1: sim_exit.py の構築**

M1 CSVデータから両EAの決済ロジックをシミュレーションするPythonスクリプト `sim_exit.py` を構築する。

#### 1-1) テストポジション生成

ポジションログCSVが添付されている場合はそれを使用する。
無い場合は以下のルールで合成ポジションを生成する：

```python
# 合成ポジション生成ルール
# 目的: 様々なトレンド局面でのexit性能を評価するため、
#        トレンド開始点にBUY/SELLポジションを配置する
#
# 方法:
# 1. M1データ上でSMA21の傾きが一定以上になった足をトレンド開始とみなす
# 2. 上昇トレンド開始 → BUYポジション（entry_price = close[i]）
# 3. 下降トレンド開始 → SELLポジション（entry_price = close[i]）
# 4. 同時に複数ポジションは持たない（前のexitが完了してから次を生成）
# 5. 最低100ポジション以上生成できるデータ量が必要
```

ポジションCSVフォーマット（生成 or 入力）：
```
entry_bar_index, entry_datetime, direction(BUY/SELL), entry_price
```

#### 1-2) CloseByFlatRangeEA ロジック移植

MQL5の状態遷移を忠実に再現する。以下の処理をバー単位で実行：

```
状態遷移:
  WAIT_FLAT → (flat検出) → RANGE_LOCKED_WAIT_TARGET → (target到達 or failsafe) → CLOSED

各バーの処理:
  1. [確定足] フラット判定:
     SlopePts = abs(MA[1] - MA[1 + FlatSlopeLookbackBars]) / point
     ATRPts   = ATR[1] / point
     Flat成立 = SlopePts <= ATRPts * FlatSlopeAtrMult

  2. [確定足] レンジ確定（フラット成立時に1回だけ）:
     RangeHigh = max(High[1..RangeLookbackBars])
     RangeLow  = min(Low[1..RangeLookbackBars])
     RangeMid  = (RangeHigh + RangeLow) / 2

  3. [毎バー] ターゲット到達判定:
     BUY:  Bid基準 → MID: close>=RangeMid / FAV: close>=RangeHigh / UNFAV: close<=RangeLow
     SELL: Ask基準 → MID: close<=RangeMid / FAV: close<=RangeLow  / UNFAV: close>=RangeHigh
     ※ M1シミュレーションではBid≈close, Ask≈close+spread で近似

  4. [確定足] WaitBars超過チェック:
     waitCount > WaitBarsAfterFlat → FailSafe発動

  5. [確定足] 5MA Assist チェック:
     BUY:  close < RangeMid AND EMA5[1] < EMA5[2] AND close <= RangeLow → FailSafe発動
     SELL: close > RangeMid AND EMA5[1] > EMA5[2] AND close >= RangeHigh → FailSafe発動
```

#### 1-3) CloseByCrossEA ロジック移植（ベースライン）

比較のため、MAクロス決済も同一ポジションに対してシミュレーションする：

```
状態遷移:
  WAIT_SYNC → ARMED → (cross検出) → CONFIRM_WAIT → (1本確認) → CLOSED

各バーの処理:
  1. SMA13/SMA21 のクロス検出（確定足2本で判定）
     GoldenCross: SMA13[2] <= SMA21[2] AND SMA13[1] > SMA21[1]
     DeadCross:   SMA13[2] >= SMA21[2] AND SMA13[1] < SMA21[1]

  2. クロス方向とポジション方向の一致確認
     GoldenCross → SELLのみ決済 / DeadCross → BUYのみ決済

  3. 1本確認（次の確定足でクロス状態が維持されているか）
```

#### 1-4) オラクル（理想exit）の計算

各ポジションに対して、entryからN本以内の最適exit価格を計算する：

```python
# BUY: entry後の max(high) に達した足で決済した場合のP&L
# SELL: entry後の min(low) に達した足で決済した場合のP&L
# N = 120 (2時間分のM1)をデフォルトの観測窓とする
```

---

### **Phase 2: ベースラインシミュレーション**

デフォルトパラメータで両EAを実行し、基礎データを収集する。

#### CloseByFlatRangeEA デフォルトパラメータ

| パラメータ | デフォルト値 |
|-----------|-------------|
| FlatMaMethod | SMA |
| FlatMaPeriod | 21 |
| FlatSlopeLookbackBars | 5 |
| ATRPeriod | 14 |
| FlatSlopeAtrMult | 0.10 |
| RangeLookbackBars | 10 |
| ExitTarget | MID |
| WaitBarsAfterFlat | 8 |
| FailSafe | MARKET_CLOSE |
| UseAssist5MA | true |

#### CloseByCrossEA パラメータ（固定）

| パラメータ | 値 |
|-----------|-----|
| SMA Fast | 13 |
| SMA Slow | 21 |
| 確認本数 | 1 |

#### 出力する集計

```
=== Exit Pipeline（CloseByFlatRangeEA） ===
Total Positions:        N
Flat Detected:          n1  (n1/N %)   ← フラット検出率
  Flat検出までのバー数:  median / mean / P25 / P75
Range Locked:           n2  (n2/n1 %)  ← 常にn1と同数のはず
Exit by Target:         n3  (n3/n2 %)  ← ターゲット到達率
Exit by FailSafe:       n4  (n4/n2 %)  ← WaitBars超過
Exit by 5MA Assist:     n5  (n5/n2 %)  ← 5MA早逃げ
Flat未検出(data end):   n6             ← データ終了で未決済

=== Exit Pipeline（CloseByCrossEA） ===
Total Positions:        N
Cross Detected:         m1  (m1/N %)
Cross Confirmed:        m2  (m2/m1 %)  ← 偽クロス除去率
Exit by Cross:          m3
Cross未検出(data end):  m4

=== 比較サマリ ===
                        FlatRange     Cross       差分
決済率:                 xx%           yy%
決済までのバー数(中央値): aa            bb          (早/遅)
Exit P&L(中央値, pips):  cc            dd
Exit効率(中央値):        ee%           ff%
  ※Exit効率 = actual_pnl / oracle_pnl × 100
勝率(P&L>0):            gg%           hh%
```

---

### **Phase 3: Exit行動分析**

ベースライン結果を掘り下げ、ボトルネックと特性を特定する。

#### 3-1) フラット検出タイミング分析

- フラット検出バーは「トレンドピーク」からどのくらい遅れているか？
  - BUY: entry後のmax(high)出現バー vs flat検出バー → ラグ（本数）
  - SELL: entry後のmin(low)出現バー vs flat検出バー → ラグ（本数）
- ラグの分布をヒストグラムで出力
- ラグが大きいケース（>20本）の価格推移を個別確認

#### 3-2) レンジ品質分析

- レンジ幅（RangeHigh - RangeLow）の分布（pips）
- レンジ幅 vs ATR(14) の比率分布 → レンジがATRの何倍か
- RangeMidはフラット検出時点のcloseと乖離しているか？
  - 乖離率 = abs(close - RangeMid) / (RangeHigh - RangeLow)
  - 0.5超 = MIDが端に近い = MIDターゲットが即到達しやすい

#### 3-3) Exit理由別P&L分析

| Exit理由 | 件数 | P&L中央値 | P&L平均 | 勝率 | Exit効率中央値 |
|----------|------|-----------|---------|------|---------------|
| Target(MID) | | | | | |
| FailSafe(WaitBars) | | | | | |
| 5MA Assist | | | | | |

- FailSafe発動ケースのP&L分布 → FailSafeが損切りとして機能しているか、利確を逃しているか
- 5MA Assist発動ケースは本当に「戻り失敗→逆行」のパターンだったか？
  - 5MA Assist後の価格推移（exit後10本のclose方向）を確認 → 正しい早逃げだったか

#### 3-4) Cross決済との個別比較

各ポジションについて：
- FlatRange exit bar vs Cross exit bar の散布図
- FlatRangeが早い場合: 早逃げ分の利益残存 or 機会逸失
- Crossが早い場合: Crossでの決済時のFlatRange状態は何だったか

---

### **Phase 4: パラメータ感度分析**

以下のパラメータを系統的にスイープし、最適値を探索する。

#### 4-1) フラット検出感度（最重要）

```
FlatSlopeAtrMult: [0.03, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20, 0.30]
```

各値について：
- フラット検出率、検出タイミング（ラグ中央値）、Exit P&L中央値
- 閾値が小さいほど検出が早いが、トレンド中に誤検出するリスク

#### 4-2) MA設定

```
FlatMaPeriod: [13, 21, 34, 50]
FlatMaMethod: [SMA, EMA]
FlatSlopeLookbackBars: [3, 5, 8, 10]
```

- Period×Method×Lookbackの3次元スイープは重いため、まず：
  1. FlatMaPeriod を固定して Method×Lookback を 2×4=8通り
  2. 最良 Method×Lookback で Period を 4通り
  - の2段階で探索

#### 4-3) ExitTarget比較

```
ExitTarget: [MID, FAVORABLE_EDGE, UNFAVORABLE_EDGE]
```

各ターゲットについて：
- 到達率（WaitBars内に到達できた割合）
- 到達までのバー数
- Exit P&L
- FailSafe発動率

予想：
- FAV_EDGE: 到達率低い → FailSafe多発 → P&L改善しない可能性
- UNFAV_EDGE: 到達率高い（即到達）→ 損切り的動作 → P&Lは低い
- MID: バランス型

#### 4-4) RangeLookbackBars

```
RangeLookbackBars: [5, 8, 10, 15, 20]
```

- レンジ幅とExitタイミングへの影響
- 小さいL: 狭レンジ → MIDが近い → 早めexit
- 大きいL: 広レンジ → MIDが遠い → FailSafe多発

#### 4-5) WaitBarsAfterFlat

```
WaitBarsAfterFlat: [4, 6, 8, 12, 16, 24]
```

- FailSafe発動率への影響
- 待ちすぎによるP&L悪化 vs 早切りによるTarget逸失

#### 4-6) 5MA Assist ON/OFF

```
UseAssist5MA: [true, false]
```

- Assist発火件数、発火時P&L、発火後の価格推移
- OFFにした場合のFailSafe依存度

#### 4-7) 出力フォーマット

各スイープの結果を以下の比較表で出力：

```
=== FlatSlopeAtrMult Sweep ===
| Mult  | Flat検出率 | ラグ(中央値) | Target到達率 | FS率 | 5MA率 | P&L中央値 | Exit効率 | 勝率 |
|-------|-----------|-------------|-------------|------|-------|----------|---------|------|
| 0.03  |           |             |             |      |       |          |         |      |
| 0.05  |           |             |             |      |       |          |         |      |
| ...   |           |             |             |      |       |          |         |      |
```

---

### **Phase 5: 市場別推奨パラメータの導出**

Phase 4 の結果を踏まえ、以下の基準で市場別推奨パラメータを決定する。

#### 判定基準（優先順）

1. **Exit効率 > 50%**: oracle対比で半分以上の利益を捕捉できること
2. **FailSafe率 < 30%**: ターゲット到達で決済できるケースが主であること
3. **Cross比改善**: CloseByCrossEA対比でP&L中央値が改善すること
4. **決済率 > 90%**: データ内でほぼ全ポジションが決済されること

#### 出力フォーマット

```
=== 市場別推奨パラメータ ===

■ {SYMBOL} ({MARKET_TYPE})
  FlatMaMethod         = SMA / EMA
  FlatMaPeriod         = XX
  FlatSlopeLookbackBars = XX
  FlatSlopeAtrMult     = X.XX
  ATRPeriod            = XX
  RangeLookbackBars    = XX
  ExitTarget           = MID / FAV_EDGE / UNFAV_EDGE
  WaitBarsAfterFlat    = XX
  UseAssist5MA         = true / false

  根拠:
  - (各パラメータの選定理由を簡潔に)

  ベースライン比較:
                          推奨値     デフォルト   Cross(参考)
  Exit P&L中央値(pips):   XX         XX          XX
  Exit効率:               XX%        XX%         XX%
  FailSafe率:             XX%        XX%         XX%
  勝率:                   XX%        XX%         XX%
```

---

### **Phase 6: MQL反映（必要な場合のみ）**

Phase 5 でデフォルト値の変更が推奨される場合、CloseByFlatRangeEA.mq5 の input初期値を更新する。

- ロジック自体の変更は行わない（パラメータ初期値の変更のみ）
- ロジック変更が必要と判断された場合は、変更提案を別途レポートする（実装はしない）
- 変更箇所と根拠をChangelogに記録する

---

## **出力（期待するもの）**

| # | ファイル | 内容 |
|---|---------|------|
| 1 | `sim_exit.py` | Pythonシミュレーター（FlatRange + Cross + Oracle） |
| 2 | `exit_analysis_{SYMBOL}.md` | Phase 2-3: ベースライン＋行動分析レポート |
| 3 | `exit_optimization_{SYMBOL}.md` | Phase 4-5: パラメータスイープ結果＋推奨値 |
| 4 | `CloseByFlatRangeEA.mq5` | Phase 6: 初期値更新版（変更がある場合のみ） |
| 5 | `CHANGELOG_Exit.md` | 変更履歴 |

---

## **注意事項**

### シミュレーション上の制約

* M1 CSVにはBid/Ask情報が無いため、ターゲット到達判定は `close` で近似する。
  スプレッドは市場ごとに以下の定数で概算し、SELL側は `close + spread` で判定する：
  - FX（USDJPY等）: 0.3 pips
  - FX（EURUSD等）: 0.2 pips
  - GOLD: 20 points (0.20)
  - CRYPTO（BTCUSD）: 50 points (50.0)
  シンボルに応じて自動設定し、input `SpreadOverride` で上書き可能にすること。

* M1データは1バー = 1分。CloseByCrossEAのSignalTFがM1以外（M5等）の場合はHTF足を内部生成する必要がある。
  まずはSignalTF=M1（PERIOD_CURRENT相当）でシミュレーションし、HTF対応は必要に応じて後から追加する。

### ロジック忠実性

* CloseByFlatRangeEAの「確定足ベース」を厳守する。shift=0（未確定足）でのFlat判定は禁止。
  sim_exit.py上では `bar[i]` の処理時に `MA[i-1]` を参照する（= iが確定した時点のshift=1に相当）。

* レンジは「フラット検出時点で固定」する。以後のバーで更新しない。

* 5MA AssistのEMA5傾きチェックも確定足ベース。ただし価格（Bid/Ask）の到達判定は
  バーのclose（= そのバー末時点のBid近似）で行う。

* CloseByCrossEAの「初期同期フェーズ」はシミュレーションでは不要（ポジション開始時点を明示的に指定するため）。
  ただし、ポジション開始直後の1本目のバーではクロス検出を行わない（WAIT_SYNC相当の1本スキップ）。

### 分析上の注意

* 「Exit効率」は oracle_pnl=0 の場合は算出不能。oracle_pnl<=0 のポジションは
  Exit効率の集計から除外し、件数を別途報告すること。

* FlatRange と Cross で決済タイミングが大幅に異なるケース（>30本差）は
  個別に確認し、どちらの決済が「正しかった」かを事後的に評価する
  （exit後20本の価格推移で判断）。

* パラメータスイープは組み合わせ爆発を避けるため、Phase 4 で示した段階的探索を遵守する。
  全パラメータ同時最適化は行わない。
