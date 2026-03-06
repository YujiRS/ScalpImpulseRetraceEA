//+------------------------------------------------------------------+
//| Visualization.mqh                                                 |
//| Fib描画・押し帯描画・チャート上STATUS表示パネル                          |
//| CRYPTO専用                                                         |
//+------------------------------------------------------------------+
#ifndef __VISUALIZATION_MQH__
#define __VISUALIZATION_MQH__

//+------------------------------------------------------------------+
//| Fib Visualization                                                 |
//+------------------------------------------------------------------+
string BuildFibObjName(const string trade_uuid)
{
   return "EA_FIB_" + trade_uuid;
}

string BuildBandObjName(const string trade_uuid)
{
   return "EA_BAND_" + trade_uuid;
}

void PurgeOldFibObjectsExcept(const string keepFibName, const string keepBandName)
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(name == "") continue;

      bool isFib  = (StringFind(name, "EA_FIB_")  == 0);
      bool isBand = (StringFind(name, "EA_BAND_") == 0);
      if(!isFib && !isBand) continue;

      if(name == keepFibName || name == keepBandName) continue;

      ObjectDelete(0, name);
   }
}

color GetBandColor()
{
   // CRYPTO: Purple系
   return (color)ColorToARGB(clrMediumPurple, 150);
}

void CreateFibVisualization()
{
   if(!EnableFibVisualization) return;
   if(g_tradeUUID == "") return;

   string fibName = BuildFibObjName(g_tradeUUID);
   string bandName = BuildBandObjName(g_tradeUUID);

   g_fibObjName = fibName;
   g_bandObjName = bandName;

   PurgeOldFibObjectsExcept(fibName, bandName);

   if(ObjectFind(0, fibName) < 0)
   {
      datetime t1 = iTime(Symbol(), PERIOD_M1, g_impulseBarIndex);
      datetime t2 = g_freezeBarTime;
      if(t1 <= 0) t1 = iTime(Symbol(), PERIOD_M1, 0);
      if(t1 <= 0) t1 = TimeCurrent();
      if(t2 <= 0) t2 = iTime(Symbol(), PERIOD_M1, 0);
      if(t2 <= 0) t2 = TimeCurrent();
      if(t2 < t1) t2 = t1 + PeriodSeconds(PERIOD_M1);

      if(!ObjectCreate(0, fibName, OBJ_FIBO, 0, t1, g_impulseStart, t2, g_impulseEnd))
      {
         Print("[VIS] Fib create failed: ", GetLastError());
      }
      else
      {
         ObjectSetInteger(0, fibName, OBJPROP_RAY_RIGHT, true);
         ObjectSetInteger(0, fibName, OBJPROP_SELECTABLE, true);
         ObjectSetInteger(0, fibName, OBJPROP_HIDDEN, false);

         ObjectSetInteger(0, fibName, OBJPROP_LEVELS, 6);

         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 0, 0.0);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 1, 0.382);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 2, 0.5);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 3, 0.618);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 4, 0.786);
         ObjectSetDouble(0, fibName, OBJPROP_LEVELVALUE, 5, 1.0);

         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 0, "0");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 1, "38.2");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 2, "50");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 3, "61.8");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 4, "78.6");
         ObjectSetString(0, fibName, OBJPROP_LEVELTEXT, 5, "100");
      }
   }

   // CRYPTO: Band = PrimaryBand (50-61.8 always)
   if(ObjectFind(0, bandName) < 0)
   {
      double bandUpper = g_primaryBandUpper;
      double bandLower = g_primaryBandLower;

      if(bandUpper > 0 && bandLower > 0)
      {
         datetime t1 = g_freezeBarTime;
         if(t1 <= 0) t1 = iTime(Symbol(), PERIOD_M1, 0);
         if(t1 <= 0) t1 = TimeCurrent();

         int futureBars = g_profile.retouchTimeLimitBars + 50;
         if(futureBars < 200) futureBars = 200;
         if(futureBars > 2000) futureBars = 2000;
         datetime t2 = t1 + (datetime)(PeriodSeconds(PERIOD_M1) * futureBars);
         if(t2 <= t1) t2 = t1 + 60 * 60 * 4;

         if(!ObjectCreate(0, bandName, OBJ_RECTANGLE, 0, t1, bandUpper, t2, bandLower))
         {
            Print("[VIS] Band create failed: ", GetLastError());
         }
         else
         {
            ObjectSetInteger(0, bandName, OBJPROP_BACK, true);
            ObjectSetInteger(0, bandName, OBJPROP_FILL, true);
            ObjectSetInteger(0, bandName, OBJPROP_SELECTABLE, true);
            ObjectSetInteger(0, bandName, OBJPROP_HIDDEN, false);
            ObjectSetInteger(0, bandName, OBJPROP_COLOR, GetBandColor());
         }
      }
   }
}

