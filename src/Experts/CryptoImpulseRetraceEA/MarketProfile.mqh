//+------------------------------------------------------------------+
//| MarketProfile.mqh                                                |
//| CRYPTO専用パラメータ初期化・BandWidth算出                             |
//| DeepBand判定なし（50-61.8常時ON）                                    |
//+------------------------------------------------------------------+
#ifndef __MARKET_PROFILE_MQH__
#define __MARKET_PROFILE_MQH__

void InitMarketProfile()
{
   g_profile.impulseATRMult         = 2.0;
   g_profile.impulseMinBars          = 1;
   g_profile.smallBodyRatio          = 0.45;
   g_profile.freezeCancelWindowBars  = 1;
   g_profile.deepBandEnabled         = false;   // CRYPTO: no DeepBand
   g_profile.leaveDistanceMult       = 1.2;
   g_profile.leaveMinBars            = 1;
   g_profile.retouchTimeLimitBars    = 25;
   g_profile.resetMinBars            = 6;
   g_profile.confirmTimeLimitBars    = 4;
   g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 8.0;
   g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 12.0;
   g_profile.timeExitBars            = 6;
   g_profile.spreadMult              = SpreadMult_CRYPTO;
   g_profile.wickRatioMin            = 0.0;     // unused for CRYPTO
   g_profile.slATRMult               = SLATRMult_CRYPTO;
   g_profile.minRR_EntryGate         = MinRR_EntryGate_CRYPTO;
   g_profile.minRangeCostMult        = MinRangeCostMult_CRYPTO;
   g_profile.tpExtensionRatio        = TPExtRatio_CRYPTO;
}

// CRYPTO BandWidthPts確定: ATR(M1)×0.08
void CalculateBandWidth()
{
   double atr = GetATR_M1(0);
   g_bandWidthPts = atr * 0.08;
}

#endif // __MARKET_PROFILE_MQH__
