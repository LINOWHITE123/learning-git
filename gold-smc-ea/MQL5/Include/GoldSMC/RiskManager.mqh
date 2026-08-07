//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|   Position sizing, exposure limits and the account protection     |
//|   rules that keep a losing streak from ending the account.        |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_RISK_MQH__
#define __GOLDSMC_RISK_MQH__

#include <GoldSMC/Types.mqh>

class CRiskManager
  {
private:
   string            m_symbol;
   long              m_magic;

   double            m_risk_percent;        // nominal risk per trade
   double            m_max_risk_percent;    // hard ceiling, whatever the inputs say
   double            m_daily_loss_percent;  // stop trading for the day beyond this
   double            m_max_dd_percent;      // stop trading entirely beyond this
   int               m_max_positions;
   int               m_max_trades_per_day;
   double            m_min_lot_override;

   double            m_day_start_equity;
   double            m_peak_equity;
   datetime          m_day_stamp;
   int               m_trades_today;
   int               m_losses_today;
   bool              m_halted;
   string            m_halt_reason;

   datetime          DayStart(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      dt.hour = 0;
      dt.min  = 0;
      dt.sec  = 0;
      return StructToTime(dt);
     }

public:
                     CRiskManager(void) : m_symbol(""), m_magic(0), m_risk_percent(1.0), m_max_risk_percent(5.0),
                                          m_daily_loss_percent(3.0), m_max_dd_percent(15.0), m_max_positions(1),
                                          m_max_trades_per_day(5), m_min_lot_override(0.0), m_day_start_equity(0.0),
                                          m_peak_equity(0.0), m_day_stamp(0), m_trades_today(0), m_losses_today(0),
                                          m_halted(false), m_halt_reason("") {}

   void              Init(const string symbol, const long magic, const double risk_percent, const double max_risk_percent,
                          const double daily_loss_percent, const double max_dd_percent, const int max_positions,
                          const int max_trades_per_day)
     {
      m_symbol             = symbol;
      m_magic              = magic;
      m_max_risk_percent   = MathMax(0.01, max_risk_percent);
      m_risk_percent       = MathMin(MathMax(0.01, risk_percent), m_max_risk_percent);
      m_daily_loss_percent = MathMax(0.1, daily_loss_percent);
      m_max_dd_percent     = MathMax(1.0, max_dd_percent);
      m_max_positions      = MathMax(1, max_positions);
      m_max_trades_per_day = MathMax(1, max_trades_per_day);

      double eq            = AccountInfoDouble(ACCOUNT_EQUITY);
      m_day_start_equity   = eq;
      m_peak_equity        = eq;
      m_day_stamp          = DayStart(TimeCurrent());
      m_trades_today       = 0;
      m_losses_today       = 0;
      m_halted             = false;
      m_halt_reason        = "";
     }

   double            RiskPercent(void) const { return m_risk_percent; }
   bool              Halted(void) const      { return m_halted; }
   string            HaltReason(void) const  { return m_halt_reason; }
   int               TradesToday(void) const { return m_trades_today; }

   void              RegisterTrade(void)     { m_trades_today++; }
   void              RegisterLoss(void)      { m_losses_today++; }
   int               LossesToday(void) const { return m_losses_today; }

   //--- call once per tick: rolls the daily counters and refreshes the equity peak
   void              Update(void)
     {
      datetime today = DayStart(TimeCurrent());
      if(today != m_day_stamp)
        {
         m_day_stamp        = today;
         m_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_trades_today     = 0;
         m_losses_today     = 0;
         //--- a daily stop is released with the new session, a drawdown halt is not
         if(m_halt_reason == "daily loss limit")
           {
            m_halted      = false;
            m_halt_reason = "";
           }
        }

      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > m_peak_equity)
         m_peak_equity = eq;
     }

   //--- how much of the day's allowance has already been lost
   double            DailyLossPercent(void) const
     {
      if(m_day_start_equity <= 0.0)
         return 0.0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      return (m_day_start_equity - eq) / m_day_start_equity * 100.0;
     }

   double            DrawdownPercent(void) const
     {
      if(m_peak_equity <= 0.0)
         return 0.0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      return (m_peak_equity - eq) / m_peak_equity * 100.0;
     }

   int               OpenPositions(void) const
     {
      int count = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         count++;
        }
      return count;
     }

   //--- master gate: may the EA open a new position right now?
   bool              CanTrade(string &reason)
     {
      if(m_halted)
        {
         reason = "halted: " + m_halt_reason;
         return false;
        }
      if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
        {
         reason = "trading not allowed by terminal or account";
         return false;
        }
      if(DrawdownPercent() >= m_max_dd_percent)
        {
         m_halted      = true;
         m_halt_reason = "max drawdown";
         reason        = "max drawdown reached";
         return false;
        }
      if(DailyLossPercent() >= m_daily_loss_percent)
        {
         m_halted      = true;
         m_halt_reason = "daily loss limit";
         reason        = "daily loss limit reached";
         return false;
        }
      if(OpenPositions() >= m_max_positions)
        {
         reason = "max concurrent positions";
         return false;
        }
      if(m_trades_today >= m_max_trades_per_day)
        {
         reason = "max trades per day";
         return false;
        }
      reason = "";
      return true;
     }

   //--- normalise a volume to the symbol's constraints
   double            NormalizeLots(const double lots) const
     {
      double min_lot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double max_lot  = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double lot_step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(lot_step <= 0.0)
         lot_step = 0.01;

      double v = MathFloor(lots / lot_step) * lot_step;
      if(v < min_lot)
         v = min_lot;
      if(v > max_lot)
         v = max_lot;

      int digits = (int)MathMax(0, MathRound(-MathLog10(lot_step)));
      return NormalizeDouble(v, digits);
     }

   //--- money lost per lot if the stop distance is hit
   double            LossPerLot(const double stop_distance) const
     {
      double tick_value = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick_size <= 0.0 || tick_value <= 0.0)
         return 0.0;
      return stop_distance / tick_size * tick_value;
     }

   //--- volume for a given stop distance, scaled by an optional 0..1 confidence factor
   double            LotsForRisk(const double stop_distance, const double confidence_factor, double &risk_money) const
     {
      risk_money = 0.0;
      if(stop_distance <= 0.0)
         return 0.0;

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double base    = MathMin(balance, equity);

      double pct     = m_risk_percent * MathMin(1.0, MathMax(0.1, confidence_factor));
      risk_money     = base * pct / 100.0;

      double per_lot = LossPerLot(stop_distance);
      if(per_lot <= 0.0)
         return 0.0;

      double lots = risk_money / per_lot;
      lots        = NormalizeLots(lots);

      //--- never let the rounded-up minimum lot exceed the hard risk ceiling
      double actual_risk = lots * per_lot;
      double ceiling     = base * m_max_risk_percent / 100.0;
      if(actual_risk > ceiling)
         return 0.0;

      //--- respect free margin
      double margin = 0.0;
      double price  = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      if(OrderCalcMargin(ORDER_TYPE_BUY, m_symbol, lots, price, margin))
        {
         double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         if(margin > free_margin * 0.5)
            return 0.0;
        }

      risk_money = actual_risk;
      return lots;
     }
  };

#endif // __GOLDSMC_RISK_MQH__
