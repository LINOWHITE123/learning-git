//+------------------------------------------------------------------+
//|                                                 TradeManager.mqh |
//|   Order placement and in-trade management: break even, partial    |
//|   profit and either an ATR or a structure trail that runs the      |
//|   remainder towards the fixed reward target.                       |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_TRADEMGR_MQH__
#define __GOLDSMC_TRADEMGR_MQH__

#include <Trade/Trade.mqh>
#include <GoldSMC/Types.mqh>
#include <GoldSMC/Logger.mqh>
#include <GoldSMC/Notifier.mqh>

class CTradeManager
  {
private:
   CTrade            m_trade;
   string            m_symbol;
   long              m_magic;
   CLogger          *m_log;
   CNotifier        *m_notify;

   ENUM_TRAIL_MODE   m_trail_mode;
   double            m_reward_ratio;    // used to reconstruct 1R from the take profit
   bool              m_breakeven_enabled;
   double            m_breakeven_at_r;
   double            m_breakeven_offset_r;
   bool              m_partial_enabled;
   double            m_partial_at_r;
   double            m_partial_percent;
   double            m_trail_start_r;
   double            m_trail_atr_mult;
   double            m_trail_struct_buffer_atr;   // ATR multiple kept behind the swing

   double            Point(void) const  { return SymbolInfoDouble(m_symbol, SYMBOL_POINT); }
   int               Digits_(void) const { return (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS); }

   double            MinStopDistance(void) const
     {
      long stops_level = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      long freeze      = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      long lvl         = MathMax(stops_level, freeze);
      double spread    = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD) * Point();
      return MathMax(lvl * Point(), spread * 1.5);
     }

