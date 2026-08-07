//+------------------------------------------------------------------+
//|                                                        Types.mqh |
//|                    Shared enums and structures for the GoldSMC EA |
//+------------------------------------------------------------------+
#ifndef __GOLDSMC_TYPES_MQH__
#define __GOLDSMC_TYPES_MQH__

//--- Directional bias produced by higher timeframe analysis
enum ENUM_BIAS
  {
   BIAS_NONE = 0,
   BIAS_BULL = 1,
   BIAS_BEAR = -1
  };

//--- Kind of point of interest the entry engine reacts to
enum ENUM_ZONE_TYPE
  {
   ZONE_DEMAND = 0,   // bullish order block / base of an up impulse
   ZONE_SUPPLY = 1,   // bearish order block / base of a down impulse
   ZONE_FVG_BULL = 2, // bullish fair value gap / imbalance
   ZONE_FVG_BEAR = 3  // bearish fair value gap / imbalance
  };

//--- How aggressively the sentiment/news layer is allowed to veto a setup
enum ENUM_FILTER_MODE
  {
   FILTER_OFF = 0,        // ignore the external intelligence layer
   FILTER_SOFT = 1,       // only reduce risk when the layer disagrees
   FILTER_STRICT = 2      // block the trade when the layer disagrees
  };

//--- A swing point detected on any timeframe
struct SwingPoint
  {
   datetime          time;
   double            price;
   int               shift;
   bool              is_high;
  };

//--- A supply/demand area of interest
struct Zone
  {
   ENUM_ZONE_TYPE    type;
   double            upper;        // upper boundary (price)
   double            lower;        // lower boundary (price)
   datetime          created;      // open time of the base candle
   int               touches;      // how many times price has revisited it
   double            impulse;      // size of the impulse that created the zone, in points
   bool              mitigated;    // fully traded through -> no longer valid
  };

//--- Snapshot of the multi timeframe read used for one decision
struct BiasSnapshot
  {
   ENUM_BIAS         htf;          // H4 structural bias
   ENUM_BIAS         mtf;          // H1 alignment
   double            htf_strength; // 0..1 confidence from structure + momentum
   datetime          stamp;
  };

//--- External intelligence (news + sentiment + model score)
struct IntelSnapshot
  {
   bool              valid;
   double            sentiment;    // -1..+1, positive = bullish gold
   double            model_score;  // -1..+1 output of the neural model
   double            confidence;   // 0..1
   bool              news_blackout;
   string            note;
   datetime          stamp;
  };

//--- Everything needed to place one order
struct TradePlan
  {
   bool              valid;
   ENUM_ORDER_TYPE   direction;
   double            entry;
   double            sl;
   double            tp;
   double            lots;
   double            risk_money;
   double            rr;
   string            reason;
  };

#endif // __GOLDSMC_TYPES_MQH__
