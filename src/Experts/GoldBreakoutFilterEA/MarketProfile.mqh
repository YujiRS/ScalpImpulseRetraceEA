//+------------------------------------------------------------------+
//| MarketProfile.mqh                                                |
//| GOLD専用パラメータ初期化・DeepBand判定・BandWidth算出                  |
//+------------------------------------------------------------------+
#ifndef __MARKET_PROFILE_MQH__
#define __MARKET_PROFILE_MQH__

void InitMarketProfile()
{
   g_profile.impulseATRMult         = 1.8;
   g_profile.impulseMinBars          = 1;
   g_profile.smallBodyRatio          = 0.40;
   g_profile.freezeCancelWindowBars  = 3;
   g_profile.deepBandEnabled         = false;   // 動的判定（DeepBand）
   g_profile.leaveDistanceMult       = 1.5;
   g_profile.leaveMinBars            = 1;
   g_profile.retouchTimeLimitBars    = 30;
   g_profile.resetMinBars            = 8;
   g_profile.confirmTimeLimitBars    = 5;
   g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 5.0;
   g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 8.0;
   g_profile.timeExitBars            = 8;
   g_profile.spreadMult              = SpreadMult_GOLD;
   g_profile.volExpansionRatio       = 1.5;
   g_profile.overextensionMult       = 2.5;
   g_profile.wickRatioMin            = 0.55;
   g_profile.slATRMult               = SLATRMult_GOLD;
   g_profile.minRR_EntryGate         = MinRR_EntryGate_GOLD;
   g_profile.minRangeCostMult        = MinRangeCostMult_GOLD;
   g_profile.tpExtensionRatio        = TPExtRatio_GOLD;
}

//+------------------------------------------------------------------+
//| GOLD DeepBand判定                                                 |
//+------------------------------------------------------------------+
bool EvaluateGoldDeepBand()
{
   // 【必須ゲート】（いずれか1つ）
   bool G1 = false;
   bool G2 = false;

   // G1: ATR(M1) / ATR(M1,長期) >= VolExpansionRatio
   double atrShort = GetATR_M1(0);
   double atrLong  = GetATR_M1_Long(0, 50);
   if(atrLong > 0)
      G1 = (atrShort / atrLong >= g_profile.volExpansionRatio);

   // G2: Impulseが"過伸長": ImpulseRangePts >= ATR(M1) * OverextensionMult
   double impulseRange = MathAbs(g_impulseEnd - g_impulseStart);
   if(atrShort > 0)
      G2 = (impulseRange >= atrShort * g_profile.overextensionMult);

   bool gate = (G1 || G2);

   // 【追加条件】（いずれか1つ）
   bool C1 = false;
   bool C2 = false;
   bool C3 = false;

   // C1: セッションが荒い時間帯（NY前半など）
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   C1 = (hour >= 13 && hour <= 17);

   // C2: 直近でスイープ痕跡
   C2 = DetectSweep(5);

   // C3: スプレッドが通常域
   double spread = GetCurrentSpreadPts();
   C3 = (spread <= g_maxSpreadPts);

   bool additional = (C1 || C2 || C3);

   return (gate && additional);
}

bool DetectSweep(int lookback)
{
   for(int i = 1; i < lookback; i++)
   {
      double h_i = iHigh(Symbol(), PERIOD_M1, i);
      double h_prev = iHigh(Symbol(), PERIOD_M1, i + 1);
      double c_i = iClose(Symbol(), PERIOD_M1, i);

      if(h_i > h_prev && c_i <= h_prev)
         return true;

      double l_i = iLow(Symbol(), PERIOD_M1, i);
      double l_prev = iLow(Symbol(), PERIOD_M1, i + 1);

      if(l_i < l_prev && c_i >= l_prev)
         return true;
   }
   return false;
}

// GOLD BandWidthPts確定: ATR(M1)×0.05
void CalculateBandWidth()
{
   double atr = GetATR_M1(0);
   g_bandWidthPts = atr * 0.05;
}

#endif // __MARKET_PROFILE_MQH__
