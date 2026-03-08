//+------------------------------------------------------------------+
//| Constants.mqh                                                    |
//| GoldBreakoutFilterEA 定数定義・Enum・構造体・ToString変換・ATRヘルパー |
//| GOLD専用                                                          |
//+------------------------------------------------------------------+
#ifndef __CONSTANTS_MQH__
#define __CONSTANTS_MQH__

//+------------------------------------------------------------------+
//| 定数定義                                                          |
//+------------------------------------------------------------------+
#define EA_NAME           "GbfEA"
#define EA_VERSION        "v2.1"

//+------------------------------------------------------------------+
//| Enum定義                                                          |
//+------------------------------------------------------------------+

// StateID定義（数値固定・変更禁止）
enum ENUM_EA_STATE
{
   STATE_IDLE                    = 0, // IDLE
   STATE_IMPULSE_FOUND           = 1, // IMPULSE_FOUND
   STATE_IMPULSE_CONFIRMED       = 2, // IMPULSE_CONFIRMED
   STATE_MA_PULLBACK_WAIT        = 3, // MA_PULLBACK_WAIT (旧FIB_ACTIVE)
   STATE_RESERVED_4              = 4, // (reserved)
   STATE_RESERVED_5              = 5, // (reserved)
   STATE_ENTRY_PLACED            = 6, // ENTRY_PLACED
   STATE_IN_POSITION             = 7, // IN_POSITION
   STATE_COOLDOWN                = 8  // COOLDOWN
};

// ログレベル
enum ENUM_LOG_LEVEL
{
   LOG_LEVEL_OFF     = 0, // OFF
   LOG_LEVEL_NORMAL  = 1, // NORMAL
   LOG_LEVEL_DEBUG   = 2, // DEBUG
   LOG_LEVEL_ANALYZE = 3  // ANALYZE（ログ出力制御のみ・ロジック関与なし）
};

// ロットモード
enum ENUM_LOT_MODE
{
   LOT_MODE_FIXED        = 0, // FIXED
   LOT_MODE_RISK_PERCENT = 1  // RISK_PERCENT
};

// スプレッドモード
enum ENUM_SPREAD_MODE
{
   SPREAD_MODE_FIXED    = 0, // FIXED
   SPREAD_MODE_ADAPTIVE = 1  // ADAPTIVE
};

// 方向
enum ENUM_DIRECTION
{
   DIR_NONE  = 0, // NONE
   DIR_LONG  = 1, // LONG
   DIR_SHORT = 2  // SHORT
};

// Confirm種別（GOLD: CloseBounce / WickRejection）
enum ENUM_CONFIRM_TYPE
{
   CONFIRM_NONE           = 0, // NONE
   CONFIRM_WICK_REJECTION = 1, // WickRejection (MA bounce)
   CONFIRM_CLOSE_BOUNCE   = 4  // CloseBounce (MA bounce)
};

// FlatRange Exit State（Hybrid Exit用）
enum ENUM_FR_STATE
{
   FR_INACTIVE     = 0, // FlatRange不使用（EMAクロス Exit）
   FR_WAIT_FLAT    = 1, // Flat検出待ち
   FR_RANGE_LOCKED = 2, // レンジ確定・ブレイクアウト待ち
   FR_TRAILING     = 3  // 有利ブレイクアウト後 ATR トレーリング
};

// Entry種別
enum ENUM_ENTRY_TYPE
{
   ENTRY_NONE   = 0, // NONE
   ENTRY_LIMIT  = 1, // LIMIT
   ENTRY_MARKET = 2  // MARKET
};

// ログイベント分類
enum ENUM_LOG_EVENT
{
   LOG_STATE     = 0, // LOG_STATE
   LOG_IMPULSE   = 1, // LOG_IMPULSE
   LOG_TOUCH     = 2, // LOG_TOUCH
   LOG_CONFIRM   = 3, // LOG_CONFIRM
   LOG_ENTRY     = 4, // LOG_ENTRY
   LOG_POSITION  = 5, // LOG_POSITION
   LOG_EXIT      = 6, // LOG_EXIT
   LOG_REJECT    = 7  // LOG_REJECT
};

//+------------------------------------------------------------------+
//| MarketProfile構造体（GOLD専用）                                     |
//+------------------------------------------------------------------+
struct MarketProfileData
{
   // Impulse確定パラメータ
   double            impulseATRMult;
   int               impulseMinBars;
   double            smallBodyRatio;
   int               freezeCancelWindowBars;

   // 押し帯パラメータ
   bool              deepBandEnabled;         // 動的判定結果

   // タッチ/離脱パラメータ
   double            leaveDistanceMult;
   int               leaveMinBars;
   int               retouchTimeLimitBars;
   int               resetMinBars;

