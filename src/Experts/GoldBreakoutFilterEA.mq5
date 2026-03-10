//+------------------------------------------------------------------+
//| GoldBreakoutFilterEA.mq5                                         |
//| GoldBreakoutFilterEA v2.1                                        |
//| GOLD専用: Impulse検出＋MA Bounce Entry＋EMA/Exceedフィルター        |
//| v2.1: Fib 2-Touch → MA Bounce (EMA13@M15) に変更                 |
//+------------------------------------------------------------------+
#property copyright "GoldBreakoutFilterEA"
#property link      ""
#property version   "2.10"
#property strict

//+------------------------------------------------------------------+
//| Module Includes                                                    |
//| 順序重要: Constants → Logger → MarketProfile → ImpulseDetector     |
//|          → MABounceEngine → EntryEngine → RiskManager → Execution |
//|          → Notification → Visualization                            |
//+------------------------------------------------------------------+
#include "GoldBreakoutFilterEA/Constants.mqh"
#include "GoldBreakoutFilterEA/SRDetector.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+

// 【G1：運用（普段触る）】
input bool              EnableTrading          = true;           // EnableTrading(false=ロジック稼働・Entry禁止)
input bool              UseLimitEntry          = true;           // UseLimitEntry
input bool              UseMarketFallback      = true;           // UseMarketFallback
input ENUM_LOT_MODE     LotMode                = LOT_MODE_FIXED; // LotMode
input double            FixedLot               = 0.01;           // FixedLot
input double            RiskPercent            = 1.0;            // RiskPercent (有効証拠金の%)
input double            MinMarginLevel         = 1500;           // MinMarginLevel(%) エントリー後維持率下限
input ENUM_LOG_LEVEL    LogLevel               = LOG_LEVEL_NORMAL; // LogLevel
input int               RunId                  = 0;              // RunId (0=自動連番)
input string            InstanceTag            = "";             // InstanceTag(コメント欄に付与、例:"Aggressive")
input double            LongDisableAbove       = 0;              // LongDisableAbove(Bid≧この値でLong禁止, 0=制御なし)
input double            ShortDisableBelow      = 0;              // ShortDisableBelow(Bid≦この値でShort禁止, 0=制御なし)

// --- Notification (Impulse only) ---
input bool              EnableDialogNotification = true;          // MT5端末ダイアログ通知（Alert）
input bool              EnablePushNotification   = true;          // MT5プッシュ通知（SendNotification）
input bool              EnableMailNotification   = false;         // メール通知（初期OFF）
input bool              EnableSoundNotification  = false;         // サウンド通知（初期OFF）
input string            SoundFileName            = "alert.wav";   // terminal/Sounds 内

// --- Exit: 建値移動 ---
input bool              EnableBreakeven        = true;            // 建値移動 ON/OFF
input double            BreakevenRR            = 1.5;             // 建値移動トリガー R:R

// --- Exit: EMAクロス決済 ---
input int               ExitMAFastPeriod       = 13;             // Exit EMA Fast Period
input int               ExitMASlowPeriod       = 21;             // Exit EMA Slow Period
input int               ExitConfirmBars        = 1;              // Exit Confirm Bars (1本確認)

// --- Exit: S/R Target TP ---
input bool              SR_Exit_Enable         = true;            // S/Rターゲット Exit ON/OFF
input double            SR_SkipATRMult         = 1.0;             // S/Rスキップ閾値 ATR(M15) × this
input int               SR_SwingLookback       = 7;               // M15 Swing検出 Lookback
input double            SR_MergeATRMult        = 0.5;             // S/Rレベル統合 ATR(M15) × this
input int               SR_MinTouches          = 2;               // S/Rレベル最小タッチ回数
input int               SR_MaxAgeBars          = 800;             // S/Rレベル最大年齢（M15 bars）
input int               SR_RefreshInterval     = 48;              // S/R再検出間隔（M15 bars = 12H）

// --- Exit: Hybrid (FlatRange) ---
input bool              HybridExit_Enable      = true;           // Hybrid Exit: 21MA方向一致時FlatRange決済
input int               HybridExit_TimeExitBars = 30;            // Hybrid Exit: FlatRange時のTimeExit(本)
input int               FR_FlatMaPeriod        = 21;             // FlatRange: MA Period
input int               FR_FlatSlopeLookback   = 3;              // FlatRange: Slope Lookback Bars
input double            FR_FlatSlopeAtrMult    = 0.30;           // FlatRange: Slope ATR Mult
input int               FR_RangeLookback       = 20;             // FlatRange: Range Lookback Bars
input double            FR_TrailATRMult        = 1.0;            // FlatRange: Trail ATR Mult
input int               FR_WaitBarsAfterFlat   = 30;             // FlatRange: FailSafe WaitBars

