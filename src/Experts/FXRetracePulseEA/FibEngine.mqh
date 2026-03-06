//+------------------------------------------------------------------+
//| FibEngine.mqh                                                    |
//| FX専用: Fib算出・押し帯計算・Touch/Leave/ReTouch判定                 |
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

// FX押し帯計算: Primary = Fib50±BW, Optional = Fib38.2±BW
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

   // Primary Band (Fib50)
   g_primaryBandUpper = g_fib500 + bw;
   g_primaryBandLower = g_fib500 - bw;

   // Optional 38.2 Band
   if(g_profile.optionalBand38)
   {
      g_optBand38Upper = g_fib382 + bw;
      g_optBand38Lower = g_fib382 - bw;
   }
   else
   {
      g_optBand38Upper = 0;
      g_optBand38Lower = 0;
   }

   // クランプ
   if(g_primaryBandUpper != 0 || g_primaryBandLower != 0)
      ClampBandToFibRange(g_primaryBandUpper, g_primaryBandLower);
   if(g_optBand38Upper != 0 || g_optBand38Lower != 0)
      ClampBandToFibRange(g_optBand38Upper, g_optBand38Lower);
}

//+------------------------------------------------------------------+
//| Touch / Leave / ReTouch判定                                       |
//+------------------------------------------------------------------+

bool CheckBandEntry(double bandUpper, double bandLower)
{
   double low0  = iLow(Symbol(), PERIOD_M1, 1);
   double high0 = iHigh(Symbol(), PERIOD_M1, 1);

   if(g_impulseDir == DIR_LONG)
      return (low0 <= bandUpper);
   else
      return (high0 >= bandLower);
}

bool CheckLeave(double bandUpper, double bandLower, double leaveDistance,
                int &leaveBarCount, bool &leaveEstablished)
{
   if(leaveEstablished) return true;

   double close1 = iClose(Symbol(), PERIOD_M1, 1);

   bool outsideFar = false;
   if(g_impulseDir == DIR_LONG)
      outsideFar = (close1 > bandUpper + leaveDistance);
   else
      outsideFar = (close1 < bandLower - leaveDistance);

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

// タッチ処理（Primary + Opt38のみ）
int ProcessTouches()
{
   double leaveDist = g_effectiveBandWidthPts * g_profile.leaveDistanceMult;

   // Primary Band
   if(g_primaryBandUpper > 0 && g_primaryBandLower > 0)
   {
      int result = ProcessSingleBandTouch(
         g_primaryBandUpper, g_primaryBandLower, leaveDist,
         g_touchCount_Primary, g_inBand_Primary,
         g_leaveEstablished_Primary, g_leaveBarCount_Primary, 0);
      if(result >= 0) return result;
   }

   // Optional 38.2 Band
   if(g_optBand38Upper > 0 && g_optBand38Lower > 0 && g_profile.optionalBand38)
   {
      int result = ProcessSingleBandTouch(
         g_optBand38Upper, g_optBand38Lower, leaveDist,
         g_touchCount_Opt38, g_inBand_Opt38,
         g_leaveEstablished_Opt38, g_leaveBarCount_Opt38, 2);
      if(result >= 0) return result;
   }

   return -1;
}

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

void GetActiveBand(double &bandUpper, double &bandLower)
{
   switch(g_touch2BandId)
   {
      case 0:
         bandUpper = g_primaryBandUpper;
         bandLower = g_primaryBandLower;
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
