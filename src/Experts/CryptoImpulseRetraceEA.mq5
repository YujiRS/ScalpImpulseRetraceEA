//+------------------------------------------------------------------+
//| CryptoImpulseRetraceEA.mq5                                       |
//| CryptoImpulseRetraceEA v1.1                                       |
//| CRYPTO専用: Impulse検出＋MA Bounce Entry＋EMA21/50 TrendFilter      |
//| v1.1: Fib 2-Touch → MA Bounce (EMA13@M5) に変更                   |
//+------------------------------------------------------------------+
#property copyright "CryptoImpulseRetraceEA"
#property link      ""
#property version   "1.10"
#property strict

//+------------------------------------------------------------------+
//| Module Includes                                                    |
//| 順序重要: Constants → Logger → MarketProfile → ImpulseDetector     |
//|          → MABounceEngine → EntryEngine → RiskManager → Execution |
//|          → Notification → Visualization                            |
//+------------------------------------------------------------------+
#include "CryptoImpulseRetraceEA/Constants.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+

// 【G1：運用（普段触る）】
input bool              EnableTrading          = true;           // EnableTrading(false=ロジック稼働・Entry禁止)
input bool              UseLimitEntry          = true;           // UseLimitEntry
input bool              UseMarketFallback      = true;           // UseMarketFallback
input ENUM_LOT_MODE     LotMode                = LOT_MODE_FIXED; // Lot Mode
input double            FixedLot               = 0.01;           // Fixed Lot (0=min lot)
input double            RiskPercent            = 1.0;            // RiskPercent (有効証拠金の%)
input double            MinMarginLevel         = 1500;           // MinMarginLevel(%) エントリー後維持率下限
input ENUM_LOG_LEVEL    LogLevel               = LOG_LEVEL_NORMAL; // LogLevel
input int               RunId                  = 0;              // RunId (0=自動連番)
input string            InstanceTag            = "";             // InstanceTag(コメント欄に付与、例:"Aggressive")
input double            LongDisableAbove       = 0;              // LongDisableAbove(Bid≧この値でLong禁止, 0=制御なし)
input double            ShortDisableBelow      = 0;              // ShortDisableBelow(Bid≦この値でShort禁止, 0=制御なし)

// --- FlatFilter Mode ---
input ENUM_FLAT_FILTER_MODE FlatFilterMode      = FLAT_FILTER_OFF; // FlatFilterMode (OFF/FlatGuard/FlatMatch)
input int               FlatRangeLookback       = 8;              // M5 Flat Range Lookback Bars
input double            FlatRangeATRMult        = 2.5;            // M5 Range <= ATR(M5)*this → FLAT

// --- Notification ---
input bool              EnableDialogNotification = true;
input bool              EnablePushNotification   = true;
input bool              EnableMailNotification   = false;
input bool              EnableSoundNotification  = false;
input string            SoundFileName            = "alert.wav";

// --- Exit: 建値移動 ---
input bool              EnableBreakeven        = false;           // 建値移動 ON/OFF
input double            BreakevenRR            = 1.0;             // 建値移動トリガー R:R

// --- Exit: EMAクロス決済 ---
input int               ExitMAFastPeriod       = 13;             // Exit EMA Fast Period
input int               ExitMASlowPeriod       = 21;             // Exit EMA Slow Period
input int               ExitConfirmBars        = 1;              // Exit Confirm Bars

// === MA Bounce Entry ===
input ENUM_TIMEFRAMES   MABounce_Timeframe     = PERIOD_M5;      // MA Bounce HTF (CRYPTO: M5推奨)
input int               MABounce_Period         = 13;             // MA Bounce EMA Period
input double            MABounce_BandMult       = 0.5;            // MA Bounce Band Width = ATR(HTF) × this

// === TrendFilter / ReversalGuard (CRYPTO) ===
input bool   TrendFilter_Enable          = true;
input double TrendSlopeMult_CRYPTO       = 0.07;   // CRYPTO ATR(M15)*mult for slope threshold
input bool   ReversalGuard_Enable        = true;
input double ReversalBigBodyMult_CRYPTO  = 1.0;    // CRYPTO ATR(H1)*mult for big body

// === Visualization ===
input bool              EnableFibVisualization = true;
input bool              EnableStatusPanel      = true;           // On-chart status display

