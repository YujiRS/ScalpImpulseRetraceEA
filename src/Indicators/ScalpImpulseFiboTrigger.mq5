//+------------------------------------------------------------------+
//| ScalpImpulseFiboTrigger_PRO.mq5                                  |
//| Full PRO Version – Fixed Fibonacci Levels                        |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_plots 0

//================ ENUM =================
enum PRESET_MODE { PRESET_CUSTOM=0, PRESET_CRYPTO, PRESET_GOLD, PRESET_FX };

//================ INPUTS =================
input PRESET_MODE Preset = PRESET_CUSTOM;

input bool EnableAlert = true;
input bool EnablePush  = false;
input bool EnableEmail = false;
input bool EnableSound = false;

input ENUM_TIMEFRAMES TriggerTF   = PERIOD_M1;
input ENUM_TIMEFRAMES TrendTF     = PERIOD_M15;
input ENUM_TIMEFRAMES StructureTF = PERIOD_M5;

input bool ShowStatusLabel = true;

input int  TrendMAPeriod      = 50;
input int  StructureMAPeriod  = 50;
input bool UseStructureTF     = false;

input int    ATR_Period    = 20;
input double RangeMult     = 1.8;
input double BodyMult      = 1.2;
input double WickRatioMax  = 0.9;
input double MinBodyPoints = 0;

input bool UseSessionFilter = false;
input int  Session1_StartHour = 15;
input int  Session1_EndHour   = 19;
input int  Session2_StartHour = 21;
input int  Session2_EndHour   = 2;

input bool   AutoDrawFibo       = true;
input int    SwingLookbackBars  = 150;
input bool   KeepOnlyLatestFibo = true;
input string FiboObjPrefix      = "SIF_";

input string EmailSubjectTag = "[SIF]";
input string SoundFileName   = "alert.wav";

//================ GLOBALS =================
int hATR = INVALID_HANDLE;
int hTrendMA = INVALID_HANDLE;
int hStructMA = INVALID_HANDLE;
int hH1MA = INVALID_HANDLE;

ENUM_TIMEFRAMES gTriggerTF;
ENUM_TIMEFRAMES gTrendTF;
ENUM_TIMEFRAMES gStructureTF;
bool gUseStructureTF;
bool gUseSessionFilter;
double gRangeMult;
double gBodyMult;
double gWickRatioMax;

datetime lastBarTime = 0;
//================ FIBO TRACKING (Impulse-follow, 100-only update) =================
string   gActiveFiboName = "";
bool     gTrackActive    = false;   // true while 100 is following extremes
bool     gTrackBullish   = true;
double   gFixed0Price    = 0.0;
datetime gFixed0Time     = 0;
double   gExt100Price    = 0.0;
datetime gExt100Time     = 0;


//================ UTILS =================
bool InSession(datetime t)
{
   if(!gUseSessionFilter) return true;

   MqlDateTime dt; TimeToStruct(t, dt);
   int h = dt.hour;

   bool s1 = (Session1_StartHour <= Session1_EndHour)
      ? (h >= Session1_StartHour && h < Session1_EndHour)
      : (h >= Session1_StartHour || h < Session1_EndHour);

   bool s2 = (Session2_StartHour <= Session2_EndHour)
      ? (h >= Session2_StartHour && h < Session2_EndHour)
      : (h >= Session2_StartHour || h < Session2_EndHour);

   return (s1 || s2);
}

void Notify(string msg)
{
   if(EnableAlert) Alert(msg);
   if(EnablePush)  SendNotification(msg);
   if(EnableEmail) SendMail(EmailSubjectTag+" "+_Symbol, msg);
   if(EnableSound) PlaySound(SoundFileName);
}

