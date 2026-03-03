【タイトル】 ScalpImpulseRetraceEA：ExitをEMA13/21（M1）クロスへ置換（確定足＋1本確認）— MQL改修依頼

【1. 目的】 添付する最新の ScalpImpulseRetraceEA.mq5 を改修し、   
決済ロジックを「0/100 指値TP」ベースから 「M1の EMA13 と EMA21 のクロス」ベースへ  
置換してください。

※ Entry〜TOUCH\_1（およびTOUCH\_2〜Entry）までの仕様は原則踏襲。   
※ RR Gate は廃止方針（ただし RangeCost は維持）。

【2. 重要前提（厳守）】

- 改修根拠は「添付MQLのみ」。過去スレ、記憶、外部データ参照禁止。  
- コンパイルが通ること（未定義参照、二重定義、型不一致を出さない）。  
- Exit判定は M1 の「確定足のみ」で行う（Tickでは確定させない）。

【3. 仕様（改修内容）】

3-1) Exitの新仕様（EMAクロス）

- ExitTF：M1固定  
- ExitMA：EMA  
- FastPeriod=13 / SlowPeriod=21  
- クロス判定は「確定足のみ」。  
- 1本確認あり：  
  - ある確定足でクロスが発生したら“ExitPending”状態に遷移（または内部フラグ保持）。  
  - 次の確定足でもクロス状態が維持されていれば成行決済を実行。  
  - 次足でクロスが維持されていなければ ExitPending を解除（決済しない）。

クロス方向：

- ロング保有中：EMA13 が EMA21 を下抜け（デッドクロス）で Exit候補  
- ショート保有中：EMA13 が EMA21 を上抜け（ゴールデンクロス）で Exit候補

3-2) Exit優先順位（必須） Exit判定は必ず以下の優先順位で評価する：

1) 価格起点の構造破綻（強制Exit）  
   - ロング：インパルス起点安値（=Fib0）を「終値で明確割れ」したら即Exit  
   - ショート：インパルス起点高値（=Fib0）を「終値で明確突破」したら即Exit ※ “途中Fibレベル（50/61.8/78.6など）” による破綻Exitは新設しない（既存があれば撤去/無効化）。  
2) 時間無効（強制Exit）  
   - エントリー後に「時間無効」条件に該当したら Exit（既存仕様がある場合は踏襲）  
3) EMAクロス（通常Exit）  
   - 3-1のクロス＋1本確認で Exit

3-3) RR Gate（廃止）と RangeCost（維持）

- RR系のGate/判定/RejectStage が存在する場合：無効化または削除。  
- RangeCost（MinRangeCostMult 等）は維持（既存実装があればそのまま生かす）。

【4. 実装要件（具体指示）】

4-1) 追加/変更する input

ExitMAMethod \= MODE\_EMA     // 現行はEMA固定運用 ExitMAFastPeriod \= 13 ExitMASlowPeriod \= 21 ExitConfirmBars \= 1         // 1本確認

※ Exit方式はMAクロスに完全置換するため、 旧TP/SL切替用のbooleanは設けない。

4-2) “確定足のみ”の担保

- M1の新バー検出に紐づけてExit判定すること。  
- iMA取得は「確定足=1」を参照すること（現在足=0で確定させない）。  
- クロス判定は直近2本の確定足（shift=2 と shift=1）で行う。

4-3) ログ拡張（任意だが推奨） 決済発生時の Eventログ（LOG\_ENTRYEXIT 等）に Extra で以下を追記：

- ExitReason=EMA\_CROSS | STRUCT\_BREAK | TIMEOUT  
- CrossDir=DEAD | GOLDEN（EMAクロスの場合）  
- EMA13=EMA21=  
- ConfirmBars=1 ※ 列追加ではなく Extra 追記で対応。

【5. 成果物（出力形式）】

- 修正した関数を“関数単位”で、差し替え用コピーブロックで提示。  
- どの関数を新規追加/変更/削除したかの一覧を短く添える（箇条書き）。  
- 最後に「想定されるコンパイルエラー要因が残っていないか」の自己チェック結果を1段落で記載。

【6. 添付】

- 最新の ScalpImpulseRetraceEA.mq5（必ずこの添付のみを正とする）