   // Confirm
   int               confirmTimeLimitBars;

   // Execution
   double            maxSlippagePts;
   double            maxFillDeviationPts;

   // Risk
   int               timeExitBars;

   // スプレッド
   double            spreadMult;

   // DeepBand条件パラメータ
   double            volExpansionRatio;
   double            overextensionMult;

   // WickRatioMin
   double            wickRatioMin;

   // EntryGate
   double            slATRMult;
   double            minRR_EntryGate;
   double            minRangeCostMult;
   double            tpExtensionRatio;
};

// ImpulseSummary構造体
struct ImpulseStats
{
   datetime   StartTime;
   string     TradeUUID;

   double     RangePts;
   double     BandWidthPts;
   double     LeaveDistancePts;
   double     SpreadBasePts;

   int        FreezeCancelCount;

   int        Touch1Count;
   int        LeaveCount;
   int        Touch2Count;
   int        ConfirmCount;

   bool       RiskGatePass;
   bool       Touch2Reached;
   bool       ConfirmReached;
   bool       EntryGatePass;

   double     RR_Actual;
   double     RR_Min;
   double     RangeCostMult_Actual;
   double     RangeCostMult_Min;

   string     FinalState;
   string     RejectStage;

   // STRUCTURE_BREAK 詳細
   string     StructBreakReason;
   int        StructBreakPriority;
   string     StructBreakRefLevel;
   double     StructBreakRefPrice;
   double     StructBreakAtPrice;
   double     StructBreakDistPts;
   int        StructBreakBarShift;
   string     StructBreakSide;
   string     StructBreakAtKind;
   int        StructBreakWickCross;
   double     StructBreakWickDistPts;

   // MA Confluence
   int        MA_ConfluenceCount;
   string     MA_InBand_List;
   string     MA_InBand_FibPct;
   int        MA_TightHitCount;
   string     MA_TightHit_List;
   string     MA_NearBand_List;
   double     MA_NearestDistance;
   int        MA_DirectionAligned;
   string     MA_Values;
   double     MA_Eval_Price;
   bool       MA_Evaluated;

   // TrendFilter / ReversalGuard
   int        TrendFilterEnable;
   string     TrendTF;
   string     TrendMethod;
   string     TrendDir;
   double     TrendSlope;
   double     TrendSlopeMin;
   bool       TrendSlopeSet;
   double     TrendATRFloor;
   bool       TrendATRFloorSet;
   int        TrendAligned;

   int        ReversalGuardEnable;
   string     ReversalTF;
   int        ReversalGuardTriggered;
   string     ReversalReason;

   // EMA Cross Filter
   int        EMACrossFilterEnable;
   double     EMACrossFastVal;
   double     EMACrossSlowVal;
   string     EMACrossDir;
   int        EMACrossAligned;

   // Impulse Exceed Filter
   int        ImpulseExceedEnable;
   double     ImpulseRangeATR;
   double     ImpulseExceedMax;
   int        ImpulseExceedTriggered;

   void Reset()
   {
      StartTime = TimeCurrent();
      TradeUUID = "";
      RangePts = 0; BandWidthPts = 0; LeaveDistancePts = 0; SpreadBasePts = 0;
      FreezeCancelCount = 0;
      Touch1Count = 0; LeaveCount = 0; Touch2Count = 0; ConfirmCount = 0;
      RiskGatePass = false; Touch2Reached = false; ConfirmReached = false; EntryGatePass = false;
      RR_Actual = 0; RR_Min = 0; RangeCostMult_Actual = 0; RangeCostMult_Min = 0;
      FinalState = ""; RejectStage = "NONE";
      StructBreakReason = ""; StructBreakPriority = 0; StructBreakRefLevel = "";
      StructBreakRefPrice = 0; StructBreakAtPrice = 0; StructBreakDistPts = 0;
      StructBreakBarShift = 0; StructBreakSide = "";
      StructBreakAtKind = ""; StructBreakWickCross = 0; StructBreakWickDistPts = 0;
      MA_ConfluenceCount = 0; MA_InBand_List = ""; MA_InBand_FibPct = "";
      MA_TightHitCount = 0; MA_TightHit_List = ""; MA_NearBand_List = "";
      MA_NearestDistance = 0; MA_DirectionAligned = -1; MA_Values = "";
      MA_Eval_Price = 0; MA_Evaluated = false;
      TrendFilterEnable = -1; TrendTF = ""; TrendMethod = ""; TrendDir = "";
      TrendSlope = 0; TrendSlopeMin = 0; TrendSlopeSet = false;
      TrendATRFloor = 0; TrendATRFloorSet = false; TrendAligned = -1;
      ReversalGuardEnable = -1; ReversalTF = "";
      ReversalGuardTriggered = -1; ReversalReason = "";
      EMACrossFilterEnable = -1; EMACrossFastVal = 0; EMACrossSlowVal = 0;
      EMACrossDir = ""; EMACrossAligned = -1;
      ImpulseExceedEnable = -1; ImpulseRangeATR = 0;
      ImpulseExceedMax = 0; ImpulseExceedTriggered = -1;
   }
};

