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
   SS_LOG_NORMAL  = 0,  // Print only
   SS_LOG_DEBUG   = 1,  // TSV file log
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

// === G9: Notification ===
input bool              EnableAlert            = true;           // Alert on entry/exit
input bool              EnablePush             = true;           // Push notification
input bool              EnableEmail            = false;          // Email notification
input bool              EnableSoundNotification = false;          // Sound notification
input string            SoundFileName           = "alert.wav";    // Sound file in <MT5>/Sounds/ folder

// === G10: Logging ===
input ENUM_SS_LOG_LEVEL LogLevel               = SS_LOG_DEBUG;  // Log Level

// === G2: M5 EMA (Trigger) ===
input int               M5_EMA_Fast            = 13;             // M5 EMA Fast Period
input int               M5_EMA_Slow            = 21;             // M5 EMA Slow Period
input bool              UseEMA                 = true;           // true: EMA / false: SMA

// === G3: H1 EMA (Direction Filter) ===
input int               H1_EMA_Fast            = 13;             // H1 EMA Fast Period
input int               H1_EMA_Slow            = 21;             // H1 EMA Slow Period

// === G4: H1 Swing (TP Target) ===
input int               H1_SwingStrength       = 5;              // H1 Swing Lookback (bars each side)
input int               H1_SwingMaxAge         = 200;            // H1 Swing Max Age (bars)

// === G5: Stop Loss ===
input double            SL_BufferATR           = 0.5;            // SL Buffer (ATR fraction)
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

// Logging
int    g_logFileHandle = INVALID_HANDLE;
string g_logDate       = "";

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

   CloseLogFile();
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
      else if(EnableTrading)
      {
         // ATR Trailing Stop (Exit 2) — only when trading enabled
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

   // H1 direction filter
   if(crossSignal == 1 && g_h1Regime != 1)
      return;
   if(crossSignal == -1 && g_h1Regime != -1)
      return;

   // M5 slope filter
   if(!CheckSlopeFilter(crossSignal))
      return;

   // Time filter
   if(!CheckTimeFilter())
      return;

   // Spread filter
   if(!CheckSpreadFilter())
      return;

   // Duplicate / reverse position check
   if(g_posTicket > 0)
   {
      if(g_posDir == crossSignal)
         return;  // Same direction already held

      // Opposite direction
      if(ReverseMode == REVERSE_IGNORE)
         return;

      // REVERSE_CLOSE_AND_OPEN: close existing, then enter new
      ClosePosition("REVERSE");
   }

   // Calculate SL
   double atr = GetM5ATR();
   if(atr <= 0)
      return;

   double sl = CalculateSL(crossSignal, atr);
   if(sl <= 0)
      return;

   double entryPrice = (crossSignal == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDistance = MathAbs(entryPrice - sl);

   // Max SL check
   if(slDistance > MaxSL_ATR * atr)
   {
      LogEvent("REJECT", crossSignal, entryPrice, sl, 0, atr, "SL_TOO_WIDE");
      return;
   }

   // Calculate TP (H1 Swing)
   double tp = CalculateTP(crossSignal, entryPrice, slDistance);
   if(tp <= 0)
      return;

   // Calculate lot
   double lot = CalculateLot(slDistance);
   if(lot <= 0)
      return;

   // Margin check
   if(MinMarginLevel > 0)
   {
      if(!CheckMarginLevel(crossSignal, lot))
      {
         LogEvent("REJECT", crossSignal, entryPrice, sl, tp, atr, "MARGIN_LOW");
         return;
      }
   }

   // Execute entry
   ExecuteEntry(crossSignal, lot, sl, tp, atr);
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
      {
         if(LogLevel >= SS_LOG_DEBUG)
            Print("[SS] H1 Regime initialized: ", dir);
      }
      else if(LogLevel >= SS_LOG_DEBUG)
         Print("[SS] H1 Regime changed: ", dir);

      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      LogEvent("REGIME_CHANGE", g_h1Regime, price, 0, 0, 0,
               "H1Fast=" + DoubleToString(h1Fast[0], (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) +
               " H1Slow=" + DoubleToString(h1Slow[0], (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
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
bool CheckSlopeFilter(int direction)
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

   double sl;
   if(direction == 1)
      sl = low1 - SL_BufferATR * atr;
   else
      sl = high1 + SL_BufferATR * atr;

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
   }

   // Normalize lot
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   if(lot < minLot) lot = 0;
   if(lot > maxLot) lot = maxLot;

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
void ExecuteEntry(int direction, double lot, double sl, double tp, double atr)
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
      LogEvent("REJECT", direction, price, sl, tp, atr,
               "SEND_FAIL_" + IntegerToString(result.retcode));
      return;
   }

   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
   {
      Print("[SS] OrderSend rejected: ", result.retcode, " ", result.comment);
      LogEvent("REJECT", direction, price, sl, tp, atr,
               "REJECTED_" + IntegerToString(result.retcode));
      return;
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
   LogEvent("ENTRY", direction, g_posOpenPrice, sl, tp, atr, "");
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
      if(LogLevel >= SS_LOG_DEBUG)
         Print("[SS] Trail SL updated: ", DoubleToString(currentSL, digits),
               " -> ", DoubleToString(newSL, digits));
      LogEvent("TRAIL_UPDATE", g_posDir, SymbolInfoDouble(_Symbol, SYMBOL_BID),
               newSL, currentTP, atr, "prev=" + DoubleToString(currentSL, digits));
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

   double volume = PositionGetDouble(POSITION_VOLUME);
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

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double profitPts = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point > 0)
   {
      if(g_posDir == 1)
         profitPts = (price - openPrice) / point;
      else
         profitPts = (openPrice - price) / point;
   }

   string dirStr = (g_posDir == 1) ? "BUY" : "SELL";
   string msg = StringFormat("[SS_EXIT] %s  %s | %s | %."+IntegerToString(digits)+"f | Profit=%+.0fpoints | Reason=%s",
                             dirStr, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                             _Symbol, price, profitPts, reason);

   Print(msg);
   SendNotification_SS(msg);
   LogEvent("EXIT", g_posDir, price, 0, 0, 0, "Reason=" + reason);

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

   // Check recent deal history
   datetime from = TimeCurrent() - 360;
   datetime to   = TimeCurrent() + 1;
   HistorySelect(from, to);

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
         if(dealReason == DEAL_REASON_TP)
            reason = "TP_HIT";
         else if(dealReason == DEAL_REASON_SL)
            reason = "SL_HIT";
         // Could be ATR_TRAIL if SL was trailed, but MT5 reports as SL
         break;
      }
   }

   // For SL_HIT, check if SL was trailed (different from initial)
   // Heuristic: if SL reason and we had updated trailing, call it ATR_TRAIL
   if(reason == "SL_HIT" && g_posDir == 1 && g_trailHighest > g_posOpenPrice)
      reason = "ATR_TRAIL";
   else if(reason == "SL_HIT" && g_posDir == -1 && g_trailLowest > 0 && g_trailLowest < g_posOpenPrice)
      reason = "ATR_TRAIL";

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double profitPts = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point > 0 && g_posOpenPrice > 0)
   {
      if(g_posDir == 1)
         profitPts = (price - g_posOpenPrice) / point;
      else
         profitPts = (g_posOpenPrice - price) / point;
   }

   string dirStr = (g_posDir == 1) ? "BUY" : "SELL";
   string msg = StringFormat("[SS_EXIT] %s  %s | %s | %."+IntegerToString(digits)+"f | Profit=%+.0fpoints | Reason=%s",
                             dirStr, TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
                             _Symbol, price, profitPts, reason);

   Print(msg);
   SendNotification_SS(msg);
   LogEvent("EXIT", g_posDir, price, 0, 0, 0, "Reason=" + reason);
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

   if(LogLevel >= SS_LOG_DEBUG && barShift > 0)
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
//| Log Event (TSV)                                                    |
//+------------------------------------------------------------------+
void LogEvent(string event, int direction, double price, double sl, double tp,
              double atr, string detail)
{
   if(LogLevel < SS_LOG_DEBUG)
      return;

   // Ensure log file is open
   OpenLogFile();
   if(g_logFileHandle == INVALID_HANDLE)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Get current EMA values
   double h1Fast = 0, h1Slow = 0, m5Fast = 0, m5Slow = 0;
   double buf[];
   ArraySetAsSeries(buf, true);

   if(CopyBuffer(g_h1EmaFastHandle, 0, 1, 1, buf) >= 1) h1Fast = buf[0];
   if(CopyBuffer(g_h1EmaSlowHandle, 0, 1, 1, buf) >= 1) h1Slow = buf[0];
   if(CopyBuffer(g_m5EmaFastHandle, 0, 1, 1, buf) >= 1) m5Fast = buf[0];
   if(CopyBuffer(g_m5EmaSlowHandle, 0, 1, 1, buf) >= 1) m5Slow = buf[0];

   string dirStr = (direction == 1) ? "BUY" : (direction == -1) ? "SELL" : "NONE";

   string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS) + "\t" +
                 _Symbol + "\t" +
                 event + "\t" +
                 dirStr + "\t" +
                 DoubleToString(price, digits) + "\t" +
                 DoubleToString(sl, digits) + "\t" +
                 DoubleToString(tp, digits) + "\t" +
                 DoubleToString(atr, digits) + "\t" +
                 DoubleToString(h1Fast, digits) + "\t" +
                 DoubleToString(h1Slow, digits) + "\t" +
                 DoubleToString(m5Fast, digits) + "\t" +
                 DoubleToString(m5Slow, digits) + "\t" +
                 detail + "\n";

   FileWriteString(g_logFileHandle, line);
   FileFlush(g_logFileHandle);
}

