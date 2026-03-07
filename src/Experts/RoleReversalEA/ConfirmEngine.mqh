//+------------------------------------------------------------------+
//| ConfirmEngine.mqh - RoleReversalEA                                |
//| Key Reversal, Engulfing, Pin Bar detection on M5                  |
//+------------------------------------------------------------------+
#ifndef __RR_CONFIRM_ENGINE_MQH__
#define __RR_CONFIRM_ENGINE_MQH__

//+------------------------------------------------------------------+
//| Bullish Key Reversal                                              |
//| - New low in N bars                                               |
//| - Close above previous close                                      |
//| - Close in upper portion, bullish body                            |
//+------------------------------------------------------------------+
bool IsBullishKeyReversal(int shift, int lookback, double bodyMinRatio, double closePosition)
{
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   int need = shift + lookback + 2;
   if(CopyOpen(Symbol(), PERIOD_M5, 0, need, o) < need) return false;
   if(CopyHigh(Symbol(), PERIOD_M5, 0, need, h) < need) return false;
   if(CopyLow(Symbol(), PERIOD_M5, 0, need, l) < need) return false;
   if(CopyClose(Symbol(), PERIOD_M5, 0, need, c) < need) return false;

   double rng = h[shift] - l[shift];
   if(rng <= 0) return false;

   double body = MathAbs(c[shift] - o[shift]);
   if(body / rng < bodyMinRatio) return false;

   // Bullish candle
   if(c[shift] <= o[shift]) return false;

   // New low in lookback
   double minLow = l[shift + 1];
   for(int i = shift + 2; i <= shift + lookback; i++)
      minLow = MathMin(minLow, l[i]);
   if(l[shift] > minLow) return false;

   // Close above previous close
   if(c[shift] <= c[shift + 1]) return false;

   // Close in upper portion
   double closePos = (c[shift] - l[shift]) / rng;
   if(closePos < closePosition) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Bearish Key Reversal                                              |
//+------------------------------------------------------------------+
bool IsBearishKeyReversal(int shift, int lookback, double bodyMinRatio, double closePosition)
{
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   int need = shift + lookback + 2;
   if(CopyOpen(Symbol(), PERIOD_M5, 0, need, o) < need) return false;
   if(CopyHigh(Symbol(), PERIOD_M5, 0, need, h) < need) return false;
   if(CopyLow(Symbol(), PERIOD_M5, 0, need, l) < need) return false;
   if(CopyClose(Symbol(), PERIOD_M5, 0, need, c) < need) return false;

   double rng = h[shift] - l[shift];
   if(rng <= 0) return false;

   double body = MathAbs(c[shift] - o[shift]);
   if(body / rng < bodyMinRatio) return false;

   // Bearish candle
   if(c[shift] >= o[shift]) return false;

   // New high in lookback
   double maxHigh = h[shift + 1];
   for(int i = shift + 2; i <= shift + lookback; i++)
      maxHigh = MathMax(maxHigh, h[i]);
   if(h[shift] < maxHigh) return false;

   // Close below previous close
   if(c[shift] >= c[shift + 1]) return false;

   // Close in lower portion
   double closePos = (c[shift] - l[shift]) / rng;
   if(closePos > (1.0 - closePosition)) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Bullish Engulfing                                                  |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(int shift, double bodyMinRatio)
{
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   int need = shift + 3;
   if(CopyOpen(Symbol(), PERIOD_M5, 0, need, o) < need) return false;
   if(CopyHigh(Symbol(), PERIOD_M5, 0, need, h) < need) return false;
   if(CopyLow(Symbol(), PERIOD_M5, 0, need, l) < need) return false;
   if(CopyClose(Symbol(), PERIOD_M5, 0, need, c) < need) return false;

   double rng = h[shift] - l[shift];
   if(rng <= 0) return false;

   double body = MathAbs(c[shift] - o[shift]);
   if(body / rng < bodyMinRatio) return false;

   // Current bullish, previous bearish
   if(c[shift] <= o[shift]) return false;
   if(c[shift + 1] >= o[shift + 1]) return false;

   // Body engulfs previous
   double prevBodyLow = MathMin(o[shift + 1], c[shift + 1]);
   double prevBodyHigh = MathMax(o[shift + 1], c[shift + 1]);
   if(o[shift] > prevBodyLow || c[shift] < prevBodyHigh) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Bearish Engulfing                                                  |
//+------------------------------------------------------------------+
bool IsBearishEngulfing(int shift, double bodyMinRatio)
{
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   int need = shift + 3;
   if(CopyOpen(Symbol(), PERIOD_M5, 0, need, o) < need) return false;
   if(CopyHigh(Symbol(), PERIOD_M5, 0, need, h) < need) return false;
   if(CopyLow(Symbol(), PERIOD_M5, 0, need, l) < need) return false;
   if(CopyClose(Symbol(), PERIOD_M5, 0, need, c) < need) return false;

   double rng = h[shift] - l[shift];
   if(rng <= 0) return false;

   double body = MathAbs(c[shift] - o[shift]);
   if(body / rng < bodyMinRatio) return false;

   // Current bearish, previous bullish
   if(c[shift] >= o[shift]) return false;
   if(c[shift + 1] <= o[shift + 1]) return false;

   // Body engulfs previous
   double prevBodyLow = MathMin(o[shift + 1], c[shift + 1]);
   double prevBodyHigh = MathMax(o[shift + 1], c[shift + 1]);
   if(o[shift] < prevBodyHigh || c[shift] > prevBodyLow) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Bullish Pin Bar                                                    |
//+------------------------------------------------------------------+
bool IsBullishPinBar(int shift, double bodyMaxRatio, double wickRatio)
{
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   int need = shift + 2;
   if(CopyOpen(Symbol(), PERIOD_M5, 0, need, o) < need) return false;
   if(CopyHigh(Symbol(), PERIOD_M5, 0, need, h) < need) return false;
   if(CopyLow(Symbol(), PERIOD_M5, 0, need, l) < need) return false;
   if(CopyClose(Symbol(), PERIOD_M5, 0, need, c) < need) return false;

   double rng = h[shift] - l[shift];
   if(rng <= 0) return false;

   double body = MathAbs(c[shift] - o[shift]);
   if(body / rng > bodyMaxRatio) return false;

   double lowerWick = MathMin(o[shift], c[shift]) - l[shift];
   if(body > 0 && lowerWick / body < wickRatio) return false;

   // Close in upper portion
   double closePos = (c[shift] - l[shift]) / rng;
   return (closePos >= 0.6);
}

//+------------------------------------------------------------------+
//| Bearish Pin Bar                                                    |
//+------------------------------------------------------------------+
bool IsBearishPinBar(int shift, double bodyMaxRatio, double wickRatio)
{
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   int need = shift + 2;
   if(CopyOpen(Symbol(), PERIOD_M5, 0, need, o) < need) return false;
   if(CopyHigh(Symbol(), PERIOD_M5, 0, need, h) < need) return false;
   if(CopyLow(Symbol(), PERIOD_M5, 0, need, l) < need) return false;
   if(CopyClose(Symbol(), PERIOD_M5, 0, need, c) < need) return false;

   double rng = h[shift] - l[shift];
   if(rng <= 0) return false;

   double body = MathAbs(c[shift] - o[shift]);
   if(body / rng > bodyMaxRatio) return false;

   double upperWick = h[shift] - MathMax(o[shift], c[shift]);
   if(body > 0 && upperWick / body < wickRatio) return false;

   // Close in lower portion
   double closePos = (c[shift] - l[shift]) / rng;
   return (closePos <= 0.4);
}

//+------------------------------------------------------------------+
//| Check any bullish confirm pattern                                  |
//+------------------------------------------------------------------+
ENUM_CONFIRM_PATTERN CheckBullishConfirm(int shift, int krLookback,
                                          double krBodyMin, double krClosePos,
                                          double engulfBodyMin,
                                          double pinBodyMax, double pinWickRatio)
{
   if(IsBullishKeyReversal(shift, krLookback, krBodyMin, krClosePos))
      return CONFIRM_KEY_REVERSAL;
   if(IsBullishEngulfing(shift, engulfBodyMin))
      return CONFIRM_ENGULFING;
   if(IsBullishPinBar(shift, pinBodyMax, pinWickRatio))
      return CONFIRM_PIN_BAR;
   return CONFIRM_NONE;
}

//+------------------------------------------------------------------+
//| Check any bearish confirm pattern                                  |
//+------------------------------------------------------------------+
ENUM_CONFIRM_PATTERN CheckBearishConfirm(int shift, int krLookback,
                                          double krBodyMin, double krClosePos,
                                          double engulfBodyMin,
                                          double pinBodyMax, double pinWickRatio)
{
   if(IsBearishKeyReversal(shift, krLookback, krBodyMin, krClosePos))
      return CONFIRM_KEY_REVERSAL;
   if(IsBearishEngulfing(shift, engulfBodyMin))
      return CONFIRM_ENGULFING;
   if(IsBearishPinBar(shift, pinBodyMax, pinWickRatio))
      return CONFIRM_PIN_BAR;
   return CONFIRM_NONE;
}

#endif
