# **EAコード仕様書：ScalpImpulseRetraceEA v1.0（設計書）**

## **0\. 目的**

Impulse後の押し（Retrace）を狙うスキャル戦略を、

**市場特性ごとにパラメータと許可レンジを分離**してEA化する。  
最速層（23.6/38.2の1回目）を追わず、\*\*「完了確認→2回目反応→反転確定」\*\*で期待値を安定化。

---

### **ログ仕様の正典**

ログ仕様（Eventログ / ImpulseSummary / 命名規則 / 列順 / 拡張方針 / RejectStage語彙）は  
**EA\_LogSpec\_v202603（DOC-LOG）** を唯一の正典とする。

※ 本書（DOC-CORE）ではログ仕様の詳細を定義しない（重複禁止）。  
※ DOC-CORE内でログ仕様を参照する場合、章番号参照（13.x等）は禁止し、常に **DOC-LOG** を参照する。  
---

## **1\. 対象市場と“押し帯”ポリシー**

### **1.1 MarketMode（シンボル特性）**

* `FX`：USDJPY / EURUSD / GBPJPY など  
* `GOLD`：XAUUSD（CFD含む）  
* `CRYPTO`：BTCUSD / ETHUSD など

### 1.2 RetraceBand（押し帯ルール）

* FX：50主軸（38.2はOptionalBandとして任意ON、初期OFF）  
* CRYPTO：50〜61.8（常時ON）  
* GOLD：50メイン \+ 条件付きで61.8 ON

---

## **2\. 全体アーキテクチャ（モジュール）**

### **2.1 モジュール構成**

1. `MarketProfile`  
* 市場別パラメータセット（FX/GOLD/CRYPTO）  
* GOLDの61.8 ON判定ロジックを持つ  
2. `ImpulseDetector`  
* Impulseの認定  
* Impulse“完了確定”（継続中の逆張り事故を防ぐ）  
* 起点算出ロジック  
  Impulse認定は単足基準で行う。 起点0の算出のみ、以下の条件付き補正を適用する。  
    
  ■ 条件（両方成立時のみ補正）  
  * 前足がImpulse方向と逆色  
  * 前足実体 \<= ATR(M1) × SmallBodyRatio

  SmallBodyRatio 初期値： FX      \= 0.35 GOLD    \= 0.40 CRYPTO  \= 0.45


  ■ 起点算出

  条件成立時： Long  \= min(Low\[ImpulseBar\], Low\[ImpulseBar-1\]) Short \= max(High\[ImpulseBar\], High\[ImpulseBar-1\])

  条件不成立時： Long  \= Low\[ImpulseBar\] Short \= High\[ImpulseBar\]

  ※ 2本より前の足は参照しない（将来ブレ防止）

3. `FibEngine`  
* Impulse起点/終点からFib算出  
* **Freeze（凍結）**：確定後は再計算しない（条件満了まで）  
4. `EntryEngine`  
* 押し帯内でのタッチ判定  
* **2回目反応**カウント  
* 反転条件（ヒゲ/包み/ミクロ構造）判定  
5. `RiskManager`
* SL算出/建値移動/時間撤退
* 取引停止（スプレッド、ニュース、スリップ超過）
* RangeCost評価用の理論TP算出（サーバーTP=0）
6. `Execution`
* 指値/成行の方針
* スリッページ上限、約定後乖離チェック
* EMAクロス決済（ManagePosition）  
7. `Logger`  
* 取引ログ、状態遷移ログ、拒否理由ログ

---

## **3\. 状態遷移（ステートマシン）**

### **3.1 State定義**

* `IDLE`：監視  
* `IMPULSE_FOUND`：Impulse認定済  
* `IMPULSE_CONFIRMED`：Impulse完了確定  
* `FIB_ACTIVE`：Fib凍結＆押し待ち  
* `TOUCH_1`：押し帯タッチ1回目（原則エントリー禁止）  
* `TOUCH_2_WAIT_CONFIRM`：2回目タッチ＋反転条件待ち  
* `ENTRY_PLACED`：注文発行済  
* `IN_POSITION`：保有中  
* `COOLDOWN`：クールダウン（再エントリー抑制）

#### 3.1.1 StateID定義（固定）

IDLE \= 0  
IMPULSE\_FOUND \= 1  
IMPULSE\_CONFIRMED \= 2  
FIB\_ACTIVE \= 3  
TOUCH\_1 \= 4  
TOUCH\_2\_WAIT\_CONFIRM \= 5  
ENTRY\_PLACED \= 6  
IN\_POSITION \= 7  
COOLDOWN \= 8

StateIDは変更禁止。

### 3.2 遷移概要

- IDLE → IMPULSE\_FOUND：Impulse認定  
- IMPULSE\_FOUND → IMPULSE\_CONFIRMED：Freeze成立（＝Impulse完了確定）

【RiskGate評価（取引価値なし判定）】

- IMPULSE\_CONFIRMED → IDLE：RiskGateFail（LogLevel ≠ ANALYZE）   
  （0–100幅 / 帯幅 / Leave幅 / Spread を総合評価し、取引価値なしと判断）  
- IMPULSE\_CONFIRMED → FIB\_ACTIVE：RiskGateFail   
- IMPULSE\_CONFIRMED → FIB\_ACTIVE：RiskGatePass   
  （Fib算出および100固定、Freeze後は再計算しない）  
- FIB\_ACTIVE → TOUCH\_1：押し帯タッチ（1回目）  
- TOUCH\_1 → TOUCH\_2\_WAIT\_CONFIRM：押し帯再タッチ（2回目）  
- TOUCH\_2\_WAIT\_CONFIRM → ENTRY\_PLACED：反転条件成立  
- ENTRY\_PLACED → IN\_POSITION：約定成立  
- IN\_POSITION → COOLDOWN：決済 or 強制撤退  
- COOLDOWN → IDLE：時間経過で解除

### 3.3 状態遷移図（State Machine Map）

\[IDLE\]

  └─(Impulse認定)→ \[IMPULSE\_FOUND\]

        └─(Freeze成立)→ \[IMPULSE\_CONFIRMED\]

              ├─(RiskGateFail, LogLevel≠ANALYZE)→ \[IDLE\]

              └─(RiskGatePass→Fib算出+Freeze)→ \[FIB\_ACTIVE\]

                    └─(Touch1侵入)→ \[TOUCH\_1\]

                          └─(Leave成立→再侵入)→ \[TOUCH\_2\_WAIT\_CONFIRM\]

                                ├─(Confirm成立)→ \[ENTRY\_PLACED\]

                                │       └─(約定)→ \[IN\_POSITION\]

                                │             └─(決済/撤退)→ \[COOLDOWN\]

                                │                    └─(解除)→ \[IDLE\]

                                └─(ConfirmTimeLimitExpired)→ \[IDLE\]

SoftGate経由（RiskGateSoftPass=1）の追加ルール：

\- \[TOUCH\_2\_WAIT\_CONFIRM\] で Confirm 成立しても \[ENTRY\_PLACED\] に遷移せず \[IDLE\] へ遷移する

