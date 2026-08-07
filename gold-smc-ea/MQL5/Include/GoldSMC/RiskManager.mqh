//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|   Position sizing, exposure limits and the account protection     |
//|   rules that keep a losing streak from ending the account.        |
//|                                                                   |
//|   Risk per trade is a function of account size: the smaller the    |
//|   balance the larger the percentage, stepping down automatically   |
//|   as the account grows. Everything compounds off live equity.      |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_RISK_MQH__
#define __GOLDSMC_RISK_MQH__

#include <GoldSMC/Types.mqh>

class CRiskManager
  {
private:
   string            m_symbol;
   long              m_magic;

   //--- balance tiered risk
   ENUM_RISK_PROFILE m_profile;
   double            m_tier1_balance;       // upper bound of the smallest band
   double            m_tier2_balance;
   double            m_tier3_balance;
   double            m_risk_tier1;          // risk % used inside each band
   double            m_risk_tier2;
   double            m_risk_tier3;
   double            m_risk_tier4;          // above tier3_balance
   double            m_max_risk_percent;    // hard ceiling, whatever the inputs say
   double            m_manual_lots;         // > 0 disables auto sizing

   //--- protection limits
   double            m_daily_loss_percent;  // stop trading for the day beyond this
   double            m_max_dd_percent;      // stop trading entirely beyond this
   int               m_max_positions;
   int               m_max_trades_per_day;
   int               m_max_losses_per_day;
   int               m_max_consecutive_losses;
   double            m_daily_profit_target; // account currency, 0 disables

   //--- daily state
   double            m_day_start_equity;
   double            m_peak_equity;
   datetime          m_day_stamp;
   int               m_trades_today;
   int               m_losses_today;
   int               m_consecutive_losses;
   bool              m_target_hit;
   bool              m_halted;
   string            m_halt_reason;

   //--- lifetime stats for the dashboard
   int               m_wins_total;
   int               m_losses_total;

   datetime          DayStart(const datetime t) const
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      dt.hour = 0;
      dt.min  = 0;
      dt.sec  = 0;
      return StructToTime(dt);
     }

   //--- preset ladders; Custom keeps whatever the inputs supplied
   void              ApplyProfile(void)
     {
      switch(m_profile)
        {
         case RISK_CONSERVATIVE:
            m_risk_tier1 = 2.0;  m_risk_tier2 = 1.5;  m_risk_tier3 = 1.0;  m_risk_tier4 = 0.75;
            break;
         case RISK_BALANCED:
            m_risk_tier1 = 10.0; m_risk_tier2 = 7.0;  m_risk_tier3 = 5.0;  m_risk_tier4 = 2.5;
            break;
         case RISK_AGGRESSIVE:
            m_risk_tier1 = 25.0; m_risk_tier2 = 15.0; m_risk_tier3 = 10.0; m_risk_tier4 = 5.0;
            break;
         default:
            break;   // RISK_CUSTOM: leave the explicit inputs untouched
        }
     }

