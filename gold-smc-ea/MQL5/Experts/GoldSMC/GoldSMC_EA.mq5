//+------------------------------------------------------------------+
//|                                                   GoldSMC_EA.mq5 |
//|   Multi timeframe smart-money expert advisor for XAUUSD.          |
//|                                                                   |
//|   H4 decides the bias, H1 must agree, M15 provides the entry at   |
//|   an unmitigated demand / supply zone. Every trade is sized from  |
//|   account risk, protected by a structural stop and targeted at a  |
//|   fixed reward multiple (1:4 by default).                         |
//+------------------------------------------------------------------+
#property copyright "GoldSMC"
#property link      "https://github.com"
#property version   "1.00"
#property description "Multi timeframe gold EA: H4 bias, H1 alignment, M15 demand/supply entries, fixed R:R, risk based sizing."

#include <GoldSMC/Types.mqh>
#include <GoldSMC/Logger.mqh>
#include <GoldSMC/MarketStructure.mqh>
#include <GoldSMC/Zones.mqh>
#include <GoldSMC/RiskManager.mqh>
#include <GoldSMC/NewsFilter.mqh>
#include <GoldSMC/Intel.mqh>
#include <GoldSMC/TradeManager.mqh>

//--- how the entry timeframe must confirm the reaction inside a zone
enum ENUM_CONFIRM_MODE
  {
   CONFIRM_NONE = 0,      // trade the touch
   CONFIRM_CANDLE = 1,    // rejection wick or engulfing candle
   CONFIRM_STRUCTURE = 2  // candle confirmation plus a micro shift in structure
  };

//==================================================================
input group "=== Instrument ==="
input string  InpSymbolOverride     = "";        // Symbol to trade (empty = chart symbol)
input long    InpMagic              = 20250806;  // Magic number
input int     InpSlippagePoints     = 30;        // Max slippage (points)
input double  InpMaxSpreadPoints    = 350;       // Max spread to trade (points, 0 = ignore)

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpHTF        = PERIOD_H4; // Higher timeframe (bias)
input ENUM_TIMEFRAMES InpMTF        = PERIOD_H1; // Alignment timeframe
input ENUM_TIMEFRAMES InpLTF        = PERIOD_M15;// Entry timeframe
input bool    InpRequireMtfAlign    = true;      // Require alignment timeframe to agree
input double  InpMinHtfStrength     = 0.5;       // Min HTF bias strength (0..1)

input group "=== Structure & zones ==="
input int     InpFractalSize        = 2;         // Bars each side of a swing point
input int     InpHtfBars            = 300;       // Bars analysed on the higher timeframes
input int     InpLtfBars            = 500;       // Bars analysed on the entry timeframe
input int     InpBiasEmaPeriod      = 50;        // EMA period used in the bias score
input double  InpImpulseAtr         = 1.3;       // Impulse leaving a zone (x ATR)
input int     InpMaxZoneTouches     = 1;         // Discard a zone after this many taps
input bool    InpUseFvg             = true;      // Also treat fair value gaps as areas of interest
input double  InpZoneProximityAtr   = 1.0;       // Max distance from price to a zone (x ATR)
input ENUM_CONFIRM_MODE InpConfirm  = CONFIRM_CANDLE; // Entry confirmation

input group "=== Risk (defaults are deliberately conservative) ==="
input double  InpRiskPercent        = 1.0;       // Risk per trade (% of balance)
input double  InpMaxRiskPercent     = 5.0;       // Hard ceiling on risk per trade (%)
input bool    InpScaleRiskByQuality = true;      // Scale risk down on lower quality setups
input double  InpDailyLossPercent   = 3.0;       // Stop for the day after this loss (%)
input double  InpMaxDrawdownPercent = 15.0;      // Halt the EA after this equity drawdown (%)
input int     InpMaxPositions       = 1;         // Max concurrent positions
input int     InpMaxTradesPerDay    = 3;         // Max new trades per day
input int     InpMaxLossesPerDay    = 2;         // Stop after this many losers in a day