（RejectStage=RISK\_GATE\_SOFT\_BLOCK）

---

## 4\. Impulse確定仕様（市場別）

Impulseは「0固定・100追従更新」を前提とする。  
Freeze成立をもってImpulse完了確定と定義する。 Freeze成立時点で100を固定し、以降は再計算しない。

---

■ FX（標準安定型）

Freeze条件（Level2固定）：

1) 更新停止  
     
   - Long：High\[0\] \<= ImpulseHigh  
   - Short：Low\[0\] \>= ImpulseLow

   

2) 反対色足  
     
   - Long：Close\[0\] \< Open\[0\]  
   - Short：Close\[0\] \> Open\[0\]

両条件を同一確定足で満たした場合 Freeze。

Freeze取消： ・CancelWindowBars \= 2 ・Frozen100を 1tick 超えて更新した場合取消

---

■ GOLD（事故防止型）

Freeze条件（Level3固定）：

1) 更新停止  
2) 反対色足  
3) 内部回帰（Impulse高値/安値から ATR(M1)×0.15 以上戻す）

3条件を同一足で満たした場合 Freeze。

Freeze取消： ・CancelWindowBars \= 3 ・Frozen100を Spread×2 以上突破で取消

---

■ CRYPTO（追従優先型）

Freeze条件（Level2）：

1) 更新停止  
2) 反対色足

Freeze取消： ・CancelWindowBars \= 1 ・Frozen100を 0.1% 以上更新で取消

---

## 5\. Fibレベル運用（押し帯：市場別 最終確定）

### 5.1 レベル（参照レベル）

Fib参照レベルは 38.2 / 50 / 61.8 / 78.6 を使用する。 （Entryは“点”ではなく“帯”で扱う）

---

### 5.2 押し帯（RetraceBand：市場別）

押し帯は「Impulse確定（Freeze）後」にのみ有効とする。 押し帯到達はタッチ回数カウント対象となる。

■ FX（50主軸・38.2は任意）

- PrimaryBand：50（±BandWidthPts）  
- OptionalBand：38.2（±BandWidthPts）※初期OFF  
- 61.8は押し帯に含めない

#### ■ GOLD（条件付きで61.8 ON）

- PrimaryBand：50（±BandWidthPts）  
- DeepBand（ON条件成立時のみ）：50〜61.8（帯として運用）  
  - DeepBandON：Impulse確定時に評価（MarketProfileで決定）  
  - DeepBandON=FALSE の場合、61.8はEntry帯に含めない  
- 無効（GOLD特則）：  
  - DeepBand運用時は 78.6 終値割れ（Long）/ 終値超え（Short）で無効  
  - 共通無効（0/100外の明確突破、TimeLimit超過）も適用

#### ■ CRYPTO（61.8常時ON）

- PrimaryBand：50〜61.8（帯として常時運用）  
- OptionalBand：38.2（±BandWidthPts）※有効化は任意（初期OFF）  
- 無効：0/100外の明確突破（共通）＋ 78.6 終値割れ/終値超えで無効（初期ON）

---

### 5.3 タッチ判定（2回目タッチ：市場別 厳密化）

本EAは「同一押し帯への再侵入」を 2回目タッチとして扱う。 タッチは “帯に侵入した時点” でカウントする。

---

#### 5.3.1 タッチ（Touch）判定

■ 侵入条件（共通）

- Long：  
  - Low が BandUpper 以下に到達した時点で「侵入」とみなす  
- Short：  
  - High が BandLower 以上に到達した時点で「侵入」とみなす

※ BandUpper/BandLower は押し帯（±BandWidthPts）を含む。

タッチは「侵入の瞬間」に 1回だけカウントする。 （帯の中で何本過ごしても追加カウントしない）

---

#### 5.3.2 2回目タッチ（ReTouch）判定

2回目タッチは以下をすべて満たす場合に成立する。

A) すでに1回目タッチが記録されている  
B) 1回目以降、いったん帯から “離脱” が成立している  
C) 離脱後に、同一帯へ再侵入した（＝再侵入が2回目タッチ）

---

#### 5.3.3 離脱（Leave）判定：市場別

離脱は「価格が帯の外へ十分離れた」ことで成立する。   
離脱が成立するまでは、   
再侵入しても 2回目タッチとして扱わない （＝帯内ウロウロによる誤カウント防止）。

- FX：  
    
  - LeaveDistance \= BandWidthPts × 1.5  
  - LeaveMinBars  \= 1


- GOLD：  
    
  - LeaveDistance \= BandWidthPts × 1.5  
  - LeaveMinBars  \= 1


- CRYPTO：  
    
  - LeaveDistance \= BandWidthPts × 1.2  
  - LeaveMinBars  \= 1

■ 離脱成立条件（Long例）

- Close が BandUpper \+ LeaveDistance を上回る状態で LeaveMinBars 本確定

（Shortは対称：Close が BandLower \- LeaveDistance を下回る）

---

#### 5.3.4 同一帯扱い（BandIdentity）：市場別

同一帯としてカウントする単位を市場別に定義する。

- FX：  
    
  - 50帯と38.2帯は別扱い（別カウンタ）  
  - 50帯の中（±BandWidth）での再侵入のみを2回目とする


- GOLD：  
    
  - PrimaryBand（50）と DeepBand（50〜61.8）は別扱い  
  - DeepBandON=TRUE のときのみ DeepBandカウンタを使用  
  - DeepBandON=FALSE の場合、61.8側侵入はタッチ対象外


- CRYPTO：  
    
  - PrimaryBand（50〜61.8）を1つの帯として扱う（単一カウンタ）  
  - 38.2は別帯（別カウンタ、初期OFF）

---

#### 5.3.5 リセット（ReTouchReset）：市場別

以下のいずれかでタッチ履歴をリセットする。

(1) 時間切れ：

- Freeze後 RetouchTimeLimitBars を超えたらリセット（＝そのImpulseは捨てる）

(2) 構造破綻：

- 無効条件発動（0/100外突破、GOLDは78.6終値、等）で即リセット

(3) 明確離脱リセット：

- 離脱が成立してから ResetMinBars 経過でリセット（再機会を作る）

市場別パラメータ：

- FX：  
    
  - RetouchTimeLimitBars \= 35  
  - ResetMinBars \= 10


- GOLD：  
    
  - RetouchTimeLimitBars \= 30  
  - ResetMinBars \= 8


- CRYPTO：  
    
  - RetouchTimeLimitBars \= 25  
  - ResetMinBars \= 6

■ 時間制限の優先順位（固定）

1) ConfirmTimeLimitBars は「2回目タッチ成立後」にのみ適用する。  
   2) RetouchTimeLimitBars は「Freeze成立後」から常時計測する。  
   3) Confirm待機中であっても、RetouchTimeLimitBars を超過した場合は優先的にIDLEへ戻す。

---

#### 5.3.6 例外禁止（ブレ防止）