public:
                     CRiskManager(void) : m_symbol(""), m_magic(0),
                                          m_profile(RISK_BALANCED),
                                          m_tier1_balance(250.0), m_tier2_balance(500.0), m_tier3_balance(1000.0),
                                          m_risk_tier1(10.0), m_risk_tier2(7.0), m_risk_tier3(5.0), m_risk_tier4(2.5),
                                          m_max_risk_percent(10.0), m_manual_lots(0.0),
                                          m_daily_loss_percent(10.0), m_max_dd_percent(25.0), m_max_positions(1),
                                          m_max_trades_per_day(5), m_max_losses_per_day(2), m_max_consecutive_losses(3),
                                          m_daily_profit_target(0.0),
                                          m_day_start_equity(0.0), m_peak_equity(0.0), m_day_stamp(0),
                                          m_trades_today(0), m_losses_today(0), m_consecutive_losses(0),
                                          m_target_hit(false), m_halted(false), m_halt_reason(""),
                                          m_wins_total(0), m_losses_total(0) {}

   void              Init(const string symbol, const long magic)
     {
      m_symbol = symbol;
      m_magic  = magic;
      ResetState();
     }

   //--- balance tiered sizing configuration
   void              ConfigureRisk(const ENUM_RISK_PROFILE profile,
                                   const double tier1_balance, const double tier2_balance, const double tier3_balance,
                                   const double risk1, const double risk2, const double risk3, const double risk4,
                                   const double max_risk_percent, const double manual_lots)
     {
      m_profile          = profile;
      m_tier1_balance    = MathMax(1.0, tier1_balance);
      m_tier2_balance    = MathMax(m_tier1_balance, tier2_balance);
      m_tier3_balance    = MathMax(m_tier2_balance, tier3_balance);
      m_risk_tier1       = MathMax(0.01, risk1);
      m_risk_tier2       = MathMax(0.01, risk2);
      m_risk_tier3       = MathMax(0.01, risk3);
      m_risk_tier4       = MathMax(0.01, risk4);
      m_max_risk_percent = MathMax(0.01, max_risk_percent);
      m_manual_lots      = MathMax(0.0, manual_lots);
      ApplyProfile();
     }

   void              ConfigureLimits(const double daily_loss_percent, const double max_dd_percent,
                                     const int max_positions, const int max_trades_per_day,
                                     const int max_losses_per_day, const int max_consecutive_losses,
                                     const double daily_profit_target)
     {
      m_daily_loss_percent     = MathMax(0.1, daily_loss_percent);
      m_max_dd_percent         = MathMax(1.0, max_dd_percent);
      m_max_positions          = MathMax(1, max_positions);
      m_max_trades_per_day     = MathMax(1, max_trades_per_day);
      m_max_losses_per_day     = MathMax(1, max_losses_per_day);
      m_max_consecutive_losses = MathMax(1, max_consecutive_losses);
      m_daily_profit_target    = MathMax(0.0, daily_profit_target);
     }

   void              ResetState(void)
     {
      double eq            = AccountInfoDouble(ACCOUNT_EQUITY);
      m_day_start_equity   = eq;
      m_peak_equity        = eq;
      m_day_stamp          = DayStart(TimeCurrent());
      m_trades_today       = 0;
      m_losses_today       = 0;
      m_consecutive_losses = 0;
      m_target_hit         = false;
      m_halted             = false;
      m_halt_reason        = "";
     }

   //--- risk percentage for the current account size
   double            RiskPercent(void) const
     {
      double base = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
      double pct;
      if(base < m_tier1_balance)      pct = m_risk_tier1;
      else if(base < m_tier2_balance) pct = m_risk_tier2;
      else if(base < m_tier3_balance) pct = m_risk_tier3;
      else                            pct = m_risk_tier4;
      return MathMin(pct, m_max_risk_percent);
     }

   ENUM_RISK_PROFILE Profile(void) const            { return m_profile; }
   bool              Halted(void) const             { return m_halted; }
   string            HaltReason(void) const         { return m_halt_reason; }
   int               TradesToday(void) const        { return m_trades_today; }
   int               LossesToday(void) const        { return m_losses_today; }
   int               ConsecutiveLosses(void) const  { return m_consecutive_losses; }
   bool              TargetHit(void) const          { return m_target_hit; }
   double            DailyTarget(void) const        { return m_daily_profit_target; }
   double            ManualLots(void) const         { return m_manual_lots; }

   void              RegisterTrade(void)            { m_trades_today++; }

   //--- feed every closed deal here so streak protection stays accurate
   void              RegisterResult(const double profit)
     {
      if(profit < 0.0)
        {
         m_losses_today++;
         m_losses_total++;
         m_consecutive_losses++;
        }
      else
        {
         m_wins_total++;
         m_consecutive_losses = 0;
        }
     }

   double            WinRate(void) const
     {
      int total = m_wins_total + m_losses_total;
      if(total <= 0)
         return 0.0;
      return (double)m_wins_total / (double)total * 100.0;
     }

   //--- realised + floating profit since the day rolled over
   double            DailyProfit(void) const
     {
      if(m_day_start_equity <= 0.0)
         return 0.0;
      return AccountInfoDouble(ACCOUNT_EQUITY) - m_day_start_equity;
     }

   double            RemainingTarget(void) const
     {
      if(m_daily_profit_target <= 0.0)
         return 0.0;
      return MathMax(0.0, m_daily_profit_target - DailyProfit());
     }

   //--- true the moment the daily target is reached; the EA then flattens
   bool              CheckDailyTarget(void)
     {
      if(m_daily_profit_target <= 0.0 || m_target_hit)
         return false;
      if(DailyProfit() >= m_daily_profit_target)
        {
         m_target_hit  = true;
         m_halted      = true;
         m_halt_reason = "daily profit target";
         return true;
        }
      return false;
     }

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
         m_target_hit       = false;
         m_consecutive_losses = 0;
         //--- daily stops are released with the new session, a drawdown halt is not
         if(m_halt_reason != "max drawdown")
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
      if(m_consecutive_losses >= m_max_consecutive_losses)
        {
         m_halted      = true;
         m_halt_reason = "consecutive losses";
         reason        = "max consecutive losses reached";
         return false;
        }
      if(m_losses_today >= m_max_losses_per_day)
        {
         m_halted      = true;
         m_halt_reason = "daily loss count";
         reason        = "max losses per day reached";
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

      double per_lot = LossPerLot(stop_distance);
      if(per_lot <= 0.0)
         return 0.0;

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double base    = MathMin(balance, equity);

      double lots;
      if(m_manual_lots > 0.0)
        {
         lots = NormalizeLots(m_manual_lots);
        }
      else
        {
         //--- compounding: the percentage always applies to the live account size
         double pct = RiskPercent() * MathMin(1.0, MathMax(0.1, confidence_factor));
         lots       = NormalizeLots(base * pct / 100.0 / per_lot);
        }

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
