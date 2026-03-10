//+------------------------------------------------------------------+
//| Constants.mqh - RoleReversalEA                                    |
//| 定数・列挙型定義                                                    |
//+------------------------------------------------------------------+
#ifndef __RR_CONSTANTS_MQH__
#define __RR_CONSTANTS_MQH__

//--- State Machine
enum ENUM_RR_STATE
{
   RR_IDLE = 0,                     // 待機中
   RR_BREAKOUT_DETECTED = 1,        // ブレイクアウト検出
   RR_BREAKOUT_CONFIRMED = 2,       // ブレイクアウト確認済み
   RR_WAITING_PULLBACK = 3,         // プルバック待ち
   RR_PULLBACK_AT_LEVEL = 4,        // レベル到達（コンフルエンス確認中）
   RR_ENTRY_READY = 5,              // エントリー条件成立
   RR_IN_POSITION = 6,              // ポジション保有中
   RR_COOLDOWN = 7,                 // クールダウン
};

//--- Direction
enum ENUM_RR_DIR
{
   RR_DIR_NONE = 0,
   RR_DIR_LONG = 1,
   RR_DIR_SHORT = -1,
};

//--- Confirm Pattern
enum ENUM_CONFIRM_PATTERN
{
   CONFIRM_NONE = 0,
   CONFIRM_KEY_REVERSAL = 1,
   CONFIRM_ENGULFING = 2,
   CONFIRM_PIN_BAR = 3,
};

//--- Lot Mode
enum ENUM_RR_LOT_MODE
{
   RR_LOT_FIXED = 0,               // FIXED
   RR_LOT_RISK_PERCENT = 1,        // RISK_PERCENT
};

//--- Log Level
enum ENUM_RR_LOG_LEVEL
{
   RR_LOG_NORMAL = 0,
   RR_LOG_DEBUG = 1,
   RR_LOG_ANALYZE = 2,
};

//--- S/R Level structure
struct SRLevel
{
   double   price;
   bool     is_resistance;     // true=resistance, false=support
   int      detected_bar;      // H1 bar index
   int      touch_count;
   bool     broken;
   int      broken_direction;  // 1=up, -1=down
   datetime broken_time;
   bool     used;              // Already traded
};

//--- Trade record
struct TradeRecord
{
   datetime entry_time;
   double   entry_price;
   int      direction;         // 1=long, -1=short
   double   sl;
   double   tp;
   double   sr_level;
   ENUM_CONFIRM_PATTERN confirm;
};

#endif
