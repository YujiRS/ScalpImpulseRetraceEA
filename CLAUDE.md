# GoldBreakoutFilterEA

## プロジェクト概要
MT5用GOLD特化ブレイクアウトEA（MQL5）。
Impulse検出＋EMA/Exceedフィルターで高確度エントリー。
旧称: ScalpImpulseRetraceEA → v2.0でGOLD特化・ロジック刷新。

## 仕様書（実装・修正時は必ず該当章を読んでから作業すること）
- docs/DOC-CORE.md：設計仕様書（ロジック・状態遷移・パラメータの正典）
- docs/DOC-LOG.md：ログ仕様書（列定義・命名規則・RejectStage語彙の正典）
- ログ仕様はDOC-LOGが唯一の正典。DOC-CORE内の章番号参照は禁止。

## 技術スタック
- MQL5 / MetaTrader 5
- M1（主軸）、M15（Trend判定）、H1（Reversal Guard）

## 作業ルール
- 仕様書に書いてあることをこのファイルに複製しない
- コード修正前に、関連する仕様書の章を必ず読むこと
- 仕様と食い違う実装を見つけたら、勝手に直さず報告すること
- 判断に迷ったら聞くこと（推測で進めない）
