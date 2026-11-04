//+------------------------------------------------------------------+
//|                                                SpreadMonitor.mq5 |
//|                                          Copyright 2026, rbot.cc |
//|                                                  https://rbot.cc |
//+------------------------------------------------------------------+
#property copyright   "rbot.cc"
#property link        "https://rbot.cc"
#property version     "1.10"
#property description "Real-time Bar Max & Average Spread Subwindow Curve Indicator"
#property description "Reconstructs historical spread via CopyTicks and tracks live spread peaks & averages."
#property description "Powered by rbot.cc (https://rbot.cc)"
#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   2
#property indicator_minimum 0

//--- Plot 1: Max Spread
#property indicator_label1  "Max Spread"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrTomato
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

//--- Plot 2: Avg Spread
#property indicator_label2  "Avg Spread"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

//--- Input parameters
input bool   InpUsePips        = false;     // Display in Standard Pips (false = Points)
input int    InpTickHistoryBars = 500;      // Historical Bars to Backfill via CopyTicks (0 = Disable)
input bool   InpSaveToFile     = true;      // Auto-save Spread History to Local CSV File
input bool   InpShowDashboard  = true;      // Show Real-Time Spread Dashboard in Subwindow
input color  InpTextColor      = clrSilver; // Dashboard Text Color
input int    InpFontSize       = 9;         // Dashboard Font Size

//--- Indicator buffers
double ExtMaxSpreadBuffer[];
double ExtAvgSpreadBuffer[];

//--- Current bar tracking variables
datetime g_currentBarTime = 0;
double   g_curMaxPoints   = 0.0;
double   g_curSumPoints   = 0.0;
long     g_curTickCount   = 0;
double   g_unitDivisor    = 1.0;
string   g_unitName       = "pts";
string   g_digitsFormat   = "%.0f";
string   g_shortName      = "Spread Monitor";
string   g_labelPrefix    = "SpreadMon_";

//+------------------------------------------------------------------+
//| Get persistence CSV file name                                    |
//+------------------------------------------------------------------+
string GetDataFileName()
{
   return StringFormat("SpreadHistory_%s_%d.csv", _Symbol, (int)PeriodSeconds(_Period) / 60);
}