// MA Confluence
#define MA_MAX_PERIODS 6

//+------------------------------------------------------------------+
//| ToString変換関数                                                   |
//+------------------------------------------------------------------+
string StateToString(ENUM_EA_STATE state)
{
   switch(state)
   {
      case STATE_IDLE:                   return "IDLE";
      case STATE_IMPULSE_FOUND:          return "IMPULSE_FOUND";
      case STATE_IMPULSE_CONFIRMED:      return "IMPULSE_CONFIRMED";
      case STATE_MA_PULLBACK_WAIT:       return "MA_PULLBACK_WAIT";
      case STATE_RESERVED_4:             return "RESERVED_4";
      case STATE_RESERVED_5:             return "RESERVED_5";
      case STATE_ENTRY_PLACED:           return "ENTRY_PLACED";
      case STATE_IN_POSITION:            return "IN_POSITION";
      case STATE_COOLDOWN:               return "COOLDOWN";
      default:                           return "UNKNOWN";
   }
}

string DirectionToString(ENUM_DIRECTION dir)
{
   switch(dir)
   {
      case DIR_LONG:  return "LONG";
      case DIR_SHORT: return "SHORT";
      default:        return "NONE";
   }
}

string ConfirmTypeToString(ENUM_CONFIRM_TYPE ct)
{
   switch(ct)
   {
      case CONFIRM_WICK_REJECTION: return "WickRejection";
      case CONFIRM_CLOSE_BOUNCE:   return "CloseBounce";
      default:                     return "NONE";
   }
}

string EntryTypeToString(ENUM_ENTRY_TYPE et)
{
   switch(et)
   {
      case ENTRY_LIMIT:  return "LIMIT";
      case ENTRY_MARKET: return "MARKET";
      default:           return "NONE";
   }
}

string LogEventToString(ENUM_LOG_EVENT ev)
{
   switch(ev)
   {
      case LOG_STATE:    return "LOG_STATE";
      case LOG_IMPULSE:  return "LOG_IMPULSE";
      case LOG_TOUCH:    return "LOG_TOUCH";
      case LOG_CONFIRM:  return "LOG_CONFIRM";
      case LOG_ENTRY:    return "LOG_ENTRY";
      case LOG_POSITION: return "LOG_POSITION";
      case LOG_EXIT:     return "LOG_EXIT";
      case LOG_REJECT:   return "LOG_REJECT";
      default:           return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| ATR取得ヘルパー                                                    |
//+------------------------------------------------------------------+
double GetATR_M1(int shift)
{
   if(g_atrHandleM1 == INVALID_HANDLE)
      return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandleM1, 0, shift, 1, buf) <= 0)
      return 0.0;
   return buf[0];
}

// 長期ATR（DeepBand VolExpansionRatio用）
double GetATR_M1_Long(int shift, int period = 50)
{
   int handle = iATR(Symbol(), PERIOD_M1, period);
   if(handle == INVALID_HANDLE)
      return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) <= 0)
   {
      IndicatorRelease(handle);
      return 0.0;
   }
   double val = buf[0];
   IndicatorRelease(handle);
   return val;
}

//+------------------------------------------------------------------+
//| MA/ATR汎用取得ヘルパー（TrendFilter等で使用）                         |
//+------------------------------------------------------------------+
double GetMAValue(const string sym, ENUM_TIMEFRAMES tf, int period, ENUM_MA_METHOD method, int applied_price, int shift)
{
   int h = iMA(sym, tf, period, 0, method, applied_price);
   if(h == INVALID_HANDLE) return EMPTY_VALUE;

   double buf[];
   ArraySetAsSeries(buf, true);

   if(CopyBuffer(h, 0, shift, 1, buf) != 1)
   {
      IndicatorRelease(h);
      return EMPTY_VALUE;
   }

   IndicatorRelease(h);
   return buf[0];
}

double GetATRValue(const string sym, ENUM_TIMEFRAMES tf, int period, int shift)
{
   int h = iATR(sym, tf, period);
   if(h == INVALID_HANDLE) return EMPTY_VALUE;

   double buf[];
   ArraySetAsSeries(buf, true);

   if(CopyBuffer(h, 0, shift, 1, buf) != 1)
   {
      IndicatorRelease(h);
      return EMPTY_VALUE;
   }

   IndicatorRelease(h);
   return buf[0];
}

#endif // __CONSTANTS_MQH__
