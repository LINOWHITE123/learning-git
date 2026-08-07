//+------------------------------------------------------------------+
//|                                                        Zones.mqh |
//|   Detection of demand / supply areas (order blocks) and fair      |
//|   value gaps on the entry timeframe, with mitigation tracking.    |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_ZONES_MQH__
#define __GOLDSMC_ZONES_MQH__

#include <GoldSMC/Types.mqh>

class CZoneEngine
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_depth;
   int               m_atr_handle;
   double            m_impulse_atr;    // impulse must be >= this many ATR
   int               m_max_touches;    // a zone is discarded after this many taps
   bool              m_use_fvg;
   Zone              m_zones[];

   void              Add(const Zone &z)
     {
      int n = ArraySize(m_zones);
      ArrayResize(m_zones, n + 1);
      m_zones[n] = z;
     }

   //--- walk forward in time (lower shift) to see whether the zone still holds
   void              Evaluate(Zone &z, const int base_shift, const double &high[], const double &low[])
     {
      z.touches   = 0;
      z.mitigated = false;
      bool demand = (z.type == ZONE_DEMAND || z.type == ZONE_FVG_BULL);

      for(int i = base_shift - 1; i >= 1; i--)
        {
         bool inside = (low[i] <= z.upper && high[i] >= z.lower);
         if(inside)
            z.touches++;
         if(demand && low[i] < z.lower)
           {
            z.mitigated = true;
            return;
           }
         if(!demand && high[i] > z.upper)
           {
            z.mitigated = true;
            return;
           }
        }
      if(z.touches > m_max_touches)
         z.mitigated = true;
     }

