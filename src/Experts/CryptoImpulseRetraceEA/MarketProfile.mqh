//+------------------------------------------------------------------+
//| MarketProfile.mqh                                                |
//| CRYPTO専用パラメータ初期化                                          |
//| v1.1: BandWidth削除（MA Bounce移行）                               |
//+------------------------------------------------------------------+
#ifndef __MARKET_PROFILE_MQH__
#define __MARKET_PROFILE_MQH__

void InitMarketProfile()
{
   g_profile.impulseATRMult         = 2.0;
   g_profile.impulseMinBars          = 1;
   g_profile.smallBodyRatio          = 0.45;
   g_profile.freezeCancelWindowBars  = 1;
   g_profile.deepBandEnabled         = false;
   g_profile.leaveDistanceMult       = 0;
   g_profile.leaveMinBars            = 0;
   g_profile.retouchTimeLimitBars    = 25;
   g_profile.resetMinBars            = 0;
   g_profile.confirmTimeLimitBars    = 0;
   g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 8.0;
   g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 12.0;
   g_profile.timeExitBars            = 6;
   g_profile.spreadMult              = SpreadMult_CRYPTO;
   g_profile.wickRatioMin            = 0.55;
   g_profile.slATRMult               = SLATRMult_CRYPTO;
   g_profile.slMarginSpreadMult      = SLMarginSpreadMult_CRYPTO;
   g_profile.minRR_EntryGate         = MinRR_EntryGate_CRYPTO;
   g_profile.minRangeCostMult        = MinRangeCostMult_CRYPTO;
   g_profile.tpExtensionRatio        = TPExtRatio_CRYPTO;
}

#endif // __MARKET_PROFILE_MQH__
