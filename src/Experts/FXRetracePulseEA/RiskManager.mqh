//+------------------------------------------------------------------+
//| RiskManager.mqh                                                   |
//| 構造無効判定・RiskGate・SL/TP計算                                   |
//+------------------------------------------------------------------+
#ifndef __RISK_MANAGER_MQH__
#define __RISK_MANAGER_MQH__

//+------------------------------------------------------------------+
//| 構造無効判定（第9.4章）: 詳細版                              |
//+------------------------------------------------------------------+
bool CheckStructureInvalid_Detail(
   string &reason, int &priority,
   string &refLevel, double &refPrice,
   double &atPrice, double &distPts,
   int &barShift
)
{
   barShift = 1;

   double close1 = iClose(Symbol(), PERIOD_M1, barShift);

   // ■ 共通: 起点(START)割れ/超え（close判定）
   if(g_impulseDir == DIR_LONG)
   {
      if(close1 < g_impulseStart)
      {
         reason   = "BRK_OUT_START";
         priority = 1;
         refLevel = "START";
         refPrice = g_impulseStart;

         atPrice  = close1;
         distPts  = (atPrice - refPrice) / _Point;
         return true;
      }
   }
   else
   {
      if(close1 > g_impulseStart)
      {
         reason   = "BRK_OUT_START";
         priority = 1;
         refLevel = "START";
         refPrice = g_impulseStart;

         atPrice  = close1;
         distPts  = (atPrice - refPrice) / _Point;
         return true;
      }
   }

   // ■ 市場別（close判定）
   switch(g_resolvedMarketMode)
   {
      case MARKET_MODE_FX:
      {
         // FX: 61.8終値突破
         if(g_impulseDir == DIR_LONG)
         {
            if(close1 < g_fib618)
            {
               reason="BRK_CLOSE_61_8"; priority=2;
               refLevel="61.8"; refPrice=g_fib618;
               atPrice=close1; distPts=(atPrice-refPrice)/_Point;
               return true;
            }
         }
         else
         {
            if(close1 > g_fib618)
            {
               reason="BRK_CLOSE_61_8"; priority=2;
               refLevel="61.8"; refPrice=g_fib618;
               atPrice=close1; distPts=(atPrice-refPrice)/_Point;
               return true;
            }
         }
         break;
      }

      case MARKET_MODE_GOLD:
      {
         if(g_goldDeepBandON)
         {
            // GOLD deep: 78.6終値割れ/超え
            if(g_impulseDir == DIR_LONG)
            {
               if(close1 < g_fib786)
               {
                  reason="BRK_CLOSE_78_6"; priority=2;
                  refLevel="78.6"; refPrice=g_fib786;
                  atPrice=close1; distPts=(atPrice-refPrice)/_Point;
                  return true;
               }
            }
            else
            {
               if(close1 > g_fib786)
               {
                  reason="BRK_CLOSE_78_6"; priority=2;
                  refLevel="78.6"; refPrice=g_fib786;
                  atPrice=close1; distPts=(atPrice-refPrice)/_Point;
                  return true;
               }
            }
         }
         else
         {
            // deep OFF: 61.8終値突破
            if(g_impulseDir == DIR_LONG)
            {
               if(close1 < g_fib618)
               {
                  reason="BRK_CLOSE_61_8"; priority=2;
                  refLevel="61.8"; refPrice=g_fib618;
                  atPrice=close1; distPts=(atPrice-refPrice)/_Point;
                  return true;
               }
            }
            else
            {
               if(close1 > g_fib618)
               {
                  reason="BRK_CLOSE_61_8"; priority=2;
                  refLevel="61.8"; refPrice=g_fib618;
                  atPrice=close1; distPts=(atPrice-refPrice)/_Point;
                  return true;
               }
            }
         }
         break;
      }

      case MARKET_MODE_CRYPTO:
      {
         // CRYPTO: 78.6終値割れ/超え
         if(g_impulseDir == DIR_LONG)
         {
            if(close1 < g_fib786)
            {
               reason="BRK_CLOSE_78_6"; priority=2;
               refLevel="78.6"; refPrice=g_fib786;
               atPrice=close1; distPts=(atPrice-refPrice)/_Point;
               return true;
            }
         }
         else
         {
            if(close1 > g_fib786)
            {
               reason="BRK_CLOSE_78_6"; priority=2;
               refLevel="78.6"; refPrice=g_fib786;
               atPrice=close1; distPts=(atPrice-refPrice)/_Point;
               return true;
            }
         }
         break;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Entry待ちの「リスク/コスト過大」失効ゲート（追加）                    |
//| 目的: 0-100幅 / 帯幅 / Leave距離 / スプレッド等の摩擦を総合して、     |
//|       「取りに行ける値幅が無い」状態ならFIB_ACTIVE開始前に失効させる |
//+------------------------------------------------------------------+
bool CheckNoEntryRiskGate()
{
   // RiskGate = 「待つ価値が無いImpulse」をFIB_ACTIVE開始前に落とす事前スクリーニング。
   // CHANGE-002で MinRR_EntryGate / MinRangeCostMult は EntryGate 側へ移動したため、
   // ここでは「帯がレンジを支配する」系（主にFXのSpread由来帯幅）だけを扱う。

   double point  = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double rangeP = MathAbs(g_impulseEnd - g_impulseStart);     // 0–100 価格レンジ
   if(rangeP <= point * 2.0)
      return true; // そもそもレンジが無さすぎる（安全側）

   // 帯高さ = 2×BandWidth（上下±）
   double bandHeight = g_effectiveBandWidthPts * 2.0;
   double ratio = bandHeight / rangeP; // BandDominanceRatio

   // FXはBandWidthがSpread由来なので、過大化すると「帯=ほぼ全域」になりやすい。
   // この状態は"待つ場所"ではないため失効させる（固定閾値）。
   if(g_resolvedMarketMode == MARKET_MODE_FX)
   {
      if(ratio >= 0.85)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| TP算出（CHANGE-006: TP Extension対応）                              |
//| TP = ImpulseEnd ± ImpulseRange × tpExtensionRatio                |
//| tpExtensionRatio=0 のとき従来どおり ImpulseEnd そのまま              |
//+------------------------------------------------------------------+
double GetExtendedTP()
{
   double impulseRange = MathAbs(g_impulseEnd - g_impulseStart);
   double ext = g_profile.tpExtensionRatio;
   if(g_impulseDir == DIR_LONG)
      return g_impulseEnd + impulseRange * ext;
   else
      return g_impulseEnd - impulseRange * ext;
}

//+------------------------------------------------------------------+
//| SL/TP計算（第9章）CHANGE-008: TP=0（EMAクロス決済のためサーバーTP不使用）|
//+------------------------------------------------------------------+
void CalculateSLTP(double entryPrice)
{
   // SL: 構造（Impulse起点/直近スイング外）で決める
   // 第9.1章: 市場別パラメータ → g_profile.slATRMult
   double atr = GetATR_M1(0);
   double mult = g_profile.slATRMult;

   if(g_impulseDir == DIR_LONG)
   {
      g_sl = g_impulseStart - atr * mult;
   }
   else
   {
      g_sl = g_impulseStart + atr * mult;
   }

   // CHANGE-008: サーバーTP=0（EMAクロスで決済するため指値TPを使用しない）
   g_tp = 0;
}

// === CHANGE-002 === EntryGate用: SL/TPのプレビュー算出（グローバル非書き換え）
void PreviewSLTP(double entryPrice, double &outSL, double &outTP)
{
   double atr = GetATR_M1(0);
   double mult = g_profile.slATRMult;
   outTP = GetExtendedTP();   // CHANGE-006
   outSL = (g_impulseDir == DIR_LONG) ? (g_impulseStart - atr * mult) : (g_impulseStart + atr * mult);
}

#endif // __RISK_MANAGER_MQH__
