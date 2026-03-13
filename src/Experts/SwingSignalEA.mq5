//+------------------------------------------------------------------+
//| SwingSignalEA.mq5                                                |
//| SwingSignalEA v1.0                                               |
//| M5 EMA Cross + H1 EMA Direction Filter + H1 Swing TP            |
//| ATR Trailing Stop + H1 Regime Exit                               |
//+------------------------------------------------------------------+
#property copyright "SwingSignalEA"
#property link      ""
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| ENUM Definitions                                                  |
//+------------------------------------------------------------------+
enum ENUM_SS_LOT_MODE
{
   SS_LOT_FIXED        = 0,  // Fixed Lot
   SS_LOT_RISK_PERCENT = 1,  // Risk % of Equity
};

enum ENUM_REVERSE_MODE
{
   REVERSE_CLOSE_AND_OPEN = 0,  // Close & Reverse
   REVERSE_IGNORE         = 1,  // Ignore reverse signal
};

enum ENUM_SS_LOG_LEVEL
{
   SS_LOG_OFF      = 0,  // Off
   SS_LOG_NORMAL   = 1,  // Trade log
   SS_LOG_ANALYZE  = 2,  // Trade + Signal log
};

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+

// === G1: Operation ===
input bool              EnableTrading          = true;                       // Enable Trading
input ENUM_SS_LOT_MODE  LotMode                = SS_LOT_FIXED;              // Lot Mode
input double            FixedLot               = 0.01;                      // Fixed Lot
input double            RiskPercent            = 1.0;                        // Risk % (of equity)
input double            MinMarginLevel         = 1500;                       // Min margin level after entry (%, 0=off)
input string            InstanceTag            = "";                         // Instance Tag (comment)
input ENUM_REVERSE_MODE ReverseMode            = REVERSE_CLOSE_AND_OPEN;    // Reverse Mode
input double            LongDisableAbove       = 0;                         // LongDisableAbove(Bid≧この値でLong禁止, 0=制御なし)
input double            ShortDisableBelow      = 0;                         // ShortDisableBelow(Bid≦この値でShort禁止, 0=制御なし)

// === G9: Notification ===
input bool              EnableAlert            = true;           // Alert on entry/exit
input bool              EnablePush             = true;           // Push notification
input bool              EnableEmail            = false;          // Email notification
input bool              EnableSoundNotification = false;          // Sound notification
input string            SoundFileName           = "alert.wav";    // Sound file in <MT5>/Sounds/ folder

// === G10: Logging ===
input ENUM_SS_LOG_LEVEL LogLevel               = SS_LOG_ANALYZE;  // Log Level

// === G2: M5 EMA (Trigger) ===
input int               M5_EMA_Fast            = 13;             // M5 EMA Fast Period
input int               M5_EMA_Slow            = 21;             // M5 EMA Slow Period
input bool              UseEMA                 = true;           // true: EMA / false: SMA
input double            SlopeMinATR            = 0.05;           // Slope minimum (ATR fraction, 0=disable)

// === G3: H1 EMA (Direction Filter) ===
input int               H1_EMA_Fast            = 13;             // H1 EMA Fast Period
input int               H1_EMA_Slow            = 21;             // H1 EMA Slow Period

// === G4: H1 Swing (TP Target) ===
input int               H1_SwingStrength       = 5;              // H1 Swing Lookback (bars each side)
input int               H1_SwingMaxAge         = 200;            // H1 Swing Max Age (bars)

// === G5: Stop Loss ===
input double            SL_BufferATR           = 0.5;            // SL Buffer (ATR fraction)
input double            SLMarginSpreadMult     = 1.5;            // SL Margin (Spread * this)
input double            MaxSL_ATR              = 2.0;            // Max SL Width (ATR multiple)
input double            MinRR                  = 2.0;            // Min Reward:Risk

// === G6: ATR Trailing Stop ===
input int               ATR_Period             = 14;             // ATR Period
input double            TrailATR_Multi         = 2.0;            // Trailing Distance (ATR multiple)

// === G7: Time Filter (Server Time) ===
input int               TradeHourStart         = 8;              // Trading Start Hour
input int               TradeHourEnd           = 21;             // Trading End Hour

// === G8: Spread Filter ===
input int               MaxSpreadPoints        = 0;              // Max Spread (points, 0=unlimited)


//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+

// Indicator handles
int g_m5EmaFastHandle  = INVALID_HANDLE;
int g_m5EmaSlowHandle  = INVALID_HANDLE;
int g_h1EmaFastHandle  = INVALID_HANDLE;
int g_h1EmaSlowHandle  = INVALID_HANDLE;
int g_m5AtrHandle      = INVALID_HANDLE;

// Bar tracking
datetime g_lastM5Bar = 0;
datetime g_lastH1Bar = 0;

// H1 regime
int g_h1Regime = 0;     // 1=Long, -1=Short, 0=Neutral
bool g_h1RegimeReady = false;  // true after first H1 regime calculation

// Position tracking
ulong  g_posTicket = 0;
int    g_posDir    = 0;     // 1=Buy, -1=Sell
double g_posOpenPrice = 0;
double g_trailHighest = 0;  // Highest price since entry (for long trailing)
double g_trailLowest  = 0;  // Lowest price since entry (for short trailing)

// Tester flag (set once in OnInit)
bool g_isTester = false;

// GlobalVariable key for position ticket persistence
string g_gvKey = "";

// Logging — Signal log + Trade log
int    g_signalLogHandle = INVALID_HANDLE;
string g_signalLogDate   = "";
int    g_tradeLogHandle  = INVALID_HANDLE;
string g_tradeLogDate    = "";

// Trade lifecycle tracking (set at entry, used at exit for Trade log)
datetime g_tradeEntryTime  = 0;
double   g_tradeATR        = 0;
long     g_tradeSpread     = 0;
double   g_tradeSLInitial  = 0;
double   g_tradeLastSL     = 0;
double   g_tradeTP         = 0;
double   g_tradeLot        = 0;
int      g_tradeH1Regime   = 0;
int      g_tradeTrailCount = 0;
double   g_tradePeakHigh   = 0;
double   g_tradePeakLow    = DBL_MAX;

