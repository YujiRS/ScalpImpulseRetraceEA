//+------------------------------------------------------------------+
//| GoldBreakoutFilterEA.mq5                                         |
//| GoldBreakoutFilterEA v2.0                                        |
//| GOLD専用: Impulse検出＋EMA/Exceedフィルター                        |
//+------------------------------------------------------------------+
#property copyright "GoldBreakoutFilterEA"
#property link      ""
#property version   "2.00"
#property strict

//+------------------------------------------------------------------+
//| Module Includes                                                    |
//| 順序重要: Constants → Logger → MarketProfile → ImpulseDetector     |
//|          → FibEngine → EntryEngine → RiskManager → Execution      |
//|          → Notification → Visualization                            |
//+------------------------------------------------------------------+
#include "GoldBreakoutFilterEA/Constants.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+

// 【G1：運用（普段触る）】
input bool              EnableTrading          = true;           // EnableTrading(false=ロジック稼働・Entry禁止)
input bool              UseLimitEntry          = true;           // UseLimitEntry
input bool              UseMarketFallback      = true;           // UseMarketFallback
input ENUM_LOT_MODE     LotMode                = LOT_MODE_FIXED; // LotMode
input double            FixedLot               = 0.01;           // FixedLot
input double            RiskPercent            = 1.0;            // RiskPercent (口座残高の%)
input ENUM_LOG_LEVEL    LogLevel               = LOG_LEVEL_NORMAL; // LogLevel
input int               RunId                  = 1;              // RunId
input double            LongDisableAbove       = 0;              // LongDisableAbove(Bid≧この値でLong禁止, 0=制御なし)
input double            ShortDisableBelow      = 0;              // ShortDisableBelow(Bid≦この値でShort禁止, 0=制御なし)

// --- Notification (Impulse only) ---
input bool              EnableDialogNotification = true;          // MT5端末ダイアログ通知（Alert）
input bool              EnablePushNotification   = true;          // MT5プッシュ通知（SendNotification）
input bool              EnableMailNotification   = false;         // メール通知（初期OFF）
input bool              EnableSoundNotification  = false;         // サウンド通知（初期OFF）
input string            SoundFileName            = "alert.wav";   // terminal/Sounds 内

// --- Exit: EMAクロス決済 ---
input int               ExitMAFastPeriod       = 13;             // Exit EMA Fast Period
input int               ExitMASlowPeriod       = 21;             // Exit EMA Slow Period
input int               ExitConfirmBars        = 1;              // Exit Confirm Bars (1本確認)

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

// Fib
double            g_fib382             = 0.0;
double            g_fib500             = 0.0;
double            g_fib618             = 0.0;
double            g_fib786             = 0.0;

// BandWidth
double            g_bandWidthPts       = 0.0;
double            g_effectiveBandWidthPts = 0.0;

// Band上下限
double            g_primaryBandUpper   = 0.0;
double            g_primaryBandLower   = 0.0;
double            g_deepBandUpper      = 0.0;
double            g_deepBandLower      = 0.0;
double            g_optBand38Upper     = 0.0;
double            g_optBand38Lower     = 0.0;

// Touch
int               g_touchCount_Primary   = 0;
int               g_touchCount_Deep      = 0;
int               g_touchCount_Opt38     = 0;
bool              g_inBand_Primary       = false;
bool              g_inBand_Deep          = false;
bool              g_inBand_Opt38         = false;
bool              g_leaveEstablished_Primary = false;
bool              g_leaveEstablished_Deep    = false;
bool              g_leaveEstablished_Opt38   = false;
int               g_leaveBarCount_Primary    = 0;
int               g_leaveBarCount_Deep       = 0;
int               g_leaveBarCount_Opt38      = 0;

// Touch2成立帯識別
int               g_touch2BandId       = -1; // 0=Primary, 1=Deep

// Confirm
ENUM_CONFIRM_TYPE g_confirmType        = CONFIRM_NONE;
int               g_confirmWaitBars    = 0;

// MicroBreak用（フラクタル型）
double            g_microHigh          = 0.0;
double            g_microLow           = 0.0;
bool              g_microHighValid     = false;
bool              g_microLowValid      = false;