// === MA Bounce Entry ===
input ENUM_TIMEFRAMES   MABounce_Timeframe     = PERIOD_M15;     // MA Bounce HTF (GOLD: M15推奨)
input int               MABounce_Period         = 13;             // MA Bounce EMA Period
input double            MABounce_BandMult       = 0.3;            // MA Bounce Band Width = ATR(HTF) × this

// === TrendFilter / ReversalGuard ===
input bool   TrendFilter_Enable          = true;
input double TrendSlopeMult_GOLD         = 0.07;   // GOLD ATR(M15)*mult
input double TrendATRFloorPts_GOLD       = 80.0;   // GOLD ATR(M15) in points floor

input bool   ReversalGuard_Enable        = true;
input bool   ReversalEngulfing_Enable    = true;
input double ReversalBigBodyMult_GOLD    = 1.0;    // GOLD ATR(H1)*mult
input bool   ReversalWickReject_Enable_GOLD = true;
input double ReversalWickRatioMin_GOLD   = 0.60;

// === EMA Cross Filter (EMA20 vs EMA50 position) ===
input bool   EMACrossFilter_Enable_GOLD    = true;    // EMA20>EMA50=LONG, EMA20<EMA50=SHORT
input int    EMACrossFilter_FastPeriod_GOLD = 20;     // EMA Fast period for cross filter
// === Impulse Exceed Filter (overextension guard) ===
input bool   ImpulseExceed_Enable_GOLD     = true;    // Reject if impulse > MaxExceedATR × ATR(M15)
input double ImpulseExceed_MaxATR_GOLD     = 3.0;     // Max impulse range in ATR(M15) units

input bool              EnableFibVisualization = true;           // EnableFibVisualization
input bool              EnableStatusPanel      = true;           // On-chart status display (左下)

// 【G2：安全弁（事故防止）】
input ENUM_SPREAD_MODE  MaxSpreadMode          = SPREAD_MODE_ADAPTIVE; // MaxSpreadMode
input double            SpreadMult_GOLD        = 2.5;           // SpreadMult_GOLD
input double            InputMaxSlippagePts    = 0;             // MaxSlippagePts(0=デフォルト)
input double            InputMaxFillDeviationPts = 0;           // MaxFillDeviationPts(0=デフォルト)
input double            InputMaxSpreadPts      = 0;             // MaxSpreadPts(FIXED時)
// --- EntryGate ---
input double            MinRR_EntryGate_GOLD    = 0.6;           // MinRR_EntryGate_GOLD
input double            MinRangeCostMult_GOLD   = 2.5;           // MinRangeCostMult_GOLD
input double            SLATRMult_GOLD          = 0.8;           // SLATRMult_GOLD(SL=ImpulseStart±ATR*this)
// --- TP Extension ---
input double            TPExtRatio_GOLD         = 0.382;         // TPExtRatio_GOLD(0=Fib100そのまま)

// 【G3：戦略（基本触らない）】
input bool              ConfirmModeOverride    = false;          // ConfirmModeOverride

// 【G4：検証・デバッグ（普段触らない）】
input bool              DumpStateOnChange      = true;           // DumpStateOnChange
input bool              DumpRejectReason       = true;           // DumpRejectReason
input bool              DumpFibValues          = true;           // DumpFibValues
input bool              DumpMarketProfile      = true;           // DumpMarketProfile
input bool              LogStateTransitions    = true;           // LogStateTransitions
input bool              LogImpulseEvents       = true;           // LogImpulseEvents
input bool              LogTouchEvents         = true;           // LogTouchEvents
input bool              LogConfirmEvents       = true;           // LogConfirmEvents
input bool              LogEntryExit           = true;           // LogEntryExit
input bool              LogRejectReason        = true;           // LogRejectReason
input bool              LogMAConfluence        = true;           // LogMAConfluence(ANALYZE時のみ有効)

//+------------------------------------------------------------------+
//| グローバル変数                                                     |
//+------------------------------------------------------------------+

// State
ENUM_EA_STATE     g_currentState       = STATE_IDLE;
ENUM_EA_STATE     g_previousState      = STATE_IDLE;

// MarketProfile
MarketProfileData g_profile;

// ImpulseSummary統計グローバル
ImpulseStats      g_stats;

// Impulse
ENUM_DIRECTION    g_impulseDir         = DIR_NONE;
double            g_impulseStart       = 0.0;
double            g_impulseEnd         = 0.0;
double            g_impulseHigh        = 0.0;
double            g_impulseLow         = 0.0;
bool              g_startAdjusted      = false;
int               g_impulseBarIndex    = -1;
datetime          g_impulseBarTime     = 0;

// Freeze
bool              g_frozen             = false;
double            g_frozen100          = 0.0;
int               g_freezeBarIndex     = -1;
datetime          g_freezeBarTime      = 0;
int               g_freezeCancelCount  = 0;

