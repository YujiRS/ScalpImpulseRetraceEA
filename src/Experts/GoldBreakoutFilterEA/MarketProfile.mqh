//+------------------------------------------------------------------+
//| MarketProfile.mqh                                                |
//| 市場別パラメータ初期化・GOLD DeepBand判定・BandWidth算出             |
//+------------------------------------------------------------------+
#ifndef __MARKET_PROFILE_MQH__
#define __MARKET_PROFILE_MQH__

ENUM_MARKET_MODE ResolveMarketMode()
{
   if(MarketMode != MARKET_MODE_AUTO)
      return MarketMode;

   string sym = Symbol();
   StringToUpper(sym);

   // GOLD判定
   if(StringFind(sym, "XAUUSD") >= 0 || StringFind(sym, "GOLD") >= 0)
      return MARKET_MODE_GOLD;

   // CRYPTO判定
   if(StringFind(sym, "BTCUSD") >= 0 || StringFind(sym, "ETHUSD") >= 0 ||
      StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH") >= 0 ||
      StringFind(sym, "CRYPTO") >= 0)
      return MARKET_MODE_CRYPTO;

   // 判定不能時はFX扱い（安全側）
   return MARKET_MODE_FX;
}

void InitMarketProfile()
{
   g_resolvedMarketMode = ResolveMarketMode();
   g_profile.marketMode = g_resolvedMarketMode;

   switch(g_resolvedMarketMode)
   {
      case MARKET_MODE_FX:
         g_profile.impulseATRMult         = 1.6;
         g_profile.impulseMinBars          = 1;
         g_profile.smallBodyRatio          = 0.35;
         g_profile.freezeCancelWindowBars  = 2;
         g_profile.deepBandEnabled         = false;
         g_profile.cryptoDeepBandAlwaysOn  = false;
         g_profile.optionalBand38          = OptionalBand38;
         g_profile.leaveDistanceMult       = 1.5;
         g_profile.leaveMinBars            = 1;       // BT の改善提案で 2->1 2026/02/22
         g_profile.retouchTimeLimitBars    = 35;
         g_profile.resetMinBars            = 10;
         g_profile.confirmTimeLimitBars    = 6;
         g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 2.0;
         g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 3.0;
         g_profile.timeExitBars            = 10;
         g_profile.spreadMult              = SpreadMult_FX;
         g_profile.volExpansionRatio       = 0.0;  // N/A
         g_profile.overextensionMult       = 0.0;  // N/A
         g_profile.wickRatioMin            = 0.0;  // FXはWickRejection不採用
         g_profile.lookbackMicroBars       = 0;    // FXはフラクタル型
         g_profile.slATRMult               = SLATRMult_FX;
         g_profile.minRR_EntryGate         = MinRR_EntryGate_FX;
         g_profile.minRangeCostMult        = MinRangeCostMult_FX;
         g_profile.tpExtensionRatio        = TPExtRatio_FX;
         break;

      case MARKET_MODE_GOLD:
         g_profile.impulseATRMult         = 1.8;
         g_profile.impulseMinBars          = 1;
         g_profile.smallBodyRatio          = 0.40;
         g_profile.freezeCancelWindowBars  = 3;
         g_profile.deepBandEnabled         = false;   // 動的判定（第6章）
         g_profile.cryptoDeepBandAlwaysOn  = false;
         g_profile.optionalBand38          = false;   // GOLDは38.2帯なし
         g_profile.leaveDistanceMult       = 1.5;     // BT の改善提案で 2.0 -> 1.5 2026/02/22
         g_profile.leaveMinBars            = 1;       // BT の改善提案で 2->1 2026/02/22
         g_profile.retouchTimeLimitBars    = 30;
         g_profile.resetMinBars            = 8;
         g_profile.confirmTimeLimitBars    = 5;
         g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 5.0;
         g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 8.0;
         g_profile.timeExitBars            = 8;
         g_profile.spreadMult              = SpreadMult_GOLD;
         g_profile.volExpansionRatio       = 1.5;   // 第6章
         g_profile.overextensionMult       = 2.5;   // 第6章
         g_profile.wickRatioMin            = 0.55;  // 第7章
         g_profile.lookbackMicroBars       = 0;     // GOLDはフラクタル型
         g_profile.slATRMult               = SLATRMult_GOLD;
         g_profile.minRR_EntryGate         = MinRR_EntryGate_GOLD;
         g_profile.minRangeCostMult        = MinRangeCostMult_GOLD;
         g_profile.tpExtensionRatio        = TPExtRatio_GOLD;
         break;

      case MARKET_MODE_CRYPTO:
         g_profile.impulseATRMult         = 2.0;
         g_profile.impulseMinBars          = 1;
         g_profile.smallBodyRatio          = 0.45;
         g_profile.freezeCancelWindowBars  = 1;
         g_profile.deepBandEnabled         = false;
         g_profile.cryptoDeepBandAlwaysOn  = true;  // CRYPTO: 61.8常時ON
         g_profile.optionalBand38          = OptionalBand38;
         g_profile.leaveDistanceMult       = 1.2;
         g_profile.leaveMinBars            = 1;
         g_profile.retouchTimeLimitBars    = 25;
         g_profile.resetMinBars            = 6;
         g_profile.confirmTimeLimitBars    = 4;
         g_profile.maxSlippagePts          = (InputMaxSlippagePts > 0) ? InputMaxSlippagePts : 8.0;
         g_profile.maxFillDeviationPts     = (InputMaxFillDeviationPts > 0) ? InputMaxFillDeviationPts : 12.0;
         g_profile.timeExitBars            = 6;
         g_profile.spreadMult              = SpreadMult_CRYPTO;
         g_profile.volExpansionRatio       = 0.0;   // N/A
         g_profile.overextensionMult       = 0.0;   // N/A
         g_profile.wickRatioMin            = 0.0;   // CRYPTOはWickRejection不採用
         g_profile.lookbackMicroBars       = 3;     // 第7章
         g_profile.slATRMult               = SLATRMult_CRYPTO;
         g_profile.minRR_EntryGate         = MinRR_EntryGate_CRYPTO;
         g_profile.minRangeCostMult        = MinRangeCostMult_CRYPTO;
         g_profile.tpExtensionRatio        = TPExtRatio_CRYPTO;
         break;

      default:
         // 安全側: FX扱い（再帰的にFXを設定）
         g_resolvedMarketMode = MARKET_MODE_FX;
         InitMarketProfile();
         return;
   }
}

