//+------------------------------------------------------------------+
//| Visualization.mqh                                                 |
//| Fib描画・押し帯描画（第16章）                                        |
//+------------------------------------------------------------------+
#ifndef __VISUALIZATION_MQH__
#define __VISUALIZATION_MQH__

//+------------------------------------------------------------------+
//| Fib Visualization（第16章）                                       |
//+------------------------------------------------------------------+
string BuildFibObjName(const string trade_uuid)
{
   return "EA_FIB_" + trade_uuid;
}

string BuildBandObjName(const string trade_uuid)
{
   return "EA_BAND_" + trade_uuid;
}


// 旧UUIDのFib/Bandオブジェクトを掃除して「直近作成分だけ」オブジェクトリストに残す
void PurgeOldFibObjectsExcept(const string keepFibName, const string keepBandName)
{
   // 逆順で削除（インデックスずれ防止）
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
   // GOLD専用: Gold系（透明度60%推奨）
   return (color)ColorToARGB(clrGold, 150);
}

void CreateFibVisualization()
{
   if(!EnableFibVisualization) return;
   if(g_tradeUUID == "") return;

   string fibName = BuildFibObjName(g_tradeUUID);
   string bandName = BuildBandObjName(g_tradeUUID);

   g_fibObjName = fibName;
   g_bandObjName = bandName;

   // --- 追加：新規作成前に、現在のUUID以外のゴミを掃除する ---
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

   if(ObjectFind(0, bandName) < 0)
   {
      double bandUpper = 0.0;
      double bandLower = 0.0;

      if(g_goldDeepBandON && g_deepBandUpper > 0 && g_deepBandLower > 0)
      {
         bandUpper = g_deepBandUpper;
         bandLower = g_deepBandLower;
      }
      else if(g_primaryBandUpper > 0 && g_primaryBandLower > 0)
      {
         bandUpper = g_primaryBandUpper;
         bandLower = g_primaryBandLower;
      }

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

#endif // __VISUALIZATION_MQH__