int TrendDirection(ENUM_TIMEFRAMES tf, int maPeriod, int handle)
{
   if(handle==INVALID_HANDLE) return 0;

   double ma[];
   ArraySetAsSeries(ma,true);
   if(CopyBuffer(handle,0,1,3,ma)<3) return 0;

   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,tf,0,2,r)<2) return 0;

   double slope = ma[0]-ma[1];
   double close = r[1].close;

   if(slope>0 && close>ma[0]) return 1;
   if(slope<0 && close<ma[0]) return -1;
   return 0;
}

//================ PRESET =================
void ApplyPreset()
{
   // ★ Impulseは常にM1固定
   gTriggerTF = PERIOD_M1;

   gTrendTF   = TrendTF;
   gStructureTF = StructureTF;
   gUseStructureTF = UseStructureTF;
   gUseSessionFilter = UseSessionFilter;
   gRangeMult = RangeMult;
   gBodyMult  = BodyMult;
   gWickRatioMax = WickRatioMax;

   if(Preset==PRESET_CRYPTO)
   {
      gTrendTF   = PERIOD_M15;
      gUseStructureTF = false;
      gUseSessionFilter = false;
   }
   else if(Preset==PRESET_GOLD)
   {
      gTrendTF   = PERIOD_M15;   // ← H1は傾きのみで使うので方向基準はM15で統一
      gStructureTF = PERIOD_M5;
      gUseStructureTF = true;
      gUseSessionFilter = false;
   }
   else if(Preset==PRESET_FX)
   {
      gTrendTF   = PERIOD_M15;
      gUseStructureTF = false;
      gUseSessionFilter = true;
   }
}

//================ INIT =================
int OnInit()
{
   ApplyPreset();

   hATR = iATR(_Symbol,gTriggerTF,ATR_Period);
   hTrendMA = iMA(_Symbol,gTrendTF,TrendMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   hH1MA = iMA(_Symbol,PERIOD_H1,TrendMAPeriod,0,MODE_EMA,PRICE_CLOSE);

   if(gUseStructureTF)
      hStructMA = iMA(_Symbol,gStructureTF,StructureMAPeriod,0,MODE_EMA,PRICE_CLOSE);
   
   DrawStatusLabel();

   return(INIT_SUCCEEDED);
}

int TrendSlopeOnly(int handle)
{
   if(handle==INVALID_HANDLE) return 0;

   double ma[];
   ArraySetAsSeries(ma,true);
   if(CopyBuffer(handle,0,1,3,ma)<3) return 0;

   double slope = ma[0]-ma[1];

   if(slope>0)  return 1;
   if(slope<0)  return -1;
   return 0;
}

bool IsSwingHigh(MqlRates &r[], int i)
{
   return (r[i].high > r[i+1].high &&
           r[i].high > r[i+2].high &&
           r[i].high > r[i-1].high &&
           r[i].high > r[i-2].high);
}

bool IsSwingLow(MqlRates &r[], int i)
{
   return (r[i].low < r[i+1].low &&
           r[i].low < r[i+2].low &&
           r[i].low < r[i-1].low &&
           r[i].low < r[i-2].low);
}

bool GetLastTwoSwingsH1(double &lastHigh, double &prevHigh,
                        double &lastLow,  double &prevLow)
{
   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_H1,0,200,r)<50)
      return false;

   int foundHigh=0, foundLow=0;

   for(int i=5; i<150; i++)
   {
      if(foundHigh<2 && IsSwingHigh(r,i))
      {
         if(foundHigh==0) lastHigh=r[i].high;
         else prevHigh=r[i].high;
         foundHigh++;
      }

      if(foundLow<2 && IsSwingLow(r,i))
      {
         if(foundLow==0) lastLow=r[i].low;
         else prevLow=r[i].low;
         foundLow++;
      }

      if(foundHigh>=2 && foundLow>=2)
         break;
   }

   return (foundHigh>=2 && foundLow>=2);
}

