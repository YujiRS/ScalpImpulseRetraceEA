//+------------------------------------------------------------------+
//| MarketProfile.mqh                                                |
//| GOLD専用パラメータ初期化                                            |
//| v2.1: DeepBand/BandWidth削除（MA Bounce移行）                      |
//+------------------------------------------------------------------+
#ifndef __MARKET_PROFILE_MQH__
#define __MARKET_PROFILE_MQH__

void InitMarketProfile()
{
   g_profile.impulseATRMult         = 1.8;
   g_profile.impulseMinBars          = 1;
   g_profile.smallBodyRatio          = 0.40;
   g_profile.freezeCancelWindowBars  = 3;
   g_profile.deepBandEnabled         = false;
   g_profile.leaveDistanceMult       = 0;
   g_profile.leaveMinBars            = 0;
   g_profile.retouchTimeLimitBars    = 30;
   g_profile.resetMinBars            = 0;
   g_profile.confirmTimeLimitBars    = 0;
   g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 5.0;
   g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 8.0;
   g_profile.timeExitBars            = 8;
   g_profile.spreadMult              = SpreadMult_GOLD;
   g_profile.volExpansionRatio       = 0;
   g_profile.overextensionMult       = 0;
   g_profile.wickRatioMin            = 0.55;
   g_profile.slATRMult               = SLATRMult_GOLD;
   g_profile.slMarginSpreadMult      = SLMarginSpreadMult_GOLD;
   g_profile.minRR_EntryGate         = MinRR_EntryGate_GOLD;
   g_profile.minRangeCostMult        = MinRangeCostMult_GOLD;
   g_profile.tpExtensionRatio        = TPExtRatio_GOLD;
}

#endif // __MARKET_PROFILE_MQH__