public:
                     CTradeManager(void) : m_symbol(""), m_magic(0), m_log(NULL), m_notify(NULL),
                                           m_trail_mode(TRAIL_ATR), m_reward_ratio(4.0),
                                           m_breakeven_enabled(true), m_breakeven_at_r(1.0), m_breakeven_offset_r(0.1),
                                           m_partial_enabled(true), m_partial_at_r(1.0), m_partial_percent(30.0),
                                           m_trail_start_r(2.0), m_trail_atr_mult(1.5), m_trail_struct_buffer_atr(0.5) {}

   void              Init(const string symbol, const long magic, const int slippage_points, CLogger *log, CNotifier *notify)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_log    = log;
      m_notify = notify;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints(slippage_points);
      m_trade.SetTypeFillingBySymbol(symbol);
      m_trade.SetAsyncMode(false);
     }

   void              ConfigureManagement(const double reward_ratio,
                                         const bool be_enabled, const double be_at_r, const double be_offset_r,
                                         const bool partial_enabled, const double partial_at_r, const double partial_pct,
                                         const ENUM_TRAIL_MODE trail_mode, const double trail_start_r,
                                         const double trail_atr_mult, const double trail_struct_buffer_atr)
     {
      m_reward_ratio       = MathMax(0.5, reward_ratio);
      m_breakeven_enabled  = be_enabled;
      m_breakeven_at_r     = MathMax(0.1, be_at_r);
      m_breakeven_offset_r = MathMax(0.0, be_offset_r);
      m_partial_enabled    = partial_enabled;
      m_partial_at_r       = MathMax(0.1, partial_at_r);
      m_partial_percent    = MathMin(90.0, MathMax(0.0, partial_pct));
      m_trail_mode         = trail_mode;
      m_trail_start_r      = MathMax(0.1, trail_start_r);
      m_trail_atr_mult     = MathMax(0.2, trail_atr_mult);
      m_trail_struct_buffer_atr = MathMax(0.0, trail_struct_buffer_atr);
     }

   //--- validate distances then send the market order
   bool              Execute(const TradePlan &plan, const string comment)
     {
      if(!plan.valid || plan.lots <= 0.0)
         return false;

      double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double price = (plan.direction == ORDER_TYPE_BUY ? ask : bid);
      double min_dist = MinStopDistance();

      double sl = NormalizeDouble(plan.sl, Digits_());
      double tp = NormalizeDouble(plan.tp, Digits_());

      if(plan.direction == ORDER_TYPE_BUY)
        {
         if(price - sl < min_dist || tp - price < min_dist)
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("order rejected locally: stops too close (sl=%.2f tp=%.2f price=%.2f min=%.2f)",
                                       sl, tp, price, min_dist));
            return false;
           }
         if(!m_trade.Buy(plan.lots, m_symbol, 0.0, sl, tp, comment))
           {
            if(m_log != NULL)
               m_log.Error(StringFormat("buy failed: retcode=%d %s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription()));
            return false;
           }
        }
      else
        {
         if(sl - price < min_dist || price - tp < min_dist)
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("order rejected locally: stops too close (sl=%.2f tp=%.2f price=%.2f min=%.2f)",
                                       sl, tp, price, min_dist));
            return false;
           }
         if(!m_trade.Sell(plan.lots, m_symbol, 0.0, sl, tp, comment))
           {
            if(m_log != NULL)
               m_log.Error(StringFormat("sell failed: retcode=%d %s", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription()));
            return false;
           }
        }

      string summary = StringFormat("%s %.2f lots @ %.2f sl=%.2f tp=%.2f risk=%.2f rr=%.1f | %s",
                                    (plan.direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                                    plan.lots, price, sl, tp, plan.risk_money, plan.rr, plan.reason);
      if(m_log != NULL)
         m_log.Info("opened " + summary);
      if(m_notify != NULL)
         m_notify.Send("trade opened", summary);
      return true;
     }

   //--- Run break even / partial / trail logic across the EA's own positions.
   //--- struct_low / struct_high are the latest execution timeframe swings and
   //--- are only used when the trail mode is TRAIL_STRUCTURE.
   void              ManageOpenPositions(const double atr, const double struct_low, const double struct_high)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;

         long   type    = PositionGetInteger(POSITION_TYPE);
         double open    = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl      = PositionGetDouble(POSITION_SL);
         double tp      = PositionGetDouble(POSITION_TP);
         double volume  = PositionGetDouble(POSITION_VOLUME);
         double current = (type == POSITION_TYPE_BUY ? SymbolInfoDouble(m_symbol, SYMBOL_BID)
                                                     : SymbolInfoDouble(m_symbol, SYMBOL_ASK));

         //--- reconstruct the initial risk from the take profit (placed at a fixed R multiple)
         double risk = 0.0;
         if(tp > 0.0)
            risk = MathAbs(tp - open) / m_reward_ratio;
         if(risk <= 0.0 && sl > 0.0)
            risk = MathAbs(open - sl);
         if(risk <= 0.0)
            continue;

         double r_now = (type == POSITION_TYPE_BUY ? (current - open) : (open - current)) / risk;
         double min_dist = MinStopDistance();

         //--- partial profit
         if(m_partial_enabled && m_partial_percent > 0.0 && r_now >= m_partial_at_r)
           {
            double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
            double min_lot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
            if(step <= 0.0)
               step = 0.01;
            double close_vol = MathFloor(volume * m_partial_percent / 100.0 / step) * step;
            if(close_vol >= min_lot && volume - close_vol >= min_lot)
              {
               if(m_trade.PositionClosePartial(ticket, close_vol))
                 {
                  if(m_log != NULL)
                     m_log.Info(StringFormat("partial close %.2f lots at %.2fR on #%s", close_vol, r_now, IntegerToString((long)ticket)));
                  if(!PositionSelectByTicket(ticket))
                     continue;
                  volume = PositionGetDouble(POSITION_VOLUME);
                 }
              }
           }

         //--- break even
         if(m_breakeven_enabled && r_now >= m_breakeven_at_r)
           {
            double be = (type == POSITION_TYPE_BUY ? open + m_breakeven_offset_r * risk
                                                   : open - m_breakeven_offset_r * risk);
            be = NormalizeDouble(be, Digits_());
            bool improves = (type == POSITION_TYPE_BUY ? (be > sl + Point()) : (sl == 0.0 || be < sl - Point()));
            bool valid    = (type == POSITION_TYPE_BUY ? (current - be > min_dist) : (be - current > min_dist));
            if(improves && valid)
              {
               if(m_trade.PositionModify(ticket, be, tp))
                 {
                  sl = be;
                  if(m_log != NULL)
                     m_log.Info(StringFormat("moved #%s to break even at %.2f", IntegerToString((long)ticket), be));
                 }
              }
           }

         //--- trail once the trade is well in profit
         if(m_trail_mode != TRAIL_OFF && r_now >= m_trail_start_r)
           {
            double trail = 0.0;
            if(m_trail_mode == TRAIL_ATR)
              {
               if(atr <= 0.0)
                  continue;
               trail = (type == POSITION_TYPE_BUY ? current - m_trail_atr_mult * atr
                                                  : current + m_trail_atr_mult * atr);
              }
            else
              {
               //--- structure trail: sit behind the last swing that held
               double buffer = m_trail_struct_buffer_atr * atr;
               if(type == POSITION_TYPE_BUY)
                 {
                  if(struct_low <= 0.0)
                     continue;
                  trail = struct_low - buffer;
                 }
               else
                 {
                  if(struct_high <= 0.0)
                     continue;
                  trail = struct_high + buffer;
                 }
              }
            trail = NormalizeDouble(trail, Digits_());
            bool improves = (type == POSITION_TYPE_BUY ? (trail > sl + Point()) : (sl == 0.0 || trail < sl - Point()));
            bool valid    = (type == POSITION_TYPE_BUY ? (current - trail > min_dist) : (trail - current > min_dist));
            if(improves && valid)
              {
               if(m_trade.PositionModify(ticket, trail, tp))
                  if(m_log != NULL)
                     m_log.Debug(StringFormat("trailed #%s stop to %.2f", IntegerToString((long)ticket), trail));
              }
           }
        }
     }

   void              CloseAll(const string reason)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         if(m_trade.PositionClose(ticket))
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("closed #%s: %s", IntegerToString((long)ticket), reason));
            if(m_notify != NULL)
               m_notify.Send("trade closed", StringFormat("#%s %s", IntegerToString((long)ticket), reason));
           }
        }
     }

   //--- remove any of the EA's resting orders, used when the day is closed out
   void              CancelPendingOrders(const string reason)
     {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;
         if(OrderGetString(ORDER_SYMBOL) != m_symbol)
            continue;
         if(OrderGetInteger(ORDER_MAGIC) != m_magic)
            continue;
         if(m_trade.OrderDelete(ticket) && m_log != NULL)
            m_log.Warn(StringFormat("cancelled order #%s: %s", IntegerToString((long)ticket), reason));
        }
     }
  };

#endif // __GOLDSMC_TRADEMGR_MQH__