// WickRejection状態
bool              g_wickRejectionSeen  = false;

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

// Touch2成立後のBar数（Confirm待ち）
int               g_barsAfterTouch2    = 0;

// Cooldownカウンタ
int               g_cooldownBars       = 0;
int               g_cooldownDuration   = 3;

// GOLD DeepBand
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

// 離脱開始バー
datetime          g_leaveStartTime_Primary = 0;
datetime          g_leaveStartTime_Deep    = 0;
datetime          g_leaveStartTime_Opt38   = 0;

// ADAPTIVE Spread計算用
int               g_spreadSampleMinutes = 15;

// Exit EMAクロス用ハンドル・状態
int               g_exitEMAFastHandle  = INVALID_HANDLE;
int               g_exitEMASlowHandle  = INVALID_HANDLE;
bool              g_exitPending        = false;
int               g_exitPendingBars    = 0;

// ATRハンドル
int               g_atrHandleM1        = INVALID_HANDLE;

// MA Confluence
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
#include "GoldBreakoutFilterEA/FibEngine.mqh"
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
      DeleteCurrentFibVisualization();

   if(newState == STATE_IDLE && LogLevel == LOG_LEVEL_ANALYZE)
   {
      if(g_stats.FinalState == "")
         g_stats.FinalState = reason;

      if(g_stats.RejectStage == "NONE")
      {
         if(!g_stats.Touch2Reached)
            g_stats.RejectStage = "NO_TOUCH2";
         else if(!g_stats.ConfirmReached)
            g_stats.RejectStage = "NO_CONFIRM";
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

   g_primaryBandUpper = 0; g_primaryBandLower = 0;
   g_deepBandUpper = 0;    g_deepBandLower = 0;
   g_optBand38Upper = 0;   g_optBand38Lower = 0;

   g_touchCount_Primary = 0; g_touchCount_Deep = 0; g_touchCount_Opt38 = 0;
   g_inBand_Primary = false; g_inBand_Deep = false; g_inBand_Opt38 = false;
   g_leaveEstablished_Primary = false; g_leaveEstablished_Deep = false; g_leaveEstablished_Opt38 = false;
   g_leaveBarCount_Primary = 0; g_leaveBarCount_Deep = 0; g_leaveBarCount_Opt38 = 0;
   g_touch2BandId = -1;

   g_confirmType      = CONFIRM_NONE;
   g_confirmWaitBars  = 0;
   g_wickRejectionSeen = false;

   g_microHigh = 0; g_microLow = 0;
   g_microHighValid = false; g_microLowValid = false;

   g_entryType  = ENTRY_NONE;
   g_entryPrice = 0;
   g_sl = 0; g_tp = 0;
   g_ticket = 0;
   g_positionBars = 0;

   g_barsAfterFreeze = 0;
   g_barsAfterTouch2 = 0;

   g_goldDeepBandON   = false;
   g_riskGateSoftPass = false;

   g_exitPending     = false;
   g_exitPendingBars = 0;

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
      case STATE_FIB_ACTIVE:             Process_FIB_ACTIVE(); break;
      case STATE_TOUCH_1:                Process_TOUCH_1(); break;
      case STATE_TOUCH_2_WAIT_CONFIRM:   Process_TOUCH_2_WAIT_CONFIRM(); break;
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
   // GOLD DeepBand判定
   g_goldDeepBandON = EvaluateGoldDeepBand();
   g_profile.deepBandEnabled = g_goldDeepBandON;

   // BandWidth確定
   CalculateBandWidth();

   // Fib算出
   CalculateFibLevels();

   // 押し帯計算
   CalculateBands();

   // MA Confluence
   EvaluateMAConfluence();

   // 統計記録
   g_stats.RangePts         = MathAbs(g_impulseEnd - g_impulseStart);
   g_stats.BandWidthPts     = g_effectiveBandWidthPts;
   g_stats.LeaveDistancePts = g_effectiveBandWidthPts * g_profile.leaveDistanceMult;
   g_stats.SpreadBasePts    = g_spreadBasePts;
   {
      double _atr = GetATR_M1(0);
      double _entry = g_fib500;
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

      double _cost = (_spread * g_profile.spreadMult) + (g_effectiveBandWidthPts * 2.0) + (g_stats.LeaveDistancePts * 2.0);
      double _rangeP = g_stats.RangePts;
      g_stats.RangeCostMult_Actual = (_cost > 0.0) ? (_rangeP / _cost) : 0.0;
      g_stats.RangeCostMult_Min    = g_profile.minRangeCostMult;
   }

   // RiskGate判定
   if(CheckNoEntryRiskGate())
   {
      g_stats.RiskGatePass = false;
      g_stats.RejectStage  = "RISK_GATE_FAIL";
      g_stats.FinalState   = "RiskGateFail";

      int _d = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
      double _range  = g_stats.RangePts;
      double _leave  = g_stats.LeaveDistancePts;
      double _spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double _ratio  = (_range > 0.0 ? (g_effectiveBandWidthPts * 2.0) / _range : 999.0);

      WriteLog(LOG_REJECT, "", "RISK_GATE_FAIL",
               "range=" + DoubleToString(_range, _d) +
               ";bw=" + DoubleToString(g_effectiveBandWidthPts, _d) +
               ";leave=" + DoubleToString(_leave, _d) +
               ";spread=" + DoubleToString(_spread, _d) +
               ";band_dom_ratio=" + DoubleToString(_ratio, 3));

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

   CreateFibVisualization();
   ChangeState(STATE_FIB_ACTIVE, "FibCalculated");

   if(DumpFibValues)
   {
      Print("[FIB] 0=", g_impulseStart, " 100=", g_impulseEnd,
            " 38.2=", g_fib382, " 50=", g_fib500,
            " 61.8=", g_fib618, " 78.6=", g_fib786,
            " BW=", g_bandWidthPts,
            " DeepBandON=", g_goldDeepBandON);
   }
}

void Process_FIB_ACTIVE()
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
      g_barsAfterFreeze <= g_profile.freezeCancelWindowBars &&
      g_touchCount_Primary == 0 &&
      g_touchCount_Deep == 0 &&
      g_touchCount_Opt38 == 0)
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

   // RetouchTimeLimit
   if(g_barsAfterFreeze > g_profile.retouchTimeLimitBars)
   {
      g_stats.RejectStage = "RETOUCH_TIMEOUT";
      ChangeState(STATE_IDLE, "RetouchTimeLimitExpired");
      ResetAllState();
      return;
   }

   // タッチ判定
   int touch1BandId = ProcessTouchesForState();

   if(touch1BandId >= 0)
   {
      ChangeState(STATE_TOUCH_1, "Touch1Reached");
      return;
   }
}

