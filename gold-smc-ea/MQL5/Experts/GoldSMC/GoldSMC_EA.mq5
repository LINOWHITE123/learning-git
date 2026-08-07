//+------------------------------------------------------------------+
//|                                                   GoldSMC_EA.mq5 |
//|   Institutional style multi timeframe expert advisor for XAUUSD.  |
//|                                                                   |
//|   Flow, top down:                                                 |
//|     H4  - primary trend from market structure (swings, BOS/CHoCH) |
//|     H1  - must confirm H4, plus liquidity and premium/discount    |
//|     M15 - locates the setup: sweep, BOS/CHoCH, order block / FVG,  |
//|           the zone is then stored and armed                       |
//|     M5  - execution only: price must retrace into the stored M15   |
//|           zone, print a fresh BOS/CHoCH, confirm momentum and pass |
//|           the spread / volatility gates                            |
//|                                                                   |
//|   The EA never enters from H1 or M15 directly. Every gate must     |
//|   pass, there is at most one open position, and there is no        |
//|   averaging, martingale or grid logic anywhere in the code.        |
//|                                                                   |
//|   All structural decisions are taken on closed bars only, so the   |
//|   behaviour in the strategy tester matches live behaviour and no   |
//|   value is ever read from a bar that had not finished forming.     |
//+------------------------------------------------------------------+
#property copyright "GoldSMC"
#property link      "https://github.com"
#property version   "2.00"
#property description "Gold SMC AI EA: H4 trend, H1 confirmation, M15 setup detection, M5 execution, tiered risk."

#include <GoldSMC/Types.mqh>
#include <GoldSMC/Logger.mqh>
#include <GoldSMC/Notifier.mqh>
#include <GoldSMC/MarketStructure.mqh>
#include <GoldSMC/Zones.mqh>
#include <GoldSMC/RiskManager.mqh>
#include <GoldSMC/NewsFilter.mqh>
#include <GoldSMC/Intel.mqh>
#include <GoldSMC/TradeManager.mqh>

//==================================================================
input group "=== Instrument ==="
input string  InpSymbolOverride     = "";        // Symbol to trade (empty = chart symbol)
input long    InpMagic              = 20250806;  // Magic number
input int     InpSlippagePoints     = 30;        // Max slippage (points)

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_H4; // Trend timeframe
input ENUM_TIMEFRAMES InpConfirmTF  = PERIOD_H1; // Confirmation timeframe
input ENUM_TIMEFRAMES InpSetupTF    = PERIOD_M15;// Setup timeframe (zones are stored here)
input ENUM_TIMEFRAMES InpExecTF     = PERIOD_M5; // Execution timeframe (entries only)
input double  InpMinTrendStrength   = 0.5;       // Min H4 trend strength (0..1)

input group "=== Structure & zones ==="
input int     InpFractalSize        = 2;         // Bars each side of a swing point
input int     InpHtfBars            = 300;       // Bars analysed on H4 / H1
input int     InpSetupBars          = 500;       // Bars analysed on the setup timeframe
input int     InpExecBars           = 400;       // Bars analysed on the execution timeframe
input int     InpBiasEmaPeriod      = 50;        // EMA period used in the trend score
input double  InpImpulseAtr         = 1.3;       // Impulse leaving a zone (x ATR)
input int     InpMaxZoneTouches     = 1;         // Discard a zone after this many taps
input bool    InpUseFvg             = true;      // Treat fair value gaps as areas of interest
input bool    InpUseMitigationBlock = true;      // Allow mitigation blocks (re-tapped zones)
input double  InpZoneProximityAtr   = 1.5;       // Max distance from price to a zone (x ATR)

input group "=== Setup detection (M15) ==="
input bool    InpRequireSweep       = true;      // Require a liquidity sweep before the shift
input int     InpSweepLookback      = 8;         // Sweep lookback (setup bars)
input int     InpStructureLookback  = 6;         // Max age of the M15 BOS/CHoCH (bars)
input int     InpSetupExpiryBars    = 12;        // Discard an armed setup after this many bars
input bool    InpRequireDiscount    = true;      // Longs only in discount, shorts only in premium

input group "=== Execution (M5) ==="
input int     InpExecEventBars      = 3;         // Max age of the M5 BOS/CHoCH (bars)
input bool    InpRequireExecMomentum = true;     // Require a momentum candle on M5

