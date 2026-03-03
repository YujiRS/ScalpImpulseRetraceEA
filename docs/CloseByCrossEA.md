# 依頼：MT5 / MQL5 既存ポジション決済EAの作成（Ticket指定・SMAクロス・表示パネル付き）

あなたは MQL5（MT5）開発者です。
以下の仕様を満たす「既存ポジションを自動決済するEA」を実装してください。

## 0) 前提
- プラットフォーム：MT5
- 種別：EA（常駐して監視）
- Symbol 指定は不要（EAを起動したチャートの Symbol を自動使用）
- 新規エントリーは一切しない（決済のみ）
- MT5の制約上、1チャートウィンドウにつきEAは1つのみ起動可能。複数EA同時表示は想定しない。

## 1) 入力（input）
1) 監視TF（クロス判定に使うTF）
- input ENUM_TIMEFRAMES SignalTF = PERIOD_CURRENT;  // チャート表示TFを使用

2) 対象ポジション Ticket（必須）
- input ulong TargetTicket = 0;  // 0は禁止（必須入力）

3) チャート表示（パネル）
- input bool ShowPanel = true;
- input int PanelX = 10;        // 左下起点からのXオフセット
- input int PanelY = 20;        // 左下起点からのYオフセット

※ 行間（LINE_HEIGHT）はInput化せず内部定数（20px）とする。
※ SMAのチャート描写はEAでは行わない（テンプレート等で別途設定する運用）。

## 2) 指標・判定仕様
- 使用する移動平均：13SMA と 21SMA（SignalTF上）
- クロス判定は「確定足」のみで行う（未確定足での判定は禁止）
- 判定タイミング：SignalTF の新バー確定時に1回だけチェック
- クロス定義（確定足2本で判定）：
  - GoldenCross：SMA13 が SMA21 を下から上へクロス
    - prev(shift=2): SMA13 <= SMA21
    - curr(shift=1): SMA13 >  SMA21
  - DeadCross：SMA13 が SMA21 を上から下へクロス
    - prev(shift=2): SMA13 >= SMA21
    - curr(shift=1): SMA13 <  SMA21

### 2a) クロス確認（1本確認ルール・固定）
- クロス検出後、即決済せず **次の確定足1本** でクロス状態が維持されていることを確認する。
- 確認条件（確定足 shift=1 時点）：
  - DeadCross確認：SMA13 < SMA21 が維持されている → 確認OK
  - GoldenCross確認：SMA13 > SMA21 が維持されている → 確認OK
- 維持されていない場合（偽クロス）：
  - 決済せず ARMED に戻る（次のクロスを待つ）
- 設計意図：SMA差が極小（例：-0.75pt）で一瞬だけクロスして戻るケースをフィルタし、無駄な決済を防止する。
- 確認本数は1本固定とし、Input化しない。

## 3) 決済仕様（Ticket指定）
- 対象は「TargetTicket で指定された1つのポジションのみ」
- EA起動時に以下をチェック：
  1) TargetTicket のポジションが存在すること（存在しなければエラーをログ出して監視停止 or 待機）
  2) 対象ポジションの Symbol が "EAを動かしているチャートSymbol" と一致すること（不一致ならエラー）
- さらに「指定ポジションが既に条件を通過してしまっている場合は弾くチェック」を入れてください。
  - 意図：EAを後から起動したときに、既に直近確定足でクロス済み（またはクロス状態が成立済み）で即時に誤決済しないようにする。
  - 実装方針はお任せだが、少なくとも以下を満たすこと：
    - EA起動直後は "初期同期フェーズ" として、現在のMA関係（SMA13とSMA21の位置関係）を記録し、
      「次に新バーが確定してクロスが"発生した"とき」だけ決済する（起動時点の状態だけで決済しない）。
    - もしくは「最後に確定したバーでクロスが既に発生している場合は、そのクロスを無視して次のクロス待ち」とする。

## 4) クロスと決済の対応
- GoldenCross で決済するのは「SELLポジションのみ」
- DeadCross で決済するのは「BUYポジションのみ」
- もし TargetTicket のポジション方向が上記と一致しない場合は "何もしない" で次のクロスを待つ
- クロス検出時点でポジション方向が不一致の場合は、CONFIRM_WAIT に遷移せずスキップする（無駄な確認待ちの防止）