//+------------------------------------------------------------------+
//| Open Log File                                                      |
//+------------------------------------------------------------------+
void OpenLogFile()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   string dateStr = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);

   // Rotate daily
   if(dateStr != g_logDate)
   {
      CloseLogFile();
      g_logDate = dateStr;
   }

   if(g_logFileHandle != INVALID_HANDLE)
      return;

   string tagSuffix = (InstanceTag != "") ? "_" + InstanceTag : "";
   string fileName = "SwingSignalEA_" + dateStr + "_" + _Symbol + tagSuffix + ".tsv";
   g_logFileHandle = FileOpen(fileName, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);

   if(g_logFileHandle == INVALID_HANDLE)
   {
      Print("[SS] WARNING: Cannot open log file: ", fileName);
      return;
   }

   // If new file, write header
   if(FileSize(g_logFileHandle) == 0)
   {
      string header = "Time\tSymbol\tEvent\tDirection\tPrice\tSL\tTP\tATR\tH1_Fast\tH1_Slow\tM5_Fast\tM5_Slow\tDetail\n";
      FileWriteString(g_logFileHandle, header);
   }
   else
   {
      FileSeek(g_logFileHandle, 0, SEEK_END);
   }
}

//+------------------------------------------------------------------+
//| Close Log File                                                     |
//+------------------------------------------------------------------+
void CloseLogFile()
{
   if(g_logFileHandle != INVALID_HANDLE)
   {
      FileClose(g_logFileHandle);
      g_logFileHandle = INVALID_HANDLE;
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
