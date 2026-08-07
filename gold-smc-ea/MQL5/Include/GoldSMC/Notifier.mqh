//+------------------------------------------------------------------+
//|                                                     Notifier.mqh |
//|   Single place for terminal alerts, push notifications and mail.  |
//|   Everything is silent in the strategy tester so optimisation      |
//|   runs are not slowed down by popup windows.                      |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_NOTIFIER_MQH__
#define __GOLDSMC_NOTIFIER_MQH__

#include <GoldSMC/Logger.mqh>

class CNotifier
  {
private:
   bool              m_alerts;
   bool              m_push;
   bool              m_email;
   string            m_prefix;
   CLogger          *m_log;

public:
                     CNotifier(void) : m_alerts(false), m_push(false), m_email(false), m_prefix("GoldSMC"), m_log(NULL) {}

   void              Init(const bool alerts, const bool push, const bool email, const string prefix, CLogger *log)
     {
      m_alerts = alerts;
      m_push   = push;
      m_email  = email;
      m_prefix = prefix;
      m_log    = log;
     }

   //--- fan a single event out to every enabled channel
   void              Send(const string subject, const string text)
     {
      string body = m_prefix + " | " + subject + ": " + text;

      if(m_log != NULL)
         m_log.Info(body);

      //--- alerts and mail are unavailable / pointless while testing
      if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
         return;

      if(m_alerts)
         Alert(body);
      if(m_push)
         SendNotification(body);
      if(m_email)
         SendMail(m_prefix + " " + subject, body);
     }
  };

#endif // __GOLDSMC_NOTIFIER_MQH__