input group "=== Risk profile ==="
input ENUM_RISK_PROFILE InpRiskProfile = RISK_BALANCED; // Risk preset (Custom = use the tiers below)
input bool    InpAutoLot            = true;      // Auto lot size from risk
input double  InpManualLots         = 0.01;      // Manual lot size (used when auto lot is off)
input double  InpTier1Balance       = 250.0;     // Upper bound of band 1
input double  InpTier2Balance       = 500.0;     // Upper bound of band 2
input double  InpTier3Balance       = 1000.0;    // Upper bound of band 3
input double  InpRiskTier1          = 10.0;      // Risk % below tier 1 balance
input double  InpRiskTier2          = 7.0;       // Risk % below tier 2 balance
input double  InpRiskTier3          = 5.0;       // Risk % below tier 3 balance
input double  InpRiskTier4          = 2.5;       // Risk % above tier 3 balance
input double  InpMaxRiskPercent     = 12.0;      // Hard ceiling on risk per trade (%)
input bool    InpScaleRiskByQuality = true;      // Scale risk down on lower quality setups

input group "=== Account protection ==="
input double  InpDailyProfitTarget  = 500.0;     // Daily profit target in account currency (0 = off)
input double  InpDailyLossPercent   = 10.0;      // Stop for the day after this loss (%)
input double  InpMaxDrawdownPercent = 25.0;      // Halt the EA after this equity drawdown (%)
input int     InpMaxPositions       = 1;         // Max concurrent positions
input int     InpMaxTradesPerDay    = 5;         // Max new trades per day
input int     InpMaxLossesPerDay    = 3;         // Stop after this many losers in a day
input int     InpMaxConsecutiveLoss = 3;         // Stop after this many losses in a row

input group "=== Targets & stops ==="
input double  InpRewardRatio        = 4.0;       // Reward to risk ratio (1:R)
input double  InpStopBufferAtr      = 0.25;      // Stop distance beyond the zone (x ATR)
input double  InpMinStopAtr         = 0.5;       // Min stop distance (x ATR)
input double  InpMaxStopAtr         = 3.0;       // Max stop distance (x ATR)

input group "=== Trade management ==="
input bool    InpUseBreakEven       = true;      // Move to break even
input double  InpBreakEvenAtR       = 1.0;       // Break even trigger (R)
input double  InpBreakEvenOffsetR   = 0.1;       // Break even offset (R, locks a small profit)
input bool    InpUsePartial         = true;      // Take partial profit
input double  InpPartialAtR         = 1.0;       // Partial trigger (R)
input double  InpPartialPercent     = 50.0;      // Percent of the position to close (25/50/75)
input ENUM_TRAIL_MODE InpTrailMode  = TRAIL_ATR; // Trailing mode
input double  InpTrailStartR        = 2.0;       // Trail start (R)
input double  InpTrailAtrMult       = 1.5;       // ATR trail distance (x ATR)
input double  InpTrailStructBuffer  = 0.5;       // Structure trail buffer (x ATR)

input group "=== Sessions (server time) ==="
input bool    InpUseSessionFilter   = true;      // Restrict trading to the sessions below
input bool    InpTradeLondon        = true;      // London session
input int     InpLondonStartHour    = 7;         // London start hour
input int     InpLondonEndHour      = 12;        // London end hour
input bool    InpTradeNewYork       = true;      // New York session
input int     InpNewYorkStartHour   = 12;        // New York start hour
input int     InpNewYorkEndHour     = 20;        // New York end hour
input bool    InpTradeMonday        = true;
input bool    InpTradeFriday        = true;
input bool    InpCloseBeforeWeekend = true;      // Flatten late on Friday
input int     InpFridayCloseHour    = 20;        // Friday flatten hour

input group "=== Filters ==="
input double  InpMaxSpreadPoints    = 350;       // Max spread to trade (points, 0 = ignore)
input double  InpMinAtrPoints       = 0;         // Min execution ATR (points, 0 = ignore)
input double  InpMaxAtrPoints       = 0;         // Max execution ATR (points, 0 = ignore)
input double  InpMinCandleAtr       = 0.15;      // Min execution candle range (x ATR, 0 = ignore)
input double  InpMaxCandleAtr       = 3.0;       // Max execution candle range (x ATR, 0 = ignore)
input bool    InpUseLiquidityFilter = true;      // Skip thin, low volume conditions
input int     InpLiquidityLookback  = 20;        // Bars used for the average tick volume
input double  InpMinVolumeRatio     = 0.5;       // Min tick volume vs its average

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

