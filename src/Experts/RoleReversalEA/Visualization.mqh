//+------------------------------------------------------------------+
//| Visualization.mqh - RoleReversalEA                                |
//| S/Rライン描画・ステータスパネル                                      |
//+------------------------------------------------------------------+
#ifndef __RR_VISUALIZATION_MQH__
#define __RR_VISUALIZATION_MQH__

//+------------------------------------------------------------------+
//| 定数                                                              |
//+------------------------------------------------------------------+
#define RR_PANEL_PREFIX  "RrEA_SP_"
#define RR_SR_PREFIX     "RrEA_SR_"
#define RR_ZONE_PREFIX   "RrEA_ZN_"
#define RR_PANEL_FONT    "Consolas"
#define RR_PANEL_FSIZE   9
#define RR_PANEL_CLR     clrWhite
#define RR_PANEL_CLR_DIM clrDarkGray
#define RR_PANEL_LINE_H  16

int g_panelMaxRow = 0;

//+------------------------------------------------------------------+
//| S/R Level Drawing                                                  |
//| H1で検出したS/Rを水平線で描画                                        |
//+------------------------------------------------------------------+
void DrawSRLevels()
{
   if(!EnableSRLines) return;

   // 古いS/Rラインを削除
   PurgeSRObjects();

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   for(int i = 0; i < g_srCount; i++)
   {
      string name = RR_SR_PREFIX + IntegerToString(i);

      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);

      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_srLevels[i].price))
         continue;

      // 色分け: Resistance=赤系, Support=青系, Broken=グレー, Used=非表示
      color lineClr;
      int lineWidth;
      ENUM_LINE_STYLE lineStyle;

      if(g_srLevels[i].used)
      {
         // 使用済み: 薄いグレー点線
         lineClr = clrDimGray;
         lineWidth = 1;
         lineStyle = STYLE_DOT;
      }
      else if(g_srLevels[i].broken)
      {
         // ブレイク済み（ロールリバーサル待ち）: 黄色
         lineClr = clrGold;
         lineWidth = 2;
         lineStyle = STYLE_DASH;
      }
      else if(g_srLevels[i].is_resistance)
      {
         // アクティブResistance: 赤
         lineClr = clrOrangeRed;
         lineWidth = (g_srLevels[i].touch_count >= 3) ? 2 : 1;
         lineStyle = STYLE_SOLID;
      }
      else
      {
         // アクティブSupport: 青
         lineClr = clrDodgerBlue;
         lineWidth = (g_srLevels[i].touch_count >= 3) ? 2 : 1;
         lineStyle = STYLE_SOLID;
      }

      ObjectSetInteger(0, name, OBJPROP_COLOR, lineClr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, lineWidth);
      ObjectSetInteger(0, name, OBJPROP_STYLE, lineStyle);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);

      // ラベル: "R 2750.50 (T=5)" or "S 2700.00 (T=3)"
      string label = (g_srLevels[i].is_resistance ? "R " : "S ") +
                      DoubleToString(g_srLevels[i].price, digits) +
                      " (T=" + IntegerToString(g_srLevels[i].touch_count) + ")";
      ObjectSetString(0, name, OBJPROP_TOOLTIP, label);
   }
}

//+------------------------------------------------------------------+
//| Pullback Zone Drawing                                              |
//| ブレイクしたレベル周辺のロールリバーサルゾーンを矩形で描画              |
//+------------------------------------------------------------------+
void DrawPullbackZone(int levelIdx, double atrVal)
{
   if(!EnableSRLines) return;
   if(levelIdx < 0 || levelIdx >= g_srCount) return;

   string name = RR_ZONE_PREFIX + IntegerToString(levelIdx);

   // 既存削除
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   double zone = atrVal * PB_ZoneATR;
   double upper = g_srLevels[levelIdx].price + zone;
   double lower = g_srLevels[levelIdx].price - zone;

   datetime t1 = g_srLevels[levelIdx].broken_time;
   if(t1 <= 0) t1 = TimeCurrent();
   datetime t2 = t1 + (datetime)(PeriodSeconds(PERIOD_M5) * PB_MaxBars);

   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, upper, t2, lower))
      return;

   // 半透明の緑 or 赤
   color zoneClr = (g_srLevels[levelIdx].broken_direction == RR_DIR_LONG) ?
                    clrDarkGreen : clrDarkRed;

   ObjectSetInteger(0, name, OBJPROP_COLOR, zoneClr);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);

   string tooltip = "Pullback Zone: " +
                     DoubleToString(lower, _Digits) + " - " +
                     DoubleToString(upper, _Digits);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tooltip);
}