public:
                     CZoneEngine(void) : m_symbol(""), m_tf(PERIOD_M15), m_depth(400),
                                         m_atr_handle(INVALID_HANDLE), m_impulse_atr(1.5),
                                         m_max_touches(1), m_use_fvg(true) {}

                    ~CZoneEngine(void) { Release(); }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf, const int depth,
                          const double impulse_atr, const int max_touches, const bool use_fvg)
     {
      m_symbol       = symbol;
      m_tf           = tf;
      m_depth        = MathMax(100, depth);
      m_impulse_atr  = MathMax(0.3, impulse_atr);
      m_max_touches  = MathMax(0, max_touches);
      m_use_fvg      = use_fvg;
      m_atr_handle   = iATR(m_symbol, m_tf, 14);
      return (m_atr_handle != INVALID_HANDLE);
     }

   void              Release(void)
     {
      if(m_atr_handle != INVALID_HANDLE)
        {
         IndicatorRelease(m_atr_handle);
         m_atr_handle = INVALID_HANDLE;
        }
     }

   int               Count(void) const { return ArraySize(m_zones); }

   bool              At(const int index, Zone &out) const
     {
      if(index < 0 || index >= ArraySize(m_zones))
         return false;
      out = m_zones[index];
      return true;
     }

   double            ATR(void) const
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_atr_handle, 0, 0, 2, buf) < 2)
         return 0.0;
      return buf[1];
     }

   //--- rescan the entry timeframe and rebuild the list of live zones
   bool              Refresh(void)
     {
      double high[], low[], open[], close[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      ArraySetAsSeries(open, true);
      ArraySetAsSeries(close, true);

      int total = CopyHigh(m_symbol, m_tf, 0, m_depth, high);
      if(total <= 0)
         return false;
      if(CopyLow(m_symbol, m_tf, 0, m_depth, low) != total)     return false;
      if(CopyOpen(m_symbol, m_tf, 0, m_depth, open) != total)   return false;
      if(CopyClose(m_symbol, m_tf, 0, m_depth, close) != total) return false;

      double atr = ATR();
      if(atr <= 0.0)
         return false;

      ArrayResize(m_zones, 0);

      //--- order blocks: last opposite colour candle before an impulse
      for(int i = total - 3; i >= 2; i--)
        {
         double impulse_up   = close[i - 1] - open[i - 1];
         double impulse_down = open[i - 1] - close[i - 1];

         bool base_bear = (close[i] < open[i]);
         bool base_bull = (close[i] > open[i]);

         if(base_bear && impulse_up >= m_impulse_atr * atr && close[i - 1] > high[i])
           {
            Zone z;
            z.type      = ZONE_DEMAND;
            z.upper     = high[i];
            z.lower     = low[i];
            z.created   = iTime(m_symbol, m_tf, i);
            z.impulse   = impulse_up;
            z.touches   = 0;
            z.mitigated = false;
            Evaluate(z, i, high, low);
            if(!z.mitigated)
               Add(z);
           }

         if(base_bull && impulse_down >= m_impulse_atr * atr && close[i - 1] < low[i])
           {
            Zone z;
            z.type      = ZONE_SUPPLY;
            z.upper     = high[i];
            z.lower     = low[i];
            z.created   = iTime(m_symbol, m_tf, i);
            z.impulse   = impulse_down;
            z.touches   = 0;
            z.mitigated = false;
            Evaluate(z, i, high, low);
            if(!z.mitigated)
               Add(z);
           }

         //--- fair value gaps (three candle imbalance around bar i)
         if(m_use_fvg && i + 1 < total)
           {
            if(low[i - 1] > high[i + 1])
              {
               Zone z;
               z.type      = ZONE_FVG_BULL;
               z.upper     = low[i - 1];
               z.lower     = high[i + 1];
               z.created   = iTime(m_symbol, m_tf, i);
               z.impulse   = z.upper - z.lower;
               z.touches   = 0;
               z.mitigated = false;
               if(z.impulse >= 0.25 * atr)
                 {
                  Evaluate(z, i, high, low);
                  if(!z.mitigated)
                     Add(z);
                 }
              }
            if(high[i - 1] < low[i + 1])
              {
               Zone z;
               z.type      = ZONE_FVG_BEAR;
               z.upper     = low[i + 1];
               z.lower     = high[i - 1];
               z.created   = iTime(m_symbol, m_tf, i);
               z.impulse   = z.upper - z.lower;
               z.touches   = 0;
               z.mitigated = false;
               if(z.impulse >= 0.25 * atr)
                 {
                  Evaluate(z, i, high, low);
                  if(!z.mitigated)
                     Add(z);
                 }
              }
           }
        }

      return (ArraySize(m_zones) > 0);
     }

   //--- nearest unmitigated demand zone at or below price
   bool              NearestDemand(const double price, const double max_distance, Zone &out) const
     {
      bool found = false;
      double best = DBL_MAX;
      for(int i = 0; i < ArraySize(m_zones); i++)
        {
         Zone z = m_zones[i];
         if(z.mitigated)
            continue;
         if(z.type != ZONE_DEMAND && z.type != ZONE_FVG_BULL)
            continue;
         if(z.upper > price)
            continue;
         double dist = price - z.upper;
         if(dist <= max_distance && dist < best)
           {
            best  = dist;
            out   = z;
            found = true;
           }
        }
      return found;
     }

   //--- nearest unmitigated supply zone at or above price
   bool              NearestSupply(const double price, const double max_distance, Zone &out) const
     {
      bool found = false;
      double best = DBL_MAX;
      for(int i = 0; i < ArraySize(m_zones); i++)
        {
         Zone z = m_zones[i];
         if(z.mitigated)
            continue;
         if(z.type != ZONE_SUPPLY && z.type != ZONE_FVG_BEAR)
            continue;
         if(z.lower < price)
            continue;
         double dist = z.lower - price;
         if(dist <= max_distance && dist < best)
           {
            best  = dist;
            out   = z;
            found = true;
           }
        }
      return found;
     }

   //--- price is currently trading inside the zone
   static bool       PriceInside(const Zone &z, const double price)
     {
      return (price >= z.lower && price <= z.upper);
     }
  };

#endif // __GOLDSMC_ZONES_MQH__