input group "=== Notifications ==="
input bool    InpAlerts             = false;     // Terminal alerts
input bool    InpPushNotifications  = false;     // Push notifications to the mobile terminal
input bool    InpEmailNotifications = false;     // Email (requires terminal mail settings)

input group "=== Diagnostics ==="
input bool    InpShowDashboard      = true;      // Draw the on-chart dashboard
input ENUM_LOG_LEVEL InpLogLevel    = LOG_INFO;  // Journal verbosity
input bool    InpLogToFile          = false;     // Also write a CSV log
input string  InpLogFile            = "GoldSMC_log.csv";
input string  InpTradeComment       = "GoldSMC";

//==================================================================
CLogger           g_log;
CNotifier         g_notify;
CMarketStructure  g_trend;     // H4
CMarketStructure  g_confirm;   // H1
CMarketStructure  g_setup_ms;  // M15
CMarketStructure  g_exec;      // M5
CZoneEngine       g_zones;     // zones on the setup timeframe
CRiskManager      g_risk;
CNewsFilter       g_news;
CIntelClient      g_intel;
CTradeManager     g_trades;

string            g_symbol       = "";
datetime          g_last_setup_bar = 0;
datetime          g_last_exec_bar  = 0;
string            g_status       = "initialising";
string            g_signal       = "none";
BiasSnapshot      g_bias;
Setup             g_setup;
IntelSnapshot     g_intel_snapshot;
int               g_deals_seen   = 0;

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
bool HourInWindow(const int hour, const int start, const int end)
  {
   if(start == end)
      return false;
   if(start < end)
      return (hour >= start && hour < end);
   //--- window wraps midnight
   return (hour >= start || hour < end);
  }

bool SessionOpen(string &reason, string &session_name)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   session_name = "closed";

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

   if(!InpUseSessionFilter)
     {
      session_name = "any";
      reason = "";
      return true;
     }

   if(InpTradeLondon && HourInWindow(dt.hour, InpLondonStartHour, InpLondonEndHour))
      session_name = "London";
   else if(InpTradeNewYork && HourInWindow(dt.hour, InpNewYorkStartHour, InpNewYorkEndHour))
      session_name = "New York";

   if(session_name == "closed")
     {
      reason = "outside the enabled sessions";
      return false;
     }
   reason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Spread / volatility / candle / liquidity filters                  |
//+------------------------------------------------------------------+
bool SpreadAcceptable(double &spread_points)
  {
   spread_points = (double)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   if(InpMaxSpreadPoints <= 0.0)
      return true;
   return (spread_points <= InpMaxSpreadPoints);
  }

bool VolatilityAcceptable(const double exec_atr, string &reason)
  {
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0.0 || exec_atr <= 0.0)
     {
      reason = "ATR unavailable";
      return false;
     }
   double atr_points = exec_atr / point;

   if(InpMinAtrPoints > 0.0 && atr_points < InpMinAtrPoints)
     {
      reason = StringFormat("volatility too low (ATR %.0f pts)", atr_points);
      return false;
     }
   if(InpMaxAtrPoints > 0.0 && atr_points > InpMaxAtrPoints)
     {
      reason = StringFormat("volatility too high (ATR %.0f pts)", atr_points);
      return false;
     }

   //--- candle size, measured against the same ATR
   double range = iHigh(g_symbol, InpExecTF, 1) - iLow(g_symbol, InpExecTF, 1);
   if(InpMinCandleAtr > 0.0 && range < InpMinCandleAtr * exec_atr)
     {
      reason = "execution candle too small";
      return false;
     }
   if(InpMaxCandleAtr > 0.0 && range > InpMaxCandleAtr * exec_atr)
     {
      reason = "execution candle too large (climax move)";
      return false;
     }

   reason = "";
   return true;
  }

