//+------------------------------------------------------------------+
//| Notification.mqh                                                  |
//| Impulse検出通知（第14章）                                           |
//+------------------------------------------------------------------+
#ifndef __NOTIFICATION_MQH__
#define __NOTIFICATION_MQH__

//+------------------------------------------------------------------+
//| Notification（第14章）                                             |
//+------------------------------------------------------------------+
void SendImpulseNotification()
{
   string sideStr = DirectionToString(g_impulseDir);

   if(!EnableDialogNotification && !EnablePushNotification && !EnableMailNotification && !EnableSoundNotification)
      return;

   string subject = "[" + EA_NAME + "] " + Symbol() + " " + sideStr + " IMPULSE";
   string body =
      "EA      : " + EA_NAME + " " + EA_VERSION + "\n" +
      "Symbol  : " + Symbol() + "\n" +
      "Event   : IMPULSE\n" +
      "Side    : " + sideStr + "\n" +
      "State   : IMPULSE_FOUND\n" +
      "Time    : " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);

   // 1) ダイアログ通知（MT5端末）
   if(EnableDialogNotification)
      Alert(body);

   // 2) プッシュ通知（MT5）
   if(EnablePushNotification)
      SendNotification(subject + "\n" + body);

   // 3) メール通知
   if(EnableMailNotification)
      SendMail(subject, body);

   // 4) サウンド通知
   if(EnableSoundNotification)
   {
      if(!PlaySound(SoundFileName))
         Print("[NOTIFY] Sound file not found: ", SoundFileName);
   }
}

#endif // __NOTIFICATION_MQH__