bool H1_ReversalZone(double currentPrice)
{
   double lastHigh, prevHigh, lastLow, prevLow;
   if(!GetLastTwoSwingsH1(lastHigh,prevHigh,lastLow,prevLow))
      return false;

   double atr[];
   ArraySetAsSeries(atr,true);
   if(CopyBuffer(iATR(_Symbol,PERIOD_H1,14),0,0,1,atr)<1)
      return false;

   double tol = atr[0]*0.2;  // 許容幅（B案：縮小）

   // ダブルトップ候補
   if(MathAbs(lastHigh-prevHigh)<tol &&
      currentPrice > lastHigh - tol)
      return true;

   // ダブルボトム候補
   if(MathAbs(lastLow-prevLow)<tol &&
      currentPrice < lastLow + tol)
      return true;

   return false;
}


void DeleteOldFibos()
{
   if(!KeepOnlyLatestFibo) return;

   int total = ObjectsTotal(0,0,-1);
   for(int i=total-1; i>=0; i--)
   {
      string name = ObjectName(0,i,0,-1);
      if(StringFind(name, FiboObjPrefix) == 0)
         ObjectDelete(0,name);
   }
}

// Create a new Fib for the newly detected impulse.
// 0 (origin) is fixed forever at the impulse bar's extreme (Low for long, High for short).
// 100 starts at the impulse bar's opposite extreme and then follows ONLY new extremes.
// When a closed bar does NOT make a new extreme, tracking stops and the Fib is fixed.
bool StartImpulseFibo(bool bullish, datetime impulseTime, double impHigh, double impLow)
{
   if(!AutoDrawFibo) return false;

   // overwrite old fibos if configured
   DeleteOldFibos();

   string name = FiboObjPrefix
               + _Symbol + "_"
               + EnumToString(gTriggerTF) + "_"
               + TimeToString(impulseTime, TIME_DATE|TIME_SECONDS);

   // Determine fixed 0 and initial 100
   gTrackBullish = bullish;
   gFixed0Time   = impulseTime;
   gFixed0Price  = bullish ? impLow : impHigh;

   // Use the bar end as the initial 100 time (so the object is not vertical)
   gExt100Time   = impulseTime + PeriodSeconds(gTriggerTF);
   gExt100Price  = bullish ? impHigh : impLow;

   // Create Fib: point 0 = fixed origin, point 1 = 100 (tracking)
   if(!ObjectCreate(0, name, OBJ_FIBO, 0, gFixed0Time, gFixed0Price, gExt100Time, gExt100Price))
      return false;

   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);

   // Levels (keep existing style)
   ObjectSetInteger(0, name, OBJPROP_LEVELS, 7);
   double levels[7] = {0.0,0.236,0.382,0.5,0.618,0.786,1.0};
   string texts[7]  = {"0","23.6","38.2","50","61.8","78.6","100"};

   for(int i=0;i<7;i++)
   {
      ObjectSetDouble(0, name, OBJPROP_LEVELVALUE, i, levels[i]);
      ObjectSetString(0, name, OBJPROP_LEVELTEXT, i, texts[i]);
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

   // Save tracking state
   gActiveFiboName = name;
   gTrackActive    = true;

   return true;
}

// Update only the 100 anchor while tracking is active.
// Stop tracking when a closed bar did not make a new extreme.
void UpdateImpulseFibo(datetime closedBarTime, double closedHigh, double closedLow)
{
   if(!gTrackActive) return;

   // If user deleted the fib manually, stop tracking silently.
   if(gActiveFiboName=="" || ObjectFind(0, gActiveFiboName) < 0)
   {
      gActiveFiboName = "";
      gTrackActive    = false;
      return;
   }

   bool updated = false;

   if(gTrackBullish)
   {
      // new higher high -> update 100
      if(closedHigh > gExt100Price + (_Point*0.1))
      {
         gExt100Price = closedHigh;
         gExt100Time  = closedBarTime + PeriodSeconds(gTriggerTF);
         updated      = true;
      }
   }
   else
   {
      // new lower low -> update 100 (short)
      if(closedLow < gExt100Price - (_Point*0.1))
      {
         gExt100Price = closedLow;
         gExt100Time  = closedBarTime + PeriodSeconds(gTriggerTF);
         updated      = true;
      }
   }

   if(updated)
   {
      // Move point index 1 (100 side). Point 0 stays fixed forever.
      ObjectMove(0, gActiveFiboName, 1, gExt100Time, gExt100Price);
      return;
   }

   // No new extreme on a confirmed bar -> impulse complete, fib fixed
   gTrackActive = false;
}