- 1回目タッチでのエントリーは禁止（市場別に例外を設けない）  
- 離脱未成立の再侵入は2回目と数えない  
- 2回目タッチ成立後は「反転条件判定」へ移行する（Entryは反転条件次第）

---

### 5.4 推奨初期パラメータ（市場別）

※ BandWidthPts の算出ロジックは第10章を唯一の正典とする。  
※ 本節は運用上のイメージ例であり、算出定義ではない。

- FX：  
    
  - OptionalBand38：OFF（初期）  
  - ReTouchResetBars：5


- GOLD：  
    
  - DeepBandON条件：MarketProfileに従う  
  - ReTouchResetBars：5


- CRYPTO：  
    
  - OptionalBand38：OFF（初期）  
  - ReTouchResetBars：3

---

## **6\. GOLDの「61.8 ONになる条件」**

### **6.1 判定タイミング**

* `IMPULSE_CONFIRMED → FIB_ACTIVE` の直前に評価  
* Trueなら `GOLD_DeepBandEnabled = true`

### **6.2 条件（OR/AND構造）**

**推奨：2段階（必須ゲート＋追加条件）**

**【必須ゲート】（いずれか1つ）**

* G1: `ATR(M1) / ATR(M1,長期) >= VolExpansionRatio`（ボラ拡大）  
* G2: Impulseが“過伸長”：`ImpulseRangePts >= ATR(M1) * OverextensionMult`

**【追加条件】（いずれか1つ）**

* C1: セッションが荒い時間帯（NY前半など）`SessionFlag = RiskOn`  
* C2: 直近でスイープ痕跡（直近高安を一瞬抜いて戻す）がある  
* C3: スプレッドが通常域（拡大していない）

**最終判定**

* `DeepBandON = (G1 OR G2) AND (C1 OR C2 OR C3)`

### **6.3 意味（設計意図）**

* GOLDはFXより深押しが起きやすいが、常時61.8にすると“構造崩れ”も拾う  
  → **“深押しが自然に起きる局面だけ許可”**する。

---

## 7\. エントリー条件（2回目タッチ後の反転確定）

本EAは「押し帯2回目タッチ」成立後、  
以下の反転確定（Confirm）を満たす場合のみエントリーを許可する。

加えて、本EAは **順張りのみ**を採用する。 ここでいう順張りとは、  
**M1 Impulse方向（ImpulseDir）が、**  
**上位足（Primary Trend）の方向（TrendDir）と一致していること**を指す。   
不一致の場合は逆張りとして当該ImpulseをRejectする（逆張り禁止）。

---

### 7.0 順張り方向フィルタ（上位足方向：MarketMode別）

#### 7.0.1 目的（共通）

M1 Impulse はノイズや瞬間的な逆行を含むため、   
上位足の方向（Trend）に一致するImpulseのみを採用し、逆張り起点の事故を抑制する。

※ 本節で用いる Trend判定用のEMA（例：EMA50）は、  
　既存の MAセット（SMA5〜365 等）とは **別系統**である。  
※ 既存の MAセットは「押し帯×MA重なり（MA Confluence）の記録・評価」等に使用され得るが、  
　Trendフィルタの定義・計算・パラメータとは独立し、相互に影響しない（混同禁止）。

#### 7.0.2 判定タイミング（共通・固定）

- Impulse検出が成立した瞬間（IMPULSE\_FOUND確定時）に1回だけ評価する  
- 同一TradeUUID内で再評価しない（以後固定）  
- H1は「方向一致」を要求せず、反転回避の禁止条件のみを評価する（Reversal Guard）

#### 7.0.3 入力（Input分離・共通）

MarketModeごとに以下をInputとして分離し、デフォルト値も市場別に持つ。

- TrendFilter\_Enable（bool）  
- TrendFilter\_TF（固定：M15）  
- TrendFilter\_Method（例：EMA\_SLOPE / EMA\_CROSS 等）  
- TrendFilter\_SlopeMin（ATR比率など、固定値pips禁止）  
- TrendFilter\_ATRFloor（必要な場合のみ：GOLD向け等）  
- ReversalGuard\_Enable（bool）  
- ReversalGuard\_TF（固定：H1）  
- ReversalGuard\_BigBodyMin（ATR比率）  
- ReversalGuard\_EngulfingEnable（bool）  
- ReversalGuard\_WickRejectEnable（bool、必要な市場のみ）

※ TrendFilter / ReversalGuard のInputは、  
　既存MAセット（SMA5〜365）とは独立のパラメータ群として扱う。

#### 7.0.4 ログ要件（共通）

ImpulseSummary（解析ログ）に、少なくとも以下を列として出力する（DOC-LOGに定義すること）。

- TrendFilterEnable  
- TrendDir（LONG / SHORT / FLAT）  
- ImpulseDir（LONG / SHORT）  
- TrendAligned（bool：ImpulseDir==TrendDir）  
- ReversalGuardTriggered（bool）  
- RejectStage（不一致やFLATによるRejectを識別できる語彙を割り当てる）

#### 7.0.5 市場別ロジック（案A最適化）

■ FX（案A-FX：バランス）

- Primary Trend（M15）：EMA50の傾きで判定  
    
  - EMA50(0) \- EMA50(1) \>= SlopeMin\_FX → TrendDir=LONG  
  - EMA50(0) \- EMA50(1) \<= \-SlopeMin\_FX → TrendDir=SHORT  
  - それ以外 → TrendDir=FLAT ※ SlopeMin\_FX は ATR(M15) 比率で定義（固定pips禁止）


- 順張り判定：  
    
  - TrendDir=FLAT → Reject  
  - ImpulseDir \!= TrendDir → Reject（逆張り）  
  - 一致 → Pass


- Reversal Guard（H1：事故回避のみ）：  
    
  - 逆向き大実体（\>= BigBodyMin\_FX）または逆向きEngulfing成立時 → Reject

■ GOLD（案A-GOLD：レンジ除外＋反転ガード強化）

- Primary Trend（M15）：EMA50傾きで判定（FX同型、ただし閾値はGOLD用）  
    
  - 追加で、以下のいずれかに該当する場合は強制FLAT（レンジ扱い）  
    - ATR(M15) \< ATRFloor\_GOLD  
    - 直近n本で高値/安値更新が混在し方向性が出ていない（実装定義は別途固定）   
      ※ SlopeMin\_GOLD / ATRFloor\_GOLD は ATR(M15) 比率で定義

    
- 順張り判定：  
    
  - TrendDir=FLAT → Reject  
  - ImpulseDir \!= TrendDir → Reject（逆張り）  
  - 一致 → Pass


- Reversal Guard（H1：強化）：  
    
  - 逆向きEngulfing → Reject  
  - 逆向きWick Rejection（長ヒゲ拒否）→ Reject（必要なら有効化）  
  - 逆向き大実体の連続など、強反転兆候 → Reject（閾値はATR比率）

■ CRYPTO（案A-CRYPTO：追随性重視＋ガード軽め）