// Fib (Structure Break用に維持)
double            g_fib382             = 0.0;
double            g_fib500             = 0.0;
double            g_fib618             = 0.0;
double            g_fib786             = 0.0;

// BandWidth (MA Bounce用)
double            g_bandWidthPts       = 0.0;
double            g_effectiveBandWidthPts = 0.0;

// MA Bounce
int               g_maBounceMAHandle   = INVALID_HANDLE;
int               g_maBounceATRHandle  = INVALID_HANDLE;
datetime          g_maBounceLastHTFBarTime = 0;
double            g_maBounceMAValue    = 0.0;
double            g_maBounceBandWidth  = 0.0;

// Confirm
ENUM_CONFIRM_TYPE g_confirmType        = CONFIRM_NONE;

// Entry / Position
ENUM_ENTRY_TYPE   g_entryType          = ENTRY_NONE;
double            g_entryPrice         = 0.0;
double            g_sl                 = 0.0;
double            g_tp                 = 0.0;
ulong             g_ticket             = 0;
int               g_positionBars       = 0;

// Spread（ADAPTIVE）
double            g_spreadBasePts      = 0.0;
double            g_maxSpreadPts       = 0.0;

// TradeUUID
string            g_tradeUUID          = "";

// Visualization object names
string            g_fibObjName         = "";
string            g_bandObjName        = "";
// タイマーカウンタ（Freeze後からのBar数）
int               g_barsAfterFreeze    = 0;

// Cooldownカウンタ
int               g_cooldownBars       = 0;
int               g_cooldownDuration   = 3;

// GOLD DeepBand (Structure Break用に維持)
bool              g_goldDeepBandON     = false;
bool              g_riskGateSoftPass   = false;

// Logger
int               g_logFileHandle      = INVALID_HANDLE;
string            g_logFileName        = "";

// Bar管理
datetime          g_lastBarTime        = 0;
bool              g_newBar             = false;

// FreezeCancel後の再監視フラグ
bool              g_freezeCancelled    = false;

// ADAPTIVE Spread計算用
int               g_spreadSampleMinutes = 15;

// Exit EMAクロス用ハンドル・状態
int               g_exitEMAFastHandle  = INVALID_HANDLE;
int               g_exitEMASlowHandle  = INVALID_HANDLE;
bool              g_exitPending        = false;
int               g_exitPendingBars    = 0;

// S/R Target Exit
double            g_srTargetTP         = 0.0;
SRLevel_Gold      g_srLevels[];
int               g_srCount            = 0;
datetime          g_srLastRefreshBarTime = 0;
int               g_atrHandleM15       = INVALID_HANDLE;

// Hybrid Exit: FlatRange用
int               g_frMAHandle         = INVALID_HANDLE;
ENUM_FR_STATE     g_frState            = FR_INACTIVE;
double            g_frRangeHigh        = 0.0;
double            g_frRangeLow         = 0.0;
double            g_frRangeMid         = 0.0;
double            g_frTrailPeak        = 0.0;
double            g_frTrailLine        = 0.0;
int               g_frWaitBarsCount    = 0;

// ATRハンドル
int               g_atrHandleM1        = INVALID_HANDLE;

// MA Confluence (ANALYZE用に維持)
int               g_maPeriods[];
int               g_maPeriodsCount     = 0;
int               g_smaHandles[MA_MAX_PERIODS];

// Impulse確定後のBar位置
int               g_freezeConfirmedBarShift = 0;

// Status Panel
int               g_panelMaxRow        = 0;

//+------------------------------------------------------------------+
//| Remaining Module Includes                                          |
//| (グローバル変数定義後にInclude)                                      |
//+------------------------------------------------------------------+
#include "GoldBreakoutFilterEA/Logger.mqh"
#include "GoldBreakoutFilterEA/MarketProfile.mqh"
#include "GoldBreakoutFilterEA/ImpulseDetector.mqh"
#include "GoldBreakoutFilterEA/MABounceEngine.mqh"
#include "GoldBreakoutFilterEA/EntryEngine.mqh"
#include "GoldBreakoutFilterEA/RiskManager.mqh"
#include "GoldBreakoutFilterEA/Execution.mqh"
#include "GoldBreakoutFilterEA/Notification.mqh"
#include "GoldBreakoutFilterEA/Visualization.mqh"

//+------------------------------------------------------------------+
//| 新しいバー検出                                                     |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(Symbol(), PERIOD_M1, 0);
   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| State遷移関数                                                     |