//+------------------------------------------------------------------+
//| Pullback Zone Update (右端を現在時刻に追従)                         |
//+------------------------------------------------------------------+
void UpdatePullbackZoneEnd(int levelIdx)
{
   if(!EnableSRLines) return;
   string name = RR_ZONE_PREFIX + IntegerToString(levelIdx);
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetInteger(0, name, OBJPROP_TIME, 1,
                       TimeCurrent() + (datetime)(PeriodSeconds(PERIOD_M5) * 5));
   }
}

//+------------------------------------------------------------------+
//| Delete Pullback Zone                                               |
//+------------------------------------------------------------------+
void DeletePullbackZone(int levelIdx)
{
   string name = RR_ZONE_PREFIX + IntegerToString(levelIdx);
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
}

//+------------------------------------------------------------------+
//| Purge old S/R objects                                              |
//+------------------------------------------------------------------+
void PurgeSRObjects()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, RR_SR_PREFIX) == 0 || StringFind(name, RR_ZONE_PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| On-Chart Status Panel (OBJ_LABEL — 左下配置)                       |
//+------------------------------------------------------------------+
void PanelSetLine(int row, const string text, color clr = RR_PANEL_CLR)
{
   string name = RR_PANEL_PREFIX + IntegerToString(row);

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetString(0, name, OBJPROP_FONT, RR_PANEL_FONT);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, RR_PANEL_FSIZE);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 14);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 20 + row * RR_PANEL_LINE_H);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void PanelDeleteAll()
{
   int total = ObjectsTotal(0, -1, OBJ_LABEL);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, OBJ_LABEL);
      if(StringFind(name, RR_PANEL_PREFIX) == 0)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| State名変換                                                        |
//+------------------------------------------------------------------+
// チャート表示用: 短縮ステート名
string RRStateToShortString(ENUM_RR_STATE st)
{
   switch(st)
   {
      case RR_IDLE:                return "IDLE";
      case RR_BREAKOUT_DETECTED:   return "BO_DETECT";
      case RR_BREAKOUT_CONFIRMED:  return "BO_CONFIRM";
      case RR_WAITING_PULLBACK:    return "WAIT_PB";
      case RR_PULLBACK_AT_LEVEL:   return "PB_LEVEL";
      case RR_ENTRY_READY:         return "ENTRY_RDY";
      case RR_IN_POSITION:         return "IN_POS";
      case RR_COOLDOWN:            return "COOLDOWN";
      default:                     return "UNKNOWN";
   }
}

string RRDirToString(int dir)
{
   if(dir == RR_DIR_LONG)  return "LONG";
   if(dir == RR_DIR_SHORT) return "SHORT";
   return "---";
}

