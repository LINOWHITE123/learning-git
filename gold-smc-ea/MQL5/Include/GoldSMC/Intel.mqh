//+------------------------------------------------------------------+
//|                                                        Intel.mqh |
//|   Bridge to the external intelligence service (neural model +     |
//|   news / social sentiment). The service either writes a JSON file |
//|   into MQL5/Files or answers an HTTP request on localhost.        |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_INTEL_MQH__
#define __GOLDSMC_INTEL_MQH__

#include <GoldSMC/Types.mqh>

class CIntelClient
  {
private:
   bool              m_enabled;
   bool              m_use_http;
   string            m_url;
   string            m_file;
   int               m_max_age_sec;
   int               m_timeout_ms;
   IntelSnapshot     m_last;
   datetime          m_last_poll;
   string            m_last_error;

   //--- minimal flat-JSON reader: returns the raw text after "key":
   bool              RawValue(const string json, const string key, string &out) const
     {
      string pattern = "\"" + key + "\"";
      int p = StringFind(json, pattern);
      if(p < 0)
         return false;
      p = StringFind(json, ":", p + StringLen(pattern));
      if(p < 0)
         return false;
      p++;

      int len = StringLen(json);
      while(p < len)
        {
         ushort c = StringGetCharacter(json, p);
         if(c != ' ' && c != '\t' && c != '\n' && c != '\r')
            break;
         p++;
        }
      if(p >= len)
         return false;

      bool quoted = (StringGetCharacter(json, p) == '"');
      if(quoted)
         p++;

      string acc = "";
      while(p < len)
        {
         ushort c = StringGetCharacter(json, p);
         if(quoted)
           {
            if(c == '"')
               break;
           }
         else
           {
            if(c == ',' || c == '}' || c == ' ' || c == '\n' || c == '\r' || c == '\t')
               break;
           }
         acc += ShortToString(c);
         p++;
        }
      out = acc;
      return true;
     }

   double            NumberValue(const string json, const string key, const double fallback) const
     {
      string raw;
      if(!RawValue(json, key, raw))
         return fallback;
      return StringToDouble(raw);
     }

   bool              BoolValue(const string json, const string key, const bool fallback) const
     {
      string raw;
      if(!RawValue(json, key, raw))
         return fallback;
      return (StringCompare(raw, "true", false) == 0 || raw == "1");
     }

   string            StringValue(const string json, const string key, const string fallback) const
     {
      string raw;
      if(!RawValue(json, key, raw))
         return fallback;
      return raw;
     }

   bool              ReadFile(string &content)
     {
      int h = FileOpen(m_file, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h == INVALID_HANDLE)
         h = FileOpen(m_file, FILE_READ|FILE_TXT|FILE_ANSI);
      if(h == INVALID_HANDLE)
        {
         m_last_error = "cannot open " + m_file;
         return false;
        }
      content = "";
      while(!FileIsEnding(h))
         content += FileReadString(h);
      FileClose(h);
      return (StringLen(content) > 0);
     }

   bool              ReadHttp(const string symbol, string &content)
     {
      string url = m_url;
      if(StringFind(url, "?") < 0)
         url += "?symbol=" + symbol;
      else
         url += "&symbol=" + symbol;

      char post[], result[];
      string headers = "Content-Type: application/json\r\n";
      string response_headers;

      ResetLastError();
      int code = WebRequest("GET", url, headers, m_timeout_ms, post, result, response_headers);
      if(code != 200)
        {
         m_last_error = StringFormat("WebRequest failed, http=%d err=%d (allow %s in Tools>Options>Expert Advisors)",
                                     code, GetLastError(), url);
         return false;
        }
      content = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      return (StringLen(content) > 0);
     }

   bool              Parse(const string json, IntelSnapshot &out) const
     {
      if(StringLen(json) < 2)
         return false;
      out.valid         = true;
      out.sentiment     = MathMax(-1.0, MathMin(1.0, NumberValue(json, "sentiment", 0.0)));
      out.model_score   = MathMax(-1.0, MathMin(1.0, NumberValue(json, "model_score", 0.0)));
      out.confidence    = MathMax(0.0, MathMin(1.0, NumberValue(json, "confidence", 0.0)));
      out.news_blackout = BoolValue(json, "news_blackout", false);
      out.note          = StringValue(json, "note", "");
      long ts           = (long)NumberValue(json, "timestamp", 0.0);
      out.stamp         = (ts > 0 ? (datetime)ts : TimeCurrent());
      return true;
     }

public:
                     CIntelClient(void) : m_enabled(false), m_use_http(false), m_url("http://127.0.0.1:8711/signal"),
                                          m_file("GoldSMC_intel.json"), m_max_age_sec(1800), m_timeout_ms(3000),
                                          m_last_poll(0), m_last_error("")
     {
      m_last.valid = false;
     }

   void              Init(const bool enabled, const bool use_http, const string url, const string file,
                          const int max_age_sec, const int timeout_ms)
     {
      m_enabled     = enabled;
      m_use_http    = use_http;
      m_url         = url;
      m_file        = file;
      m_max_age_sec = MathMax(60, max_age_sec);
      m_timeout_ms  = MathMax(500, timeout_ms);
      m_last.valid  = false;
      m_last_poll   = 0;
     }

   bool              Enabled(void) const     { return m_enabled; }
   string            LastError(void) const   { return m_last_error; }

   //--- poll at most once a minute; returns the cached snapshot otherwise
   IntelSnapshot     Poll(const string symbol, const int poll_seconds = 60)
     {
      IntelSnapshot empty;
      empty.valid         = false;
      empty.sentiment     = 0.0;
      empty.model_score   = 0.0;
      empty.confidence    = 0.0;
      empty.news_blackout = false;
      empty.note          = "";
      empty.stamp         = 0;

      if(!m_enabled)
         return empty;

      datetime now = TimeCurrent();
      if(m_last.valid && m_last_poll > 0 && now - m_last_poll < poll_seconds)
         return m_last;

      string json = "";
      bool ok = (m_use_http ? ReadHttp(symbol, json) : ReadFile(json));
      m_last_poll = now;

      if(!ok)
        {
         m_last.valid = false;
         return empty;
        }

      IntelSnapshot snap;
      if(!Parse(json, snap))
        {
         m_last_error = "malformed intel payload";
         m_last.valid = false;
         return empty;
        }

      //--- stale data must not be trusted
      if(snap.stamp > 0 && now - snap.stamp > m_max_age_sec)
        {
         m_last_error = "intel payload is stale";
         snap.valid   = false;
         m_last       = snap;
         return empty;
        }

      m_last_error = "";
      m_last       = snap;
      return snap;
     }

   //--- combined directional score of the intelligence layer, -1..+1
   static double     Score(const IntelSnapshot &snap, const double sentiment_weight)
     {
      if(!snap.valid)
         return 0.0;
      double w = MathMax(0.0, MathMin(1.0, sentiment_weight));
      return snap.sentiment * w + snap.model_score * (1.0 - w);
     }
  };

#endif // __GOLDSMC_INTEL_MQH__
