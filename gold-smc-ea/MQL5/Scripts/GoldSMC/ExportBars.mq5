//+------------------------------------------------------------------+
//|                                                   ExportBars.mq5 |
//|   Exports chart history to CSV so the Python service can train    |
//|   the directional model on the same data the EA trades on.        |
//|   Output goes to MQL5/Files (or Common/Files when InpCommon).     |
//+------------------------------------------------------------------+
#property copyright "GoldSMC"
#property version   "1.00"
#property script_show_inputs
#property description "Export OHLC history to a CSV the GoldSMC Python service can train on."

input ENUM_TIMEFRAMES InpTimeframe = PERIOD_H1;   // Timeframe to export
input int             InpBars      = 20000;       // Bars to export (0 = all available)
input string          InpFileName  = "";          // File name (empty = SYMBOL_TF.csv)
input bool            InpCommon    = true;        // Write to the common Files folder

//+------------------------------------------------------------------+
void OnStart(void)
  {
   string filename = InpFileName;
   if(StringLen(filename) == 0)
      filename = StringFormat("%s_%s.csv", _Symbol, EnumToString(InpTimeframe));

   int available = Bars(_Symbol, InpTimeframe);
   if(available <= 0)
     {
      Print("no history for ", _Symbol, " ", EnumToString(InpTimeframe),
            " - open the chart and scroll back to download it first");
      return;
     }

   int count = (InpBars <= 0 ? available : MathMin(InpBars, available));

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, InpTimeframe, 0, count, rates);
   if(copied <= 0)
     {
      Print("CopyRates failed, error ", GetLastError());
      return;
     }

   int flags = FILE_WRITE|FILE_CSV|FILE_ANSI;
   if(InpCommon)
      flags |= FILE_COMMON;

   int handle = FileOpen(filename, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("cannot create ", filename, ", error ", GetLastError());
      return;
     }

   FileWrite(handle, "time", "open", "high", "low", "close", "volume");
   for(int i = 0; i < copied; i++)
     {
      FileWrite(handle,
                TimeToString(rates[i].time, TIME_DATE|TIME_MINUTES),
                DoubleToString(rates[i].open, _Digits),
                DoubleToString(rates[i].high, _Digits),
                DoubleToString(rates[i].low, _Digits),
                DoubleToString(rates[i].close, _Digits),
                IntegerToString(rates[i].tick_volume));
     }
   FileClose(handle);

   PrintFormat("exported %d bars of %s %s to %s%s", copied, _Symbol,
               EnumToString(InpTimeframe), (InpCommon ? "Common/Files/" : "MQL5/Files/"), filename);
  }
//+------------------------------------------------------------------+