//+------------------------------------------------------------------+
void ChangeState(ENUM_EA_STATE newState, string reason = "")
{
   g_previousState = g_currentState;
   g_currentState  = newState;

   if(newState == STATE_IDLE)
      DeleteMABounceVisualization();

   if(newState == STATE_IDLE && LogLevel == LOG_LEVEL_ANALYZE)
   {
      if(g_stats.FinalState == "")
         g_stats.FinalState = reason;

      if(g_stats.RejectStage == "NONE")
      {
         if(!g_stats.ConfirmReached)
            g_stats.RejectStage = "NO_MA_BOUNCE";
      }

      DumpImpulseSummary();
   }

   string extra = "reason=" + reason;
   WriteLog(LOG_STATE, "", "", extra);

   if(DumpStateOnChange)
      Print("[STATE] ", StateToString(g_previousState), " -> ", StateToString(g_currentState), " | ", reason);
}

//+------------------------------------------------------------------+
//| 全State変数リセット                                                |
//+------------------------------------------------------------------+
void ResetAllState()
{
   g_impulseDir       = DIR_NONE;
   g_impulseStart     = 0;
   g_impulseEnd       = 0;
   g_impulseHigh      = 0;
   g_impulseLow       = 0;
   g_startAdjusted    = false;
   g_impulseBarIndex  = -1;
   g_impulseBarTime   = 0;

   g_frozen           = false;
   g_frozen100        = 0;
   g_freezeBarIndex   = -1;
   g_freezeBarTime    = 0;
   g_freezeCancelCount = 0;
   g_freezeCancelled  = false;

   g_fib382 = 0; g_fib500 = 0; g_fib618 = 0; g_fib786 = 0;
   g_bandWidthPts = 0;
   g_effectiveBandWidthPts = 0;

   // MA Bounce state
   g_maBounceLastHTFBarTime = 0;
   g_maBounceMAValue = 0;
   g_maBounceBandWidth = 0;

   g_confirmType      = CONFIRM_NONE;

   g_entryType  = ENTRY_NONE;
   g_entryPrice = 0;
   g_sl = 0; g_tp = 0;
   g_ticket = 0;
   g_positionBars = 0;

   g_barsAfterFreeze = 0;

   g_goldDeepBandON   = false;
   g_riskGateSoftPass = false;

   g_exitPending     = false;
   g_exitPendingBars = 0;

   // S/R Target
   g_srTargetTP      = 0.0;

   // FlatRange state
   g_frState         = FR_INACTIVE;
   g_frRangeHigh     = 0.0;
   g_frRangeLow      = 0.0;
   g_frRangeMid      = 0.0;
   g_frTrailPeak     = 0.0;
   g_frTrailLine     = 0.0;
   g_frWaitBarsCount = 0;

   g_tradeUUID = "";
}

//+------------------------------------------------------------------+
//| メインStateMachine処理                                            |
//+------------------------------------------------------------------+
void ProcessStateMachine()
{
   switch(g_currentState)
   {
      case STATE_IDLE:                   Process_IDLE(); break;
      case STATE_IMPULSE_FOUND:          Process_IMPULSE_FOUND(); break;
      case STATE_IMPULSE_CONFIRMED:      Process_IMPULSE_CONFIRMED(); break;
      case STATE_MA_PULLBACK_WAIT:       Process_MA_PULLBACK_WAIT(); break;
      case STATE_ENTRY_PLACED:           Process_ENTRY_PLACED(); break;
      case STATE_IN_POSITION:            Process_IN_POSITION(); break;
      case STATE_COOLDOWN:               Process_COOLDOWN(); break;
   }
}

//--- State処理関数群 ---

void Process_IDLE()
{
   if(!g_newBar) return;

   if(DetectImpulse())
   {
      g_tradeUUID = GenerateTradeUUID();
      g_freezeCancelCount = 0;

      g_stats.Reset();
      g_stats.TradeUUID = g_tradeUUID;
      g_stats.StartTime = TimeCurrent();

      UpdateAdaptiveSpread();

      string rejectStage = "NONE";
      if(!EvaluateTrendFilterAndGuard(rejectStage))
      {
         g_stats.FinalState  = "TREND_FILTER_REJECT";
         g_stats.RejectStage = rejectStage;

         WriteLog(LOG_REJECT, "", rejectStage);
         DumpImpulseSummary();

         g_stats.Reset();
         g_tradeUUID = "";
         return;
      }

      // Impulse Exceed Filter
      if(!EvaluateImpulseExceedFilter(rejectStage))
      {
         g_stats.FinalState  = "IMPULSE_EXCEED_REJECT";
         g_stats.RejectStage = rejectStage;

         WriteLog(LOG_REJECT, "", rejectStage);
         DumpImpulseSummary();

         g_stats.Reset();
         g_tradeUUID = "";
         return;
      }

      ChangeState(STATE_IMPULSE_FOUND, "ImpulseDetected");
      WriteLog(LOG_IMPULSE, "", "", "dir=" + DirectionToString(g_impulseDir));

      SendImpulseNotification();
   }
}

