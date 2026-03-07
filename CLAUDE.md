# GoldBreakoutFilterEA

## プロジェクト概要
MT5用GOLD特化ブレイクアウトEA（MQL5）。
Impulse検出＋EMA/Exceedフィルターで高確度エントリー。
旧称: ScalpImpulseRetraceEA → v2.0でGOLD特化・ロジック刷新。

## ドキュメント構成（3層）

| 層 | ファイル | 内容 |
|---|---|---|
| 上流（仕様の正典） | `docs/SPEC.md` | 何を作るか・制約・受け入れ条件 |
| 中流（意思決定の正典） | `docs/DECISIONS.md` | なぜそうしたか・没案・変更可否 |
| 下流（実装の正典） | コード＋テスト＋コードコメント | 細部はコードが正典 |

旧ドキュメント（参照用・廃止候補）:
- docs/DOC-CORE.md：旧設計仕様書（SPEC.md + DECISIONS.md に移行済み）
- docs/DOC-LOG.md：旧ログ仕様書（語彙定義はSPEC.md、列順詳細はコードが正典）

## 技術スタック
- MQL5 / MetaTrader 5
- M1（主軸）、M15（Trend判定）、H1（Reversal Guard）

## 作業ルール
- 仕様書に書いてあることをこのファイルに複製しない
- コード修正前に、SPEC.md の関連セクションを必ず読むこと
- 仕様と食い違う実装を見つけたら、勝手に直さず報告すること
- 判断に迷ったら聞くこと（推測で進めない）
- 設計判断を変更した場合は DECISIONS.md に記録すること