//+------------------------------------------------------------------+
//| Save recorded bar spread history to local file                   |
//+------------------------------------------------------------------+
void SaveHistoryToFile(const datetime &time[], const int rates_total)
{
   if(!InpSaveToFile || rates_total <= 0) return;

   string fileName = GetDataFileName();
   int handle = FileOpen(fileName, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return;

   int bufSize = MathMin(ArraySize(ExtMaxSpreadBuffer), ArraySize(ExtAvgSpreadBuffer));
   int limit   = MathMin(MathMin(rates_total, bufSize) - 1, 5000);

   // In Series mode, index 0 is newest and index limit is oldest
   for(int i = limit; i >= 0; i--)
   {
      if(ExtMaxSpreadBuffer[i] != EMPTY_VALUE && ExtAvgSpreadBuffer[i] != EMPTY_VALUE && ExtMaxSpreadBuffer[i] > 0)
      {
         double rawMax = ExtMaxSpreadBuffer[i] * g_unitDivisor;
         double rawAvg = ExtAvgSpreadBuffer[i] * g_unitDivisor;
         FileWrite(handle, IntegerToString((long)time[i]), DoubleToString(rawMax, 2), DoubleToString(rawAvg, 4));
      }
   }
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Load recorded bar spread history from local file                 |
//+------------------------------------------------------------------+
void LoadHistoryFromFile(const datetime &time[], const int rates_total)
{
   if(!InpSaveToFile || rates_total <= 0) return;

   string fileName = GetDataFileName();
   if(!FileIsExist(fileName)) return;

   int handle = FileOpen(fileName, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE) return;

   int bufSize = MathMin(ArraySize(ExtMaxSpreadBuffer), ArraySize(ExtAvgSpreadBuffer));

   while(!FileIsEnding(handle))
   {
      string strTime = FileReadString(handle);
      if(StringLen(strTime) == 0) continue;

      datetime barTime = (datetime)StringToInteger(strTime);
      double rawMax    = StringToDouble(FileReadString(handle));
      double rawAvg    = StringToDouble(FileReadString(handle));

      int shift = iBarShift(_Symbol, _Period, barTime, true);
      if(shift >= 0 && shift < rates_total && shift < bufSize)
      {
         ExtMaxSpreadBuffer[shift] = rawMax / g_unitDivisor;
         ExtAvgSpreadBuffer[shift] = rawAvg / g_unitDivisor;

         if(shift == 0)
         {
            g_curMaxPoints   = rawMax;
            g_curSumPoints   = rawAvg;
            g_curTickCount   = 1;
            g_currentBarTime = time[0];
         }
      }
   }
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Reconstruct exact Max & Avg spread from MT5 Native Tick History  |
//+------------------------------------------------------------------+
void BackfillFromCopyTicks(const datetime &time[], const int rates_total)
{
   if(InpTickHistoryBars <= 0 || rates_total <= 0 || _Point <= 0) return;

   int barsToCalc = MathMin(InpTickHistoryBars, rates_total - 1);
   if(barsToCalc <= 0) return;

   int periodSec = PeriodSeconds(_Period);
   if(periodSec <= 0) periodSec = 60;

   for(int i = barsToCalc; i >= 0; i--)
   {
      ulong fromMsc = (ulong)time[i] * 1000;
      ulong toMsc   = (i > 0) ? ((ulong)time[i - 1] * 1000 - 1) : ((ulong)TimeCurrent() * 1000 + 999);

      MqlTick ticks[];
      int copied = CopyTicksRange(_Symbol, ticks, COPY_TICKS_INFO, fromMsc, toMsc);
      if(copied > 0)
      {
         double maxPts = 0.0;
         double sumPts = 0.0;
         long   validCount = 0;

         for(int k = 0; k < copied; k++)
         {
            if(ticks[k].ask > 0 && ticks[k].bid > 0 && ticks[k].ask >= ticks[k].bid)
            {
               double sp = MathRound((ticks[k].ask - ticks[k].bid) / _Point);
               if(sp > maxPts) maxPts = sp;
               sumPts += sp;
               validCount++;
            }
         }

         if(validCount > 0)
         {
            ExtMaxSpreadBuffer[i] = maxPts / g_unitDivisor;
            ExtAvgSpreadBuffer[i] = (sumPts / (double)validCount) / g_unitDivisor;

            if(i == 0)
            {
               g_curMaxPoints   = maxPts;
               g_curSumPoints   = sumPts;
               g_curTickCount   = validCount;
               g_currentBarTime = time[0];
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Update subwindow top-left dashboard                              |
//+------------------------------------------------------------------+
void UpdateDashboard(double curSpread, double avgSpread, double maxSpread)
{
   if(!InpShowDashboard) return;

   int window = ChartWindowFind(0, g_shortName);
   if(window < 0) window = 1;

   string objName = g_labelPrefix + "Info";
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_LABEL, window, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, InpTextColor);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, InpFontSize);
      ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
   }

   string text = StringFormat("Current: " + g_digitsFormat + " %s | Bar Avg: %.1f %s | Bar Max: " + g_digitsFormat + " %s | Samples: %s Ticks",
                              curSpread, g_unitName,
                              avgSpread, g_unitName,
                              maxSpread, g_unitName,
                              IntegerToString(g_curTickCount));
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Unit conversion: for 5-digit or 3-digit quotes, 1 Pip = 10 Points
   if(InpUsePips && (_Digits == 3 || _Digits == 5))
   {
      g_unitDivisor  = 10.0;
      g_unitName     = "pips";
      g_digitsFormat = "%.1f";
      IndicatorSetInteger(INDICATOR_DIGITS, 2);
   }
   else
   {
      g_unitDivisor  = 1.0;
      g_unitName     = "pts";
      g_digitsFormat = "%.0f";
      IndicatorSetInteger(INDICATOR_DIGITS, 1);
   }

   // Bind indicator buffers and set as time series (0 = newest bar, matching MT4)
   SetIndexBuffer(0, ExtMaxSpreadBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, ExtAvgSpreadBuffer, INDICATOR_DATA);
   ArraySetAsSeries(ExtMaxSpreadBuffer, true);
   ArraySetAsSeries(ExtAvgSpreadBuffer, true);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   g_shortName = StringFormat("Spread Monitor (%s)", g_unitName);
   IndicatorSetString(INDICATOR_SHORTNAME, g_shortName);

   PlotIndexSetString(0, PLOT_LABEL, "Max Spread (" + g_unitName + ")");
   PlotIndexSetString(1, PLOT_LABEL, "Avg Spread (" + g_unitName + ")");

   // Initialize tracking variables
   g_currentBarTime = 0;
   g_curMaxPoints   = 0.0;
   g_curSumPoints   = 0.0;
   g_curTickCount   = 0;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   datetime time[];
   ArraySetAsSeries(time, true);
   int copied = CopyTime(_Symbol, _Period, 0, MathMin(Bars(_Symbol, _Period), 5000), time);
   if(copied > 0)
   {
      SaveHistoryToFile(time, copied);
   }
   ObjectsDeleteAll(0, g_labelPrefix);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total <= 0) return(0);

   // Set input arrays as series (index 0 = newest bar)
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(spread, true);

   // Initial load or full recalculation
   if(prev_calculated == 0)
   {
      ArrayInitialize(ExtMaxSpreadBuffer, EMPTY_VALUE);
      ArrayInitialize(ExtAvgSpreadBuffer, EMPTY_VALUE);

      // 1. Pre-fill baseline from MT5 native bar spread[] (minimum spread of each bar)
      int spreadArrSize = ArraySize(spread);
      int bufSize       = MathMin(ArraySize(ExtMaxSpreadBuffer), ArraySize(ExtAvgSpreadBuffer));
      int safeLimit     = MathMin(rates_total, MathMin(spreadArrSize, bufSize));

      for(int i = safeLimit - 1; i >= 0; i--)
      {
         if(spread[i] > 0)
         {
            double histSpread = (double)spread[i] / g_unitDivisor;
            ExtMaxSpreadBuffer[i] = histSpread;
            ExtAvgSpreadBuffer[i] = histSpread;
         }
      }

      // 2. Load saved CSV history if available
      LoadHistoryFromFile(time, rates_total);

      // 3. Reconstruct exact Max & Average spread from MT5 Native Tick History (CopyTicksRange)
      BackfillFromCopyTicks(time, rates_total);
   }

   // Get current real-time spread in Points
   double currentSpreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   MqlTick lastTick;
   if(SymbolInfoTick(_Symbol, lastTick) && lastTick.ask > 0 && lastTick.bid > 0 && _Point > 0)
   {
      currentSpreadPoints = MathRound((lastTick.ask - lastTick.bid) / _Point);
   }

   // Detect new bar opening
   if(g_currentBarTime != time[0])
   {
      if(g_currentBarTime != 0)
      {
         SaveHistoryToFile(time, rates_total);
      }

      g_currentBarTime = time[0];

      if(g_curTickCount <= 0 || prev_calculated > 0)
      {
         g_curMaxPoints = currentSpreadPoints;
         g_curSumPoints = currentSpreadPoints;
         g_curTickCount = 1;
      }
   }
   else
   {
      // Within the same bar, update max and cumulative sum on every tick
      if(currentSpreadPoints > g_curMaxPoints)
         g_curMaxPoints = currentSpreadPoints;

      g_curSumPoints += currentSpreadPoints;
      g_curTickCount++;
   }

   // Convert current bar max and average spread to display unit
   double curSpreadDisplay = currentSpreadPoints / g_unitDivisor;
   double maxSpreadDisplay = g_curMaxPoints / g_unitDivisor;
   double avgSpreadDisplay = (g_curSumPoints / (double)g_curTickCount) / g_unitDivisor;

   // Write to current bar (index 0) buffers
   ExtMaxSpreadBuffer[0] = maxSpreadDisplay;
   ExtAvgSpreadBuffer[0] = avgSpreadDisplay;

   // Update subwindow dashboard
   UpdateDashboard(curSpreadDisplay, avgSpreadDisplay, maxSpreadDisplay);

   return(rates_total);
}
//+------------------------------------------------------------------+