void Process_IMPULSE_FOUND()
{
   if(!g_newBar) return;

   if(CheckFreeze())
   {
      g_frozen    = true;
      g_frozen100 = g_impulseEnd;
      g_freezeBarIndex = 1;
      g_freezeBarTime  = iTime(Symbol(), PERIOD_M1, 1);
      g_barsAfterFreeze = 0;

      ChangeState(STATE_IMPULSE_CONFIRMED, "FreezeEstablished");
      WriteLog(LOG_IMPULSE, "", "", "Frozen100=" + DoubleToString(g_frozen100,
               (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));
   }
}

void Process_IMPULSE_CONFIRMED()
{
   // Fib算出（Structure Break用に維持）
   CalculateFibLevels();

   // MA Bounce セットアップ
   if(!SetupMABounce())
   {
      g_stats.RejectStage = "MA_SETUP_FAIL";
      ChangeState(STATE_IDLE, "MASetupFailed");
      ResetAllState();
      return;
   }

   // MA Confluence (ANALYZE用に維持)
   EvaluateMAConfluence();

   // 統計記録
   g_stats.RangePts         = MathAbs(g_impulseEnd - g_impulseStart);
   g_stats.BandWidthPts     = g_maBounceBandWidth;
   g_stats.SpreadBasePts    = g_spreadBasePts;
   {
      double _atr = GetATR_M1(0);
      double _entry = g_maBounceMAValue; // MA値をentry予測に使用
      double _sl = 0.0;
      double _tp = GetExtendedTP();
      double _point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      double _spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);

      _sl = (g_impulseDir == DIR_LONG)
            ? (g_impulseStart - _atr * g_profile.slATRMult)
            : (g_impulseStart + _atr * g_profile.slATRMult);

      double _risk   = MathAbs(_entry - _sl);
      double _reward = MathAbs(_tp - _entry);
      g_stats.RR_Actual = (_risk > _point * 0.5) ? (_reward / _risk) : 0.0;
      g_stats.RR_Min    = g_profile.minRR_EntryGate;
   }

   // RiskGate判定
   if(CheckNoEntryRiskGate())
   {
      g_stats.RiskGatePass = false;
      g_stats.RejectStage  = "RISK_GATE_FAIL";
      g_stats.FinalState   = "RiskGateFail";

      int _d = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
      double _range  = g_stats.RangePts;
      double _spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);

      WriteLog(LOG_REJECT, "", "RISK_GATE_FAIL",
               "range=" + DoubleToString(_range, _d) +
               ";bw=" + DoubleToString(g_maBounceBandWidth, _d) +
               ";spread=" + DoubleToString(_spread, _d));

      if(LogLevel != LOG_LEVEL_ANALYZE)
      {
         ChangeState(STATE_IDLE, "RiskGateFail");
         ResetAllState();
         return;
      }

      g_riskGateSoftPass = true;
   }
   else
   {
      g_stats.RiskGatePass = true;
      g_riskGateSoftPass   = false;
   }

   CreateMABounceVisualization();
   ChangeState(STATE_MA_PULLBACK_WAIT, "MABounceSetup");

   if(DumpFibValues)
   {
      Print("[MA_BOUNCE] 0=", g_impulseStart, " 100=", g_impulseEnd,
            " MA(", MABounce_Period, ")=", g_maBounceMAValue,
            " BandWidth=", g_maBounceBandWidth,
            " HTF=", EnumToString(MABounce_Timeframe));
   }
}