// 【G2：安全弁】
input ENUM_SPREAD_MODE  MaxSpreadMode          = SPREAD_MODE_ADAPTIVE;
input double            SpreadMult_CRYPTO      = 3.0;            // SpreadMult_CRYPTO
input double            InputMaxSlippagePts    = 0;
input double            InputMaxFillDeviationPts = 0;
input double            InputMaxSpreadPts      = 0;
// --- EntryGate ---
input double            MinRR_EntryGate_CRYPTO  = 0.5;
input double            MinRangeCostMult_CRYPTO = 2.0;
input double            SLATRMult_CRYPTO        = 0.7;
input double            SLMarginSpreadMult_CRYPTO = 1.5;           // SLMarginSpreadMult_CRYPTO(SL margin=Spread*this)
input double            TPExtRatio_CRYPTO       = 0.382;
// --- Insurance TP (PC断時の安全ネット) ---
input double            InsuranceTP_ATRMult_CRYPTO = 3.0;        // 保険TP=Entry±ATR(M1)*this (0=無効)

// 【G4：検証・デバッグ】
input bool              DumpStateOnChange      = true;
input bool              DumpRejectReason       = true;
input bool              DumpFibValues          = true;
input bool              DumpMarketProfile      = true;
input bool              LogStateTransitions    = true;
input bool              LogImpulseEvents       = true;
input bool              LogTouchEvents         = true;
input bool              LogConfirmEvents       = true;
input bool              LogEntryExit           = true;
input bool              LogRejectReason        = true;

//+------------------------------------------------------------------+
//| グローバル変数                                                     |
//+------------------------------------------------------------------+

// State
ENUM_EA_STATE     g_currentState       = STATE_IDLE;
ENUM_EA_STATE     g_previousState      = STATE_IDLE;

// MarketProfile
MarketProfileData g_profile;

// ImpulseSummary統計
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
string            g_instanceTag        = "";

// Visualization object names
string            g_fibObjName         = "";
string            g_bandObjName        = "";

// タイマーカウンタ
int               g_barsAfterFreeze    = 0;

// ENTRY_PLACEDタイムアウト
int               g_entryPlacedBars    = 0;
const int         ENTRY_PLACED_TIMEOUT = 10;

// Cooldown
int               g_cooldownBars       = 0;
int               g_cooldownDuration   = 3;

// RiskGate soft pass (ANALYZE mode)
bool              g_riskGateSoftPass   = false;

// Logger
int               g_logFileHandle      = INVALID_HANDLE;
string            g_logFileName        = "";

// Bar管理
datetime          g_lastBarTime        = 0;
bool              g_newBar             = false;

// FreezeCancel後の再監視フラグ
bool              g_freezeCancelled    = false;

// Exit EMAクロス用
int               g_exitEMAFastHandle  = INVALID_HANDLE;
int               g_exitEMASlowHandle  = INVALID_HANDLE;
bool              g_exitPending        = false;
int               g_exitPendingBars    = 0;

// ATRハンドル
int               g_atrHandleM1        = INVALID_HANDLE;

// Status Panel
int               g_panelMaxRow        = 0;