//--- thin books produce slippage and false breaks: require a normal tick volume
bool LiquidityAcceptable(string &reason)
  {
   if(!InpUseLiquidityFilter)
     {
      reason = "";
      return true;
     }

   int bars = MathMax(5, InpLiquidityLookback);
   long total = 0;
   for(int i = 1; i <= bars; i++)
      total += iVolume(g_symbol, InpExecTF, i);
   if(total <= 0)
     {
      reason = "";
      return true;
     }

   double average = (double)total / (double)bars;
   double latest  = (double)iVolume(g_symbol, InpExecTF, 1);
   if(average > 0.0 && latest < InpMinVolumeRatio * average)
     {
      reason = StringFormat("low liquidity (%.0f vs avg %.0f)", latest, average);
      return false;
     }
   reason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| H4 trend + H1 confirmation                                        |
//+------------------------------------------------------------------+
bool BuildBias(BiasSnapshot &out)
  {
   out.htf           = BIAS_NONE;
   out.mtf           = BIAS_NONE;
   out.htf_strength  = 0.0;
   out.htf_event     = STRUCT_NONE;
   out.mtf_event     = STRUCT_NONE;
   out.mtf_range     = RANGE_UNKNOWN;
   out.mtf_liquidity = false;
   out.stamp         = TimeCurrent();

   if(!g_trend.Refresh() || !g_confirm.Refresh())
      return false;

   double s_htf = 0.0, s_mtf = 0.0;
   out.htf          = g_trend.Bias(s_htf);
   out.mtf          = g_confirm.Bias(s_mtf);
   out.htf_strength = s_htf;
   out.htf_event    = g_trend.LastEvent();
   out.mtf_event    = g_confirm.LastEvent();

   double price     = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   out.mtf_range    = g_confirm.RangeZone(price);
   if(out.htf != BIAS_NONE)
      out.mtf_liquidity = g_confirm.SweptWithin(out.htf == BIAS_BULL, InpSweepLookback);
   return true;
  }

//+------------------------------------------------------------------+
//| Quality score of a candidate setup, 0..1                          |
//+------------------------------------------------------------------+
double SetupQuality(const Zone &zone, const bool bullish, const bool swept, const ENUM_STRUCT_EVENT trigger)
  {
   double q = 0.30;

   q += 0.25 * g_bias.htf_strength;

   if((bullish && g_bias.mtf == BIAS_BULL) || (!bullish && g_bias.mtf == BIAS_BEAR))
      q += 0.15;

   if(swept)
      q += 0.10;

   //--- a change of character in the trade direction is the strongest trigger
   if((bullish && trigger == STRUCT_CHOCH_BULL) || (!bullish && trigger == STRUCT_CHOCH_BEAR))
      q += 0.05;

   if(zone.touches == 0)
      q += 0.10;

   if((bullish && g_bias.mtf_range == RANGE_DISCOUNT) || (!bullish && g_bias.mtf_range == RANGE_PREMIUM))
      q += 0.05;

   if(g_intel_snapshot.valid)
     {
      double score   = CIntelClient::Score(g_intel_snapshot, InpIntelSentimentW);
      double aligned = (bullish ? score : -score);
      q += 0.10 * MathMax(-1.0, MathMin(1.0, aligned));
     }

   return MathMax(0.1, MathMin(1.0, q));
  }

//+------------------------------------------------------------------+
//| Assemble a trade plan from the armed setup                        |
//+------------------------------------------------------------------+
bool BuildPlan(const bool bullish, const Zone &zone, const double atr, TradePlan &plan)
  {
   plan.valid = false;

   double ask    = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double entry  = (bullish ? ask : bid);
   double buffer = InpStopBufferAtr * atr;

   //--- the stop always sits behind structure: the far side of the zone or the
   //--- protecting swing on the execution timeframe, whichever is further away
   double sl;
   if(bullish)
     {
      sl = zone.lower - buffer;
      double swing = g_exec.LastSwingLowBelow(entry);
      if(swing > 0.0 && swing - buffer < sl)
         sl = swing - buffer;
     }
   else
     {
      sl = zone.upper + buffer;
      double swing = g_exec.LastSwingHighAbove(entry);
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

   double factor = (InpScaleRiskByQuality ? g_setup.quality : 1.0);

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
   plan.reason     = StringFormat("%s zone %.2f-%.2f touches=%d quality=%.2f trend=%.2f risk=%.2f%% sweep=%s",
                                  (bullish ? "demand" : "supply"), zone.lower, zone.upper,
                                  zone.touches, g_setup.quality, g_bias.htf_strength,
                                  g_risk.RiskPercent(), (g_setup.swept ? "yes" : "no"));
   return true;
  }

//+------------------------------------------------------------------+
//| Stage 1: refresh the trend read and arm an M15 setup              |
//+------------------------------------------------------------------+
void ScanForSetup(void)
  {
   //--- an armed setup expires if price never comes back to it
   if(g_setup.valid)
     {
      int age = iBarShift(g_symbol, InpSetupTF, g_setup.armed, false);
      if(age < 0 || age > InpSetupExpiryBars)
        {
         g_log.Debug("armed setup expired");
         g_setup.valid = false;
        }
     }

   if(!BuildBias(g_bias))
     {
      g_status = "waiting: not enough history for the trend read";
      return;
     }
   if(g_bias.htf == BIAS_NONE)
     {
      g_status = "waiting: H4 has no clear trend";
      g_setup.valid = false;
      return;
     }
   if(g_bias.htf_strength < InpMinTrendStrength)
     {
      g_status = StringFormat("waiting: H4 strength %.2f < %.2f", g_bias.htf_strength, InpMinTrendStrength);
      return;
     }
   if(g_bias.mtf != g_bias.htf)
     {
      g_status = "waiting: H1 does not confirm H4";
      return;
     }

   bool bullish = (g_bias.htf == BIAS_BULL);

   //--- H1 premium / discount: buy cheap, sell expensive
   if(InpRequireDiscount)
     {
      if(bullish && g_bias.mtf_range != RANGE_DISCOUNT)
        {
         g_status = "waiting: price is not in H1 discount";
         return;
        }
      if(!bullish && g_bias.mtf_range != RANGE_PREMIUM)
        {
         g_status = "waiting: price is not in H1 premium";
         return;
        }
     }

   //--- external intelligence may veto, never create, a setup
   g_intel_snapshot = g_intel.Poll(g_symbol);
   if(InpUseIntel && g_intel_snapshot.valid && InpIntelMode != FILTER_OFF)
     {
      if(g_intel_snapshot.news_blackout)
        {
         g_status = "waiting: intel reports a news blackout";
         return;
        }
      double score   = CIntelClient::Score(g_intel_snapshot, InpIntelSentimentW);
      double aligned = (bullish ? score : -score);
      if(InpIntelMode == FILTER_STRICT && aligned < InpIntelMinAgreement)
        {
         g_status = StringFormat("waiting: intel disagrees (%.2f)", score);
         return;
        }
     }

   if(!g_setup_ms.Refresh() || !g_zones.Refresh())
     {
      g_status = "waiting: setup timeframe history unavailable";
      return;
     }

   //--- the M15 shift in structure that opens the window
   if(!g_setup_ms.FreshEvent(bullish, InpStructureLookback))
     {
      g_status = "waiting: no recent M15 BOS/CHoCH in the trend direction";
      return;
     }

   bool swept = g_setup_ms.SweptWithin(bullish, InpSweepLookback);
   if(InpRequireSweep && !swept)
     {
      g_status = "waiting: no liquidity sweep before the M15 shift";
      return;
     }

   double atr = g_zones.ATR();
   if(atr <= 0.0)
     {
      g_status = "waiting: setup ATR unavailable";
      return;
     }

   double price = (bullish ? SymbolInfoDouble(g_symbol, SYMBOL_ASK) : SymbolInfoDouble(g_symbol, SYMBOL_BID));
   Zone zone;
   bool found = (bullish ? g_zones.NearestDemand(price, InpZoneProximityAtr * atr, zone)
                         : g_zones.NearestSupply(price, InpZoneProximityAtr * atr, zone));
   if(!found)
     {
      g_status = "waiting: no unmitigated M15 zone near price";
      return;
     }
   if(!InpUseMitigationBlock && zone.touches > 0)
     {
      g_status = "waiting: only mitigation blocks available";
      return;
     }

   //--- arm it; execution now waits for the M5 trigger
   g_setup.valid   = true;
   g_setup.bullish = bullish;
   g_setup.zone    = zone;
   g_setup.trigger = g_setup_ms.LastEvent();
   g_setup.swept   = swept;
   g_setup.armed   = iTime(g_symbol, InpSetupTF, 0);
   g_setup.quality = SetupQuality(zone, bullish, swept, g_setup.trigger);

   g_signal = StringFormat("%s setup armed %.2f-%.2f (q=%.2f)",
                           (bullish ? "LONG" : "SHORT"), zone.lower, zone.upper, g_setup.quality);
   g_status = "armed: waiting for the M5 trigger";
   g_log.Info(StringFormat("M15 setup armed: %s zone %.2f-%.2f trigger=%s sweep=%s quality=%.2f",
                           (bullish ? "demand" : "supply"), zone.lower, zone.upper,
                           EnumToString(g_setup.trigger), (swept ? "yes" : "no"), g_setup.quality));
  }

//+------------------------------------------------------------------+
//| Stage 2: execute the armed setup on the execution timeframe       |
//+------------------------------------------------------------------+
void TryExecute(void)
  {
   if(!g_setup.valid)
      return;

   string reason;
   if(!g_risk.CanTrade(reason))
     {
      g_status = "no trade: " + reason;
      return;
     }

   string session;
   if(!SessionOpen(reason, session))
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

   if(!g_exec.Refresh())
     {
      g_status = "no trade: execution timeframe history unavailable";
      return;
     }

   double exec_atr = g_exec.ATR();
   if(!VolatilityAcceptable(exec_atr, reason))
     {
      g_status = "no trade: " + reason;
      return;
     }
   if(!LiquidityAcceptable(reason))
     {
      g_status = "no trade: " + reason;
      return;
     }

   bool bullish = g_setup.bullish;

   //--- 1. price must actually be back inside the stored M15 zone
   double last_low  = iLow(g_symbol, InpExecTF, 1);
   double last_high = iHigh(g_symbol, InpExecTF, 1);
   bool inside = (last_low <= g_setup.zone.upper && last_high >= g_setup.zone.lower);
   if(!inside)
     {
      g_status = "armed: waiting for the retrace into the zone";
      return;
     }

   //--- 2. a fresh shift in structure on the execution timeframe
   if(!g_exec.FreshEvent(bullish, InpExecEventBars))
     {
      g_status = "armed: in the zone, waiting for the M5 BOS/CHoCH";
      return;
     }

   //--- 3. momentum must agree with the direction
   if(InpRequireExecMomentum && !g_exec.MomentumConfirms(bullish))
     {
      g_status = "armed: M5 shift without momentum";
      return;
     }

   //--- every gate passed: size and send
   double atr = g_zones.ATR();
   if(atr <= 0.0)
      atr = exec_atr;

   TradePlan plan;
   if(!BuildPlan(bullish, g_setup.zone, atr, plan))
      return;

   //--- soft intel mode halves the size instead of vetoing the trade
   if(InpUseIntel && InpIntelMode == FILTER_SOFT && g_intel_snapshot.valid)
     {
      double score   = CIntelClient::Score(g_intel_snapshot, InpIntelSentimentW);
      double aligned = (bullish ? score : -score);
      if(aligned < InpIntelMinAgreement)
        {
         double step    = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
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

   g_log.Info(StringFormat("M5 trigger: %s event=%s momentum=%s session=%s spread=%.0f",
                           (bullish ? "long" : "short"), EnumToString(g_exec.LastEvent()),
                           (InpRequireExecMomentum ? "confirmed" : "not required"),
                           session, spread_points));

   if(g_trades.Execute(plan, InpTradeComment))
     {
      g_risk.RegisterTrade();
      g_setup.valid = false;      // one setup produces at most one trade
      g_signal = "executed";
      g_status = StringFormat("in trade: %s %.2f lots", (plan.direction == ORDER_TYPE_BUY ? "BUY" : "SELL"), plan.lots);
     }
   else
     {
      g_status = "order send failed, see journal";
      g_notify.Send("error", "order send failed on " + g_symbol);
     }
  }

//+------------------------------------------------------------------+
//| Feed closed deals into the risk manager                           |
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
   //--- the history window restarts every day, so the cursor has to follow it
   if(total < g_deals_seen)
      g_deals_seen = 0;
   if(total == g_deals_seen)
      return;

   //--- only the deals that appeared since the last call are registered
   for(int i = g_deals_seen; i < total; i++)
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
      g_risk.RegisterResult(profit);
      g_log.Info(StringFormat("deal closed: profit %.2f (losses today %d, streak %d)",
                              profit, g_risk.LossesToday(), g_risk.ConsecutiveLosses()));
      g_notify.Send("trade closed", StringFormat("result %.2f on %s", profit, g_symbol));
     }

   g_deals_seen = total;
  }

//+------------------------------------------------------------------+
//| On-chart dashboard                                                |
//+------------------------------------------------------------------+
string BiasText(const ENUM_BIAS b)
  {
   return (b == BIAS_BULL ? "BULLISH" : (b == BIAS_BEAR ? "BEARISH" : "NONE"));
  }

void DrawDashboard(void)
  {
   if(!InpShowDashboard)
      return;

   string reason, session;
   SessionOpen(reason, session);

   string range_txt = (g_bias.mtf_range == RANGE_DISCOUNT ? "discount"
                       : (g_bias.mtf_range == RANGE_PREMIUM ? "premium" : "unknown"));

   string setup_txt = "none";
   if(g_setup.valid)
      setup_txt = StringFormat("%s %.2f-%.2f q=%.2f",
                               (g_setup.bullish ? "LONG" : "SHORT"),
                               g_setup.zone.lower, g_setup.zone.upper, g_setup.quality);

   string news_txt = "off";
   if(InpUseNewsFilter)
     {
      int mins = g_news.MinutesToNextEvent();
      news_txt = (mins >= 0 ? StringFormat("next event in %d min", mins)
                            : StringFormat("no events (%d loaded)", g_news.EventCount()));
     }

   double target    = g_risk.DailyTarget();
   double remaining = g_risk.RemainingTarget();
   double day_pl    = g_risk.DailyProfit();

   string text = StringFormat(
      "GoldSMC v2  %s   [%s]\n"
      "-----------------------------------------\n"
      "Trend %s: %s (%.2f)  last %s\n"
      "Confirm %s: %s  range: %s  liquidity: %s\n"
      "Setup %s: %s\n"
      "Exec %s: %s\n"
      "-----------------------------------------\n"
      "Balance %.2f   Equity %.2f\n"
      "Risk %.2f%% (%s)   R:R 1:%.1f   Open %d\n"
      "Day P/L %.2f   Target %.2f   Remaining %.2f\n"
      "Trades today %d   Losses today %d   Streak %d\n"
      "Win rate %.1f%%   Drawdown %.2f%%\n"
      "News: %s\n"
      "Signal: %s\n"
      "Status: %s",
      g_symbol, session,
      EnumToString(InpTrendTF), BiasText(g_bias.htf), g_bias.htf_strength, EnumToString(g_bias.htf_event),
      EnumToString(InpConfirmTF), BiasText(g_bias.mtf), range_txt, (g_bias.mtf_liquidity ? "swept" : "-"),
      EnumToString(InpSetupTF), setup_txt,
      EnumToString(InpExecTF), EnumToString(g_exec.LastEvent()),
      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
      g_risk.RiskPercent(), EnumToString(InpRiskProfile), InpRewardRatio, g_risk.OpenPositions(),
      day_pl, target, remaining,
      g_risk.TradesToday(), g_risk.LossesToday(), g_risk.ConsecutiveLosses(),
      g_risk.WinRate(), g_risk.DrawdownPercent(),
      news_txt, g_signal, g_status);

   Comment(text);
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_symbol = ResolveSymbol(InpSymbolOverride);

   g_log.Init("GoldSMC", InpLogLevel, InpLogToFile, InpLogFile);
   g_notify.Init(InpAlerts, InpPushNotifications, InpEmailNotifications, "GoldSMC", GetPointer(g_log));
   g_log.Info("initialising on " + g_symbol);

   if(InpRewardRatio < 1.0)
     {
      g_log.Error("reward ratio must be at least 1.0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(PeriodSeconds(InpExecTF) > PeriodSeconds(InpSetupTF))
     {
      g_log.Error("the execution timeframe must not be higher than the setup timeframe");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(!g_trend.Init(g_symbol, InpTrendTF, InpFractalSize, InpHtfBars, InpBiasEmaPeriod) ||
      !g_confirm.Init(g_symbol, InpConfirmTF, InpFractalSize, InpHtfBars, InpBiasEmaPeriod) ||
      !g_setup_ms.Init(g_symbol, InpSetupTF, InpFractalSize, InpSetupBars, InpBiasEmaPeriod) ||
      !g_exec.Init(g_symbol, InpExecTF, InpFractalSize, InpExecBars, InpBiasEmaPeriod))
     {
      g_log.Error("failed to create structure indicators");
      return INIT_FAILED;
     }

   if(!g_zones.Init(g_symbol, InpSetupTF, InpSetupBars, InpImpulseAtr, InpMaxZoneTouches, InpUseFvg))
     {
      g_log.Error("failed to create the zone engine");
      return INIT_FAILED;
     }

   g_risk.Init(g_symbol, InpMagic);
   g_risk.ConfigureRisk(InpRiskProfile, InpTier1Balance, InpTier2Balance, InpTier3Balance,
                        InpRiskTier1, InpRiskTier2, InpRiskTier3, InpRiskTier4,
                        InpMaxRiskPercent, (InpAutoLot ? 0.0 : InpManualLots));
   g_risk.ConfigureLimits(InpDailyLossPercent, InpMaxDrawdownPercent, InpMaxPositions,
                          InpMaxTradesPerDay, InpMaxLossesPerDay, InpMaxConsecutiveLoss,
                          InpDailyProfitTarget);

   double risk_now = g_risk.RiskPercent();
   g_log.Info(StringFormat("risk profile %s, current risk %.2f%% of %.2f",
                           EnumToString(InpRiskProfile), risk_now, AccountInfoDouble(ACCOUNT_BALANCE)));
   if(risk_now >= 10.0)
      g_log.Warn("risk per trade is very high: a run of three losses will do severe damage to the account");

   g_news.Init(InpUseNewsFilter, InpNewsMinutesBefore, InpNewsMinutesAfter, InpNewsMinImportance,
               InpNewsCurrencies, InpNewsCsvFallback);

   g_intel.Init(InpUseIntel, InpIntelUseHttp, InpIntelUrl, InpIntelFile, InpIntelMaxAgeSec, 3000);

   g_trades.Init(g_symbol, InpMagic, InpSlippagePoints, GetPointer(g_log), GetPointer(g_notify));
   g_trades.ConfigureManagement(InpRewardRatio,
                                InpUseBreakEven, InpBreakEvenAtR, InpBreakEvenOffsetR,
                                InpUsePartial, InpPartialAtR, InpPartialPercent,
                                InpTrailMode, InpTrailStartR, InpTrailAtrMult, InpTrailStructBuffer);

   g_bias.htf             = BIAS_NONE;
   g_bias.mtf             = BIAS_NONE;
   g_bias.htf_strength    = 0.0;
   g_bias.htf_event       = STRUCT_NONE;
   g_bias.mtf_event       = STRUCT_NONE;
   g_bias.mtf_range       = RANGE_UNKNOWN;
   g_bias.mtf_liquidity   = false;
   g_setup.valid          = false;
   g_intel_snapshot.valid = false;

   g_status = "ready";
   g_signal = "none";
   g_notify.Send("EA started", g_symbol + " ready");
   EventSetTimer(60);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
   g_trend.Release();
   g_confirm.Release();
   g_setup_ms.Release();
   g_exec.Release();
   g_zones.Release();
   g_log.Info("stopped, reason " + IntegerToString(reason));
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   g_risk.Update();
   SyncClosedDeals();

   //--- in-trade management runs on every tick
   double atr = g_zones.ATR();
   double struct_low  = g_exec.LastSwingLowBelow(SymbolInfoDouble(g_symbol, SYMBOL_BID));
   double struct_high = g_exec.LastSwingHighAbove(SymbolInfoDouble(g_symbol, SYMBOL_ASK));
   g_trades.ManageOpenPositions(atr, struct_low, struct_high);

   //--- daily profit target: flatten, cancel and stand down until tomorrow
   if(g_risk.CheckDailyTarget())
     {
      g_trades.CloseAll("daily profit target reached");
      g_trades.CancelPendingOrders("daily profit target reached");
      g_setup.valid  = false;
      g_status       = "daily profit target reached, standing down";
      g_notify.Send("daily target reached", StringFormat("%.2f on %s", g_risk.DailyProfit(), g_symbol));
      DrawDashboard();
      return;
     }
   if(g_risk.TargetHit())
     {
      g_status = "daily profit target reached, standing down";
      return;
     }

   //--- optional Friday flatten
   if(InpCloseBeforeWeekend)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
        {
         g_trades.CloseAll("weekend flatten");
         g_trades.CancelPendingOrders("weekend flatten");
         g_setup.valid = false;
         g_status = "flat for the weekend";
         DrawDashboard();
         return;
        }
     }

   //--- setup detection runs once per closed setup timeframe bar
   datetime setup_bar = iTime(g_symbol, InpSetupTF, 0);
   if(setup_bar != g_last_setup_bar)
     {
      g_last_setup_bar = setup_bar;
      ScanForSetup();
     }

   //--- execution is evaluated once per closed execution timeframe bar
   datetime exec_bar = iTime(g_symbol, InpExecTF, 0);
   if(exec_bar != g_last_exec_bar)
     {
      g_last_exec_bar = exec_bar;
      TryExecute();
      DrawDashboard();
     }
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