void Process_MA_PULLBACK_WAIT()
{
   if(!g_newBar) return;

   g_barsAfterFreeze++;

   // 構造無効チェック
   string br; int pr; string rl; double rp, ap, dp; int sh;
   if(CheckStructureInvalid_Detail(br, pr, rl, rp, ap, dp, sh))
   {
      g_stats.RejectStage         = "STRUCTURE_BREAK";
      g_stats.StructBreakReason   = br;
      g_stats.StructBreakPriority = pr;
      g_stats.StructBreakRefLevel = rl;
      g_stats.StructBreakRefPrice = rp;
      g_stats.StructBreakAtPrice  = ap;
      g_stats.StructBreakDistPts  = dp;
      g_stats.StructBreakBarShift = sh;

      g_stats.StructBreakSide     = (dp < 0.0 ? "UNDER" : (dp > 0.0 ? "OVER" : "ON"));
      g_stats.StructBreakAtKind   = "CLOSE";

      if(g_impulseDir == DIR_LONG)
      {
         double w = iLow(Symbol(), PERIOD_M1, 1);
         g_stats.StructBreakWickCross   = (w < rp) ? 1 : 0;
         g_stats.StructBreakWickDistPts = (w - rp) / _Point;
      }
      else
      {
         double w = iHigh(Symbol(), PERIOD_M1, 1);
         g_stats.StructBreakWickCross   = (w > rp) ? 1 : 0;
         g_stats.StructBreakWickDistPts = (w - rp) / _Point;
      }

      ChangeState(STATE_IDLE, "StructureInvalid");
      ResetAllState();
      return;
   }

   // FreezeCancel判定
   if(g_frozen &&
      g_barsAfterFreeze <= g_profile.freezeCancelWindowBars)
   {
      if(CheckFreezeCancel())
      {
         g_frozen = false;
         g_freezeCancelCount++;
         g_freezeCancelled = true;

         g_stats.FreezeCancelCount = g_freezeCancelCount;

         WriteLog(LOG_IMPULSE, "", "", "FreezeCancel;count=" + IntegerToString(g_freezeCancelCount));

         ChangeState(STATE_IMPULSE_FOUND, "FreezeCancelled");
         return;
      }
   }

   // Pullbackタイムアウト
   if(g_barsAfterFreeze > g_profile.retouchTimeLimitBars)
   {
      g_stats.RejectStage = "MA_PULLBACK_TIMEOUT";
      ChangeState(STATE_IDLE, "MAPullbackTimeLimitExpired");
      ResetAllState();
      return;
   }

   // MA Bounce チェック
   ENUM_CONFIRM_TYPE ct = CONFIRM_NONE;
   if(CheckMABounce(ct))
   {
      g_confirmType = ct;
      g_stats.ConfirmCount++;
      g_stats.ConfirmReached = true;

      WriteLog(LOG_CONFIRM, "", "MABounceConfirm",
               "ConfirmType=" + ConfirmTypeToString(ct) +
               ";MA=" + DoubleToString(g_maBounceMAValue, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) +
               ";BandWidth=" + DoubleToString(g_maBounceBandWidth, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));

      // Spread チェック
      if(!IsSpreadOK())
      {
         g_stats.RejectStage = "SPREAD_TOO_WIDE";
         ChangeState(STATE_IDLE, "SpreadTooWide");
         ResetAllState();
         return;
      }

      if(g_riskGateSoftPass)
      {
         g_stats.RejectStage = "RISK_GATE_SOFT_BLOCK";
         g_stats.FinalState  = "RiskGateSoftBlock";
         WriteLog(LOG_REJECT, "", "RISK_GATE_SOFT_BLOCK", "SoftPass=1;ConfirmType=" + ConfirmTypeToString(ct));
         ChangeState(STATE_IDLE, "RiskGateSoftBlock");
         ResetAllState();
         return;
      }

      // EntryGate: RangeCost チェック
      {
         double _egAtr = GetATR_M1(0);
         double _egEntry = (g_impulseDir == DIR_LONG)
                           ? SymbolInfoDouble(Symbol(), SYMBOL_ASK)
                           : SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double _egTP = GetExtendedTP();
         double _egSL = (g_impulseDir == DIR_LONG)
                        ? (g_impulseStart - _egAtr * g_profile.slATRMult)
                        : (g_impulseStart + _egAtr * g_profile.slATRMult);

         double _egRisk   = MathAbs(_egEntry - _egSL);
         double _egReward = MathAbs(_egTP - _egEntry);
         double _egPoint  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
         double _egRR     = (_egRisk > _egPoint * 0.5) ? (_egReward / _egRisk) : 0.0;

         g_stats.RR_Actual = _egRR;

         double _egSpread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double _egRangeCost = (_egSpread > 0.0) ? (_egReward / _egSpread) : 999.0;
         if(_egRangeCost < g_profile.minRangeCostMult)
         {
            g_stats.RangeCostMult_Actual = _egRangeCost;
            g_stats.RejectStage = "RANGE_COST_FAIL";
            g_stats.FinalState  = "EntryGate_RangeCost_Fail";
            WriteLog(LOG_REJECT, "", "RANGE_COST_FAIL",
                     "RangeCost=" + DoubleToString(_egRangeCost, 2) +
                     ";MinRangeCost=" + DoubleToString(g_profile.minRangeCostMult, 2) +
                     ";Reward=" + DoubleToString(_egReward, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)) +
                     ";Spread=" + DoubleToString(_egSpread, (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)));
            ChangeState(STATE_IDLE, "EntryGate_RangeCost_Fail");
            ResetAllState();
            return;
         }

         g_stats.RangeCostMult_Actual = _egRangeCost;
      }

      if(!ExecuteEntry())
      {
         ChangeState(STATE_IDLE, "EntryRejected");
         ResetAllState();
         return;
      }

      g_stats.EntryGatePass = true;
      ChangeState(STATE_ENTRY_PLACED, "EntryPlaced");
      return;
   }
}

