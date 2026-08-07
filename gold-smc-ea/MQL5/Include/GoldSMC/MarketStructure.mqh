//+------------------------------------------------------------------+
//|                                              MarketStructure.mqh |
//|   Swing detection, break of structure / change of character and   |
//|   the resulting directional bias for a single timeframe.          |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_STRUCTURE_MQH__
#define __GOLDSMC_STRUCTURE_MQH__

#include <GoldSMC/Types.mqh>

class CMarketStructure
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_fractal;      // bars on each side of a swing
   int               m_depth;        // how many bars to analyse
   int               m_ema_handle;
   int               m_atr_handle;

   SwingPoint        m_highs[];
   SwingPoint        m_lows[];
   datetime          m_last_build;

   //--- true when bar `shift` is the highest/lowest of its neighbourhood
   bool              IsSwing(const double &high[], const double &low[], const int shift, const int total, const bool want_high) const
     {
      if(shift - m_fractal < 0 || shift + m_fractal >= total)
         return false;
      for(int k = 1; k <= m_fractal; k++)
        {
         if(want_high)
           {
            if(high[shift] <= high[shift - k] || high[shift] <= high[shift + k])
               return false;
           }
         else
           {
            if(low[shift] >= low[shift - k] || low[shift] >= low[shift + k])
               return false;
           }
        }
      return true;
     }

