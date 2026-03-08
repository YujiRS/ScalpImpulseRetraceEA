//+------------------------------------------------------------------+
//| MABounceEngine.mqh                                               |
//| MA Bounce Entry: HTF EMA touch + bounce confirmation             |
//| Replaces FibEngine.mqh for GOLD MA bounce entry                  |
//| Fib levels still calculated for Structure Break check            |
//+------------------------------------------------------------------+
#ifndef __MA_BOUNCE_ENGINE_MQH__
#define __MA_BOUNCE_ENGINE_MQH__

//+------------------------------------------------------------------+
//| Fib算出（Structure Break用に維持）                                  |
//+------------------------------------------------------------------+
void CalculateFibLevels()
{
   double absRange = MathAbs(g_impulseEnd - g_impulseStart);

   if(g_impulseDir == DIR_LONG)
   {
      g_fib382 = g_impulseEnd - absRange * 0.382;
      g_fib500 = g_impulseEnd - absRange * 0.500;
      g_fib618 = g_impulseEnd - absRange * 0.618;
      g_fib786 = g_impulseEnd - absRange * 0.786;
   }
   else
   {
      g_fib382 = g_impulseEnd + absRange * 0.382;
      g_fib500 = g_impulseEnd + absRange * 0.500;
      g_fib618 = g_impulseEnd + absRange * 0.618;
      g_fib786 = g_impulseEnd + absRange * 0.786;
   }
}

//+------------------------------------------------------------------+
//| MA Bounce Handle管理                                              |
//+------------------------------------------------------------------+
bool InitMABounceHandles()
{
   string sym = Symbol();

   g_maBounceMAHandle = iMA(sym, MABounce_Timeframe, MABounce_Period,
                             0, MODE_EMA, PRICE_CLOSE);
   if(g_maBounceMAHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA bounce EMA handle. TF=",
            EnumToString(MABounce_Timeframe), " Period=", MABounce_Period);
      return false;
   }

   g_maBounceATRHandle = iATR(sym, MABounce_Timeframe, 14);
   if(g_maBounceATRHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA bounce ATR handle. TF=",
            EnumToString(MABounce_Timeframe));
      IndicatorRelease(g_maBounceMAHandle);
      g_maBounceMAHandle = INVALID_HANDLE;
      return false;
   }

   return true;
}