//+------------------------------------------------------------------+
//| GOLD DeepBand判定（第6章）                                         |
//+------------------------------------------------------------------+
bool EvaluateGoldDeepBand()
{
   if(g_resolvedMarketMode != MARKET_MODE_GOLD)
      return false;

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
   // NY前半: サーバー時間で13-17時（概算。MT5サーバーがGMT+2/+3想定）
   C1 = (hour >= 13 && hour <= 17);

   // C2: 直近でスイープ痕跡（直近高安を一瞬抜いて戻す）
   // 簡易判定: 直近5本で高値を抜いてから戻った or 安値を抜いてから戻った
   C2 = DetectSweep(5);

   // C3: スプレッドが通常域（拡大していない）
   double spread = GetCurrentSpreadPts();
   C3 = (spread <= g_maxSpreadPts);

   bool additional = (C1 || C2 || C3);

   return (gate && additional);
}

bool DetectSweep(int lookback)
{
   // 直近lookback本での高安スイープ痕跡
   // 高値が前の高値を上回ったが、次足以降で戻った場合
   for(int i = 1; i < lookback; i++)
   {
      double h_i = iHigh(Symbol(), PERIOD_M1, i);
      double h_prev = iHigh(Symbol(), PERIOD_M1, i + 1);
      double c_i = iClose(Symbol(), PERIOD_M1, i);

      // 高値スイープ: 高値が前足高値を超えたが終値が前足高値以下
      if(h_i > h_prev && c_i <= h_prev)
         return true;

      double l_i = iLow(Symbol(), PERIOD_M1, i);
      double l_prev = iLow(Symbol(), PERIOD_M1, i + 1);

      // 安値スイープ: 安値が前足安値を下回ったが終値が前足安値以上
      if(l_i < l_prev && c_i >= l_prev)
         return true;
   }
   return false;
}

// BandWidthPts確定（第10章: 唯一の定義）
void CalculateBandWidth()
{
   switch(g_resolvedMarketMode)
   {
      case MARKET_MODE_FX:
      {
         // FX = Spread×2相当（第5.4章）
         double spread = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - SymbolInfoDouble(Symbol(), SYMBOL_BID);
         g_bandWidthPts = spread * 2.0;
         break;
      }
      case MARKET_MODE_GOLD:
      {
         // GOLD = ATR(M1)×0.05
         double atr = GetATR_M1(0);
         g_bandWidthPts = atr * 0.05;
         break;
      }
      case MARKET_MODE_CRYPTO:
      {
         // CRYPTO = ATR(M1)×0.08
         double atr = GetATR_M1(0);
         g_bandWidthPts = atr * 0.08;
         break;
      }
   }
}

#endif // __MARKET_PROFILE_MQH__