public:
                     CMarketStructure(void) : m_symbol(""), m_tf(PERIOD_H4), m_fractal(2), m_depth(300),
                                              m_ema_handle(INVALID_HANDLE), m_atr_handle(INVALID_HANDLE), m_last_build(0) {}

                    ~CMarketStructure(void) { Release(); }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf, const int fractal, const int depth, const int ema_period)
     {
      m_symbol  = symbol;
      m_tf      = tf;
      m_fractal = MathMax(1, fractal);
      m_depth   = MathMax(60, depth);

      m_ema_handle = iMA(m_symbol, m_tf, ema_period, 0, MODE_EMA, PRICE_CLOSE);
      m_atr_handle = iATR(m_symbol, m_tf, 14);
      return (m_ema_handle != INVALID_HANDLE && m_atr_handle != INVALID_HANDLE);
     }

   void              Release(void)
     {
      if(m_ema_handle != INVALID_HANDLE)
        {
         IndicatorRelease(m_ema_handle);
         m_ema_handle = INVALID_HANDLE;
        }
      if(m_atr_handle != INVALID_HANDLE)
        {
         IndicatorRelease(m_atr_handle);
         m_atr_handle = INVALID_HANDLE;
        }
     }

   ENUM_TIMEFRAMES   Timeframe(void) const { return m_tf; }

   //--- rebuild the swing arrays from the latest closed bars
   bool              Refresh(void)
     {
      double high[], low[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);

      int total = CopyHigh(m_symbol, m_tf, 0, m_depth, high);
      if(total <= 0 || CopyLow(m_symbol, m_tf, 0, m_depth, low) != total)
         return false;

      ArrayResize(m_highs, 0);
      ArrayResize(m_lows, 0);

      //--- shift 0 is the forming bar, start at 1 so only closed bars are used
      for(int i = 1; i < total; i++)
        {
         if(IsSwing(high, low, i, total, true))
           {
            SwingPoint sp;
            sp.time    = iTime(m_symbol, m_tf, i);
            sp.price   = high[i];
            sp.shift   = i;
            sp.is_high = true;
            int n = ArraySize(m_highs);
            ArrayResize(m_highs, n + 1);
            m_highs[n] = sp;
           }
         if(IsSwing(high, low, i, total, false))
           {
            SwingPoint sp;
            sp.time    = iTime(m_symbol, m_tf, i);
            sp.price   = low[i];
            sp.shift   = i;
            sp.is_high = false;
            int n = ArraySize(m_lows);
            ArrayResize(m_lows, n + 1);
            m_lows[n] = sp;
           }
        }

      m_last_build = iTime(m_symbol, m_tf, 0);
      return (ArraySize(m_highs) >= 2 && ArraySize(m_lows) >= 2);
     }

   int               SwingHighCount(void) const { return ArraySize(m_highs); }
   int               SwingLowCount(void) const  { return ArraySize(m_lows); }

   //--- index 0 is the most recent swing
   bool              SwingHigh(const int index, SwingPoint &out) const
     {
      if(index < 0 || index >= ArraySize(m_highs))
         return false;
      out = m_highs[index];
      return true;
     }

   bool              SwingLow(const int index, SwingPoint &out) const
     {
      if(index < 0 || index >= ArraySize(m_lows))
         return false;
      out = m_lows[index];
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

   double            EMA(void) const
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(m_ema_handle, 0, 0, 2, buf) < 2)
         return 0.0;
      return buf[1];
     }

   //--- last closed bar broke the most recent opposing swing => break of structure
   bool              BullishBOS(void) const
     {
      if(ArraySize(m_highs) < 1)
         return false;
      double close1 = iClose(m_symbol, m_tf, 1);
      return (close1 > m_highs[0].price);
     }

   bool              BearishBOS(void) const
     {
      if(ArraySize(m_lows) < 1)
         return false;
      double close1 = iClose(m_symbol, m_tf, 1);
      return (close1 < m_lows[0].price);
     }

   //--- higher highs + higher lows / lower lows + lower highs
   bool              HigherHighsAndLows(void) const
     {
      return (ArraySize(m_highs) >= 2 && ArraySize(m_lows) >= 2 &&
              m_highs[0].price > m_highs[1].price && m_lows[0].price > m_lows[1].price);
     }

   bool              LowerHighsAndLows(void) const
     {
      return (ArraySize(m_highs) >= 2 && ArraySize(m_lows) >= 2 &&
              m_highs[0].price < m_highs[1].price && m_lows[0].price < m_lows[1].price);
     }

   //--- structural bias plus a 0..1 confidence score
   ENUM_BIAS         Bias(double &strength) const
     {
      strength = 0.0;
      if(ArraySize(m_highs) < 2 || ArraySize(m_lows) < 2)
         return BIAS_NONE;

      double close1 = iClose(m_symbol, m_tf, 1);
      double ema    = EMA();

      int bull = 0, bear = 0;
      if(HigherHighsAndLows()) bull += 2;
      if(LowerHighsAndLows())  bear += 2;
      if(BullishBOS())         bull += 1;
      if(BearishBOS())         bear += 1;
      if(ema > 0.0)
        {
         if(close1 > ema) bull += 1;
         else             bear += 1;
        }

      int total = bull + bear;
      if(total == 0)
         return BIAS_NONE;

      if(bull > bear)
        {
         strength = (double)bull / 4.0;
         if(strength > 1.0) strength = 1.0;
         return BIAS_BULL;
        }
      if(bear > bull)
        {
         strength = (double)bear / 4.0;
         if(strength > 1.0) strength = 1.0;
         return BIAS_BEAR;
        }
      return BIAS_NONE;
     }

   //--- most recent swing low below price, used as a protective stop reference
   double            LastSwingLowBelow(const double price) const
     {
      for(int i = 0; i < ArraySize(m_lows); i++)
         if(m_lows[i].price < price)
            return m_lows[i].price;
      return 0.0;
     }

   double            LastSwingHighAbove(const double price) const
     {
      for(int i = 0; i < ArraySize(m_highs); i++)
         if(m_highs[i].price > price)
            return m_highs[i].price;
      return 0.0;
     }

   //--- liquidity sweep: previous bar took out a swing then closed back inside
   bool              SweptLowsAndReversed(void) const
     {
      if(ArraySize(m_lows) < 1)
         return false;
      double low1   = iLow(m_symbol, m_tf, 1);
      double close1 = iClose(m_symbol, m_tf, 1);
      return (low1 < m_lows[0].price && close1 > m_lows[0].price);
     }

   bool              SweptHighsAndReversed(void) const
     {
      if(ArraySize(m_highs) < 1)
         return false;
      double high1  = iHigh(m_symbol, m_tf, 1);
      double close1 = iClose(m_symbol, m_tf, 1);
      return (high1 > m_highs[0].price && close1 < m_highs[0].price);
     }
  };

#endif // __GOLDSMC_STRUCTURE_MQH__