// FIB_ACTIVEからのTouch1検出用
int ProcessTouchesForState()
{
   if(g_primaryBandUpper > 0 && g_primaryBandLower > 0)
   {
      if(CheckBandEntry(g_primaryBandUpper, g_primaryBandLower))
      {
         if(g_touchCount_Primary == 0 && !g_inBand_Primary)
         {
            g_inBand_Primary = true;
            g_touchCount_Primary = 1;
            RecordTouch1(0);
            return 0;
         }
      }
      else
      {
         if(g_inBand_Primary) g_inBand_Primary = false;
      }
   }

   if(g_deepBandUpper > 0 && g_deepBandLower > 0 && g_goldDeepBandON)
   {
      if(CheckBandEntry(g_deepBandUpper, g_deepBandLower))
      {
         if(g_touchCount_Deep == 0 && !g_inBand_Deep)
         {
            g_inBand_Deep = true;
            g_touchCount_Deep = 1;
            RecordTouch1(1);
            return 1;
         }
      }
      else
      {
         if(g_inBand_Deep) g_inBand_Deep = false;
      }
   }

   return -1;
}

void Process_TOUCH_1()
{
   if(!g_newBar) return;

   g_barsAfterFreeze++;

   if(!IsSpreadOK())
   {
      g_stats.RejectStage = "SPREAD_TOO_WIDE";
      ChangeState(STATE_IDLE, "SpreadTooWide");
      ResetAllState();
      return;
   }

   if(CheckNoEntryRiskGate())
   {
      g_stats.RejectStage = "RISK_GATE_FAIL";
      ChangeState(STATE_IDLE, "RiskGateFail");
      ResetAllState();
      return;
   }

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

   if(g_barsAfterFreeze > g_profile.retouchTimeLimitBars)
   {
      g_stats.RejectStage = "RETOUCH_TIMEOUT";
      ChangeState(STATE_IDLE, "RetouchTimeLimitExpired");
      ResetAllState();
      return;
   }

   int touch2BandId = ProcessTouches();
   if(touch2BandId >= 0)
   {
      ChangeState(STATE_TOUCH_2_WAIT_CONFIRM, "Touch2Reached");
      return;
   }
}