input group "=== Targets & stops ==="
input double  InpRewardRatio        = 4.0;       // Reward to risk ratio (1:R)
input double  InpStopBufferAtr      = 0.25;      // Stop distance beyond the zone (x ATR)
input double  InpMinStopAtr         = 0.5;       // Min stop distance (x ATR)
input double  InpMaxStopAtr         = 3.0;       // Max stop distance (x ATR)

input group "=== Trade management ==="
input bool    InpUseBreakEven       = true;      // Move to break even
input double  InpBreakEvenAtR       = 1.0;       // Break even trigger (R)
input double  InpBreakEvenOffsetR   = 0.1;       // Break even offset (R)
input bool    InpUsePartial         = true;      // Take partial profit
input double  InpPartialAtR         = 1.0;       // Partial trigger (R)
input double  InpPartialPercent     = 30.0;      // Percent of the position to close
input bool    InpUseTrailing        = true;      // Trail the remainder
input double  InpTrailStartR        = 2.0;       // Trail start (R)
input double  InpTrailAtrMult       = 1.5;       // Trail distance (x ATR)

input group "=== Sessions ==="
input bool    InpUseSessionFilter   = true;      // Restrict trading hours (server time)
input int     InpSessionStartHour   = 7;         // Session start hour
input int     InpSessionEndHour     = 20;        // Session end hour
input bool    InpTradeMonday        = true;
input bool    InpTradeFriday        = true;
input bool    InpCloseBeforeWeekend = true;      // Flatten late on Friday
input int     InpFridayCloseHour    = 20;        // Friday flatten hour

input group "=== News ==="
input bool    InpUseNewsFilter      = true;      // Block trading around high impact news
input int     InpNewsMinutesBefore  = 30;        // Blackout before an event (minutes)
input int     InpNewsMinutesAfter   = 30;        // Blackout after an event (minutes)
input int     InpNewsMinImportance  = 3;         // 1 low, 2 moderate, 3 high
input string  InpNewsCurrencies     = "USD,XAU"; // Currencies to watch
input string  InpNewsCsvFallback    = "GoldSMC_calendar.csv"; // CSV fallback in MQL5/Files

input group "=== External intelligence (neural model + sentiment) ==="
input bool    InpUseIntel           = false;     // Consult the external service
input ENUM_FILTER_MODE InpIntelMode = FILTER_SOFT; // How a disagreement is handled
input bool    InpIntelUseHttp       = false;     // true = HTTP, false = JSON file in MQL5/Files
input string  InpIntelUrl           = "http://127.0.0.1:8711/signal"; // Service endpoint
input string  InpIntelFile          = "GoldSMC_intel.json";           // Snapshot file
input int     InpIntelMaxAgeSec     = 1800;      // Reject data older than this
input double  InpIntelSentimentW    = 0.4;       // Weight of sentiment vs model score
input double  InpIntelMinAgreement  = 0.15;      // Score magnitude needed to count as agreement

input group "=== Diagnostics ==="
input bool    InpShowDashboard      = true;      // Draw the on-chart dashboard
input ENUM_LOG_LEVEL InpLogLevel    = LOG_INFO;  // Journal verbosity
input bool    InpLogToFile          = false;     // Also write a CSV log
input string  InpLogFile            = "GoldSMC_log.csv";
input string  InpTradeComment       = "GoldSMC";

//==================================================================
CLogger           g_log;
CMarketStructure  g_htf;
CMarketStructure  g_mtf;
CMarketStructure  g_ltf;
CZoneEngine       g_zones;
CRiskManager      g_risk;
CNewsFilter       g_news;
CIntelClient      g_intel;
CTradeManager     g_trades;

string            g_symbol   = "";
datetime          g_last_bar = 0;
string            g_status   = "initialising";
BiasSnapshot      g_bias;
IntelSnapshot     g_intel_snapshot;
int               g_deals_seen = 0;

