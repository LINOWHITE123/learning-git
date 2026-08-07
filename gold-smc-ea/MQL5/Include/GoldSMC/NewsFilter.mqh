//+------------------------------------------------------------------+
//|                                                   NewsFilter.mqh |
//|   High impact event blackout built on the terminal's economic     |
//|   calendar, with a CSV fallback for the strategy tester and for   |
//|   brokers whose terminal does not expose the calendar.            |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_NEWS_MQH__
#define __GOLDSMC_NEWS_MQH__

#include <GoldSMC/Types.mqh>

struct NewsEvent
  {
   datetime          time;
   string            currency;
   string            name;
   int               importance;   // 0 none, 1 low, 2 moderate, 3 high
  };

class CNewsFilter
  {
private:
   bool              m_enabled;
   int               m_minutes_before;
   int               m_minutes_after;
   int               m_min_importance;
   string            m_currencies;      // comma separated, e.g. "USD,XAU,EUR"
   string            m_csv_file;        // fallback, lives in MQL5/Files
   NewsEvent         m_events[];
   datetime          m_last_load;
   bool              m_calendar_ok;
   string            m_active_event;

   bool              CurrencyWatched(const string ccy) const
     {
      if(StringLen(m_currencies) == 0)
         return true;
      string parts[];
      int n = StringSplit(m_currencies, ',', parts);
      for(int i = 0; i < n; i++)
        {
         string p = parts[i];
         StringTrimLeft(p);
         StringTrimRight(p);
         if(StringCompare(p, ccy, false) == 0)
            return true;
        }
      return false;
     }

   void              Add(const NewsEvent &e)
     {
      int n = ArraySize(m_events);
      ArrayResize(m_events, n + 1);
      m_events[n] = e;
     }

   int               ImportanceToInt(const ENUM_CALENDAR_EVENT_IMPORTANCE imp) const
     {
      switch(imp)
        {
         case CALENDAR_IMPORTANCE_HIGH:     return 3;
         case CALENDAR_IMPORTANCE_MODERATE: return 2;
         case CALENDAR_IMPORTANCE_LOW:      return 1;
         default:                           return 0;
        }
     }

   //--- terminal calendar (not available inside the strategy tester)
   bool              LoadFromCalendar(const datetime from, const datetime to)
     {
      MqlCalendarValue values[];
      int total = CalendarValueHistory(values, from, to, NULL, NULL);
      if(total <= 0)
         return false;

      for(int i = 0; i < total; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         MqlCalendarCountry country;
         string ccy = "";
         if(CalendarCountryById(ev.country_id, country))
            ccy = country.currency;

         int imp = ImportanceToInt(ev.importance);
         if(imp < m_min_importance)
            continue;
         if(!CurrencyWatched(ccy))
            continue;

         NewsEvent e;
         e.time       = values[i].time;
         e.currency   = ccy;
         e.name       = ev.name;
         e.importance = imp;
         Add(e);
        }
      return true;
     }

   //--- CSV fallback: time,currency,importance,name  (time as YYYY.MM.DD HH:MM)
   bool              LoadFromCsv(void)
     {
      if(StringLen(m_csv_file) == 0)
         return false;
      int h = FileOpen(m_csv_file, FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
         h = FileOpen(m_csv_file, FILE_READ|FILE_CSV|FILE_ANSI, ',');
      if(h == INVALID_HANDLE)
         return false;

      while(!FileIsEnding(h))
        {
         string s_time = FileReadString(h);
         if(FileIsEnding(h) && StringLen(s_time) == 0)
            break;
         string s_ccy  = FileReadString(h);
         string s_imp  = FileReadString(h);
         string s_name = FileReadString(h);

         if(StringCompare(s_time, "time", false) == 0)
            continue;

         NewsEvent e;
         e.time       = StringToTime(s_time);
         e.currency   = s_ccy;
         e.importance = (int)StringToInteger(s_imp);
         e.name       = s_name;

         if(e.time > 0 && e.importance >= m_min_importance && CurrencyWatched(e.currency))
            Add(e);
        }
      FileClose(h);
      return (ArraySize(m_events) > 0);
     }

public:
                     CNewsFilter(void) : m_enabled(true), m_minutes_before(30), m_minutes_after(30),
                                         m_min_importance(3), m_currencies("USD,XAU"), m_csv_file("GoldSMC_calendar.csv"),
                                         m_last_load(0), m_calendar_ok(false), m_active_event("") {}

   void              Init(const bool enabled, const int minutes_before, const int minutes_after,
                          const int min_importance, const string currencies, const string csv_file)
     {
      m_enabled        = enabled;
      m_minutes_before = MathMax(0, minutes_before);
      m_minutes_after  = MathMax(0, minutes_after);
      m_min_importance = MathMin(3, MathMax(1, min_importance));
      m_currencies     = currencies;
      m_csv_file       = csv_file;
      m_last_load      = 0;
     }

   bool              CalendarAvailable(void) const { return m_calendar_ok; }
   string            ActiveEvent(void) const       { return m_active_event; }
   int               EventCount(void) const        { return ArraySize(m_events); }

   //--- reload the upcoming window at most once an hour
   void              Refresh(const bool force = false)
     {
      if(!m_enabled)
         return;
      datetime now = TimeCurrent();
      if(!force && m_last_load > 0 && now - m_last_load < 3600)
         return;

      ArrayResize(m_events, 0);
      datetime from = now - 3 * 24 * 3600;
      datetime to   = now + 7 * 24 * 3600;

      m_calendar_ok = LoadFromCalendar(from, to);
      if(!m_calendar_ok)
         LoadFromCsv();

      m_last_load = now;
     }

   //--- true when the current time sits inside an event blackout window
   bool              InBlackout(void)
     {
      m_active_event = "";
      if(!m_enabled)
         return false;

      Refresh();
      datetime now = TimeCurrent();

      for(int i = 0; i < ArraySize(m_events); i++)
        {
         datetime start = m_events[i].time - m_minutes_before * 60;
         datetime end   = m_events[i].time + m_minutes_after * 60;
         if(now >= start && now <= end)
           {
            m_active_event = StringFormat("%s %s (%s)", TimeToString(m_events[i].time, TIME_MINUTES),
                                          m_events[i].name, m_events[i].currency);
            return true;
           }
        }
      return false;
     }

   //--- minutes until the next watched event, -1 when none is scheduled
   int               MinutesToNextEvent(void)
     {
      Refresh();
      datetime now  = TimeCurrent();
      long     best = -1;
      for(int i = 0; i < ArraySize(m_events); i++)
        {
         if(m_events[i].time <= now)
            continue;
         long diff = (long)(m_events[i].time - now) / 60;
         if(best < 0 || diff < best)
            best = diff;
        }
      return (int)best;
     }
  };

#endif // __GOLDSMC_NEWS_MQH__