void DeleteFibVisualizationForUUID(const string trade_uuid)
{
   if(trade_uuid == "") return;

   string fibName  = BuildFibObjName(trade_uuid);
   string bandName = BuildBandObjName(trade_uuid);

   if(ObjectFind(0, fibName) >= 0)  ObjectDelete(0, fibName);
   if(ObjectFind(0, bandName) >= 0) ObjectDelete(0, bandName);

   if(g_tradeUUID == trade_uuid)
   {
      g_fibObjName  = "";
      g_bandObjName = "";
   }
}

void DeleteCurrentFibVisualization()
{
   DeleteFibVisualizationForUUID(g_tradeUUID);
}

//+------------------------------------------------------------------+
//| On-Chart Status Panel (Comment-based)                             |
//+------------------------------------------------------------------+
void UpdateChartStatusPanel()
{
   if(!EnableStatusPanel) return;

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double spread = (ask - bid) / _Point;

   string nl = "\n";
   string sep = "────────────────────" + nl;

   string panel = "";
   panel += EA_NAME + " " + EA_VERSION + "  " + Symbol() + nl;
   panel += sep;

   // State
   panel += "State     : " + StateToString(g_currentState) + nl;
   panel += "FlatFilter: " + FlatFilterModeToString(FlatFilterMode) + nl;
   panel += "Trading   : " + (EnableTrading ? "ON" : "OFF") + nl;
   panel += sep;

   // Price info
   panel += "Bid       : " + DoubleToString(bid, digits) + nl;
   panel += "Ask       : " + DoubleToString(ask, digits) + nl;
   panel += "Spread    : " + DoubleToString(spread, 1) + " pts" + nl;
   panel += sep;

   // Impulse info (active states only)
   if(g_currentState >= STATE_IMPULSE_FOUND && g_currentState <= STATE_IN_POSITION)
   {
      panel += "Direction : " + DirectionToString(g_impulseDir) + nl;
      panel += "Start(0)  : " + DoubleToString(g_impulseStart, digits) + nl;
      panel += "End(100)  : " + DoubleToString(g_impulseEnd, digits) + nl;

      if(g_frozen)
         panel += "Frozen    : YES (100=" + DoubleToString(g_frozen100, digits) + ")" + nl;
      else
         panel += "Frozen    : NO" + nl;

      panel += "UUID      : " + g_tradeUUID + nl;
      panel += sep;
   }

   // Band info
   if(g_currentState >= STATE_FIB_ACTIVE && g_currentState <= STATE_IN_POSITION)
   {
      panel += "Fib 50    : " + DoubleToString(g_fib500, digits) + nl;
      panel += "Fib 61.8  : " + DoubleToString(g_fib618, digits) + nl;
      panel += "Band      : " + DoubleToString(g_primaryBandLower, digits) +
               " - " + DoubleToString(g_primaryBandUpper, digits) + nl;
      panel += "Touch     : " + IntegerToString(g_touchCount_Primary) + nl;
      panel += "Bars(Frz) : " + IntegerToString(g_barsAfterFreeze) +
               " / " + IntegerToString(g_profile.retouchTimeLimitBars) + nl;
      panel += sep;
   }

   // Confirm / Entry
   if(g_currentState == STATE_TOUCH_2_WAIT_CONFIRM)
   {
      panel += "Confirm   : WAITING (" + IntegerToString(g_confirmWaitBars) +
               "/" + IntegerToString(g_profile.confirmTimeLimitBars) + ")" + nl;
      panel += sep;
   }

   // Position info
   if(g_currentState == STATE_IN_POSITION && g_ticket > 0)
   {
      panel += "Ticket    : " + IntegerToString(g_ticket) + nl;
      panel += "Entry     : " + DoubleToString(g_entryPrice, digits) + nl;
      panel += "SL        : " + DoubleToString(g_sl, digits) + nl;
      panel += "Bars(Pos) : " + IntegerToString(g_positionBars) +
               " / " + IntegerToString(g_profile.timeExitBars) + nl;

      if(PositionSelectByTicket(g_ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         panel += "P/L       : " + DoubleToString(profit, 2) + nl;
      }
      panel += sep;
   }

   // Cooldown
   if(g_currentState == STATE_COOLDOWN)
   {
      panel += "Cooldown  : " + IntegerToString(g_cooldownBars) +
               " / " + IntegerToString(g_cooldownDuration) + nl;
      panel += sep;
   }

   // Time
   panel += "Server    : " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + nl;

   Comment(panel);
}

void ClearChartStatusPanel()
{
   Comment("");
}

#endif // __VISUALIZATION_MQH__