//+------------------------------------------------------------------+
//| Resolve a tradable symbol name, tolerating broker suffixes        |
//+------------------------------------------------------------------+
string ResolveSymbol(const string requested)
  {
   string candidate = (StringLen(requested) > 0 ? requested : _Symbol);
   if(SymbolSelect(candidate, true))
      return candidate;

   //--- try to find the same root with whatever suffix the broker uses
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      if(StringFind(name, candidate) == 0)
        {
         if(SymbolSelect(name, true))
            return name;
        }
     }
   return _Symbol;
  }

//+------------------------------------------------------------------+
//| Session / weekday gate                                            |
//+------------------------------------------------------------------+
bool SessionOpen(string &reason)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
     {
      reason = "weekend";
      return false;
     }
   if(!InpTradeMonday && dt.day_of_week == 1)
     {
      reason = "monday disabled";
      return false;
     }
   if(!InpTradeFriday && dt.day_of_week == 5)
     {
      reason = "friday disabled";
      return false;
     }
   if(InpUseSessionFilter)
     {
      if(InpSessionStartHour <= InpSessionEndHour)
        {
         if(dt.hour < InpSessionStartHour || dt.hour >= InpSessionEndHour)
           {
            reason = "outside session";
            return false;
           }
        }
      else
        {
         //--- session wraps midnight
         if(dt.hour < InpSessionStartHour && dt.hour >= InpSessionEndHour)
           {
            reason = "outside session";
            return false;
           }
        }
     }
   reason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Spread gate                                                       |