- Primary Trend（M15）：EMA21とEMA50の関係＋EMA50傾きで判定  
    
  - EMA21 \> EMA50 かつ EMA50傾き \>= SlopeMin\_CRYPTO → TrendDir=LONG  
  - EMA21 \< EMA50 かつ EMA50傾き \<= \-SlopeMin\_CRYPTO → TrendDir=SHORT  
  - それ以外 → TrendDir=FLAT ※ SlopeMin\_CRYPTO は ATR(M15) 比率で定義


- 順張り判定：  
    
  - TrendDir=FLAT → Reject  
  - ImpulseDir \!= TrendDir → Reject（逆張り）  
  - 一致 → Pass


- Reversal Guard（H1：最小限）：  
    
  - 逆向きEngulfing、または逆向き大実体（\>= BigBodyMin\_CRYPTO）成立時のみ Reject  
  - ガードを強くしすぎて取引機会を潰さない（基本は地雷除去に限定）

---

### 7.1 前提（共通）

- 前提状態：  
  - State \= TOUCH\_2\_WAIT\_CONFIRM  
  - 同一押し帯への2回目タッチ（ReTouch）が成立済み  
- 判定足：  
  - Confirmは M1 の確定足で判定する（未確定足で判定しない）  
- 有効期限：  
  - 2回目タッチ成立から ConfirmTimeLimitBars 本以内にConfirmが出なければ無効（リセット）

市場別：

- FX：ConfirmTimeLimitBars \= 6  
- GOLD：ConfirmTimeLimitBars \= 5  
- CRYPTO：ConfirmTimeLimitBars \= 4

### 7.1.1 Confirm不成立の扱い

Confirm判定は「成立したか否か」のみを扱い、以下の2種類を区別する。

(1) Confirm未成立（条件未達）

- Confirm条件が成立しない限り、Stateは `TOUCH_2_WAIT_CONFIRM` を維持する。  
- Confirm未成立それ自体ではIDLEへ戻さない。

(2) ConfirmTimeLimitExpired（時間切れ）

- `TOUCH_2_WAIT_CONFIRM` に遷移した時点から `ConfirmTimeLimitBars` を計測する。  
- `ConfirmTimeLimitBars` を超過した場合、当該Impulseは終了とし、Stateを `IDLE` へ遷移する。  
- 以降、同一TradeUUID（同一Impulse）内での再エントリーは行わない（7.6に従う）。

※本節により、「Confirm失敗」という曖昧語を使用しない。

---

### 7.2 Confirm条件セット（定義）

Confirmは以下の3系統のうち、市場別に指定されたもののみを採用する。 判定はすべて M1 の確定足で行う（未確定足は禁止）。

---

A) WickRejection（ヒゲ拒否）

ロング：

- 下ヒゲ比率 \>= WickRatioMin  
- かつ 終値が押し帯の内側〜上側で確定（弱い抜けは許容）

ショート：

- 上ヒゲ比率 \>= WickRatioMin  
- かつ 終値が押し帯の内側〜下側で確定

---

B) Engulfing（包み足）

ロング：

- 確定足の実体が直前足実体を包む（Bullish Engulfing）

ショート：

- 確定足の実体が直前足実体を包む（Bearish Engulfing）

---

C) MicroBreak（ミクロ構造ブレイク）

MicroBreakは「押し終了の最初の構造的証拠」として扱う。 ヒゲ突破は無効とし、終値ブレイクのみを有効とする。

■ FX / GOLD（フラクタル固定型）

MicroHigh / MicroLow は「左右2本型フラクタル」で定義する。 LookbackMicroBarsは使用しない。

【MicroHigh条件】 High\[i\] \> High\[i-1\] AND High\[i\] \> High\[i-2\] AND High\[i\] \> High\[i+1\] AND High\[i\] \> High\[i+2\]

【MicroLow条件】 Low\[i\] \< Low\[i-1\] AND Low\[i\] \< Low\[i-2\] AND Low\[i\] \< Low\[i+1\] AND Low\[i\] \< Low\[i+2\]

直近に確定したMicroHigh / MicroLowを保持する。

Break判定：

- ロング：Close\[0\] \> 直近MicroHigh  
- ショート：Close\[0\] \< 直近MicroLow

---

■ CRYPTO（スイング抽出型）

MicroHigh / MicroLow は LookbackMicroBars 本の極値で定義する。 LookbackMicroBars \= 3（固定）

【MicroHigh】 直近3本のHighの最大値

【MicroLow】 直近3本のLowの最小値

Break判定：

- ロング：Close\[0\] \> MicroHigh  
- ショート：Close\[0\] \< MicroLow

■ MicroBreak定義の市場別整理（固定）

- FX：フラクタル固定型（左右2本）  
- GOLD：フラクタル固定型（左右2本）  
- CRYPTO：Lookback抽出型（LookbackMicroBars=3固定）

---

### 7.3 市場別 採用ルール（最終確定）

■ FX（ノイズ少：包み足優先）

採用：Engulfing OR MicroBreak

\- Engulfingを優先 \- MicroBreakはフラクタル型のみ使用 \- LookbackMicroBars は使用しない \- WickRejection は採用しない（初期OFF）

■ Confirm優先順位（FX）

同一足で複数Confirm条件を満たした場合：

1. Engulfing  
2. MicroBreak

の順で判定し、最初に成立したものを ConfirmType としてログ記録する。

---

■ GOLD（ヒゲ多：拒否またはブレイクの一段）

採用：WickRejection OR MicroBreak

- ヒゲ拒否 "または" ミクロ高安ブレイクのいずれかが出たら許可  
- MicroBreakは「フラクタル固定型（左右2本）」のみ使用する  
- LookbackMicroBars は使用しない（CRYPTO専用）

■ Confirm優先順位（GOLD）

同一足で複数Confirm条件を満たした場合：

1. WickRejection  
2. MicroBreak

の順で判定し、最初に成立したものを ConfirmType としてログ記録する。

パラメータ：

- WickRatioMin \= 0.55

---

■ CRYPTO（速い：ブレイク優先）

採用：MicroBreak

- 迷いを排除し、ミクロブレイクのみで許可

パラメータ：

- LookbackMicroBars \= 3  
- WickRejection / Engulfing は採用しない（初期OFF）

---

### 7.4 エントリー発行（共通）

Confirm成立時：

- EntryType は原則 指値（Limit）  
- ただし Limit未約定が多い場合は Marketを許可（オプション）

発行条件（共通ガード）：

- SpreadPts \<= MaxSpreadPts  
- Slippage想定 \<= MaxSlippagePts（Market時）  
- 約定後乖離 \<= MaxFillDeviationPts（保険）

---

### 7.5 例外禁止（ブレ防止）

- 2回目タッチ未成立でConfirm判定を開始しない  
- Confirm成立前の先回りエントリーは禁止  
- 市場別に定義されたConfirm以外は採用しない（裁量介入禁止）

---

### 7.6 同一Impulse内の最大エントリー回数（固定）