void Process_ENTRY_PLACED()
{
   if(!g_newBar) return;

   if(PositionSelectByTicket(g_ticket))
   {
      g_positionBars = 0;

      // S/R Target TP: エントリー確定時にターゲット選定
      g_srTargetTP = 0.0;
      if(SR_Exit_Enable && g_srCount > 0 && g_atrHandleM15 != INVALID_HANDLE)
      {
         double m15ATRVal = GetATRValue(Symbol(), PERIOD_M15, 14, 1);
         if(m15ATRVal > 0)
         {
            double skipZone = m15ATRVal * SR_SkipATRMult;
            double fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            g_srTargetTP = FindSRTarget_Gold(g_srLevels, g_srCount,
                                             fillPrice, g_impulseDir,
                                             skipZone, SR_MinTouches);
            if(g_srTargetTP > 0)
            {
               // サーバーTPを設定
               g_tp = g_srTargetTP;
               ModifySL_TP(PositionGetDouble(POSITION_SL), g_srTargetTP);
               Print("[SR_Exit] Target TP set: ", DoubleToString(g_srTargetTP,
                     (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS)),
                     " dist_ATR=", DoubleToString(MathAbs(g_srTargetTP - fillPrice) / m15ATRVal, 2));
            }
            else
            {
               Print("[SR_Exit] No valid S/R target found → EMA cross fallback");
            }
         }
      }

      // Hybrid Exit: 21MA方向チェック
      g_frState = FR_INACTIVE;
      if(HybridExit_Enable && g_frMAHandle != INVALID_HANDLE)
      {
         double maCurr[1], maOld[1];
         if(CopyBuffer(g_frMAHandle, 0, 1, 1, maCurr) >= 1 &&
            CopyBuffer(g_frMAHandle, 0, 1 + FR_FlatSlopeLookback, 1, maOld) >= 1)
         {
            double slope = maCurr[0] - maOld[0];
            bool maAligned = false;
            if(g_impulseDir == DIR_LONG && slope > 0)
               maAligned = true;
            else if(g_impulseDir == DIR_SHORT && slope < 0)
               maAligned = true;

            if(maAligned)
            {
               g_frState = FR_WAIT_FLAT;
               Print("[HybridExit] 21MA aligned → FlatRange exit mode");
            }
            else
            {
               Print("[HybridExit] 21MA NOT aligned → EMA cross exit mode");
            }
         }
      }

      ChangeState(STATE_IN_POSITION, "OrderFilled");
   }
}

void Process_IN_POSITION()
{
   if(!g_newBar) return;
   ManagePosition();
}