void DrawStatusLabel()
{
   if(!ShowStatusLabel) return;

   string name = "SIF_STATUS";

   string text =
      "SIF PRO RUNNING\n"
      "TriggerTF: " + EnumToString(gTriggerTF) + "\n" +
      "TrendTF: "   + EnumToString(gTrendTF);

   if(ObjectFind(0,name) < 0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);

      // 👇 左下
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_LOWER);

      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,15);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,20);

      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(0,name,OBJPROP_COLOR,clrLime);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   }

   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

//================ MAIN =================
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   MqlRates r[];
   ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,gTriggerTF,0,3,r)<3) return rates_total;

   datetime barTime=r[1].time;
   if(barTime==lastBarTime) return rates_total;
   if(!InSession(barTime))
   {
      // Session filter is applied to NEW impulse detection, but tracking continues.
      UpdateImpulseFibo(barTime, r[1].high, r[1].low);
      lastBarTime=barTime;
      return rates_total;
   }

   double atr[];
   ArraySetAsSeries(atr,true);
   if(CopyBuffer(hATR,0,1,2,atr)<2) return rates_total;

   double o=r[1].open, h=r[1].high, l=r[1].low, c=r[1].close;
   double range=h-l;
   double body=MathAbs(c-o);

   if(MinBodyPoints>0 && body<(MinBodyPoints*_Point))
   { lastBarTime=barTime; return rates_total; }

   double upperWick=h-MathMax(o,c);
   double lowerWick=MathMin(o,c)-l;
   bool bullish=(c>=o);

   double oppWick=bullish?lowerWick:upperWick;
   double wickRatio=(body>_Point)?oppWick/body:1;

   bool impulse = (range>=atr[0]*gRangeMult)
               && (body>=atr[0]*gBodyMult)
               && (wickRatio<=gWickRatioMax);

   if(!impulse)
   {
      // While no new impulse is detected, keep following the running impulse (100-only)
      UpdateImpulseFibo(barTime, h, l);
      lastBarTime=barTime;
      return rates_total;
   }

   int trend = TrendDirection(gTrendTF,TrendMAPeriod,hTrendMA);
   if(bullish && trend!=1){ lastBarTime=barTime; return rates_total; }
   if(!bullish && trend!=-1){ lastBarTime=barTime; return rates_total; }
   
   // H1傾きのみ確認
   int trendH1 = TrendSlopeOnly(hH1MA);
   if(bullish && trendH1!=1){ lastBarTime=barTime; return rates_total; }
   if(!bullish && trendH1!=-1){ lastBarTime=barTime; return rates_total; }
   
   // H1反転候補回避（許容幅縮小）
   if(H1_ReversalZone(c))
   {
      lastBarTime=barTime;
      return rates_total;
   }

   string side = bullish ? "BULL" : "BEAR";
   string timeStr = TimeToString(barTime, TIME_DATE|TIME_SECONDS);
   double rangeATR = range / atr[0];
   double bodyATR  = body  / atr[0];
   string msg = StringFormat(
      "Impulse Detected\nTF: %s\nBarTime: %s\nSymbol: %s\nSide: %s\nRange/ATR: %.2f\nBody/ATR: %.2f",
      EnumToString(gTriggerTF),
      timeStr,
      _Symbol,
      side,
      rangeATR,
      bodyATR
   );

   Notify(msg);
   
   StartImpulseFibo(bullish, barTime, h, l);

   lastBarTime=barTime;
   return rates_total;
}

void OnDeinit(const int reason)
{
   ObjectDelete(0,"SIF_STATUS");
}