// Panel
const string g_panelPrefix = "SS_Panel_";
const int    PANEL_X       = 14;
const int    PANEL_Y       = 20;
const int    PANEL_LINE_H  = 16;
const int    PANEL_FSIZE   = 9;
const int    PANEL_MAXLINE = 10;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);

   ENUM_MA_METHOD maMethod = UseEMA ? MODE_EMA : MODE_SMA;

   g_m5EmaFastHandle = iMA(_Symbol, PERIOD_M5,  M5_EMA_Fast, 0, maMethod, PRICE_CLOSE);
   g_m5EmaSlowHandle = iMA(_Symbol, PERIOD_M5,  M5_EMA_Slow, 0, maMethod, PRICE_CLOSE);
   g_h1EmaFastHandle = iMA(_Symbol, PERIOD_H1,  H1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_h1EmaSlowHandle = iMA(_Symbol, PERIOD_H1,  H1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   g_m5AtrHandle     = iATR(_Symbol, PERIOD_M5, ATR_Period);

   if(g_m5EmaFastHandle == INVALID_HANDLE || g_m5EmaSlowHandle == INVALID_HANDLE ||
      g_h1EmaFastHandle == INVALID_HANDLE || g_h1EmaSlowHandle == INVALID_HANDLE ||
      g_m5AtrHandle == INVALID_HANDLE)
   {
      Print("[SS] ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Initialize bar tracking
   g_lastM5Bar = 0;
   g_lastH1Bar = 0;
   g_h1Regime  = 0;
   g_h1RegimeReady = false;

   // Build GlobalVariable key for position ticket persistence
   g_gvKey = (InstanceTag != "") ? "SS_" + InstanceTag + "_" + _Symbol
                                 : "SS_" + _Symbol;

   // Check for existing position (GV ticket reference)
   FindOwnPosition();

   Print("[SS] SwingSignalEA initialized. GV=", g_gvKey);
   UpdatePanel();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_m5EmaFastHandle != INVALID_HANDLE) IndicatorRelease(g_m5EmaFastHandle);
   if(g_m5EmaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_m5EmaSlowHandle);
   if(g_h1EmaFastHandle != INVALID_HANDLE) IndicatorRelease(g_h1EmaFastHandle);
   if(g_h1EmaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_h1EmaSlowHandle);
   if(g_m5AtrHandle != INVALID_HANDLE)     IndicatorRelease(g_m5AtrHandle);

   CloseSignalLog();
   CloseTradeLog();
   DeletePanel();
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1. M5 new bar check
   datetime m5BarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(m5BarTime == g_lastM5Bar)
      return;
   g_lastM5Bar = m5BarTime;
   UpdatePanel();

   //--- 2. H1 new bar check & regime update
   datetime h1BarTime = iTime(_Symbol, PERIOD_H1, 0);
   bool h1NewBar = (h1BarTime != g_lastH1Bar);
   if(h1NewBar)
   {
      g_lastH1Bar = h1BarTime;
      bool wasReady = g_h1RegimeReady;
      UpdateH1Regime();

      // Exit 4: H1 regime end → immediate close
      // Skip on first regime calculation after init (wasReady=false)
      // to avoid closing existing positions due to uninitialized state
      if(wasReady && g_posTicket > 0 && EnableTrading)
      {
         if((g_posDir == 1 && g_h1Regime != 1) ||
            (g_posDir == -1 && g_h1Regime != -1))
         {
            ClosePosition("H1_REGIME_END");
         }
      }
   }

   //--- 3. Position management
   if(g_posTicket > 0)
   {
      // Check if position still exists (state tracking only, no server ops)
      if(!PositionSelectByTicket(g_posTicket))
      {
         // Position closed externally (TP/SL hit or manual)
         DetectExitReason();
         ResetPositionState();
         // Fall through to entry logic (position may have been closed)
      }
      else
      {
         // Track MFE/MAE from confirmed M5 bars
         double m5H = iHigh(_Symbol, PERIOD_M5, 1);
         double m5L = iLow(_Symbol, PERIOD_M5, 1);
         if(m5H > g_tradePeakHigh) g_tradePeakHigh = m5H;
         if(m5L < g_tradePeakLow)  g_tradePeakLow  = m5L;

         if(EnableTrading)
            UpdateTrailingStop();
      }
   }

   //--- 4. Entry logic
   if(!EnableTrading)
      return;

   // M5 EMA cross detection
   int crossSignal = DetectM5Cross();
   if(crossSignal == 0)
      return;

   //--- Evaluate ALL filters and collect snapshot for signal log ---
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double price = (crossSignal == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                      : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double atr = GetM5ATR();

   // M5 EMA values for signal log
   double m5f[], m5s[];
   ArraySetAsSeries(m5f, true);
   ArraySetAsSeries(m5s, true);
   double m5Fast = 0, m5Slow = 0, m5CrossGap = 0, m5SlopeFast = 0, m5SlopeSlow = 0;
   if(CopyBuffer(g_m5EmaFastHandle, 0, 1, 2, m5f) >= 2 &&
      CopyBuffer(g_m5EmaSlowHandle, 0, 1, 2, m5s) >= 2)
   {
      m5Fast      = m5f[0];
      m5Slow      = m5s[0];
      m5CrossGap  = MathAbs(m5Fast - m5Slow);
      m5SlopeFast = m5f[0] - m5f[1];
      m5SlopeSlow = m5s[0] - m5s[1];
   }

   // H1 EMA values for signal log
   double h1f[], h1s[];
   ArraySetAsSeries(h1f, true);
   ArraySetAsSeries(h1s, true);
   double h1Fast = 0, h1Slow = 0;
   if(CopyBuffer(g_h1EmaFastHandle, 0, 1, 1, h1f) >= 1) h1Fast = h1f[0];
   if(CopyBuffer(g_h1EmaSlowHandle, 0, 1, 1, h1s) >= 1) h1Slow = h1s[0];

   // Server hour
   MqlDateTime dtNow;
   TimeCurrent(dtNow);
   int serverHour = dtNow.hour;

   // Filter evaluation
   bool passRegime  = (crossSignal == g_h1Regime);
   bool passSlope   = CheckSlopeFilter(crossSignal, atr);
   bool passTime    = CheckTimeFilter();
   bool passSpread  = CheckSpreadFilter();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool passPriceCtrl = true;
   if(crossSignal == 1 && LongDisableAbove > 0 && bid >= LongDisableAbove)
      passPriceCtrl = false;
   if(crossSignal == -1 && ShortDisableBelow > 0 && bid <= ShortDisableBelow)
      passPriceCtrl = false;
   bool hasPosition = (g_posTicket > 0);
   bool passPosCheck = true;
   if(hasPosition)
   {
      if(g_posDir == crossSignal)
         passPosCheck = false;
      else if(ReverseMode == REVERSE_IGNORE)
         passPosCheck = false;
   }

   // SL / TP / Lot calculation (compute even if filters fail — for signal log)
   double sl = 0, tp = 0, slDist = 0, tpDist = 0, rr = 0;
   double swingTP = 0;
   bool   fallbackUsed = false;
   bool   passSLWidth  = false;
   bool   passATR      = (atr > 0);
   double lot = 0;
   bool   passMargin   = true;

   if(passATR)
   {
      sl = CalculateSL(crossSignal, atr);
      if(sl > 0)
      {
         slDist = MathAbs(price - sl);
         passSLWidth = (slDist <= MaxSL_ATR * atr);

         swingTP = FindH1SwingTP(crossSignal, price);
         tp = CalculateTP(crossSignal, price, slDist);
         fallbackUsed = (swingTP <= 0 || MathAbs(swingTP - price) < slDist * MinRR);

         if(tp > 0)
         {
            tpDist = MathAbs(tp - price);
            rr = (slDist > 0) ? tpDist / slDist : 0;
         }

         lot = CalculateLot(slDist);
         if(MinMarginLevel > 0 && lot > 0)
            passMargin = CheckMarginLevel(crossSignal, lot);
      }
   }

   // Convert distances to points
   double slDistPts = (point > 0) ? slDist / point : 0;
   double tpDistPts = (point > 0) ? tpDist / point : 0;

   // Determine outcome (first failing filter)
   string outcome = "ENTRY";
   if(!passRegime)            outcome = "REJECT_REGIME";
   else if(!passSlope)        outcome = "REJECT_SLOPE";
   else if(!passTime)         outcome = "REJECT_TIME";
   else if(!passSpread)       outcome = "REJECT_SPREAD";
   else if(!passPriceCtrl)    outcome = "REJECT_PRICE_CTRL";
   else if(!passPosCheck)
   {
      if(hasPosition && g_posDir == crossSignal)
         outcome = "REJECT_SAME_POS";
      else
         outcome = "REJECT_REVERSE_IGN";
   }
   else if(!passATR)          outcome = "REJECT_ATR";
   else if(sl <= 0)           outcome = "REJECT_SL_CALC";
   else if(!passSLWidth)      outcome = "REJECT_SL_WIDE";
   else if(tp <= 0)           outcome = "REJECT_NO_TP";
   else if(lot <= 0)          outcome = "REJECT_NO_LOT";
   else if(!passMargin)       outcome = "REJECT_MARGIN";

   // Execute if all filters passed
   if(outcome == "ENTRY")
   {
      if(g_posTicket > 0)
         ClosePosition("REVERSE");

      if(!ExecuteEntry(crossSignal, lot, sl, tp, atr))
         outcome = "REJECT_SEND";
   }

   // Write signal log (ANALYZE mode)
   if(LogLevel >= SS_LOG_ANALYZE)
   {
      WriteSignalLog(crossSignal, outcome, price, atr, spread,
                     m5Fast, m5Slow, m5CrossGap, m5SlopeFast, m5SlopeSlow,
                     h1Fast, h1Slow,
                     sl, tp, slDistPts, tpDistPts, rr, swingTP, fallbackUsed,
                     lot, serverHour,
                     passRegime, passSlope, passTime, passSpread, passPriceCtrl, passSLWidth, passMargin);
   }

   // Print rejection
   if(outcome != "ENTRY")
   {
      string dirStr = (crossSignal == 1) ? "BUY" : "SELL";
      Print("[SS] Signal ", dirStr, " rejected: ", outcome);
   }
}

//+------------------------------------------------------------------+
//| Update H1 Regime                                                  |
//+------------------------------------------------------------------+
void UpdateH1Regime()
{
   double h1Fast[], h1Slow[];
   ArraySetAsSeries(h1Fast, true);
   ArraySetAsSeries(h1Slow, true);

   if(CopyBuffer(g_h1EmaFastHandle, 0, 1, 1, h1Fast) < 1 ||
      CopyBuffer(g_h1EmaSlowHandle, 0, 1, 1, h1Slow) < 1)
   {
      return;
   }

   int prevRegime = g_h1Regime;
   bool wasReady = g_h1RegimeReady;

   if(h1Fast[0] > h1Slow[0])
      g_h1Regime = 1;
   else if(h1Fast[0] < h1Slow[0])
      g_h1Regime = -1;
   else
      g_h1Regime = 0;

   g_h1RegimeReady = true;

   if(prevRegime != g_h1Regime)
   {
      string dir = (g_h1Regime == 1) ? "LONG" : (g_h1Regime == -1) ? "SHORT" : "NEUTRAL";
      if(!wasReady)
         Print("[SS] H1 Regime initialized: ", dir);
      else
         Print("[SS] H1 Regime changed: ", dir,
               " H1Fast=", DoubleToString(h1Fast[0], (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
               " H1Slow=", DoubleToString(h1Slow[0], (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   }
}

//+------------------------------------------------------------------+
//| Detect M5 EMA Cross                                               |
//| Returns: 1=GC(Long), -1=DC(Short), 0=None                        |
//+------------------------------------------------------------------+
int DetectM5Cross()
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(g_m5EmaFastHandle, 0, 1, 2, fast) < 2 ||
      CopyBuffer(g_m5EmaSlowHandle, 0, 1, 2, slow) < 2)
   {
      return 0;
   }

   // fast[0]=shift[1], fast[1]=shift[2]
   // GC: shift[2] Fast < Slow, shift[1] Fast > Slow
   if(fast[1] < slow[1] && fast[0] > slow[0])
      return 1;

   // DC: shift[2] Fast > Slow, shift[1] Fast < Slow
   if(fast[1] > slow[1] && fast[0] < slow[0])
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Check M5 Slope Filter                                             |
//+------------------------------------------------------------------+
bool CheckSlopeFilter(int direction, double atr)
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(g_m5EmaFastHandle, 0, 1, 2, fast) < 2 ||
      CopyBuffer(g_m5EmaSlowHandle, 0, 1, 2, slow) < 2)
   {
      return false;
   }

   double slopeFast = fast[0] - fast[1];  // EMA_Fast[1] - EMA_Fast[2]
   double slopeSlow = slow[0] - slow[1];  // EMA_Slow[1] - EMA_Slow[2]

   // Minimum slope magnitude check (ATR-normalized)
   if(SlopeMinATR > 0 && atr > 0)
   {
      double threshold = atr * SlopeMinATR;
      if(MathAbs(slopeFast) < threshold || MathAbs(slopeSlow) < threshold)
         return false;
   }

   if(direction == 1)
      return (slopeFast > 0 && slopeSlow > 0);
   else
      return (slopeFast < 0 && slopeSlow < 0);
}

//+------------------------------------------------------------------+
//| Check Time Filter                                                  |
//+------------------------------------------------------------------+
bool CheckTimeFilter()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   if(TradeHourStart <= TradeHourEnd)
      return (hour >= TradeHourStart && hour < TradeHourEnd);
   else
      return (hour >= TradeHourStart || hour < TradeHourEnd);
}

//+------------------------------------------------------------------+
//| Check Spread Filter                                                |
//+------------------------------------------------------------------+
bool CheckSpreadFilter()
{
   if(MaxSpreadPoints <= 0)
      return true;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= MaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Get M5 ATR value                                                   |
//+------------------------------------------------------------------+
double GetM5ATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(g_m5AtrHandle, 0, 1, 1, atr) < 1)
      return 0;

   return atr[0];
}

//+------------------------------------------------------------------+
//| Calculate Stop Loss                                                |
//+------------------------------------------------------------------+
double CalculateSL(int direction, double atr)
{
   double low1  = iLow(_Symbol, PERIOD_M5, 1);
   double high1 = iHigh(_Symbol, PERIOD_M5, 1);
   int digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slMargin = spread * SLMarginSpreadMult;

   double sl;
   if(direction == 1)
      sl = low1 - SL_BufferATR * atr - slMargin;
   else
      sl = high1 + SL_BufferATR * atr + slMargin;

   return NormalizeDouble(sl, digits);
}

//+------------------------------------------------------------------+
//| Calculate Take Profit (H1 Swing)                                   |
//+------------------------------------------------------------------+
double CalculateTP(int direction, double entryPrice, double slDistance)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double swingTP = FindH1SwingTP(direction, entryPrice);
   double fallbackTP = 0;

   if(direction == 1)
      fallbackTP = entryPrice + slDistance * MinRR;
   else
      fallbackTP = entryPrice - slDistance * MinRR;

   double tp;
   if(swingTP <= 0)
   {
      // No swing found → use fallback
      tp = fallbackTP;
   }
   else
   {
      // Check minimum R:R
      double tpDistance = MathAbs(swingTP - entryPrice);
      if(tpDistance < slDistance * MinRR)
         tp = fallbackTP;
      else
         tp = swingTP;
   }

   return NormalizeDouble(tp, digits);
}

//+------------------------------------------------------------------+
//| Find H1 Swing High/Low for TP                                     |
//+------------------------------------------------------------------+
double FindH1SwingTP(int direction, double entryPrice)
{
   int str = H1_SwingStrength;
   int maxBars = H1_SwingMaxAge;

   // Need str bars on each side, so scan from str to maxBars-str
   double bestSwing = 0;
   double bestDistance = DBL_MAX;

   for(int i = str; i < maxBars - str; i++)
   {
      if(direction == 1)
      {
         // Look for Swing High above entry price
         double high_i = iHigh(_Symbol, PERIOD_H1, i);
         if(high_i <= entryPrice)
            continue;

         bool isSwingHigh = true;
         for(int j = 1; j <= str; j++)
         {
            if(high_i <= iHigh(_Symbol, PERIOD_H1, i - j) ||
               high_i <= iHigh(_Symbol, PERIOD_H1, i + j))
            {
               isSwingHigh = false;
               break;
            }
         }

         if(isSwingHigh)
         {
            double dist = high_i - entryPrice;
            if(dist < bestDistance)
            {
               bestDistance = dist;
               bestSwing   = high_i;
            }
         }
      }
      else
      {
         // Look for Swing Low below entry price
         double low_i = iLow(_Symbol, PERIOD_H1, i);
         if(low_i >= entryPrice)
            continue;

         bool isSwingLow = true;
         for(int j = 1; j <= str; j++)
         {
            if(low_i >= iLow(_Symbol, PERIOD_H1, i - j) ||
               low_i >= iLow(_Symbol, PERIOD_H1, i + j))
            {
               isSwingLow = false;
               break;
            }
         }

         if(isSwingLow)
         {
            double dist = entryPrice - low_i;
            if(dist < bestDistance)
            {
               bestDistance = dist;
               bestSwing   = low_i;
            }
         }
      }
   }

   return bestSwing;
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                                 |
//+------------------------------------------------------------------+
double CalculateLot(double slDistance)
{
   double lot = 0;

   if(LotMode == SS_LOT_FIXED)
   {
      lot = FixedLot;
   }
   else
   {
      // Risk % of equity
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmount = equity * RiskPercent / 100.0;

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

      if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0)
         return 0;

      double slTicks = slDistance / tickSize;
      lot = riskAmount / (slTicks * tickValue);

      Print("[RiskCalc] equity=", equity,
            " RiskPercent=", RiskPercent,
            " riskAmount=", riskAmount,
            " slDistance=", slDistance,
            " tickValue=", tickValue,
            " tickSize=", tickSize,
            " rawLot=", lot);
   }

   // Normalize lot
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   if(lot < minLot) lot = 0;
   if(lot > maxLot) lot = maxLot;

   Print("[RiskCalc] finalLot=", lot, " minLot=", minLot, " lotStep=", lotStep);

   return lot;
}

//+------------------------------------------------------------------+
//| Check Margin Level after hypothetical entry                        |
//+------------------------------------------------------------------+
bool CheckMarginLevel(int direction, double lot)
{
   double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                    : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double marginRequired = 0;
   if(!OrderCalcMargin(orderType, _Symbol, lot, price, marginRequired))
      return true;  // If calc fails, allow entry

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   double totalMargin = usedMargin + marginRequired;

   if(totalMargin <= 0)
      return true;

   double marginLevel = (equity / totalMargin) * 100.0;
   return (marginLevel >= MinMarginLevel);
}

//+------------------------------------------------------------------+
//| Get Filling Mode                                                   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((fillMode & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Execute Entry                                                      |
//+------------------------------------------------------------------+
bool ExecuteEntry(int direction, double lot, double sl, double tp, double atr)
{
   ENUM_ORDER_TYPE orderType = (direction == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                    : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   price = NormalizeDouble(price, digits);

   string comment = "SS";
   if(InstanceTag != "")
      comment += "_" + InstanceTag;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = _Symbol;
   request.volume    = lot;
   request.type      = orderType;
   request.price     = price;
   request.sl        = sl;
   request.tp        = tp;
   request.magic     = 0;
   request.comment   = comment;
   request.deviation = 10;
   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      Print("[SS] OrderSend FAILED: ", result.retcode, " ", result.comment);
      return false;
   }

   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
   {
      Print("[SS] OrderSend rejected: ", result.retcode, " ", result.comment);
      return false;
   }

   // Resolve position ticket from deal ticket (they differ in MT5)
   ulong posTicket = 0;
   if(HistoryDealSelect(result.deal))
      posTicket = (ulong)HistoryDealGetInteger(result.deal, DEAL_POSITION_ID);
   if(posTicket == 0)
      posTicket = result.order;  // fallback

   g_posTicket    = posTicket;
   g_posDir       = direction;
   g_posOpenPrice = result.price > 0 ? result.price : price;

   // Initialize trailing trackers
   if(direction == 1)
   {
      g_trailHighest = g_posOpenPrice;
      g_trailLowest  = 0;
   }
   else
   {
      g_trailLowest  = g_posOpenPrice;
      g_trailHighest = 0;
   }

   // Initialize trade lifecycle tracking
   g_tradeEntryTime  = TimeCurrent();
   g_tradeATR        = atr;
   g_tradeSpread     = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_tradeSLInitial  = sl;
   g_tradeLastSL     = sl;
   g_tradeTP         = tp;
   g_tradeLot        = lot;
   g_tradeH1Regime   = g_h1Regime;
   g_tradeTrailCount = 0;
   g_tradePeakHigh   = g_posOpenPrice;
   g_tradePeakLow    = g_posOpenPrice;

   // Persist ticket in GlobalVariable for restart recovery
   if(g_posTicket > 0)
   {
      GlobalVariableSet(g_gvKey, (double)g_posTicket);
      GlobalVariablesFlush();
   }

   string dirStr = (direction == 1) ? "BUY" : "SELL";
   string msg = StringFormat("[SS_ENTRY] %s  %s | %s | %."+IntegerToString(digits)+"f | SL=%."+IntegerToString(digits)+"f | TP=%."+IntegerToString(digits)+"f | Lot=%.2f",
                             dirStr, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                             _Symbol, g_posOpenPrice, sl, tp, lot);

   Print(msg);
   SendNotification_SS(msg);
   return true;
}

//+------------------------------------------------------------------+
//| Update Trailing Stop                                               |
//+------------------------------------------------------------------+
void UpdateTrailingStop()
{
   if(g_posTicket == 0)
      return;

   if(!PositionSelectByTicket(g_posTicket))
      return;

   double atr = GetM5ATR();
   if(atr <= 0)
      return;

   double trailDist = atr * TrailATR_Multi;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Update highest/lowest from latest M5 confirmed bar
   double m5High = iHigh(_Symbol, PERIOD_M5, 1);
   double m5Low  = iLow(_Symbol, PERIOD_M5, 1);

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double newSL = 0;

   if(g_posDir == 1)
   {
      if(m5High > g_trailHighest)
         g_trailHighest = m5High;

      newSL = NormalizeDouble(g_trailHighest - trailDist, digits);

      if(newSL <= currentSL || newSL <= 0)
         return;
   }
   else
   {
      if(m5Low < g_trailLowest || g_trailLowest == 0)
         g_trailLowest = m5Low;

      newSL = NormalizeDouble(g_trailLowest + trailDist, digits);

      if(newSL >= currentSL && currentSL > 0)
         return;
      if(newSL <= 0)
         return;
   }

   // Modify SL
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action   = TRADE_ACTION_SLTP;
   request.symbol   = _Symbol;
   request.position = g_posTicket;
   request.sl       = newSL;
   request.tp       = currentTP;

   if(!OrderSend(request, result))
   {
      Print("[SS] Trail SL modify FAILED: ", result.retcode);
      return;
   }

   if(result.retcode == TRADE_RETCODE_DONE)
   {
      g_tradeTrailCount++;
      g_tradeLastSL = newSL;
      if(LogLevel >= SS_LOG_NORMAL)
         Print("[SS] Trail SL updated: ", DoubleToString(currentSL, digits),
               " -> ", DoubleToString(newSL, digits));
   }
}

//+------------------------------------------------------------------+
//| Close Position (for H1 regime end / reverse)                       |
//+------------------------------------------------------------------+
void ClosePosition(string reason)
{
   if(g_posTicket == 0)
      return;

   if(!PositionSelectByTicket(g_posTicket))
   {
      ResetPositionState();
      return;
   }

   // Capture position data BEFORE closing
   double slFinal     = PositionGetDouble(POSITION_SL);
   double profitMoney = PositionGetDouble(POSITION_PROFIT);
   double volume      = PositionGetDouble(POSITION_VOLUME);

   ENUM_ORDER_TYPE closeType = (g_posDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double price = (closeType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                 : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   price = NormalizeDouble(price, digits);

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume       = volume;
   request.type         = closeType;
   request.price        = price;
   request.position     = g_posTicket;
   request.magic        = 0;
   request.deviation    = 10;
   request.type_filling = GetFillingMode();

   if(!OrderSend(request, result))
   {
      Print("[SS] Close FAILED: ", result.retcode, " Reason=", reason);
      return;
   }

   if(result.retcode != TRADE_RETCODE_DONE)
   {
      Print("[SS] Close rejected: ", result.retcode, " Reason=", reason);
      return;  // Position still alive — do NOT reset state or clear GV
   }

   double profitPts = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point > 0)
   {
      if(g_posDir == 1)
         profitPts = (price - g_posOpenPrice) / point;
      else
         profitPts = (g_posOpenPrice - price) / point;
   }

   // Write trade log
   if(LogLevel >= SS_LOG_NORMAL)
   {
      int holdBars = iBarShift(_Symbol, PERIOD_M5, g_tradeEntryTime);
      double mfePts = 0, maePts = 0;
      if(point > 0)
      {
         if(g_posDir == 1)
         {
            mfePts = (g_tradePeakHigh - g_posOpenPrice) / point;
            maePts = (g_posOpenPrice - g_tradePeakLow) / point;
         }
         else
         {
            mfePts = (g_posOpenPrice - g_tradePeakLow) / point;
            maePts = (g_tradePeakHigh - g_posOpenPrice) / point;
         }
      }
      WriteTradeLog(g_tradeEntryTime, TimeCurrent(), g_posDir,
                    g_posOpenPrice, price, g_tradeLot,
                    g_tradeSLInitial, slFinal, g_tradeTP,
                    profitPts, profitMoney, holdBars, reason,
                    g_tradeTrailCount, g_tradeATR, g_tradeSpread, g_tradeH1Regime,
                    mfePts, maePts);
   }

   string dirStr = (g_posDir == 1) ? "BUY" : "SELL";
   string msg = StringFormat("[SS_EXIT] %s  %s | %s | %."+IntegerToString(digits)+"f | Profit=%+.0fpoints | Reason=%s",
                             dirStr, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                             _Symbol, price, profitPts, reason);

   Print(msg);
   SendNotification_SS(msg);

   ResetPositionState();
}

//+------------------------------------------------------------------+
//| Detect Exit Reason (when position closed externally)               |
//+------------------------------------------------------------------+
void DetectExitReason()
{
   // Try to determine how the position was closed
   string reason = "EXTERNAL";
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Check recent deal history
   datetime from = TimeCurrent() - 360;
   datetime to   = TimeCurrent() + 1;
   HistorySelect(from, to);

   double exitPrice   = 0;
   double profitMoney = 0;

   int totalDeals = HistoryDealsTotal();
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      // Match by position ticket
      ulong dealPosId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(dealPosId != g_posTicket)
         continue;

      long dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
      long dealEntry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

      if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
      {
         exitPrice   = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         profitMoney = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

         if(dealReason == DEAL_REASON_TP)
            reason = "TP_HIT";
         else if(dealReason == DEAL_REASON_SL)
            reason = "SL_HIT";
         break;
      }
   }

   // For SL_HIT, check if SL was trailed (different from initial)
   if(reason == "SL_HIT" && g_tradeTrailCount > 0)
      reason = "ATR_TRAIL";

   // Fallback exit price
   if(exitPrice <= 0)
      exitPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double profitPts = 0;
   if(point > 0 && g_posOpenPrice > 0)
   {
      if(g_posDir == 1)
         profitPts = (exitPrice - g_posOpenPrice) / point;
      else
         profitPts = (g_posOpenPrice - exitPrice) / point;
   }

   // Write trade log
   if(LogLevel >= SS_LOG_NORMAL)
   {
      int holdBars = iBarShift(_Symbol, PERIOD_M5, g_tradeEntryTime);
      double mfePts = 0, maePts = 0;
      if(point > 0)
      {
         if(g_posDir == 1)
         {
            mfePts = (g_tradePeakHigh - g_posOpenPrice) / point;
            maePts = (g_posOpenPrice - g_tradePeakLow) / point;
         }
         else
         {
            mfePts = (g_posOpenPrice - g_tradePeakLow) / point;
            maePts = (g_tradePeakHigh - g_posOpenPrice) / point;
         }
      }
      WriteTradeLog(g_tradeEntryTime, TimeCurrent(), g_posDir,
                    g_posOpenPrice, exitPrice, g_tradeLot,
                    g_tradeSLInitial, g_tradeLastSL, g_tradeTP,
                    profitPts, profitMoney, holdBars, reason,
                    g_tradeTrailCount, g_tradeATR, g_tradeSpread, g_tradeH1Regime,
                    mfePts, maePts);
   }

   string dirStr = (g_posDir == 1) ? "BUY" : "SELL";
   string msg = StringFormat("[SS_EXIT] %s  %s | %s | %."+IntegerToString(digits)+"f | Profit=%+.0fpoints | Reason=%s",
                             dirStr, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                             _Symbol, exitPrice, profitPts, reason);

   Print(msg);
   SendNotification_SS(msg);
}

//+------------------------------------------------------------------+
//| Find Own Position                                                  |
//+------------------------------------------------------------------+
void FindOwnPosition()
{
   g_posTicket = 0;
   g_posDir    = 0;

   // GV-only: only manage positions whose ticket we explicitly stored
   // No scanning, no attribute matching → zero risk of adopting foreign positions
   if(!GlobalVariableCheck(g_gvKey))
      return;

   ulong storedTicket = (ulong)GlobalVariableGet(g_gvKey);
   if(storedTicket == 0)
   {
      GlobalVariableDel(g_gvKey);
      return;
   }

   if(!PositionSelectByTicket(storedTicket))
   {
      // Position no longer exists → clear GV
      GlobalVariableDel(g_gvKey);
      return;
   }

   g_posTicket    = storedTicket;
   g_posOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   long posType   = PositionGetInteger(POSITION_TYPE);
   g_posDir = (posType == POSITION_TYPE_BUY) ? 1 : -1;

   // Reconstruct trade tracking (best-effort after restart)
   g_tradeEntryTime = (datetime)PositionGetInteger(POSITION_TIME);
   g_tradeLastSL    = PositionGetDouble(POSITION_SL);
   g_tradeSLInitial = g_tradeLastSL;  // approximate — initial SL is lost across restarts
   g_tradeTP        = PositionGetDouble(POSITION_TP);
   g_tradeLot       = PositionGetDouble(POSITION_VOLUME);
   g_tradeH1Regime  = g_h1Regime;
   g_tradeATR       = 0;     // lost across restarts
   g_tradeSpread    = 0;     // lost across restarts
   g_tradeTrailCount = 0;    // lost across restarts

   ReconstructTrailTrackers();
}

//+------------------------------------------------------------------+
//| Reconstruct trail highest/lowest from M5 bars since entry         |
//+------------------------------------------------------------------+
void ReconstructTrailTrackers()
{
   datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);

   // Count M5 bars since position open
   int barShift = iBarShift(_Symbol, PERIOD_M5, posTime);
   if(barShift < 0)
      barShift = 0;

   // Scan confirmed bars (shift 1 to barShift) for highest/lowest
   // Start from open price as baseline
   g_trailHighest = g_posOpenPrice;
   g_trailLowest  = g_posOpenPrice;

   for(int s = 1; s <= barShift; s++)
   {
      double h = iHigh(_Symbol, PERIOD_M5, s);
      double l = iLow(_Symbol, PERIOD_M5, s);
      if(h > g_trailHighest) g_trailHighest = h;
      if(l < g_trailLowest)  g_trailLowest  = l;
   }

   // Zero out the unused tracker
   if(g_posDir == 1)
      g_trailLowest = 0;
   else
      g_trailHighest = 0;

   // Also set MFE/MAE peak trackers from the same bar scan
   g_tradePeakHigh = g_trailHighest > 0 ? g_trailHighest : g_posOpenPrice;
   g_tradePeakLow  = g_trailLowest  > 0 ? g_trailLowest  : g_posOpenPrice;
   // Re-scan for full peak (need both directions regardless of posDir)
   for(int ss = 1; ss <= barShift; ss++)
   {
      double hh = iHigh(_Symbol, PERIOD_M5, ss);
      double ll = iLow(_Symbol, PERIOD_M5, ss);
      if(hh > g_tradePeakHigh) g_tradePeakHigh = hh;
      if(ll < g_tradePeakLow)  g_tradePeakLow  = ll;
   }

   if(LogLevel >= SS_LOG_NORMAL && barShift > 0)
      Print("[SS] Trail trackers reconstructed from ", barShift, " M5 bars. ",
            (g_posDir == 1) ? "Highest=" + DoubleToString(g_trailHighest, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS))
                            : "Lowest="  + DoubleToString(g_trailLowest, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
}

//+------------------------------------------------------------------+
//| Reset Position State                                               |
//+------------------------------------------------------------------+
void ResetPositionState()
{
   g_posTicket    = 0;
   g_posDir       = 0;
   g_posOpenPrice = 0;
   g_trailHighest = 0;
   g_trailLowest  = 0;

   // Reset trade lifecycle tracking
   g_tradeEntryTime  = 0;
   g_tradeATR        = 0;
   g_tradeSpread     = 0;
   g_tradeSLInitial  = 0;
   g_tradeLastSL     = 0;
   g_tradeTP         = 0;
   g_tradeLot        = 0;
   g_tradeH1Regime   = 0;
   g_tradeTrailCount = 0;
   g_tradePeakHigh   = 0;
   g_tradePeakLow    = DBL_MAX;

   // Clear persisted ticket
   if(g_gvKey != "")
      GlobalVariableDel(g_gvKey);
}

//+------------------------------------------------------------------+
//| Send Notification                                                  |
//+------------------------------------------------------------------+
void SendNotification_SS(string msg)
{
   if(EnableAlert && !g_isTester)
      Alert(msg);

   if(EnablePush && !g_isTester)
      SendNotification(msg);

   if(EnableEmail && !g_isTester)
      SendMail("SwingSignalEA", msg);

   if(EnableSoundNotification && !g_isTester)
   {
      if(!FileIsExist(SoundFileName, FILE_COMMON) && !FileIsExist(SoundFileName, 0))
         Print("[NOTIFY] Sound file not found: ", SoundFileName);
      else
         PlaySound(SoundFileName);
   }
}

//+------------------------------------------------------------------+
//| Write Signal Log (one row per M5 EMA cross)                        |
//+------------------------------------------------------------------+
void WriteSignalLog(int direction, string outcome, double price, double atr, long spread,
                    double m5Fast, double m5Slow, double m5CrossGap, double m5SlopeFast, double m5SlopeSlow,
                    double h1Fast, double h1Slow,
                    double sl, double tp, double slDistPts, double tpDistPts, double rr,
                    double swingTP, bool fallbackUsed,
                    double lot, int serverHour,
                    bool passRegime, bool passSlope, bool passTime, bool passSpread,
                    bool passPriceCtrl, bool passSLWidth, bool passMargin)
{
   OpenSignalLog();
   if(g_signalLogHandle == INVALID_HANDLE)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string dirStr = (direction == 1) ? "BUY" : "SELL";
   string regimeStr = (g_h1Regime == 1) ? "LONG" : (g_h1Regime == -1) ? "SHORT" : "NEUTRAL";

   string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\t" +
                 _Symbol + "\t" +
                 dirStr + "\t" +
                 outcome + "\t" +
                 DoubleToString(price, digits) + "\t" +
                 DoubleToString(atr, digits) + "\t" +
                 IntegerToString(spread) + "\t" +
                 DoubleToString(m5Fast, digits) + "\t" +
                 DoubleToString(m5Slow, digits) + "\t" +
                 DoubleToString(m5CrossGap, digits) + "\t" +
                 DoubleToString(m5SlopeFast, digits) + "\t" +
                 DoubleToString(m5SlopeSlow, digits) + "\t" +
                 regimeStr + "\t" +
                 DoubleToString(h1Fast, digits) + "\t" +
                 DoubleToString(h1Slow, digits) + "\t" +
                 DoubleToString(sl, digits) + "\t" +
                 DoubleToString(tp, digits) + "\t" +
                 DoubleToString(slDistPts, 1) + "\t" +
                 DoubleToString(tpDistPts, 1) + "\t" +
                 DoubleToString(rr, 2) + "\t" +
                 DoubleToString(swingTP, digits) + "\t" +
                 (fallbackUsed ? "1" : "0") + "\t" +
                 DoubleToString(lot, 2) + "\t" +
                 IntegerToString(serverHour) + "\t" +
                 (passRegime  ? "1" : "0") + "\t" +
                 (passSlope   ? "1" : "0") + "\t" +
                 (passTime    ? "1" : "0") + "\t" +
                 (passSpread  ? "1" : "0") + "\t" +
                 (passPriceCtrl ? "1" : "0") + "\t" +
                 (passSLWidth ? "1" : "0") + "\t" +
                 (passMargin  ? "1" : "0") + "\n";

   FileWriteString(g_signalLogHandle, line);
   FileFlush(g_signalLogHandle);
}

//+------------------------------------------------------------------+
//| Open Signal Log File (daily rotation)                              |
//+------------------------------------------------------------------+
void OpenSignalLog()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   string dateStr = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);

   if(dateStr != g_signalLogDate)
   {
      CloseSignalLog();
      g_signalLogDate = dateStr;
   }

   if(g_signalLogHandle != INVALID_HANDLE)
      return;

   string tagSuffix = (InstanceTag != "") ? "_" + InstanceTag : "";
   string fileName = "SS_SIGNAL_" + dateStr + "_" + _Symbol + tagSuffix + ".tsv";
   g_signalLogHandle = FileOpen(fileName, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);

   if(g_signalLogHandle == INVALID_HANDLE)
   {
      Print("[SS] WARNING: Cannot open signal log: ", fileName);
      return;
   }

   if(FileSize(g_signalLogHandle) == 0)
   {
      string header = "Time\tSymbol\tDir\tOutcome\tPrice\tATR\tSpreadPts\t"
                      "M5Fast\tM5Slow\tM5CrossGap\tM5SlopeFast\tM5SlopeSlow\t"
                      "H1Regime\tH1Fast\tH1Slow\t"
                      "SL\tTP\tSL_DistPts\tTP_DistPts\tRR\tSwingTP\tFallbackUsed\t"
                      "Lot\tServerHour\t"
                      "PassRegime\tPassSlope\tPassTime\tPassSpread\tPassPriceCtrl\tPassSLWidth\tPassMargin\n";
      FileWriteString(g_signalLogHandle, header);
   }
   else
   {
      FileSeek(g_signalLogHandle, 0, SEEK_END);
   }
}