//+------------------------------------------------------------------+
bool SpreadAcceptable(double &spread_points)
  {
   spread_points = (double)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPoints <= 0.0)
      return true;
   return (spread_points <= InpMaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| Candle confirmation on the entry timeframe                        |
//+------------------------------------------------------------------+
bool CandleConfirms(const bool bullish)
  {
   double o1 = iOpen(g_symbol, InpLTF, 1),  c1 = iClose(g_symbol, InpLTF, 1);
   double h1 = iHigh(g_symbol, InpLTF, 1),  l1 = iLow(g_symbol, InpLTF, 1);
   double o2 = iOpen(g_symbol, InpLTF, 2),  c2 = iClose(g_symbol, InpLTF, 2);

   double range = h1 - l1;
   if(range <= 0.0)
      return false;

   double body       = MathAbs(c1 - o1);
   double lower_wick = MathMin(o1, c1) - l1;
   double upper_wick = h1 - MathMax(o1, c1);

   if(bullish)
     {
      bool engulfing = (c1 > o1 && c2 < o2 && c1 >= o2 && o1 <= c2);
      bool rejection = (lower_wick >= 0.5 * range && c1 > o1);
      bool momentum  = (c1 > o1 && body >= 0.6 * range);
      return (engulfing || rejection || momentum);
     }

   bool engulfing = (c1 < o1 && c2 > o2 && c1 <= o2 && o1 >= c2);
   bool rejection = (upper_wick >= 0.5 * range && c1 < o1);
   bool momentum  = (c1 < o1 && body >= 0.6 * range);
   return (engulfing || rejection || momentum);
  }

//+------------------------------------------------------------------+
//| Micro structure shift on the entry timeframe                      |
//+------------------------------------------------------------------+
bool StructureConfirms(const bool bullish)
  {
   if(bullish)
      return (g_ltf.BullishBOS() || g_ltf.SweptLowsAndReversed());
   return (g_ltf.BearishBOS() || g_ltf.SweptHighsAndReversed());
  }

//+------------------------------------------------------------------+
//| Build the multi timeframe bias                                    |
//+------------------------------------------------------------------+
bool BuildBias(BiasSnapshot &out)
  {
   out.htf          = BIAS_NONE;
   out.mtf          = BIAS_NONE;
   out.htf_strength = 0.0;
   out.stamp        = TimeCurrent();

   if(!g_htf.Refresh() || !g_mtf.Refresh())
      return false;

   double s_htf = 0.0, s_mtf = 0.0;
   out.htf          = g_htf.Bias(s_htf);
   out.mtf          = g_mtf.Bias(s_mtf);
   out.htf_strength = s_htf;
   return true;
  }

//+------------------------------------------------------------------+
//| Quality score of a candidate setup, 0..1                          |
//+------------------------------------------------------------------+
double SetupQuality(const Zone &zone, const double intel_score, const bool bullish)
  {
   double q = 0.35;

   q += 0.25 * g_bias.htf_strength;

   if((bullish && g_bias.mtf == BIAS_BULL) || (!bullish && g_bias.mtf == BIAS_BEAR))
      q += 0.15;

   if(zone.touches == 0)
      q += 0.10;

   if(zone.type == ZONE_DEMAND || zone.type == ZONE_SUPPLY)
      q += 0.05;

   if(StructureConfirms(bullish))
      q += 0.05;

   if(g_intel_snapshot.valid)
     {
      double aligned = (bullish ? intel_score : -intel_score);
      q += 0.10 * MathMax(-1.0, MathMin(1.0, aligned));
     }

   return MathMax(0.1, MathMin(1.0, q));
  }

//+------------------------------------------------------------------+
//| Assemble a trade plan from a zone                                 |
//+------------------------------------------------------------------+
bool BuildPlan(const bool bullish, const Zone &zone, const double atr, const double intel_score, TradePlan &plan)
  {
   plan.valid = false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double entry = (bullish ? ask : bid);
   double buffer = InpStopBufferAtr * atr;

   double sl;
   if(bullish)
     {
      sl = zone.lower - buffer;
      double swing = g_ltf.LastSwingLowBelow(entry);
      if(swing > 0.0 && swing - buffer < sl)
         sl = swing - buffer;
     }
   else
     {
      sl = zone.upper + buffer;
      double swing = g_ltf.LastSwingHighAbove(entry);
      if(swing > 0.0 && swing + buffer > sl)
         sl = swing + buffer;
     }

   double stop_distance = MathAbs(entry - sl);
   if(stop_distance < InpMinStopAtr * atr)
     {
      stop_distance = InpMinStopAtr * atr;
      sl = (bullish ? entry - stop_distance : entry + stop_distance);
     }
   if(stop_distance > InpMaxStopAtr * atr)
     {
      g_status = "stop too wide for this zone";
      return false;
     }

   double tp = (bullish ? entry + InpRewardRatio * stop_distance
                        : entry - InpRewardRatio * stop_distance);

   double quality = SetupQuality(zone, intel_score, bullish);
   double factor  = (InpScaleRiskByQuality ? quality : 1.0);

   double risk_money = 0.0;
   double lots = g_risk.LotsForRisk(stop_distance, factor, risk_money);
   if(lots <= 0.0)
     {
      g_status = "position size rejected (risk ceiling or margin)";
      return false;
     }

   plan.valid      = true;
   plan.direction  = (bullish ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   plan.entry      = entry;
   plan.sl         = sl;
   plan.tp         = tp;
   plan.lots       = lots;
   plan.risk_money = risk_money;
   plan.rr         = InpRewardRatio;
   plan.reason     = StringFormat("%s zone %.2f-%.2f touches=%d quality=%.2f htf=%.2f intel=%.2f",
                                  (bullish ? "demand" : "supply"), zone.lower, zone.upper,
                                  zone.touches, quality, g_bias.htf_strength, intel_score);
   return true;
  }

//+------------------------------------------------------------------+
//| Core decision, evaluated once per closed entry-timeframe bar      |
//+------------------------------------------------------------------+
void EvaluateSetup(void)
  {
   string reason;

   if(!g_risk.CanTrade(reason))
     {
      g_status = "no trade: " + reason;
      return;
     }
   if(InpMaxLossesPerDay > 0 && g_risk.LossesToday() >= InpMaxLossesPerDay)
     {
      g_status = "no trade: daily loss streak limit";
      return;
     }
   if(!SessionOpen(reason))
     {
      g_status = "no trade: " + reason;
      return;
     }

   double spread_points;
   if(!SpreadAcceptable(spread_points))
     {
      g_status = StringFormat("no trade: spread %.0f > %.0f", spread_points, InpMaxSpreadPoints);
      return;
     }

   if(InpUseNewsFilter && g_news.InBlackout())
     {
      g_status = "no trade: news blackout " + g_news.ActiveEvent();
      return;
     }

   if(!BuildBias(g_bias))
     {
      g_status = "no trade: not enough history for bias";
      return;
     }
   if(g_bias.htf == BIAS_NONE)
     {
      g_status = "no trade: higher timeframe has no clear bias";
      return;
     }
   if(g_bias.htf_strength < InpMinHtfStrength)
     {
      g_status = StringFormat("no trade: htf strength %.2f < %.2f", g_bias.htf_strength, InpMinHtfStrength);
      return;
     }
   if(InpRequireMtfAlign && g_bias.mtf != g_bias.htf)
     {
      g_status = "no trade: alignment timeframe disagrees";
      return;
     }

   bool bullish = (g_bias.htf == BIAS_BULL);

   //--- external intelligence layer
   g_intel_snapshot = g_intel.Poll(g_symbol);
   double intel_score = CIntelClient::Score(g_intel_snapshot, InpIntelSentimentW);

   if(InpUseIntel && g_intel_snapshot.valid)
     {
      if(g_intel_snapshot.news_blackout && InpIntelMode != FILTER_OFF)
        {
         g_status = "no trade: intel reports a news blackout";
         return;
        }
      double aligned = (bullish ? intel_score : -intel_score);
      if(InpIntelMode == FILTER_STRICT && aligned < InpIntelMinAgreement)
        {
         g_status = StringFormat("no trade: intel disagrees (%.2f)", intel_score);
         return;
        }
     }

   if(!g_ltf.Refresh())
     {
      g_status = "no trade: entry timeframe history unavailable";
      return;
     }
   if(!g_zones.Refresh())
     {
      g_status = "no trade: no live zones";
      return;
     }

   double atr = g_zones.ATR();
   if(atr <= 0.0)
     {
      g_status = "no trade: ATR unavailable";
      return;
     }

   double price = (bullish ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID));
   double max_distance = InpZoneProximityAtr * atr;

   Zone zone;
   bool found = (bullish ? g_zones.NearestDemand(price, max_distance, zone)
                         : g_zones.NearestSupply(price, max_distance, zone));
   if(!found)
     {
      g_status = "waiting: price is not at an area of interest";
      return;
     }

   //--- price must have actually traded into the zone on the last closed bar
   double last_low  = iLow(g_symbol, InpLTF, 1);
   double last_high = iHigh(g_symbol, InpLTF, 1);
   bool tapped = (last_low <= zone.upper && last_high >= zone.lower);
   if(!tapped)
     {
      g_status = "waiting: zone identified but not tapped";
      return;
     }

   if(InpConfirm >= CONFIRM_CANDLE && !CandleConfirms(bullish))
     {
      g_status = "waiting: no candle confirmation in the zone";
      return;
     }
   if(InpConfirm == CONFIRM_STRUCTURE && !StructureConfirms(bullish))
     {
      g_status = "waiting: no micro structure shift";
      return;
     }

   TradePlan plan;
   if(!BuildPlan(bullish, zone, atr, intel_score, plan))
      return;

   //--- soft intel mode halves the size instead of vetoing the trade
   if(InpUseIntel && InpIntelMode == FILTER_SOFT && g_intel_snapshot.valid)
     {
      double aligned = (bullish ? intel_score : -intel_score);
      if(aligned < InpIntelMinAgreement)
        {
         double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
         double min_lot = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
         if(step <= 0.0)
            step = 0.01;
         double reduced = MathFloor(plan.lots * 0.5 / step) * step;
         if(reduced >= min_lot)
           {
            plan.lots = reduced;
            plan.reason += " | halved: intel disagrees";
           }
        }
     }

   if(g_trades.Execute(plan, InpTradeComment))
     {
      g_risk.RegisterTrade();
      g_status = StringFormat("in trade: %s %.2f lots", (plan.direction == ORDER_TYPE_BUY ? "BUY" : "SELL"), plan.lots);
     }
   else
      g_status = "order send failed, see journal";
  }

//+------------------------------------------------------------------+
//| Count today's closed losers so the streak limit can react         |
//+------------------------------------------------------------------+
void SyncClosedDeals(void)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime from = StructToTime(dt);

   if(!HistorySelect(from, TimeCurrent()))
      return;

   int total = HistoryDealsTotal();
   if(total == g_deals_seen)
      return;

   int losses = 0;
   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != g_symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      if(profit < 0.0)
         losses++;
     }

   g_deals_seen = total;
   while(g_risk.LossesToday() < losses)
      g_risk.RegisterLoss();
  }

