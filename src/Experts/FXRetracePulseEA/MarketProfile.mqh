//+------------------------------------------------------------------+
//| MarketProfile.mqh                                                |
//| FX専用パラメータ初期化・BandWidth算出                                |
//+------------------------------------------------------------------+
#ifndef __MARKET_PROFILE_MQH__
#define __MARKET_PROFILE_MQH__

void InitMarketProfile()
{
   g_profile.impulseATRMult         = 1.6;
   g_profile.impulseMinBars          = 1;
   g_profile.smallBodyRatio          = 0.35;
   g_profile.freezeCancelWindowBars  = 2;
   g_profile.optionalBand38          = OptionalBand38;
   g_profile.leaveDistanceMult       = 1.5;
   g_profile.leaveMinBars            = 1;
   g_profile.retouchTimeLimitBars    = 35;
   g_profile.resetMinBars            = 10;
   g_profile.confirmTimeLimitBars    = 6;
   g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 2.0;
   g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 3.0;
   g_profile.timeExitBars            = 10;
   g_profile.spreadMult              = SpreadMult_FX;
   g_profile.slATRMult               = SLATRMult_FX;
   g_profile.minRR_EntryGate         = MinRR_EntryGate_FX;
   g_profile.minRangeCostMult        = MinRangeCostMult_FX;
   g_profile.tpExtensionRatio        = TPExtRatio_FX;
}

// FX BandWidthPts確定: Spread×2
void CalculateBandWidth()
{
   double spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
   g_bandWidthPts = spread * 2.0;
}

#endif // __MARKET_PROFILE_MQH__