本EAは、同一TradeUUID（＝同一Impulse）内での 最大エントリー回数を「1回」に固定する。

■ ルール

- 2回目タッチ成立後、Confirm成立時のみエントリーを許可する  
- Confirm失敗、ConfirmTimeLimitExpired、Execution拒否が発生した場合、 そのImpulseは終了とし、StateをIDLEへ戻す  
- 同一Impulse内での3回目タッチはエントリー対象としない  
- 再エントリーは、新たなIMPULSE\_FOUND発生後のみ可能

■ 設計意図

- 押し目は「1回の質」を取るものであり、回数を重ねない  
- 連続タッチを許容するとレンジ吸収局面での事故率が上昇する  
- 統計の一貫性を維持するため、Impulse単位で1トレードに限定する

---

## **8\. 注文方式（Execution仕様）**

### **8.1 原則**

* 基本：**指値**  
* ただし、反転確定が遅い場合は成行に切替可能（オプション）  
* Execution方式は Input の UseLimitEntry / UseMarketFallback に従う。

### **8.2 スリッページ・約定対策**

* `MaxSlippagePts` を超えたら **注文キャンセル**  
* 約定後に `FillPrice` と想定価格の乖離が `MaxFillDeviationPts` を超えたら **即撤退（保険）**  
* `SpreadPts > MaxSpreadPts` なら **エントリー禁止**

---

## **9\. リスク管理（SL/TP/撤退 / 無効条件）**

### **9.1 SL（推奨）**

* 押し帯の外側ではなく、**構造（Impulse起点/直近スイング外）**で決める  
  （浅い押しは“レベル基準SL”が狩られやすい）

市場別例：

* FX：直近スイング外（比較的素直）  
* GOLD：スイープを想定し“少し外”＋ロット抑制  
* CRYPTO：広め前提（ロットさらに抑制）

---

### **9.2 決済仕様（EMAクロス方式）**

サーバーTP = 0（指値TPを使用しない）。
ポジション決済はM1上のEMAクロスを主体とし、構造破綻・時間撤退と組み合わせて運用する。

#### 9.2.1 Exit優先順位（固定）

ポジション保有中（IN\_POSITION）の決済判定は、以下の順で毎Tick評価する。
上位条件が成立した場合、下位は評価しない。

1) **構造破綻（Fib0）**：ImpulseStart（Fib0）を確定足（shift=1）が終値で割った/超えた場合、即時成行決済
2) **時間撤退**：Entry後 TimeExitBars 本以上保有かつ損益 ≤ 0 の場合、即時成行決済
3) **建値移動**：RR >= 1.0 でSLをエントリー価格に移動（決済ではなくSL変更のみ）
4) **EMAクロス決済**：EMA(Fast) と EMA(Slow) の逆クロスを検出し、確認後に成行決済

#### 9.2.2 EMAクロス決済仕様

■ パラメータ（M1固定・Input）

- ExitMAFastPeriod = 13（EMA Fast期間）
- ExitMASlowPeriod = 21（EMA Slow期間）
- ExitConfirmBars = 1（クロス確認本数）

■ 検出条件（確定足ベース）

- Long保有中 → デッドクロス検出：
  EMA\_Fast\[2\] >= EMA\_Slow\[2\] かつ EMA\_Fast\[1\] < EMA\_Slow\[1\]
- Short保有中 → ゴールデンクロス検出：
  EMA\_Fast\[2\] <= EMA\_Slow\[2\] かつ EMA\_Fast\[1\] > EMA\_Slow\[1\]

※ shift=1（直近確定足）と shift=2（その前足）を比較する。

■ 確認フロー（2段階）

(A) 検出フェーズ：クロス検出時に ExitPending = true、ExitPendingBars = 0 とする
(B) 確認フェーズ：ExitPending = true 後、ExitConfirmBars 本の間クロス状態が維持されていれば成行決済

- Long：EMA\_Fast\[1\] < EMA\_Slow\[1\] が維持
- Short：EMA\_Fast\[1\] > EMA\_Slow\[1\] が維持
- 維持されなかった場合、ExitPending をリセットし検出からやり直す

■ 決済時のログ出力

- FinalState = "EMACross\_Exit"
- Extra: ExitReason=EMA\_CROSS; CrossDir=DEAD|GOLDEN; EMA{Fast期間}=値; EMA{Slow期間}=値; ConfirmBars=確認本数

#### 9.2.3 構造破綻（Fib0）決済仕様

ImpulseStart（Fib0）を確定足（shift=1）の終値が割った（Long）/ 超えた（Short）場合、
構造的にImpulse前提が崩れたものとして即時成行決済する。

- FinalState = "StructBreak\_Fib0"

#### 9.2.4 時間撤退仕様

Entry後 TimeExitBars 本（市場別）以上保有し、かつ損益 ≤ 0 の場合に成行決済する。
利益が出ている場合はEMAクロスに委ねる。

- FinalState = "TimeExit"

#### 9.2.5 建値移動仕様

RR >= 1.0（現在価格とEntry/SLの比率）に到達した場合、
SLをエントリー価格（建値）に移動する。決済ではなくSL変更のみ。

#### 9.2.6 TPExtRatio の扱い（CHANGE-008）

TPExtRatio（市場別Input）は引き続き存在するが、
サーバーTPには使用しない（TP=0）。
EntryGate の RangeCost評価（9.5.2）における理論TP算出にのみ使用する。

---

### **9.3 ExitPending状態管理**

- State遷移（COOLDOWN/IDLE）時に ExitPending / ExitPendingBars をリセットする
- EMAハンドルは OnInit で作成、OnDeinit で解放する（M1固定）

---

### 9.4 無効条件（構造破綻）

無効条件は「当該Impulseを終了させる条件」である。 無効が成立した場合、StateはIDLEへ遷移し、 同一TradeUUIDは終了する。

---

■ 共通（全市場）

- 0 / 100 外側へ明確に突破した場合、構造破綻として無効  
- Freeze確定後、一定時間内に再伸長が発生しない場合のみRetrace有効  
- Spread / Slippage が閾値超過時は新規エントリー禁止 （ただし構造無効とはしない）

---

■ GOLD（XAUUSD）

- 押し帯を 50〜61.8 に拡張する場合、 78.6 終値割れ（ロング） / 78.6 終値超え（ショート）で無効  
- ヒゲのみの一時突破は即無効としない

---

■ CRYPTO

- 深押し許容だが、Impulse起点を明確に割った場合は即無効

---

■ FX

- 61.8は押し帯に含めない（基本50固定）  
- 61.8終値突破は構造崩れ扱い

---

■ 無効条件の優先順位（固定）

複数の無効条件が同時に成立した場合は、 以下の順で処理する。

1) 構造破綻（0/100外突破、78.6終値等）  
2) RetouchTimeLimit超過  
3) ConfirmTimeLimit超過  
4) Spread / Slippage超過（構造無効としない）

上位条件が成立した場合、即IDLEへ遷移する。 Spread / Slippage超過は構造無効とせず、 エントリー禁止のみ適用しStateは維持する。  
---