//+------------------------------------------------------------------+
//| On-chart dashboard                                                |
//+------------------------------------------------------------------+
void DrawDashboard(void)
  {
   if(!InpShowDashboard)
      return;

   string bias_txt = (g_bias.htf == BIAS_BULL ? "BULLISH" : (g_bias.htf == BIAS_BEAR ? "BEARISH" : "NONE"));
   string mtf_txt  = (g_bias.mtf == BIAS_BULL ? "BULLISH" : (g_bias.mtf == BIAS_BEAR ? "BEARISH" : "NONE"));
   string intel_txt = "off";
   if(InpUseIntel)
      intel_txt = (g_intel_snapshot.valid
                   ? StringFormat("sent %.2f model %.2f conf %.2f", g_intel_snapshot.sentiment,
                                  g_intel_snapshot.model_score, g_intel_snapshot.confidence)
                   : "unavailable (" + g_intel.LastError() + ")");

   string news_txt = "off";
   if(InpUseNewsFilter)
     {
      int mins = g_news.MinutesToNextEvent();
      news_txt = (mins >= 0 ? StringFormat("next event in %d min (%d loaded)", mins, g_news.EventCount())
                            : StringFormat("no upcoming events (%d loaded)", g_news.EventCount()));
     }

   string text = StringFormat(
      "GoldSMC  %s\n"
      "-----------------------------\n"
      "%s bias: %s (%.2f)   %s: %s\n"
      "Zones live: %d   ATR(%s): %.2f\n"
      "Risk/trade: %.2f%%   R:R 1:%.1f\n"
      "Equity: %.2f   DD: %.2f%%   Day P/L: %.2f%%\n"
      "Trades today: %d   Losses today: %d\n"
      "News: %s\n"
      "Intel: %s\n"
      "Status: %s",
      g_symbol,
      EnumToString(InpHTF), bias_txt, g_bias.htf_strength, EnumToString(InpMTF), mtf_txt,
      g_zones.Count(), EnumToString(InpLTF), g_zones.ATR(),
      g_risk.RiskPercent(), InpRewardRatio,
      AccountInfoDouble(ACCOUNT_EQUITY), g_risk.DrawdownPercent(), -g_risk.DailyLossPercent(),
      g_risk.TradesToday(), g_risk.LossesToday(),
      news_txt, intel_txt, g_status);

   Comment(text);
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_symbol = ResolveSymbol(InpSymbolOverride);

   g_log.Init("GoldSMC", InpLogLevel, InpLogToFile, InpLogFile);
   g_log.Info("initialising on " + g_symbol);

   if(InpRewardRatio < 1.0)
     {
      g_log.Error("reward ratio must be at least 1.0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPercent > InpMaxRiskPercent)
      g_log.Warn(StringFormat("risk %.2f%% capped to the ceiling %.2f%%", InpRiskPercent, InpMaxRiskPercent));
   if(InpRiskPercent >= 10.0)
      g_log.Warn("risk per trade is very high: three consecutive losses will do severe damage to the account");

   if(!g_htf.Init(g_symbol, InpHTF, InpFractalSize, InpHtfBars, InpBiasEmaPeriod) ||
      !g_mtf.Init(g_symbol, InpMTF, InpFractalSize, InpHtfBars, InpBiasEmaPeriod) ||
      !g_ltf.Init(g_symbol, InpLTF, InpFractalSize, InpLtfBars, InpBiasEmaPeriod))
     {
      g_log.Error("failed to create structure indicators");
      return INIT_FAILED;
     }

   if(!g_zones.Init(g_symbol, InpLTF, InpLtfBars, InpImpulseAtr, InpMaxZoneTouches, InpUseFvg))
     {
      g_log.Error("failed to create the zone engine");
      return INIT_FAILED;
     }

   g_risk.Init(g_symbol, InpMagic, InpRiskPercent, InpMaxRiskPercent, InpDailyLossPercent,
               InpMaxDrawdownPercent, InpMaxPositions, InpMaxTradesPerDay);

   g_news.Init(InpUseNewsFilter, InpNewsMinutesBefore, InpNewsMinutesAfter, InpNewsMinImportance,
               InpNewsCurrencies, InpNewsCsvFallback);

   g_intel.Init(InpUseIntel, InpIntelUseHttp, InpIntelUrl, InpIntelFile, InpIntelMaxAgeSec, 3000);

   g_trades.Init(g_symbol, InpMagic, InpSlippagePoints, GetPointer(g_log));
   g_trades.ConfigureManagement(InpUseBreakEven, InpBreakEvenAtR, InpBreakEvenOffsetR,
                                InpUsePartial, InpPartialAtR, InpPartialPercent,
                                InpUseTrailing, InpTrailStartR, InpTrailAtrMult);

   g_bias.htf          = BIAS_NONE;
   g_bias.mtf          = BIAS_NONE;
   g_bias.htf_strength = 0.0;
   g_intel_snapshot.valid = false;

   g_status = "ready";
   EventSetTimer(60);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
   g_htf.Release();
   g_mtf.Release();
   g_ltf.Release();
   g_zones.Release();
   g_log.Info("stopped, reason " + IntegerToString(reason));
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   g_risk.Update();
   SyncClosedDeals();

   double atr = g_zones.ATR();
   g_trades.ManageOpenPositions(atr);

   //--- optional Friday flatten
   if(InpCloseBeforeWeekend)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
        {
         g_trades.CloseAll("weekend flatten");
         g_status = "flat for the weekend";
         DrawDashboard();
         return;
        }
     }

   //--- decisions are taken once per closed entry-timeframe bar
   datetime bar = iTime(g_symbol, InpLTF, 0);
   if(bar == g_last_bar)
      return;
   g_last_bar = bar;

   EvaluateSetup();
   DrawDashboard();
  }

//+------------------------------------------------------------------+
void OnTimer(void)
  {
   if(InpUseNewsFilter)
      g_news.Refresh();
   DrawDashboard();
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.symbol != g_symbol)
      return;
   SyncClosedDeals();
  }

//+------------------------------------------------------------------+
double OnTester(void)
  {
   //--- optimise for a risk adjusted result rather than raw profit
   double profit  = TesterStatistics(STAT_PROFIT);
   double dd      = TesterStatistics(STAT_EQUITYDD_PERCENT);
   double trades  = TesterStatistics(STAT_TRADES);
   double pf      = TesterStatistics(STAT_PROFIT_FACTOR);

   if(trades < 30.0)
      return 0.0;
   if(dd <= 0.0)
      dd = 0.1;

   double score = (profit / dd) * MathMin(pf, 5.0);
   return score;
  }
//+------------------------------------------------------------------+