void Process_TOUCH_2_WAIT_CONFIRM()
{
   if(!g_newBar) return;

   g_barsAfterFreeze++;

   if(!IsSpreadOK())
   {
      g_stats.RejectStage = "SPREAD_TOO_WIDE";
      ChangeState(STATE_IDLE, "SpreadTooWide");
      ResetAllState();
      return;
   }

   if(CheckNoEntryRiskGate())
   {
      g_stats.RejectStage = "RISK_GATE_FAIL";
      ChangeState(STATE_IDLE, "RiskGateFail");
      ResetAllState();
      return;
   }

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

   if(g_barsAfterFreeze > g_profile.retouchTimeLimitBars)
   {
      g_stats.RejectStage = "RETOUCH_TIMEOUT";
      ChangeState(STATE_IDLE, "RetouchTimeLimitExpired");
      ResetAllState();
      return;
   }

   if(g_confirmWaitBars > g_profile.confirmTimeLimitBars)
   {
      g_stats.RejectStage = "CONFIRM_TIMEOUT";
      ChangeState(STATE_IDLE, "ConfirmTimeLimitExpired");
      ResetAllState();
      return;
   }

   UpdateFractalMicroLevels();

   ENUM_CONFIRM_TYPE ct = EvaluateConfirm();
   if(ct != CONFIRM_NONE)
   {
      g_confirmType = ct;
      g_stats.ConfirmCount++;
      g_stats.ConfirmReached = true;

      WriteLog(LOG_CONFIRM, "", "ConfirmOK", "ConfirmType=" + ConfirmTypeToString(ct));

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
   g_confirmWaitBars++;
}

void Process_ENTRY_PLACED()
{
   if(!g_newBar) return;

   if(PositionSelectByTicket(g_ticket))
   {
      ChangeState(STATE_IN_POSITION, "OrderFilled");
      g_positionBars = 0;
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
      Print("[PROFILE] MarketMode=GOLD",
            " ImpulseATRMult=", g_profile.impulseATRMult,
            " SmallBodyRatio=", g_profile.smallBodyRatio,
            " FreezeCancelWindow=", g_profile.freezeCancelWindowBars,
            " ConfirmTimeLimit=", g_profile.confirmTimeLimitBars,
            " SpreadMult=", g_profile.spreadMult,
            " SLATRMult=", g_profile.slATRMult,
            " TPExtRatio=", g_profile.tpExtensionRatio);
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

   Print(EA_NAME, " initialized. Mode=GOLD");

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
      DeleteCurrentFibVisualization();

   if(g_atrHandleM1 != INVALID_HANDLE)
   { IndicatorRelease(g_atrHandleM1); g_atrHandleM1 = INVALID_HANDLE; }

   if(g_exitEMAFastHandle != INVALID_HANDLE)
   { IndicatorRelease(g_exitEMAFastHandle); g_exitEMAFastHandle = INVALID_HANDLE; }
   if(g_exitEMASlowHandle != INVALID_HANDLE)
   { IndicatorRelease(g_exitEMASlowHandle); g_exitEMASlowHandle = INVALID_HANDLE; }

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
      g_currentState <= STATE_TOUCH_1)
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

   ProcessStateMachine();

   if(g_currentState >= STATE_FIB_ACTIVE && g_currentState <= STATE_IN_POSITION)
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