//+------------------------------------------------------------------+
//| Close Signal Log File                                              |
//+------------------------------------------------------------------+
void CloseSignalLog()
{
   if(g_signalLogHandle != INVALID_HANDLE)
   {
      FileClose(g_signalLogHandle);
      g_signalLogHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Write Trade Log (one row per completed trade lifecycle)            |
//+------------------------------------------------------------------+
void WriteTradeLog(datetime entryTime, datetime exitTime, int direction,
                   double entryPrice, double exitPrice, double lot,
                   double slInitial, double slFinal, double tp,
                   double profitPts, double profitMoney, int holdBars, string exitReason,
                   int trailCount, double atrEntry, long spreadEntry, int h1RegimeEntry,
                   double mfePts, double maePts)
{
   OpenTradeLog();
   if(g_tradeLogHandle == INVALID_HANDLE)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string dirStr = (direction == 1) ? "BUY" : "SELL";
   string regimeStr = (h1RegimeEntry == 1) ? "LONG" : (h1RegimeEntry == -1) ? "SHORT" : "NEUTRAL";

   string line = TimeToString(entryTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\t" +
                 TimeToString(exitTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\t" +
                 _Symbol + "\t" +
                 dirStr + "\t" +
                 DoubleToString(entryPrice, digits) + "\t" +
                 DoubleToString(exitPrice, digits) + "\t" +
                 DoubleToString(lot, 2) + "\t" +
                 DoubleToString(slInitial, digits) + "\t" +
                 DoubleToString(slFinal, digits) + "\t" +
                 DoubleToString(tp, digits) + "\t" +
                 DoubleToString(profitPts, 1) + "\t" +
                 DoubleToString(profitMoney, 2) + "\t" +
                 IntegerToString(holdBars) + "\t" +
                 exitReason + "\t" +
                 IntegerToString(trailCount) + "\t" +
                 DoubleToString(atrEntry, digits) + "\t" +
                 IntegerToString(spreadEntry) + "\t" +
                 regimeStr + "\t" +
                 DoubleToString(mfePts, 1) + "\t" +
                 DoubleToString(maePts, 1) + "\n";

   FileWriteString(g_tradeLogHandle, line);
   FileFlush(g_tradeLogHandle);
}

//+------------------------------------------------------------------+
//| Open Trade Log File (daily rotation)                               |
//+------------------------------------------------------------------+
void OpenTradeLog()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   string dateStr = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);

   if(dateStr != g_tradeLogDate)
   {
      CloseTradeLog();
      g_tradeLogDate = dateStr;
   }

   if(g_tradeLogHandle != INVALID_HANDLE)
      return;

   string tagSuffix = (InstanceTag != "") ? "_" + InstanceTag : "";
   string fileName = "SS_TRADE_" + dateStr + "_" + _Symbol + tagSuffix + ".tsv";
   g_tradeLogHandle = FileOpen(fileName, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);

   if(g_tradeLogHandle == INVALID_HANDLE)
   {
      Print("[SS] WARNING: Cannot open trade log: ", fileName);
      return;
   }

   if(FileSize(g_tradeLogHandle) == 0)
   {
      string header = "EntryTime\tExitTime\tSymbol\tDir\tEntryPrice\tExitPrice\tLot\t"
                      "SL_Initial\tSL_Final\tTP\tProfitPts\tProfitMoney\tHoldBarsM5\t"
                      "ExitReason\tTrailCount\tATR_Entry\tSpreadEntry\tH1Regime_Entry\t"
                      "MFE_Pts\tMAE_Pts\n";
      FileWriteString(g_tradeLogHandle, header);
   }
   else
   {
      FileSeek(g_tradeLogHandle, 0, SEEK_END);
   }
}

//+------------------------------------------------------------------+
//| Close Trade Log File                                               |
//+------------------------------------------------------------------+
void CloseTradeLog()
{
   if(g_tradeLogHandle != INVALID_HANDLE)
   {
      FileClose(g_tradeLogHandle);
      g_tradeLogHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Panel: set one label line                                         |
//+------------------------------------------------------------------+
void PanelSetLine(int row, int totalRows, const string text, color clr)
{
   string name = g_panelPrefix + IntegerToString(row);
   int yPos = PANEL_Y + (totalRows - 1 - row) * PANEL_LINE_H;

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR,      ANCHOR_LEFT_LOWER);
      ObjectSetString (0, name, OBJPROP_FONT,        "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,    PANEL_FSIZE);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,      true);
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PANEL_X);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yPos);
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
}

//+------------------------------------------------------------------+
//| Update Chart Status Panel                                         |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string lines[];
   color  colors[];
   ArrayResize(lines, PANEL_MAXLINE);
   ArrayResize(colors, PANEL_MAXLINE);
   int n = 0;

   // Line 0: EA title + time
   lines[n]  = "SwingSignalEA  " + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
   colors[n] = clrWhite;
   n++;

   // Line 1: Trading status
   string regime = (g_h1Regime == 1) ? "LONG" : (g_h1Regime == -1) ? "SHORT" : "NEUTRAL";
   lines[n]  = "H1 Regime: " + regime + "  Trading: " + (EnableTrading ? "ON" : "OFF");
   colors[n] = (g_h1Regime == 1) ? clrLime : (g_h1Regime == -1) ? clrOrangeRed : clrDarkGray;
   n++;

   // Line 2: Market
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double atr = GetM5ATR();
   lines[n]  = "Bid: " + DoubleToString(bid, digits) + "  Spread: " + IntegerToString(spread) +
               "  ATR: " + DoubleToString(atr, digits);
   colors[n] = clrWhite;
   n++;

   // Line 3+: Position info
   if(g_posTicket > 0 && PositionSelectByTicket(g_posTicket))
   {
      string dir = (g_posDir == 1) ? "BUY" : "SELL";
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double profit = PositionGetDouble(POSITION_PROFIT);

      lines[n]  = "Position: " + dir + "  #" + IntegerToString((int)g_posTicket);
      colors[n] = clrLime;
      n++;

      lines[n]  = "Entry: " + DoubleToString(openP, digits) +
                  "  SL: " + DoubleToString(sl, digits) +
                  "  TP: " + DoubleToString(tp, digits);
      colors[n] = clrWhite;
      n++;

      lines[n]  = "P/L: " + DoubleToString(profit, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
      colors[n] = (profit >= 0) ? clrLime : clrOrangeRed;
      n++;
   }
   else
   {
      lines[n]  = "Position: NONE";
      colors[n] = clrDarkGray;
      n++;
   }

   // Render lines
   for(int i = 0; i < n; i++)
      PanelSetLine(i, n, lines[i], colors[i]);

   // Delete excess lines
   for(int i = n; i < PANEL_MAXLINE; i++)
   {
      string name = g_panelPrefix + IntegerToString(i);
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete Panel                                                       |
//+------------------------------------------------------------------+
void DeletePanel()
{
   for(int i = 0; i < PANEL_MAXLINE; i++)
   {
      string name = g_panelPrefix + IntegerToString(i);
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
   }
   ChartRedraw();
}
//+------------------------------------------------------------------+