#### 9.4.1 RiskGate無効（取引価値なし：0–100幅 / 帯幅 / Leave幅 / Spread 総合評価）

RiskGate無効は「構造破綻」ではないが、トレードコスト・リスクに対して期待値幅が不足し、   
当該ImpulseでのEntry待ち自体を不要と判定する失効条件である。

---

##### 判定タイミング

- IMPULSE\_CONFIRMED → FIB\_ACTIVE 遷移直前に1回だけ評価する  
  （同一TradeUUID内で再評価しない）  
- 評価ロジックおよび使用量は現行のまま変更しない（下記参照）

---

##### 評価に使用する量

- RangePts：abs(Fib100 \- Fib0)（0–100幅）  
- BandWidthPts：当該TradeUUID内で確定した押し帯幅（第10章定義）  
- LeaveDistancePts：第5.3.3の定義に従い市場別に算出（BandWidthPts×係数）  
- SpreadPts：MaxSpreadModeにより算出される現在スプレッド（第12.3）

---

##### RiskGateFail 条件

以下のいずれかが成立した場合、当該Impulseは「取引価値なし」と判定する。

(1) 値幅不足（摩擦負け）

- RangePts が SpreadPts および押し帯関連距離（帯幅＋Leave）に対して不足する場合

(2) 期待値幅に対し構造SLが遠すぎる（RR不足）

- Entry候補（押し帯中心付近）から Fib100 までの期待値幅に対し、構造SLまでが不利な場合

(3) 帯がレンジを“支配”している（BandDominanceFail：主にFX）

- 帯高さ（= 2×BandWidthPts）が、Impulseの 0–100 幅（RangePts）に対して過大で、 「押し帯」が“待つ場所”ではなく“ほぼ全域”になっている場合は失効とする。  
  - 判定量：`BandDominanceRatio = (2×BandWidthPts) / RangePts`  
  - FX（BandWidthがSpread由来）の場合、  
    `BandDominanceRatio >= 0.85` を RiskGateFail とする（固定）。  
  - 設計意図：高スプレッド（例：GBPJPY等）や極小Impulseで、  
    帯が巨大化／上限キャップされてしまう局面を 「描写を合わせて継続」ではなく  
    「待機価値なしとして終了」に統一する。

※ 設計意図：帯の描写を0–100に潰して合わせるのではなく、そもそも待つ価値が無いImpulseを捨てる。

---

##### Fail時の挙動

判定タイミングおよび評価ロジックは現行のまま変更しない。   
Fail時の「遷移・許可」は LogLevel により分岐する。

###### *■ LogLevel \= NORMAL / DEBUG / OFF*

- Pass の場合のみ FIB\_ACTIVE に遷移し、押し待ちを開始する  
- Fail の場合は当該TradeUUIDを終了し IDLE へ遷移する（現行仕様どおり）

---

##### ログ要件（Fail時）

###### *共通*

- RiskGateFail が発生した場合、LOG\_REJECT を1行出力する  
- Extra に RangePts / BandWidthPts / LeaveDistancePts / SpreadPts を key=value で格納する

---

### 9.5 EntryGate（RRおよびRangeCostフィルタ：注文直前）

本EAは、\*\*Confirm成立後（注文発行直前）\*\*に以下の2つのゲートを適用する。

1) MinRR\_EntryGate（最低RR）  
2) MinRangeCostMult（摩擦負けフィルタ）

これらは「エントリーを物理的に許可するか否か」の最終判定に使用する。  
構造判定（Impulse / Touch / Confirm）とは独立した “リスク側ゲート” である。

---

#### 9.5.1 MinRR\_EntryGate（最低RR）— 廃止（CHANGE-008）

~~期待RR（TP距離 ÷ SL距離）がMinRR\_EntryGate 未満の場合、エントリーを禁止する。~~

**CHANGE-008 により MinRR チェックは廃止**。
RR値は ImpulseSummary への記録のみ行い、Rejectしない。
Input（MinRR\_EntryGate\_FX / GOLD / CRYPTO）は残存するが、
RR\_Min として記録用に使用するのみでゲート判定には使用しない。

初期値（Input既定値・記録用）：

- FX：MinRR\_EntryGate\_FX \= 0.7
- GOLD：MinRR\_EntryGate\_GOLD \= 0.6
- CRYPTO：MinRR\_EntryGate\_CRYPTO \= 0.5

---

#### 9.5.2 MinRangeCostMult（摩擦負けフィルタ）

定義：

期待値幅（Entry→TP距離）が  
（現在Spread × MinRangeCostMult） 未満の場合、  
コスト負けリスクが高いためエントリーを禁止する。

本値は **MarketMode別にInputを持ち**、MarketProfile にマッピングして使用する。

初期値（Input既定値）：

- FX：MinRangeCostMult\_FX \= 2.5  
- GOLD：MinRangeCostMult\_GOLD \= 2.5  
- CRYPTO：MinRangeCostMult\_CRYPTO \= 2.0

---

#### 9.5.3 適用タイミング（固定）

- **TOUCH\_2\_WAIT\_CONFIRM で Confirm成立後、注文発行直前**に判定する  
- ゲート未達の場合は ENTRY\_PLACED に遷移せず、**IDLEへ戻す**（当該TradeUUIDは終了）  
- 同一TradeUUID内で再判定は行わない

---

#### 9.5.4 失効（RejectStage）

EntryGateで失効した場合、RejectStage は以下の語彙を使用する。

- ~~RR未達：`RR_FAIL`~~（CHANGE-008 により廃止。MinRRチェック無効化のため発火しない）
- RangeCost未達：`RANGE_COST_FAIL`

---

## 10\. 市場別パラメータ（初期値テンプレ）

| Param | FX | GOLD | CRYPTO |
| :---- | :---- | :---- | :---- |
| ImpulseATRMult | 1.6 | 1.8 | 2.0 |
| ImpulseMinBars | 1 | 1 | 1 |
| BandWidthPts | 小(内部) | 中(内部) | 大(内部) |
| RetraceBand | 50 | 50 / 条件で50-61.8 | 50-61.8 |
| DeepBandCondition | N/A | あり | 常時ON |
| LeaveDistanceMult | 1.5 | 1.5 | 1.2 |
| LeaveMinBars | 1 | 1 | 1 |
| MaxSpreadMode | ADAPTIVE | ADAPTIVE | ADAPTIVE |
| SpreadMult | 2.0 | 2.5 | 3.0 |
| MaxSlippagePts | 2 | 5 | 8 |
| MaxFillDeviationPts | 3 | 8 | 12 |
| TimeExitBars | 10 | 8 | 6 |
| SLATRMult（SL=ImpulseStart±ATR×mult） | 0.7 | 0.8 | 0.7 |
| MinRR\_EntryGate（廃止・記録用） | 0.7 | 0.6 | 0.5 |
| MinRangeCostMult | 2.5 | 2.5 | 2.0 |
| TPExtRatio（RangeCost評価用） | 0.382 | 0.382 | 0.382 |
| ExitMAFastPeriod | 13 | 13 | 13 |
| ExitMASlowPeriod | 21 | 21 | 21 |
| ExitConfirmBars | 1 | 1 | 1 |