## 5) 実装上の必須要件
- iMA で 13SMA / 21SMA のハンドルを作り、CopyBuffer で値を取得
- ハンドルは OnInit で作成し、OnDeinit で解放（IndicatorRelease）
- "SignalTFの新バー"検出を実装し、バー確定時のみ判定する
- 決済は CTrade を使って PositionClose(ticket) で行う
- 決済成功/失敗、弾いた理由（存在しない、Symbol不一致、初期同期、方向不一致、偽クロス等）を Print ログに出す
- 例外系でも暴走しない（無限連打や毎Tick決済試行をしない ※ただし下記§5a のリトライ状態を除く）
  - 同一バーでは1回だけ判定する（クロス検出 / クロス確認）
  - 決済成功したら以後はEAは監視終了（停止フラグで何もしない）

### 5a) 決済失敗時のリトライ仕様
- PositionClose が失敗した場合、即座に諦めず PENDING_CLOSE 状態に遷移し、後続Tickでリトライする。
- 理由：SMAクロスは「クロスした瞬間」の1回だけしか検出できない。次のバーでは両方BELOWになりクロスではなくなるため、1回の失敗で決済チャンスを永久に逃す。
- リトライ上限（内部定数）：CLOSE_MAX_RETRY = 10
  - 上限に達した場合は ERROR 状態にして停止する（無限連打防止）
- リトライ間隔：1秒（サーバー叩きすぎ防止）
- PENDING_CLOSE 中は新バー判定・クロス判定はスキップし、決済リトライのみ行う。
- パネルにリトライ状況（回数/上限）を表示する。

### 5b) ポジション消失の誤検出防止
- PositionExists() が false を返しても、即座に ST_CLOSED にしない。
- 理由：MT5のサーバー通信が一瞬途切れると PositionsTotal が 0 を返すことがあり、ポジションは実際には存在している場合がある。
- 連続N回（内部定数 GONE_THRESHOLD = 5）false が続いた場合にのみ ST_CLOSED に遷移する。
- 途中で1回でもポジションが見つかればカウンタをリセットする。
- 各missをPrintログに出力する（何回目/閾値）。

## 6) 状態遷移まとめ

INIT → WAIT_SYNC → ARMED → CONFIRM_WAIT → PENDING_CLOSE → CLOSED
                      ↑        ↓ (false cross)
                      ←────────┘

- WAIT_SYNC：起動直後、MA関係を記録するだけで判定しない
- ARMED：クロス監視中（新バー確定時に判定）
- CONFIRM_WAIT：クロス検出済、次の確定足で維持確認待ち
  - 維持OK → 決済実行（→ CLOSED or PENDING_CLOSE）
  - 維持NG（偽クロス）→ ARMED に戻る
- PENDING_CLOSE：決済失敗、1秒間隔でリトライ中
- CLOSED：決済完了 or ポジション消失（以後何もしない）
- ERROR：致命エラー（以後何もしない）

## 7) チャート表示（OBJ_LABEL方式）要件
- 表示方式：OBJ_LABEL を使用
- 起点：チャート左下を基準（CORNER=左下）
- 位置：X=PanelX, Y=PanelY を起点とし、行間は内部定数 LINE_HEIGHT=20px で制御
- オブジェクト名：必ずユニークIDを含める
  - ObjPrefix = "CloseByCrossEA_" + (string)TargetTicket + "_";
- 表示内容（例。必要に応じて増やしてよい）：
  - EA名（CloseByCrossEA）＋ SignalTF
  - TargetTicket ＋ Positionの方向（BUY/SELL）
  - 状態（WAIT_SYNC / ARMED / CONFIRM_WAIT / PENDING_CLOSE / CLOSED / ERROR）
  - PENDING_CLOSE時：リトライ回数/上限
  - エラー理由・補足情報（ある場合）
- 状態別の表示色：
  - WAIT_SYNC: 黄色
  - ARMED: 青（DodgerBlue）
  - CONFIRM_WAIT: 金色（Gold）
  - PENDING_CLOSE: オレンジ
  - CLOSED: 緑（Lime）
  - ERROR: 赤
- 表示の更新頻度：
  - 毎Tick更新は禁止（ただし PENDING_CLOSE 時はリトライ毎に更新）
  - "状態更新時のみ" UpdatePanel() を呼んで表示更新する
- OnDeinit でパネルオブジェクトを削除する（ObjectDelete）

## 8) 受け取りたい成果物
- 完成した .mq5 のコード全文を、1つのコードブロックで提示してください
- コード内コメントは必要最小限でOK（実装意図が分かる程度）

以上の仕様で実装してください。