//+------------------------------------------------------------------+
//| Remaining Module Includes                                          |
//+------------------------------------------------------------------+
#include "CryptoImpulseRetraceEA/Logger.mqh"
#include "CryptoImpulseRetraceEA/MarketProfile.mqh"
#include "CryptoImpulseRetraceEA/ImpulseDetector.mqh"
#include "CryptoImpulseRetraceEA/MABounceEngine.mqh"
#include "CryptoImpulseRetraceEA/EntryEngine.mqh"
#include "CryptoImpulseRetraceEA/RiskManager.mqh"
#include "CryptoImpulseRetraceEA/Execution.mqh"
#include "CryptoImpulseRetraceEA/Notification.mqh"
#include "CryptoImpulseRetraceEA/Visualization.mqh"

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

      // FlatFilter
      if(!CheckFlatFilter(rejectStage))
      {
         g_stats.FinalState  = "FLAT_FILTER_REJECT";
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

   // 統計記録
   g_stats.RangePts         = MathAbs(g_impulseEnd - g_impulseStart);
   g_stats.BandWidthPts     = g_maBounceBandWidth;
   g_stats.SpreadBasePts    = g_spreadBasePts;
   {
      double _atr = GetATR_M1(0);
      double _entry = g_maBounceMAValue;
      double _sl = 0.0;
      double _tp = GetExtendedTP();
      double _point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

      double _spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double _slMargin = _spread * g_profile.slMarginSpreadMult;
      _sl = (g_impulseDir == DIR_LONG)
            ? (g_impulseStart - _atr * g_profile.slATRMult - _slMargin)
            : (g_impulseStart + _atr * g_profile.slATRMult + _slMargin);

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
         double _egSpreadSL = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double _egSLMargin = _egSpreadSL * g_profile.slMarginSpreadMult;
         double _egSL = (g_impulseDir == DIR_LONG)
                        ? (g_impulseStart - _egAtr * g_profile.slATRMult - _egSLMargin)
                        : (g_impulseStart + _egAtr * g_profile.slATRMult + _egSLMargin);

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
                     ";MinRangeCost=" + DoubleToString(g_profile.minRangeCostMult, 2));
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
      g_entryPlacedBars = 0;
      ChangeState(STATE_ENTRY_PLACED, "EntryPlaced");
      return;
   }
}

void Process_ENTRY_PLACED()
{
   if(!g_newBar) return;

   g_entryPlacedBars++;

   if(CheckPositionFilled())
   {
      g_entryPlacedBars = 0;
      g_positionBars = 0;
      ChangeState(STATE_IN_POSITION, "OrderFilled");
      return;
   }

   // タイムアウト: 一定本数経過後にIDLEにフォールバック
   if(g_entryPlacedBars >= ENTRY_PLACED_TIMEOUT)
   {
      if(g_entryType == ENTRY_LIMIT)
         CancelPendingOrder();
      g_entryPlacedBars = 0;
      WriteLog(LOG_REJECT, "", "ENTRY_PLACED_TIMEOUT",
               "Bars=" + IntegerToString(g_entryPlacedBars));
      ChangeState(STATE_IDLE, "EntryPlacedTimeout");
      ResetAllState();
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
   g_instanceTag = InstanceTag;
   InitMarketProfile();

   if(DumpMarketProfile)
   {
      Print("[PROFILE] MarketMode=CRYPTO(MA_BOUNCE)",
            " ImpulseATRMult=", g_profile.impulseATRMult,
            " SmallBodyRatio=", g_profile.smallBodyRatio,
            " FreezeCancelWindow=", g_profile.freezeCancelWindowBars,
            " SpreadMult=", g_profile.spreadMult,
            " SLATRMult=", g_profile.slATRMult,
            " TPExtRatio=", g_profile.tpExtensionRatio,
            " MABounce_TF=", EnumToString(MABounce_Timeframe),
            " MABounce_Period=", MABounce_Period,
            " MABounce_BandMult=", MABounce_BandMult,
            " FlatFilterMode=", FlatFilterModeToString(FlatFilterMode));
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

   // MA Bounce handles
   if(!InitMABounceHandles())
      return INIT_FAILED;

   if(MaxSpreadMode == SPREAD_MODE_FIXED)
      g_maxSpreadPts = InputMaxSpreadPts;
   else
      g_maxSpreadPts = GetCurrentSpreadPts() * g_profile.spreadMult;

   LoggerInit();

   g_currentState = STATE_IDLE;
   g_lastBarTime = 0;

   Print(EA_NAME, " v1.1 initialized. Mode=CRYPTO(MA_BOUNCE) FlatFilter=", FlatFilterModeToString(FlatFilterMode));

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

   if(g_atrHandleM1 != INVALID_HANDLE)
   { IndicatorRelease(g_atrHandleM1); g_atrHandleM1 = INVALID_HANDLE; }

   if(g_exitEMAFastHandle != INVALID_HANDLE)
   { IndicatorRelease(g_exitEMAFastHandle); g_exitEMAFastHandle = INVALID_HANDLE; }
   if(g_exitEMASlowHandle != INVALID_HANDLE)
   { IndicatorRelease(g_exitEMASlowHandle); g_exitEMASlowHandle = INVALID_HANDLE; }

   ReleaseMABounceHandles();

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

   ProcessStateMachine();

   // Band visualization update
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
