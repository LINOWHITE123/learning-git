//+------------------------------------------------------------------+
//|                                                       Logger.mqh |
//|            Small logging helper: journal + optional CSV audit log |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_LOGGER_MQH__
#define __GOLDSMC_LOGGER_MQH__

enum ENUM_LOG_LEVEL
  {
   LOG_ERROR = 0,
   LOG_WARN  = 1,
   LOG_INFO  = 2,
   LOG_DEBUG = 3
  };

class CLogger
  {
private:
   ENUM_LOG_LEVEL    m_level;
   string            m_prefix;
   string            m_file;
   bool              m_to_file;

   string            LevelName(const ENUM_LOG_LEVEL lvl) const
     {
      switch(lvl)
        {
         case LOG_ERROR: return "ERROR";
         case LOG_WARN:  return "WARN";
         case LOG_INFO:  return "INFO";
         default:        return "DEBUG";
        }
     }

   void              Append(const string line)
     {
      if(!m_to_file)
         return;
      int h = FileOpen(m_file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h == INVALID_HANDLE)
         return;
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line + "\r\n");
      FileClose(h);
     }

public:
                     CLogger(void) : m_level(LOG_INFO), m_prefix("GoldSMC"), m_file(""), m_to_file(false) {}

   void              Init(const string prefix, const ENUM_LOG_LEVEL level, const bool to_file, const string file)
     {
      m_prefix  = prefix;
      m_level   = level;
      m_to_file = to_file;
      m_file    = file;
     }

   void              Write(const ENUM_LOG_LEVEL lvl, const string msg)
     {
      if(lvl > m_level)
         return;
      string line = StringFormat("[%s][%s] %s", m_prefix, LevelName(lvl), msg);
      Print(line);
      Append(StringFormat("%s,%s,%s", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), LevelName(lvl), msg));
     }

   void              Error(const string msg) { Write(LOG_ERROR, msg); }
   void              Warn(const string msg)  { Write(LOG_WARN,  msg); }
   void              Info(const string msg)  { Write(LOG_INFO,  msg); }
   void              Debug(const string msg) { Write(LOG_DEBUG, msg); }
  };

#endif // __GOLDSMC_LOGGER_MQH__
