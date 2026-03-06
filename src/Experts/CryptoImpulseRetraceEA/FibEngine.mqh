//+------------------------------------------------------------------+
//| FibEngine.mqh                                                    |
//| Fib算出・押し帯計算・Touch/Leave/ReTouch判定                         |
//| CRYPTO専用: 50-61.8常時ON（単一帯）、DeepBandなし                      |
//+------------------------------------------------------------------+
#ifndef __FIB_ENGINE_MQH__
#define __FIB_ENGINE_MQH__

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

// BandがFib(0-100)の範囲を超えないようにクランプ
void ClampBandToFibRange(double &upper, double &lower)
{
   double minP = MathMin(g_impulseStart, g_impulseEnd);
   double maxP = MathMax(g_impulseStart, g_impulseEnd);

   if(upper > maxP) upper = maxP;
   if(upper < minP) upper = minP;
   if(lower > maxP) lower = maxP;
   if(lower < minP) lower = minP;

   if(upper < lower)
   {
      double tmp = upper;
      upper = lower;
      lower = tmp;
   }
}

// CRYPTO押し帯: 50-61.8常時ON（単一帯として扱う）
void CalculateBands()
{
   double bw = g_bandWidthPts;

   double point  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double rangeP = MathAbs(g_impulseEnd - g_impulseStart);
   double maxBw  = (rangeP * 0.5) - (point * 0.5);

   if(maxBw < 0.0)
      maxBw = 0.0;

   if(bw > maxBw)
      bw = maxBw;

   g_effectiveBandWidthPts = bw;

   // CRYPTO PrimaryBand = Fib50-Fib618 (always on as single band)
   if(g_impulseDir == DIR_LONG)
   {
      g_primaryBandUpper = g_fib500 + bw;
      g_primaryBandLower = g_fib618 - bw;
   }
   else
   {
      g_primaryBandLower = g_fib500 - bw;
      g_primaryBandUpper = g_fib618 + bw;
   }

   // Fib(0-100) 範囲外にBandが飛び出さないようクランプ
   if(g_primaryBandUpper != 0 || g_primaryBandLower != 0)
      ClampBandToFibRange(g_primaryBandUpper, g_primaryBandLower);
}

//+------------------------------------------------------------------+
//| Touch / Leave / ReTouch判定                                       |
//+------------------------------------------------------------------+

// 帯への侵入判定
bool CheckBandEntry(double bandUpper, double bandLower)
{
   double low0  = iLow(Symbol(), PERIOD_M1, 1);  // 確定足
   double high0 = iHigh(Symbol(), PERIOD_M1, 1);

   if(g_impulseDir == DIR_LONG)
   {
      return (low0 <= bandUpper);
   }
   else
   {
      return (high0 >= bandLower);
   }
}

// 離脱判定
bool CheckLeave(double bandUpper, double bandLower, double leaveDistance,
                int &leaveBarCount, bool &leaveEstablished)
{
   if(leaveEstablished) return true;

   double close1 = iClose(Symbol(), PERIOD_M1, 1);

   bool outsideFar = false;
   if(g_impulseDir == DIR_LONG)
   {
      outsideFar = (close1 > bandUpper + leaveDistance);
   }
   else
   {
      outsideFar = (close1 < bandLower - leaveDistance);
   }

   if(outsideFar)
   {
      leaveBarCount++;
      if(leaveBarCount >= g_profile.leaveMinBars)
      {
         leaveEstablished = true;
         return true;
      }
   }
   else
   {
      leaveBarCount = 0;
   }

   return false;
}

// タッチ処理（CRYPTO: PrimaryBandのみ）
// 戻り値: Touch2が成立した帯ID (0=Primary, -1=なし)
int ProcessTouches()
{
   double leaveDist = g_effectiveBandWidthPts * g_profile.leaveDistanceMult;

   if(g_primaryBandUpper > 0 && g_primaryBandLower > 0)
   {
      int result = ProcessSingleBandTouch(
         g_primaryBandUpper, g_primaryBandLower, leaveDist,
         g_touchCount_Primary, g_inBand_Primary,
         g_leaveEstablished_Primary, g_leaveBarCount_Primary, 0);
      if(result >= 0) return result;
   }

   return -1;
}

// 個別帯のタッチ処理
int ProcessSingleBandTouch(double bandUpper, double bandLower, double leaveDist,
                           int &touchCount, bool &inBand,
                           bool &leaveEstablished, int &leaveBarCount,
                           int bandId)
{
   bool isInBand = CheckBandEntry(bandUpper, bandLower);

   if(isInBand && !inBand)
   {
      inBand = true;

      if(touchCount == 0)
      {
         touchCount = 1;
         RecordTouch1(bandId);
         return -1;
      }
      else if(touchCount == 1 && leaveEstablished)
      {
         touchCount = 2;
         RecordTouch2(bandId);
         return bandId;
      }
   }
   else if(!isInBand && inBand)
   {
      inBand = false;
   }

   // 離脱判定（帯外にいる間）
   if(!inBand && touchCount >= 1 && !leaveEstablished)
   {
      bool prevLeaveEstablished = leaveEstablished;
      CheckLeave(bandUpper, bandLower, leaveDist, leaveBarCount, leaveEstablished);
      if(!prevLeaveEstablished && leaveEstablished)
      {
         RecordLeave(bandId);
      }
   }

   return -1;
}

// アクティブ帯の取得（CRYPTO: 常にPrimary）
void GetActiveBand(double &bandUpper, double &bandLower)
{
   bandUpper = g_primaryBandUpper;
   bandLower = g_primaryBandLower;
}

// Touch/Leaveログ記録
void RecordTouch1(const int bandId)
{
   g_stats.Touch1Count++;
   WriteLog(LOG_TOUCH, "", "", "Touch1;BandId=" + IntegerToString(bandId));
}

void RecordLeave(const int bandId)
{
   g_stats.LeaveCount++;
   WriteLog(LOG_TOUCH, "", "", "Leave;BandId=" + IntegerToString(bandId));
}

void RecordTouch2(const int bandId)
{
   g_stats.Touch2Count++;
   g_stats.Touch2Reached = true;
   WriteLog(LOG_TOUCH, "", "", "Touch2;BandId=" + IntegerToString(bandId));
}

#endif // __FIB_ENGINE_MQH__