void ReleaseMABounceHandles()
{
   if(g_maBounceMAHandle != INVALID_HANDLE)
   { IndicatorRelease(g_maBounceMAHandle); g_maBounceMAHandle = INVALID_HANDLE; }

   if(g_maBounceATRHandle != INVALID_HANDLE)
   { IndicatorRelease(g_maBounceATRHandle); g_maBounceATRHandle = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
//| Handle からバッファ値を取得                                         |
//+------------------------------------------------------------------+
double GetHandleValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return EMPTY_VALUE;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
      return EMPTY_VALUE;
   return buf[0];
}

//+------------------------------------------------------------------+
//| MA Bounce セットアップ（IMPULSE_CONFIRMED時に呼ぶ）                  |
//| MA値とバンド幅を取得して保持                                         |
//+------------------------------------------------------------------+
bool SetupMABounce()
{
   // MA値を取得（最新確定HTF足）
   double maVal = GetHandleValue(g_maBounceMAHandle, 1);
   double atrVal = GetHandleValue(g_maBounceATRHandle, 1);

   if(maVal == EMPTY_VALUE || atrVal == EMPTY_VALUE || atrVal <= 0)
   {
      Print("[MA_BOUNCE] Failed to get MA/ATR values at setup");
      return false;
   }

   g_maBounceMAValue = maVal;
   g_maBounceBandWidth = atrVal * MABounce_BandMult;
   g_maBounceLastHTFBarTime = 0; // リセット

   // BandWidthを統計用に保存
   g_bandWidthPts = g_maBounceBandWidth;
   g_effectiveBandWidthPts = g_maBounceBandWidth;

   return true;
}

//+------------------------------------------------------------------+
//| MA方向チェック: MAがインパルス方向に傾いているか                       |
//+------------------------------------------------------------------+
bool CheckMADirection(int shift)
{
   double maCurrent = GetHandleValue(g_maBounceMAHandle, shift);
   double maPrev    = GetHandleValue(g_maBounceMAHandle, shift + 2);

   if(maCurrent == EMPTY_VALUE || maPrev == EMPTY_VALUE)
      return false;

   if(g_impulseDir == DIR_LONG)
      return (maCurrent > maPrev);
   else
      return (maCurrent < maPrev);
}

//+------------------------------------------------------------------+
//| MA Bounce チェック（MA_PULLBACK_WAIT時に毎M1バーで呼ぶ）             |
//| 最新確定HTF足をチェック。バウンス成立でtrue。                          |
//| confirm_type にバウンス種別を返す                                    |
//+------------------------------------------------------------------+
bool CheckMABounce(ENUM_CONFIRM_TYPE &confirm_type)
{
   confirm_type = CONFIRM_NONE;

   ENUM_TIMEFRAMES htf = MABounce_Timeframe;

   // 最新確定HTF足の時刻を取得
   datetime htfBarTime = iTime(Symbol(), htf, 1);
   if(htfBarTime <= 0) return false;

   // 同じHTF足を二重チェックしない
   if(htfBarTime == g_maBounceLastHTFBarTime) return false;
   g_maBounceLastHTFBarTime = htfBarTime;

   // MA値とATR値を取得（確定HTF足）
   double maVal  = GetHandleValue(g_maBounceMAHandle, 1);
   double atrVal = GetHandleValue(g_maBounceATRHandle, 1);

   if(maVal == EMPTY_VALUE || atrVal == EMPTY_VALUE || atrVal <= 0)
      return false;

   // MA値を更新（Visualization用）
   g_maBounceMAValue = maVal;
   g_maBounceBandWidth = atrVal * MABounce_BandMult;

   // MA方向チェック
   if(!CheckMADirection(1))
      return false;

   double bandWidth = g_maBounceBandWidth;

   // HTF足のOHLC取得
   double htfOpen  = iOpen(Symbol(), htf, 1);
   double htfHigh  = iHigh(Symbol(), htf, 1);
   double htfLow   = iLow(Symbol(), htf, 1);
   double htfClose = iClose(Symbol(), htf, 1);

   if(htfHigh <= htfLow) return false;

   // タッチ判定: 価格がMAバンドに到達したか
   bool touched = false;
   if(g_impulseDir == DIR_LONG)
   {
      // LONG: 価格がMA+bandWidth以下に下がった（プルバック）
      touched = (htfLow <= maVal + bandWidth);
   }
   else
   {
      // SHORT: 価格がMA-bandWidth以上に上がった（プルバック）
      touched = (htfHigh >= maVal - bandWidth);
   }

   if(!touched) return false;

   // バウンス確認パターン（優先順位: close_bounce → wick_reject）

   // 1) Close Bounce: MAの正しい側でクローズ + 方向一致キャンドル
   if(g_impulseDir == DIR_LONG)
   {
      if(htfClose > maVal && htfClose > htfOpen)
      {
         confirm_type = CONFIRM_CLOSE_BOUNCE;
         return true;
      }
   }
   else
   {
      if(htfClose < maVal && htfClose < htfOpen)
      {
         confirm_type = CONFIRM_CLOSE_BOUNCE;
         return true;
      }
   }

   // 2) Wick Rejection: ヒゲでMAから拒否された
   double range = htfHigh - htfLow;
   double wickRatio = 0.55; // MA bounce用固定値

   if(g_impulseDir == DIR_LONG)
   {
      double lowerWick = MathMin(htfOpen, htfClose) - htfLow;
      if((lowerWick / range) >= wickRatio)
      {
         confirm_type = CONFIRM_WICK_REJECTION;
         return true;
      }
   }
   else
   {
      double upperWick = htfHigh - MathMax(htfOpen, htfClose);
      if((upperWick / range) >= wickRatio)
      {
         confirm_type = CONFIRM_WICK_REJECTION;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| MA Bounce Visualization                                          |
//+------------------------------------------------------------------+
string BuildMALineObjName(const string trade_uuid)
{
   return "EA_MA_" + trade_uuid;
}

string BuildMABandObjName(const string trade_uuid)
{
   return "EA_MABAND_" + trade_uuid;
}

void CreateMABounceVisualization()
{
   if(!EnableFibVisualization) return;
   if(g_tradeUUID == "") return;

   double maVal = g_maBounceMAValue;
   double bandWidth = g_maBounceBandWidth;

   if(maVal <= 0 || bandWidth <= 0) return;

   string bandName = BuildMABandObjName(g_tradeUUID);
   g_bandObjName = bandName;

   // 旧オブジェクトをクリーン
   PurgeOldMAObjectsExcept(bandName);

   if(ObjectFind(0, bandName) < 0)
   {
      datetime t1 = g_freezeBarTime;
      if(t1 <= 0) t1 = iTime(Symbol(), PERIOD_M1, 0);
      if(t1 <= 0) t1 = TimeCurrent();

      int futureBars = g_profile.retouchTimeLimitBars + 50;
      if(futureBars < 200) futureBars = 200;
      if(futureBars > 2000) futureBars = 2000;
      datetime t2 = t1 + (datetime)(PeriodSeconds(PERIOD_M1) * futureBars);
      if(t2 <= t1) t2 = t1 + 60 * 60 * 4;

      double bandUpper, bandLower;
      if(g_impulseDir == DIR_LONG)
      {
         bandUpper = maVal + bandWidth;
         bandLower = maVal - bandWidth;
      }
      else
      {
         bandUpper = maVal + bandWidth;
         bandLower = maVal - bandWidth;
      }

      if(!ObjectCreate(0, bandName, OBJ_RECTANGLE, 0, t1, bandUpper, t2, bandLower))
      {
         Print("[VIS] MA Band create failed: ", GetLastError());
      }
      else
      {
         ObjectSetInteger(0, bandName, OBJPROP_BACK, true);
         ObjectSetInteger(0, bandName, OBJPROP_FILL, true);
         ObjectSetInteger(0, bandName, OBJPROP_SELECTABLE, true);
         ObjectSetInteger(0, bandName, OBJPROP_HIDDEN, false);
         ObjectSetInteger(0, bandName, OBJPROP_COLOR, (color)ColorToARGB(clrGold, 150));
      }
   }
}

void PurgeOldMAObjectsExcept(const string keepName)
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(name == "") continue;

      bool isMA   = (StringFind(name, "EA_MA_")     == 0);
      bool isBand = (StringFind(name, "EA_MABAND_") == 0);
      bool isFib  = (StringFind(name, "EA_FIB_")    == 0);
      bool isOldBand = (StringFind(name, "EA_BAND_") == 0);
      if(!isMA && !isBand && !isFib && !isOldBand) continue;

      if(name == keepName) continue;

      ObjectDelete(0, name);
   }
}

void DeleteMABounceVisualization()
{
   if(g_tradeUUID == "") return;

   string bandName = BuildMABandObjName(g_tradeUUID);

   if(ObjectFind(0, bandName) >= 0) ObjectDelete(0, bandName);

   g_bandObjName = "";
}

#endif // __MA_BOUNCE_ENGINE_MQH__