■ SpreadMult命名規則（明示）

- Input名：  
    
  - SpreadMult\_FX  
  - SpreadMult\_GOLD  
  - SpreadMult\_CRYPTO


- 内部使用変数：  
    
  - SpreadMult（MarketProfileでInput値をマッピング）

内部ロジックでは単一変数 SpreadMult を使用し、 MarketModeに応じて該当Input値を代入する。

■ TPExtRatio命名規則（明示）

- Input名：  
    
  - TPExtRatio\_FX  
  - TPExtRatio\_GOLD  
  - TPExtRatio\_CRYPTO


- 内部使用変数：  
    
  - tpExtensionRatio（MarketProfileでInput値をマッピング）

TPExtRatio=0 のとき 理論TP \= ImpulseEnd。 TPExtRatio\>0 のとき 理論TP \= ImpulseEnd ± ImpulseRange × TPExtRatio。 （Longなら+方向、Shortなら-方向）

※ CHANGE-008：サーバーTP=0（EMAクロスで決済するため指値TPを使用しない）。
TPExtRatio は EntryGate の RangeCost評価（第9.5.2章）における理論TP算出にのみ使用する。

■ BandWidthPts確定ルール（唯一の定義）

- 確定タイミング： IMPULSE\_CONFIRMED → FIB\_ACTIVE 遷移時  
- 同一TradeUUID内で固定（再計算しない）  
- FreezeCancel発生時も再確定しない  
- 市場別算出： FX      \= 現在Spread × 2.0（IMPULSE\_CONFIRMED→FIB\_ACTIVE遷移時に確定） GOLD    \= ATR(M1) × 0.05（Freeze時点） CRYPTO  \= ATR(M1) × 0.08（Freeze時点）  
- 本定義以外の算出式は存在しない。  
- 第5章の記述は参考説明であり、算出根拠ではない。  
- Input変更不可（MarketProfile内部定義のみ）

---

## **11.（削除）**

※ ログ仕様の正典宣言は **0章**へ統合済み。ログ仕様の詳細は **DOC-LOG** を参照。

---

## 12\. Inputs（EAパラメータUI仕様：グルーピングと初期値）

本EAのInputは「誤設定で別EAになる」ことを防ぐため、  
入力項目を最小化し、グルーピングと初期値を固定する。

---

### 12.1 Inputグループ構成（表示順）

【G1：運用（普段触る）】

* EnableTrading（default: true）※エントリー可否制御（false時はロジック稼働・ログ出力のみ）
* MarketMode（default: AUTO）
* UseLimitEntry（default: true）
* UseMarketFallback（default: true）
* LotMode（default: FIXED）
  * FIXED：固定Lot
  * RISK\_PERCENT：口座％リスク型
* FixedLot（default: 0.01）
* RiskPercent（default: 1.0）  ※ RISK\_PERCENT時の口座残高リスク％。Lot = (Balance × RiskPercent%) / (SL距離pts × 1ptあたり価値)。lotStep切り捨て・min/maxクランプ適用。
* LogLevel（default: NORMAL）
* RunId（default: 01）         ※ログ命名用
  ※ LogLevel / RunId を含むログ制御仕様（出力レベル・命名規則・Dump/Log系Inputの意味）は
  **EA\_LogSpec\_v202603（DOC-LOG）** を唯一の正典とする。
* ExitMAFastPeriod（default: 13）  ※ EMAクロス決済 Fast期間（M1固定）
* ExitMASlowPeriod（default: 21）  ※ EMAクロス決済 Slow期間（M1固定）
* ExitConfirmBars（default: 1）    ※ クロス確認本数

【G2：安全弁（事故防止）】

* MaxSpreadMode（default: ADAPTIVE）
* SpreadMult\_FX（default: 2.0）
* SpreadMult\_GOLD（default: 2.5）
* SpreadMult\_CRYPTO（default: 3.0）
* MaxSlippagePts（default: 変数だが市場別テーブル初期値を採用）
* MaxFillDeviationPts（default: 変数だが市場別テーブル初期値を採用）
* SLATRMult\_FX（default: 0.7）
* SLATRMult\_GOLD（default: 0.8）
* SLATRMult\_CRYPTO（default: 0.7）
* MinRR\_EntryGate\_FX（default: 0.7）  ※ CHANGE-008: ゲート廃止・記録用のみ
* MinRR\_EntryGate\_GOLD（default: 0.6）  ※ CHANGE-008: ゲート廃止・記録用のみ
* MinRR\_EntryGate\_CRYPTO（default: 0.5）  ※ CHANGE-008: ゲート廃止・記録用のみ
* MinRangeCostMult\_FX（default: 2.5）
* MinRangeCostMult\_GOLD（default: 2.5）
* MinRangeCostMult\_CRYPTO（default: 2.0）
* TPExtRatio\_FX（default: 0.382）  ※ CHANGE-008: サーバーTPには不使用、RangeCost評価用
* TPExtRatio\_GOLD（default: 0.382）
* TPExtRatio\_CRYPTO（default: 0.382）

【G3：戦略（基本触らない）】

* OptionalBand38（default: OFF）  
* ConfirmModeOverride（default: OFF） ※OFF時は市場別仕様（第7章）に従う

【G4：検証・デバッグ（普段触らない）】

※ Dump系 / Log系Input の意味・出力範囲・相互関係は  
**EA\_LogSpec\_v202603（DOC-LOG）** を唯一の正典とする。

---

### 12.2 MarketMode（AUTO）の挙動

* AUTOの場合、Symbol名またはティッカー規則でMarketModeを自動判定する  
* 判定不能時はFX扱い（安全側）とする  
* 手動指定（FX/GOLD/CRYPTO）が優先

---

### 12.3 MaxSpreadMode（スプレッド上限の決め方）

MaxSpreadMode は以下のいずれか。

(1) FIXED：

* MaxSpreadPts を固定値として使用する

(2) ADAPTIVE（推奨）：

* SpreadBasePts \= 直近 N分のスプレッド中央値（Pts＝価格差/Point の “MT5ポイント数”）  
* MaxSpreadPts  \= SpreadBasePts × SpreadMult（市場別）  
* N は内部定数（例：15分）として固定しInput化しない

ADAPTIVE算出更新タイミング（固定）

- SpreadBasePts の更新は「新規IMPULSE\_FOUND発生時」のみ行う。  
- 毎Tick更新は行わない。  
- 同一TradeUUID内ではSpreadBasePtsを固定する。

---

### 12.4 “市場別パラメータの入力化”の方針（禁止対象と例外）

* 第4章（Freeze）、第5章（押し帯/タッチ）、第7章（Confirm）で定義された **戦略コアの市場別パラメータ**はInputで直接変更できない。  
* 市場別セットは MarketProfile 内部定義を唯一の正典とする。  
* Inputは運用・安全弁・ログに限定する。