void Process_COOLDOWN()
{
   if(!g_newBar) return;

   g_cooldownBars++;
   if(g_cooldownBars >= g_cooldownDuration)
   {
      g_cooldownBars = 0;
      ChangeState(STATE_IDLE, "CooldownExpired");
      ResetAllState();
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   InitMarketProfile();

   if(DumpMarketProfile)
   {
      Print("[PROFILE] MarketMode=GOLD(MA_BOUNCE)",
            " ImpulseATRMult=", g_profile.impulseATRMult,
            " SmallBodyRatio=", g_profile.smallBodyRatio,
            " FreezeCancelWindow=", g_profile.freezeCancelWindowBars,
            " SpreadMult=", g_profile.spreadMult,
            " SLATRMult=", g_profile.slATRMult,
            " TPExtRatio=", g_profile.tpExtensionRatio,
            " MABounce_TF=", EnumToString(MABounce_Timeframe),
            " MABounce_Period=", MABounce_Period,
            " MABounce_BandMult=", MABounce_BandMult);
   }

   g_atrHandleM1 = iATR(Symbol(), PERIOD_M1, 14);
   if(g_atrHandleM1 == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR handle");
      return INIT_FAILED;
   }

   g_exitEMAFastHandle = iMA(Symbol(), PERIOD_M1, ExitMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_exitEMASlowHandle = iMA(Symbol(), PERIOD_M1, ExitMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_exitEMAFastHandle == INVALID_HANDLE || g_exitEMASlowHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create Exit EMA handles. Fast=", g_exitEMAFastHandle, " Slow=", g_exitEMASlowHandle);
      return INIT_FAILED;
   }

   // FlatRange MA handle (Hybrid Exit)
   if(HybridExit_Enable)
   {
      g_frMAHandle = iMA(Symbol(), PERIOD_M1, FR_FlatMaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(g_frMAHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create FlatRange MA handle");
         return INIT_FAILED;
      }
   }

   // S/R Target Exit: M15 ATR handle + initial detection
   if(SR_Exit_Enable)
   {
      g_atrHandleM15 = iATR(Symbol(), PERIOD_M15, 14);
      if(g_atrHandleM15 == INVALID_HANDLE)
      {
         Print("WARNING: Failed to create M15 ATR handle for S/R detection");
      }
      else
      {
         ArrayResize(g_srLevels, GBF_MAX_SR_LEVELS);
         RefreshSRLevels_Gold(g_srLevels, g_srCount, g_srLastRefreshBarTime,
                              SR_SwingLookback, SR_MergeATRMult, SR_MaxAgeBars,
                              0.3, SR_RefreshInterval);
         Print("[SR_Exit] Initial S/R detection: ", g_srCount, " levels found");
      }
   }

   // MA Bounce handles
   if(!InitMABounceHandles())
      return INIT_FAILED;

   InitMAPeriods();
   for(int i = 0; i < MA_MAX_PERIODS; i++)
      g_smaHandles[i] = INVALID_HANDLE;

   for(int i = 0; i < g_maPeriodsCount; i++)
   {
      g_smaHandles[i] = iMA(Symbol(), PERIOD_M1, g_maPeriods[i], 0, MODE_SMA, PRICE_CLOSE);
      if(g_smaHandles[i] == INVALID_HANDLE)
         Print("WARNING: Failed to create SMA handle for period=", g_maPeriods[i]);
   }

   if(MaxSpreadMode == SPREAD_MODE_FIXED)
      g_maxSpreadPts = InputMaxSpreadPts;
   else
      g_maxSpreadPts = GetCurrentSpreadPts() * g_profile.spreadMult;

   LoggerInit();

   g_currentState = STATE_IDLE;
   g_lastBarTime = 0;

   Print(EA_NAME, " v2.1 initialized. Mode=GOLD(MA_BOUNCE)");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   LoggerDeinit();
   ClearChartStatusPanel();

   if(reason != REASON_CHARTCHANGE)
      DeleteMABounceVisualization();

   if(g_atrHandleM15 != INVALID_HANDLE)
   { IndicatorRelease(g_atrHandleM15); g_atrHandleM15 = INVALID_HANDLE; }

   if(g_atrHandleM1 != INVALID_HANDLE)
   { IndicatorRelease(g_atrHandleM1); g_atrHandleM1 = INVALID_HANDLE; }

   if(g_exitEMAFastHandle != INVALID_HANDLE)
   { IndicatorRelease(g_exitEMAFastHandle); g_exitEMAFastHandle = INVALID_HANDLE; }
   if(g_exitEMASlowHandle != INVALID_HANDLE)
   { IndicatorRelease(g_exitEMASlowHandle); g_exitEMASlowHandle = INVALID_HANDLE; }
   if(g_frMAHandle != INVALID_HANDLE)
   { IndicatorRelease(g_frMAHandle); g_frMAHandle = INVALID_HANDLE; }

   ReleaseMABounceHandles();

   for(int i = 0; i < g_maPeriodsCount; i++)
   {
      if(g_smaHandles[i] != INVALID_HANDLE)
      { IndicatorRelease(g_smaHandles[i]); g_smaHandles[i] = INVALID_HANDLE; }
   }

   Print(EA_NAME, " deinitialized. Reason=", reason);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   g_newBar = IsNewBar();

   // FreezeCancel チェック（Tick単位）
   if(g_frozen && g_currentState >= STATE_IMPULSE_CONFIRMED &&
      g_currentState <= STATE_MA_PULLBACK_WAIT)
   {
      if(g_barsAfterFreeze <= g_profile.freezeCancelWindowBars)
      {
         if(CheckFreezeCancel())
         {
            g_frozen = false;
            g_freezeCancelCount++;

            g_stats.FreezeCancelCount = g_freezeCancelCount;

            WriteLog(LOG_IMPULSE, "", "", "FreezeCancel;count=" + IntegerToString(g_freezeCancelCount));
            ChangeState(STATE_IMPULSE_FOUND, "FreezeCancelled_Tick");
         }
      }
   }

   // S/R Level refresh (M15 new bar)
   if(SR_Exit_Enable && g_atrHandleM15 != INVALID_HANDLE)
   {
      if(RefreshSRLevels_Gold(g_srLevels, g_srCount, g_srLastRefreshBarTime,
                              SR_SwingLookback, SR_MergeATRMult, SR_MaxAgeBars,
                              0.3, SR_RefreshInterval))
      {
         Print("[SR_Exit] Refreshed S/R levels: ", g_srCount, " found");
      }
   }

   ProcessStateMachine();

   if(g_currentState >= STATE_MA_PULLBACK_WAIT && g_currentState <= STATE_IN_POSITION)
   {
      if(g_bandObjName != "" && ObjectFind(0, g_bandObjName) >= 0)
      {
         ObjectSetInteger(0, g_bandObjName, OBJPROP_TIME, 1,
                          TimeCurrent() + (datetime)(PeriodSeconds(PERIOD_M1) * 10));
      }
   }

   UpdateChartStatusPanel();
}

//+------------------------------------------------------------------+
