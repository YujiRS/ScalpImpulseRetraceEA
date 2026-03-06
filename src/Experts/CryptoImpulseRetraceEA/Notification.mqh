//+------------------------------------------------------------------+
//| Notification.mqh                                                  |
//| Impulse検出通知                                                    |
//+------------------------------------------------------------------+
#ifndef __NOTIFICATION_MQH__
#define __NOTIFICATION_MQH__

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
      "FlatMode: " + FlatFilterModeToString(FlatFilterMode) + "\n" +
      "Time    : " + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);

   if(EnableDialogNotification)
      Alert(body);

   if(EnablePushNotification)
      SendNotification(subject + "\n" + body);

   if(EnableMailNotification)
      SendMail(subject, body);

   if(EnableSoundNotification)
   {
      if(!PlaySound(SoundFileName))
         Print("[NOTIFY] Sound file not found: ", SoundFileName);
   }
}

#endif // __NOTIFICATION_MQH__
