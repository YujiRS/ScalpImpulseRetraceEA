//+------------------------------------------------------------------+
//| FibEngine.mqh                                                    |
//| Fib算出・押し帯計算・Touch/Leave/ReTouch判定（第3章・第5章）          |
//+------------------------------------------------------------------+
#ifndef __FIB_ENGINE_MQH__
#define __FIB_ENGINE_MQH__

void CalculateFibLevels()
{
   // Impulse起点(0) / 終点(100)からFib算出
   double range = g_impulseEnd - g_impulseStart;

   if(g_impulseDir == DIR_LONG)
   {
      // Long: 0=Low, 100=High, 押しは上から下
      g_fib382 = g_impulseEnd - range * 0.382;
      g_fib500 = g_impulseEnd - range * 0.500;
      g_fib618 = g_impulseEnd - range * 0.618;
      g_fib786 = g_impulseEnd - range * 0.786;
   }
   else
   {
      // Short: 0=High, 100=Low, 戻しは下から上
      g_fib382 = g_impulseEnd + range * 0.382; // range is negative for short
      g_fib500 = g_impulseEnd + range * 0.500;
      g_fib618 = g_impulseEnd + range * 0.618;
      g_fib786 = g_impulseEnd + range * 0.786;
   }

   // 正規化 (Shortの場合 range = impulseEnd - impulseStart < 0)
   // 再計算: |range|使用
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
      // Short: impulseStart=High(0), impulseEnd=Low(100)
      // 戻し（押し）はLow(100)からHigh(0)方向
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

   // 念のため上下逆転を補正
   if(upper < lower)
   {
      double tmp = upper;
      upper = lower;
      lower = tmp;
   }
}

// 押し帯の上下限を計算（第5.2章）
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
   // GOLD PrimaryBand + DeepBand
   g_primaryBandUpper = g_fib500 + bw;
   g_primaryBandLower = g_fib500 - bw;

   if(g_goldDeepBandON)
   {
      if(g_impulseDir == DIR_LONG)
      {
         g_deepBandUpper = g_fib500 + bw;
         g_deepBandLower = g_fib618 - bw;
      }
      else
      {
         g_deepBandLower = g_fib500 - bw;
         g_deepBandUpper = g_fib618 + bw;
      }
   }
   else
   {
      g_deepBandUpper = 0;
      g_deepBandLower = 0;
   }
   g_optBand38Upper = 0;
   g_optBand38Lower = 0;

   // Fib(0-100) 範囲外にBandが飛び出さないようクランプ
   if(g_primaryBandUpper != 0 || g_primaryBandLower != 0)
      ClampBandToFibRange(g_primaryBandUpper, g_primaryBandLower);
   if(g_optBand38Upper != 0 || g_optBand38Lower != 0)
      ClampBandToFibRange(g_optBand38Upper, g_optBand38Lower);
   if(g_deepBandUpper != 0 || g_deepBandLower != 0)
      ClampBandToFibRange(g_deepBandUpper, g_deepBandLower);
}

//+------------------------------------------------------------------+
//| Touch / Leave / ReTouch判定（第5.3章）                             |
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

// 離脱判定（第5.3.3章）
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

// タッチ処理（全帯を処理）
// 戻り値: Touch2が成立した帯ID (0=Primary, 1=Deep, 2=Opt38, -1=なし)
int ProcessTouches()
{
   double leaveDistPrimary = g_effectiveBandWidthPts * g_profile.leaveDistanceMult;
   double leaveDistDeep    = g_effectiveBandWidthPts * g_profile.leaveDistanceMult;

   // --- Primary Band ---
   if(g_primaryBandUpper > 0 && g_primaryBandLower > 0)
   {
      int result = ProcessSingleBandTouch(
         g_primaryBandUpper, g_primaryBandLower, leaveDistPrimary,
         g_touchCount_Primary, g_inBand_Primary,
         g_leaveEstablished_Primary, g_leaveBarCount_Primary, 0);
      if(result >= 0) return result;
   }

   // --- Deep Band (GOLD) ---
   if(g_deepBandUpper > 0 && g_deepBandLower > 0 && g_goldDeepBandON)
   {
      int result = ProcessSingleBandTouch(
         g_deepBandUpper, g_deepBandLower, leaveDistDeep,
         g_touchCount_Deep, g_inBand_Deep,
         g_leaveEstablished_Deep, g_leaveBarCount_Deep, 1);
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
      // 新規侵入
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

// アクティブ帯の取得
void GetActiveBand(double &bandUpper, double &bandLower)
{
   switch(g_touch2BandId)
   {
      case 0:
         bandUpper = g_primaryBandUpper;
         bandLower = g_primaryBandLower;
         break;
      case 1:
         bandUpper = g_deepBandUpper;
         bandLower = g_deepBandLower;
         break;
      case 2:
         bandUpper = g_optBand38Upper;
         bandLower = g_optBand38Lower;
         break;
      default:
         bandUpper = g_primaryBandUpper;
         bandLower = g_primaryBandLower;
         break;
   }
}

// Touchログ/統計カウント（Touch1）
void RecordTouch1(const int bandId)
{
   g_stats.Touch1Count++;
   WriteLog(LOG_TOUCH, "", "", "Touch1;BandId=" + IntegerToString(bandId));
}

// Touchログ/統計カウント（Leave）
void RecordLeave(const int bandId)
{
   g_stats.LeaveCount++;
   WriteLog(LOG_TOUCH, "", "", "Leave;BandId=" + IntegerToString(bandId));
}

// Touchログ/統計カウント（Touch2）
void RecordTouch2(const int bandId)
{
   g_stats.Touch2Count++;
   g_stats.Touch2Reached = true;
   WriteLog(LOG_TOUCH, "", "", "Touch2;BandId=" + IntegerToString(bandId));
}

#endif // __FIB_ENGINE_MQH__