ただし、以下は **安全弁（リスク側ゲート／SL幅）として運用上の調整余地が必要**なため、MarketMode別Inputを許可する（G2に配置）。

- SLATRMult\_\*（SLのATR倍率）  
- MinRR\_EntryGate\_\*（最低RR）  
- MinRangeCostMult\_\*（摩擦負けフィルタ）

※ LogLevel / RunId / Dump系 / Log系など「ログ制御Input」の仕様詳細は  
**EA\_LogSpec\_v202603（DOC-LOG）** を唯一の正典とする（DOC-CORE側で重複定義しない）。

---

### 12.5 初期値の方針（固定）

* 実運用で必要が出た場合のみ、追加Inputを行う（Versionを上げる）

---

## 13\. 出力仕様（Logger）

Eventログおよび ImpulseSummary（ANALYZE解析ログ）の仕様は、  
別紙 **EA\_LogSpec\_v202603（DOC-LOG）** を唯一の正典とする。

- 本書（DOC-CORE）では、ログの列定義・命名規則・拡張方針・RejectStage語彙を再掲しない。  
- ログ仕様に関する疑義・改定は DOC-LOG 側でのみ行う。

---

## 14\. 通知ロジック（Notification）

本EAは、Impulse発生（IMPULSE\_FOUND）を検出した瞬間に通知を送信する。  
通知手段はすべて Input で個別にON/OFF可能とする。

---

### 14.1 通知対象イベント（固定）

通知対象イベントは以下の1種類のみとする。

1) IMPULSE\_FOUND（Impulse検出時）

※ FIB\_ACTIVE / ENTRY\_PLACED 等、他イベントでの通知は行わない（仕様外）。

---

### 14.2 通知制御Input（G1：運用）

EnableDialogNotification \= true     // MT5端末上のダイアログ通知（Alert）   
EnablePushNotification   \= true     // MT5プッシュ通知（SendNotification）   
EnableMailNotification   \= false    // メール通知（初期OFF）   
EnableSoundNotification  \= false    // サウンド通知（初期OFF）

SoundFileName            \= "alert.wav"  // terminal/Sounds 内のファイル名

---

### 14.3 通知発火条件（固定）

IMPULSE\_FOUND 発生時（Impulse通知）：

- DetectImpulse() が成立し、State が IMPULSE\_FOUND に遷移した瞬間に1回だけ発火する  
- Input でONの手段のみ実行する

---

### 14.4 通知方法（手段）

通知手段：

- ダイアログ通知：Alert()  
- プッシュ通知：SendNotification()  
- メール通知：SendMail()  
- サウンド通知：PlaySound()

---

### 14.5 件名仕様（Push/メール共通・固定）

形式：

\[ScaEA\] IMPULSE

例：

\[ScaEA\] XAUUSD LONG IMPULSE

---

### 14.6 本文（固定）

EA      : ScaEA Symbol : Event : IMPULSE Side : State : IMPULSE\_FOUND Time : 

---

### 14.7 サウンド通知仕様（固定）

- EnableSoundNotification \= true の場合のみ再生する  
- SoundFileName は terminal/Sounds 内のファイル名とする  
- 存在しない場合はログに出力する  
- 1イベントにつき1回のみ再生する（ループ禁止）

---

## 15\. フィボナッチ描写仕様（Visualization）

本EAは、Impulse確定後に算出されたFibをチャート上に描写する。   
本章は「視覚化仕様」を定義するものであり、算出ロジックは第4章および第5章を正典とする。

---

### 15.1 描写開始タイミング

- Stateが IMPULSE\_CONFIRMED へ遷移した瞬間に描写を開始する  
- Freeze成立前は描写しない  
- FreezeCancelが発生しても描写は維持する  
- 構造無効（State → IDLE）時に削除する

---

### 15.2 描写固定ルール（Freeze思想準拠）

- 0（起点）および100（終点）はFreeze成立時点で固定  
- Freeze後は再計算しない  
- 同一TradeUUID内で不変とする  
- TradeUUID終了時に削除する

---

### 15.3 描写レベル（固定）

表示レベルは以下に限定する。

- 0  
- 38.2  
- 50  
- 61.8  
- 78.6  
- 100

それ以外のレベルは描写しない。

---

### 15.4 市場別描写ルール

■ FX

- 50を主軸として強調表示  
- OptionalBand38がOFFの場合でも38.2は薄色で描写可  
- 61.8は表示するが、押し帯としては使用しない

■ GOLD

- DeepBandON \= TRUE の場合、 50〜61.8を帯として視覚強調する  
- DeepBandON \= FALSE の場合、 61.8は通常表示（帯強調なし）

■ CRYPTO

- 50〜61.8を常時帯強調表示  
- 38.2はOptionalBand38がONの場合のみ強調

---

### 15.5 帯表示（BandHighlight）

押し帯はラインではなく「帯」として描写する。

- BandLower と BandUpper の間を矩形表示  
    
- 透明度は 60% 推奨  
    
- 色はMarketMode別に固定  
    
  FX      \= Blue系 GOLD    \= Gold系 CRYPTO  \= Purple系

帯はStateが FIB\_ACTIVE 以上の間のみ表示する。

---

### 15.6 オブジェクト命名規則

Fibオブジェクト名：

EA\_FIB\_

Bandオブジェクト名：

EA\_BAND\_

- 同一TradeUUID内で1セットのみ存在する  
- TradeUUID終了時に削除する  
- 再利用は禁止（新Impulse時は新UUID）

■ オブジェクトリスト表示

- Fib / Band はオブジェクトリストに表示される設定で生成する  
  - Hidden \= false  
  - Selectable \= true  
- 目的：検証時に「今のTradeUUIDの描写物」だけを即選択・確認できるようにする

■ 直近1セットのみ表示

- チャート上には常に直近TradeUUIDの EA\_FIB\_\* / EA\_BAND\_\* の1セットのみ残す  
- 新しいTradeUUID（新Impulse）生成時、旧TradeUUID由来の EA\_FIB\_\* / EA\_BAND\_\* が残っている場合は削除してから新規生成する  
  - 他EA/他インジのオブジェクトは削除禁止  
  - 削除対象は EA\_FIB\_ / EA\_BAND\_ 接頭辞を持つ本EA由来のみ

---

### 15.7 描写更新禁止事項

- 毎Tick再描画禁止  
- Freeze後のレベル再計算禁止  
- State維持中の再生成禁止  
- 同一TradeUUID内での複数生成禁止

---

### 15.8 描写削除条件

以下の場合に削除する。

- State → IDLE（構造無効）  
- TradeUUID終了  
- EA停止（OnDeinit）

削除時は必ず対象TradeUUIDのオブジェクトのみ削除する。 全削除は禁止。

---

### 15.9 表示ON/OFF制御

Input追加：

EnableFibVisualization \= true

falseの場合：

- Fib描写を行わない  
- ロジックには影響しない