//+------------------------------------------------------------------+
//| UpdateChartStatusPanel                                             |
//| 左下にステータスパネルを表示                                         |
//+------------------------------------------------------------------+
void UpdateChartStatusPanel()
{
   if(!EnableStatusPanel) return;

   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double spread = (ask - bid) / _Point;

   int r = 0;

   // --- Server Time ---
   PanelSetLine(r++, "Server : " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                RR_PANEL_CLR_DIM);

   // --- Time Filter ---
   MqlDateTime dt;
   TimeCurrent(dt);
   bool inSession = (dt.hour >= TradeHourStart && dt.hour < TradeHourEnd);
   PanelSetLine(r++, "Session: " + (inSession ? "ACTIVE" : "CLOSED") +
                " (" + IntegerToString(TradeHourStart) + "-" +
                IntegerToString(TradeHourEnd) + " UTC)",
                inSession ? clrLime : clrOrangeRed);

   // --- Position Info ---
   if(g_state == RR_IN_POSITION && g_posTicket > 0)
   {
      if(PositionSelectByTicket(g_posTicket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         double posPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double posSL = PositionGetDouble(POSITION_SL);
         double posTP = PositionGetDouble(POSITION_TP);
         color plClr = (profit >= 0) ? clrLime : clrOrangeRed;

         PanelSetLine(r++, "P/L      : " + DoubleToString(profit, 2), plClr);
         PanelSetLine(r++, "TP       : " + DoubleToString(posTP, digits));
         PanelSetLine(r++, "SL       : " + DoubleToString(posSL, digits));
         PanelSetLine(r++, "Entry    : " + DoubleToString(posPrice, digits));
         PanelSetLine(r++, "Confirm  : " + ConfirmPatternName(g_lastConfirm), clrYellow);
      }
      else
         PanelSetLine(r++, "Position : LOST", clrOrangeRed);
   }

   // --- Pullback Wait Info ---
   if(g_state == RR_WAITING_PULLBACK || g_state == RR_PULLBACK_AT_LEVEL)
   {
      int barsSince = g_m5BarCount - g_breakoutBar;
      PanelSetLine(r++, "PB Wait  : " + IntegerToString(barsSince) +
                   " / " + IntegerToString(PB_MaxBars), clrYellow);

      if(g_breakoutLevelIdx >= 0 && g_breakoutLevelIdx < g_srCount)
      {
         PanelSetLine(r++, "Level    : " +
                      DoubleToString(g_srLevels[g_breakoutLevelIdx].price, digits),
                      clrGold);
      }
   }

   // --- Breakout Info ---
   if(g_state >= RR_BREAKOUT_DETECTED && g_state <= RR_PULLBACK_AT_LEVEL)
   {
      color dirClr = (g_breakoutDir == RR_DIR_LONG) ? clrDodgerBlue : clrOrangeRed;
      PanelSetLine(r++, "BO Dir   : " + RRDirToString(g_breakoutDir), dirClr);
      PanelSetLine(r++, "BO Conf  : " + IntegerToString(g_confirmCount) +
                   " / " + IntegerToString(BO_ConfirmBars));
   }

   PanelSetLine(r++, "-------------------", RR_PANEL_CLR_DIM);

   // --- S/R Info ---
   PanelSetLine(r++, "S/R Lvls : " + IntegerToString(g_srCount), RR_PANEL_CLR_DIM);
   int activeLevels = 0;
   for(int i = 0; i < g_srCount; i++)
      if(!g_srLevels[i].broken && !g_srLevels[i].used) activeLevels++;
   PanelSetLine(r++, "Active   : " + IntegerToString(activeLevels), RR_PANEL_CLR_DIM);

   PanelSetLine(r++, "-------------------", RR_PANEL_CLR_DIM);

   // --- Market Info ---
   PanelSetLine(r++, "Spread   : " + DoubleToString(spread, 1) + " pts");
   PanelSetLine(r++, "Ask      : " + DoubleToString(ask, digits));
   PanelSetLine(r++, "Bid      : " + DoubleToString(bid, digits));

   PanelSetLine(r++, "-------------------", RR_PANEL_CLR_DIM);

   // --- EA Status ---
   PanelSetLine(r++, "Trading  : " + (EnableTrading ? "ON" : "OFF"),
                EnableTrading ? clrLime : clrOrangeRed);

   color stateClr = RR_PANEL_CLR;
   if(g_state == RR_IN_POSITION) stateClr = clrLime;
   else if(g_state >= RR_WAITING_PULLBACK) stateClr = clrYellow;
   else if(g_state >= RR_BREAKOUT_DETECTED) stateClr = clrAqua;
   PanelSetLine(r++, "State    : " + RRStateToShortString(g_state), stateClr);

   PanelSetLine(r++, "RoleReversalEA  " + Symbol(), clrGold);

   // 不要行を掃除
   g_panelMaxRow = MathMax(g_panelMaxRow, r);
   for(int i = r; i < g_panelMaxRow; i++)
   {
      string name = RR_PANEL_PREFIX + IntegerToString(i);
      if(ObjectFind(0, name) >= 0)
         ObjectDelete(0, name);
   }
   g_panelMaxRow = r;
}

//+------------------------------------------------------------------+
//| ClearChartStatusPanel                                              |
//+------------------------------------------------------------------+
void ClearChartStatusPanel()
{
   PanelDeleteAll();
   PurgeSRObjects();
}

#endif // __RR_VISUALIZATION_MQH__
