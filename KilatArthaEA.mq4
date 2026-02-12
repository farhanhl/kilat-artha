#property strict

input string Symbols = "EURUSD,GBPUSD,USDJPY,XAUUSD";
input ENUM_TIMEFRAMES Timeframe = PERIOD_H1;
input int MagicNumber = 89786579;
input int SlippagePoints = 30;
input int MaxNewTradesPerBar = 1;

input bool Minimum_OrderBlock_to_OrderBlock_in_Pips = false;
input double Min_OrderBlock_in_Pips = 40.0;
input double Min_OBtoOB_in_Daily_ATR = 0.7;
input int ATR_Period = 14;

input bool OBtoOB_UseDistanceBetweenOBs = false;

input bool Ignore_Counter_Trend = true;
input ENUM_TIMEFRAMES Timeframe_Trend = PERIOD_MN1;
input int Trend_EMA_Period = 200;

input bool Posisi_Size_Automatically = true;
input double Position_Size_Adjust_Factor = 50000.0;
input double Posisi_Size_Fixed = 0.05;
input bool Use_Equity_Instead_of_Balance = false;

input bool Enable_Martingale = true;
input double Martingale_Multiplier = 1.3;
input int Maximum_Martingale = 5;
input double Minimum_Profit_In_Money_for_Martingale = 100.0;

enum TradingSideEnum { BUY_ONLY=0, SELL_ONLY=1, BOTH_SIDE=2 };
input TradingSideEnum Trading_Side = BOTH_SIDE;
input bool Disable_Place_New_Order_When_No_Martingale = false;
input bool Disable_Place_Opposite_Order = false;
input int Disable_New_Opposite_Order_When_Averaging_More_Than = 3;

input bool Enable_Auto_Cut_Loss = false;
input double Cut_Loss_if_Floating_Minus_More_Than = 10.0;

input double Maximum_Spread = 30;
input bool Enable_Adaptive_Spread_Per_Symbol = true;
input string Maximum_Spread_Per_Symbol = "XAUUSD=80";
input double Adaptive_Spread_Multiplier_XAU = 2.0;

input double Averaging_Distance_Pips = 0;
input int OB_Max_Bars_Valid = 48;
input bool Enable_OB_Invalidation_By_Close = true;
input double OB_Invalidation_Buffer_Pips = 0.0;

input bool Enable_Session_Filter = false;
input int Session_Start_Hour_Server = 0;
input int Session_End_Hour_Server = 23;

input bool   AntiMC_Enable = true;
input double AntiMC_MinMarginLevelPercent = 200.0;
input double AntiMC_PanicCloseMarginLevelPercent = 120.0;
input bool   AntiMC_CloseAllEAOnPanic = true;
input double AntiMC_MaxEquityDrawdownPercent = 25.0;
input bool   AntiMC_CloseEAOnMaxDD = true;
input int    AntiMC_MaxTotalOrdersEA = 20;
input int    AntiMC_MaxOrdersPerSymbol = 7;
input double AntiMC_MaxLotsTotal = 2.0;
input double AntiMC_MaxLotsPerSymbol = 0.5;
input bool   AntiMC_UseDynamicMartingaleCap = true;
input bool   AntiMC_BlockNewsMinutes = false;
input int    AntiMC_NewsBlockWindowMin = 15;

string g_symbols[];
datetime g_lastBarTime[];
int g_tradesOpenedThisBar[];
double g_lastOBMidBuy[];
double g_lastOBMidSell[];
double g_lastEntryPriceBuy[];
double g_lastEntryPriceSell[];
string g_spreadOverrideSymbols[];
double g_spreadOverrideValues[];

double g_peakEquity = 0.0;
bool g_loggedMaxDD = false;

int g_obLookback = 220;
int g_fractalL = 2;

void LogSym(string sym, string msg)
{
   Print("[KilatArthaEA][", sym, "] ", msg);
}

void LogAntiMC(string msg)
{
   Print("[KilatArthaEA][AntiMC] ", msg);
}

bool IsEAOrderCurrent(string symFilter = "")
{
   if(OrderMagicNumber() != MagicNumber)
      return false;
   if(symFilter != "" && OrderSymbol() != symFilter)
      return false;
   int t = OrderType();
   return (t == OP_BUY || t == OP_SELL);
}

double PointOf(string sym)
{
   return MarketInfo(sym, MODE_POINT);
}

int DigitsOf(string sym)
{
   return (int)MarketInfo(sym, MODE_DIGITS);
}

double PipPoint(string sym)
{
   int d = DigitsOf(sym);
   double p = PointOf(sym);
   if(d == 3 || d == 5)
      return 10.0 * p;
   return p;
}

string Trim(string s)
{
   string t = s;
   StringTrimLeft(t);
   StringTrimRight(t);
   return t;
}

void ParseSpreadOverrides()
{
   ArrayResize(g_spreadOverrideSymbols, 0);
   ArrayResize(g_spreadOverrideValues, 0);

   string raw = Trim(Maximum_Spread_Per_Symbol);
   if(raw == "")
      return;

   string pairs[];
   int n = StringSplit(raw, ',', pairs);
   if(n <= 0)
      return;

   for(int i = 0; i < n; i++)
   {
      string item = Trim(pairs[i]);
      if(item == "")
         continue;

      string kv[];
      int m = StringSplit(item, '=', kv);
      if(m != 2)
         continue;

      string sym = Trim(kv[0]);
      string valStr = Trim(kv[1]);
      if(sym == "" || valStr == "")
         continue;

      double v = StrToDouble(valStr);
      if(v <= 0.0)
         continue;

      int newSize = ArraySize(g_spreadOverrideSymbols) + 1;
      ArrayResize(g_spreadOverrideSymbols, newSize);
      ArrayResize(g_spreadOverrideValues, newSize);
      g_spreadOverrideSymbols[newSize - 1] = sym;
      g_spreadOverrideValues[newSize - 1] = v;
   }
}

double MaxSpreadForSymbol(string sym)
{
   double allowed = Maximum_Spread;
   if(!Enable_Adaptive_Spread_Per_Symbol)
      return allowed;

   for(int i = 0; i < ArraySize(g_spreadOverrideSymbols); i++)
   {
      string key = g_spreadOverrideSymbols[i];
      if(sym == key || StringFind(sym, key, 0) == 0)
      {
         allowed = g_spreadOverrideValues[i];
         return allowed;
      }
   }

   if(StringFind(sym, "XAU", 0) == 0)
      allowed = MathMax(allowed, Maximum_Spread * Adaptive_Spread_Multiplier_XAU);

   return allowed;
}

bool IsInsideTradingSession()
{
   if(!Enable_Session_Filter)
      return true;

   int h = TimeHour(TimeCurrent());
   int startH = Session_Start_Hour_Server;
   int endH = Session_End_Hour_Server;

   if(startH < 0 || startH > 23 || endH < 0 || endH > 23)
      return true;

   if(startH == endH)
      return true;

   if(startH < endH)
      return (h >= startH && h < endH);

   return (h >= startH || h < endH);
}

bool ParseSymbolsInput()
{
   string raw[];
   int n = StringSplit(Symbols, ',', raw);
   if(n <= 0)
      return false;

   ArrayResize(g_symbols, 0);
   for(int i = 0; i < n; i++)
   {
      string s = Trim(raw[i]);
      if(s == "")
         continue;

      bool exists = false;
      for(int j = 0; j < ArraySize(g_symbols); j++)
      {
         if(g_symbols[j] == s)
         {
            exists = true;
            break;
         }
      }
      if(!exists)
      {
         int newSize = ArraySize(g_symbols) + 1;
         ArrayResize(g_symbols, newSize);
         g_symbols[newSize - 1] = s;
      }
   }

   int cnt = ArraySize(g_symbols);
   if(cnt <= 0)
      return false;

   ArrayResize(g_lastBarTime, cnt);
   ArrayResize(g_tradesOpenedThisBar, cnt);
   ArrayResize(g_lastOBMidBuy, cnt);
   ArrayResize(g_lastOBMidSell, cnt);
   ArrayResize(g_lastEntryPriceBuy, cnt);
   ArrayResize(g_lastEntryPriceSell, cnt);

   for(int k = 0; k < cnt; k++)
   {
      g_lastBarTime[k] = 0;
      g_tradesOpenedThisBar[k] = 0;
      g_lastOBMidBuy[k] = 0.0;
      g_lastOBMidSell[k] = 0.0;
      g_lastEntryPriceBuy[k] = 0.0;
      g_lastEntryPriceSell[k] = 0.0;
      SymbolSelect(g_symbols[k], true);
   }

   return true;
}

int FindSymbolIndex(string sym)
{
   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      if(g_symbols[i] == sym)
         return i;
   }
   return -1;
}

void UpdatePeakEquity()
{
   double eq = AccountEquity();
   if(g_peakEquity <= 0.0 || eq > g_peakEquity)
      g_peakEquity = eq;
}

double DrawdownPct()
{
   if(g_peakEquity <= 0.0)
      return 0.0;
   double dd = (g_peakEquity - AccountEquity()) / g_peakEquity * 100.0;
   if(dd < 0.0)
      dd = 0.0;
   return dd;
}

double MarginLevelPct()
{
   double m = AccountMargin();
   if(m <= 0.0)
      return 99999.0;
   return (AccountEquity() / m) * 100.0;
}

bool IsHighImpactNewsNow(string sym)
{
   return false;
}

int AllowedMartingaleByMargin(double marginLevel)
{
   int cap = Maximum_Martingale;
   if(!AntiMC_Enable || !AntiMC_UseDynamicMartingaleCap)
      return cap;

   int dynamicCap = cap;
   if(marginLevel >= 500.0)
      dynamicCap = cap;
   else if(marginLevel >= 300.0)
      dynamicCap = MathMin(cap, 3);
   else if(marginLevel >= 200.0)
      dynamicCap = MathMin(cap, 2);
   else
      dynamicCap = 0;

   return MathMin(cap, dynamicCap);
}

void CollectGlobalEAStats(int &ordersEA, double &lotsEA)
{
   ordersEA = 0;
   lotsEA = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(!IsEAOrderCurrent())
         continue;
      ordersEA++;
      lotsEA += OrderLots();
   }
}

void CollectSymbolEAStats(string sym,
                          int &countBuy,
                          int &countSell,
                          double &sumProfit,
                          double &sumLotsBuy,
                          double &sumLotsSell,
                          double &totalLots,
                          datetime &lastBuyTime,
                          datetime &lastSellTime,
                          double &lastBuyPrice,
                          double &lastSellPrice)
{
   countBuy = 0;
   countSell = 0;
   sumProfit = 0.0;
   sumLotsBuy = 0.0;
   sumLotsSell = 0.0;
   totalLots = 0.0;
   lastBuyTime = 0;
   lastSellTime = 0;
   lastBuyPrice = 0.0;
   lastSellPrice = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(!IsEAOrderCurrent(sym))
         continue;

      sumProfit += (OrderProfit() + OrderSwap() + OrderCommission());
      totalLots += OrderLots();

      if(OrderType() == OP_BUY)
      {
         countBuy++;
         sumLotsBuy += OrderLots();
         if(OrderOpenTime() > lastBuyTime)
         {
            lastBuyTime = OrderOpenTime();
            lastBuyPrice = OrderOpenPrice();
         }
      }
      else if(OrderType() == OP_SELL)
      {
         countSell++;
         sumLotsSell += OrderLots();
         if(OrderOpenTime() > lastSellTime)
         {
            lastSellTime = OrderOpenTime();
            lastSellPrice = OrderOpenPrice();
         }
      }
   }
}

bool CloseOrderByTicket(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return false;

   int t = OrderType();
   if(t != OP_BUY && t != OP_SELL)
      return false;

   string sym = OrderSymbol();
   int digits = DigitsOf(sym);
   double price = (t == OP_BUY) ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
   price = NormalizeDouble(price, digits);

   for(int k = 0; k < 3; k++)
   {
      RefreshRates();
      price = (t == OP_BUY) ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
      price = NormalizeDouble(price, digits);

      if(OrderClose(ticket, OrderLots(), price, SlippagePoints, clrNONE))
         return true;

      int err = GetLastError();
      if(err == ERR_TRADE_CONTEXT_BUSY || err == ERR_REQUOTE || err == ERR_SERVER_BUSY || err == ERR_PRICE_CHANGED)
      {
         Sleep(250);
         ResetLastError();
         continue;
      }

      LogSym(sym, "OrderClose failed ticket=" + IntegerToString(ticket) + " err=" + IntegerToString(err));
      return false;
   }

   return false;
}

int CloseAllEAOrders(string symFilter = "")
{
   int closed = 0;
   int tickets[];
   ArrayResize(tickets, 0);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(!IsEAOrderCurrent(symFilter))
         continue;

      int n = ArraySize(tickets) + 1;
      ArrayResize(tickets, n);
      tickets[n - 1] = OrderTicket();
   }

   for(int j = 0; j < ArraySize(tickets); j++)
   {
      if(CloseOrderByTicket(tickets[j]))
         closed++;
   }

   return closed;
}

bool FindWorstBasketSymbol(string &worstSym)
{
   worstSym = "";
   double worstProfit = 0.0;
   bool found = false;

   for(int s = 0; s < ArraySize(g_symbols); s++)
   {
      string sym = g_symbols[s];
      int cb, cs;
      double sp, lb, ls, tl;
      datetime t1, t2;
      double p1, p2;
      CollectSymbolEAStats(sym, cb, cs, sp, lb, ls, tl, t1, t2, p1, p2);
      if(cb + cs <= 0)
         continue;

      if(!found || sp < worstProfit)
      {
         found = true;
         worstProfit = sp;
         worstSym = sym;
      }
   }

   return found;
}

void HandleAntiMCPanicClose()
{
   if(!AntiMC_Enable)
      return;
   if(AccountMargin() <= 0.0)
      return;

   double ml = MarginLevelPct();
   if(ml >= AntiMC_PanicCloseMarginLevelPercent)
      return;

   LogAntiMC("PanicClose triggered. marginLevel=" + DoubleToString(ml, 2));

   if(AntiMC_CloseAllEAOnPanic)
   {
      int closedAll = CloseAllEAOrders();
      LogAntiMC("PanicClose close-all closed=" + IntegerToString(closedAll));
      return;
   }

   int guard = 0;
   while(guard < 20)
   {
      guard++;
      ml = MarginLevelPct();
      if(ml >= AntiMC_MinMarginLevelPercent)
         break;

      string worst = "";
      if(!FindWorstBasketSymbol(worst))
         break;

      int closed = CloseAllEAOrders(worst);
      LogAntiMC("PanicClose worst-basket symbol=" + worst + " closed=" + IntegerToString(closed));
      if(closed <= 0)
         break;

      Sleep(250);
   }
}

void HandleAntiMCMaxDD()
{
   if(!AntiMC_Enable)
      return;

   double dd = DrawdownPct();
   if(dd < AntiMC_MaxEquityDrawdownPercent)
   {
      g_loggedMaxDD = false;
      return;
   }

   if(!g_loggedMaxDD)
   {
      LogAntiMC("MaxDD hit. drawdown%=" + DoubleToString(dd, 2));
      g_loggedMaxDD = true;
   }

   if(AntiMC_CloseEAOnMaxDD)
   {
      int closed = CloseAllEAOrders();
      LogAntiMC("MaxDD close-all closed=" + IntegerToString(closed));
   }
}

bool IsSwingHigh(string sym, ENUM_TIMEFRAMES tf, int i, int L)
{
   double h = iHigh(sym, tf, i);
   if(h <= 0.0)
      return false;

   for(int k = i - L; k <= i + L; k++)
   {
      if(k == i)
         continue;
      if(k < 0)
         continue;
      if(iHigh(sym, tf, k) > h)
         return false;
   }
   return true;
}

bool IsSwingLow(string sym, ENUM_TIMEFRAMES tf, int i, int L)
{
   double l = iLow(sym, tf, i);
   if(l <= 0.0)
      return false;

   for(int k = i - L; k <= i + L; k++)
   {
      if(k == i)
         continue;
      if(k < 0)
         continue;
      if(iLow(sym, tf, k) < l)
         return false;
   }
   return true;
}

bool FindLatestSwingHigh(string sym, ENUM_TIMEFRAMES tf, int lookback, int L, int &swingShift, double &swingPrice)
{
   swingShift = -1;
   swingPrice = 0.0;

   int bars = iBars(sym, tf);
   if(bars <= (2 * L + 5))
      return false;

   int start = L + 2;
   int end = MathMin(lookback, bars - L - 1);

   for(int i = start; i <= end; i++)
   {
      if(IsSwingHigh(sym, tf, i, L))
      {
         swingShift = i;
         swingPrice = iHigh(sym, tf, i);
         return true;
      }
   }

   return false;
}

bool FindLatestSwingLow(string sym, ENUM_TIMEFRAMES tf, int lookback, int L, int &swingShift, double &swingPrice)
{
   swingShift = -1;
   swingPrice = 0.0;

   int bars = iBars(sym, tf);
   if(bars <= (2 * L + 5))
      return false;

   int start = L + 2;
   int end = MathMin(lookback, bars - L - 1);

   for(int i = start; i <= end; i++)
   {
      if(IsSwingLow(sym, tf, i, L))
      {
         swingShift = i;
         swingPrice = iLow(sym, tf, i);
         return true;
      }
   }

   return false;
}

bool DetectBullishOB(string sym, ENUM_TIMEFRAMES tf, int spreadPoints, int &obShift, double &obLow, double &obHigh, double &obMid)
{
   obShift = -1;
   obLow = 0.0;
   obHigh = 0.0;
   obMid = 0.0;

   int swingShift;
   double swingHigh;
   if(!FindLatestSwingHigh(sym, tf, g_obLookback, g_fractalL, swingShift, swingHigh))
      return false;

   double buffer = MathMax(spreadPoints * PointOf(sym), 2.0 * PointOf(sym));
   int bars = iBars(sym, tf);

   for(int bosShift = swingShift - 1; bosShift >= 1; bosShift--)
   {
      double closeBos = iClose(sym, tf, bosShift);
      if(closeBos <= swingHigh + buffer)
         continue;

      int obShift = -1;
      int maxJ = MathMin(swingShift + 25, bars - 2);
      for(int j = bosShift + 1; j <= maxJ; j++)
      {
         double o = iOpen(sym, tf, j);
         double c = iClose(sym, tf, j);
         if(c < o)
         {
            obShift = j;
            break;
         }
      }

      if(obShift < 0)
         return false;

      obLow = iLow(sym, tf, obShift);
      obHigh = iHigh(sym, tf, obShift);
      obMid = (obLow + obHigh) * 0.5;
      return true;
   }

   return false;
}

bool DetectBearishOB(string sym, ENUM_TIMEFRAMES tf, int spreadPoints, int &obShift, double &obLow, double &obHigh, double &obMid)
{
   obShift = -1;
   obLow = 0.0;
   obHigh = 0.0;
   obMid = 0.0;

   int swingShift;
   double swingLow;
   if(!FindLatestSwingLow(sym, tf, g_obLookback, g_fractalL, swingShift, swingLow))
      return false;

   double buffer = MathMax(spreadPoints * PointOf(sym), 2.0 * PointOf(sym));
   int bars = iBars(sym, tf);

   for(int bosShift = swingShift - 1; bosShift >= 1; bosShift--)
   {
      double closeBos = iClose(sym, tf, bosShift);
      if(closeBos >= swingLow - buffer)
         continue;

      int obShift = -1;
      int maxJ = MathMin(swingShift + 25, bars - 2);
      for(int j = bosShift + 1; j <= maxJ; j++)
      {
         double o = iOpen(sym, tf, j);
         double c = iClose(sym, tf, j);
         if(c > o)
         {
            obShift = j;
            break;
         }
      }

      if(obShift < 0)
         return false;

      obLow = iLow(sym, tf, obShift);
      obHigh = iHigh(sym, tf, obShift);
      obMid = (obLow + obHigh) * 0.5;
      return true;
   }

   return false;
}

bool ValidateOBFilters(string sym, bool isBuy, int symIndex, double obLow, double obHigh, double obMid)
{
   double thickness = obHigh - obLow;

   if(Minimum_OrderBlock_to_OrderBlock_in_Pips)
   {
      double minP = Min_OrderBlock_in_Pips * PipPoint(sym);
      if(!OBtoOB_UseDistanceBetweenOBs)
      {
         if(thickness < minP)
         {
            LogSym(sym, "OB filter fail: thickness too small");
            return false;
         }
      }
      else
      {
         double prevMid = isBuy ? g_lastOBMidBuy[symIndex] : g_lastOBMidSell[symIndex];
         if(prevMid > 0.0 && MathAbs(obMid - prevMid) < minP)
         {
            LogSym(sym, "OB filter fail: OB-mid distance too small");
            return false;
         }
      }
   }

   double atr = iATR(sym, PERIOD_D1, ATR_Period, 0);
   if(atr <= 0.0)
   {
      LogSym(sym, "ATR unavailable for OB filter");
      return false;
   }

   if(thickness < Min_OBtoOB_in_Daily_ATR * atr)
   {
      LogSym(sym, "OB filter fail: thickness below ATR threshold");
      return false;
   }

   return true;
}

bool IsOBExpired(int obShift)
{
   if(OB_Max_Bars_Valid <= 0)
      return false;

   int ageBars = obShift - 1;
   return (ageBars > OB_Max_Bars_Valid);
}

bool IsOBInvalidatedByClose(string sym, ENUM_TIMEFRAMES tf, bool isBuy, int obShift, double obLow, double obHigh)
{
   if(!Enable_OB_Invalidation_By_Close)
      return false;

   if(obShift <= 1)
      return false;

   double buffer = OB_Invalidation_Buffer_Pips * PipPoint(sym);
   for(int i = obShift - 1; i >= 1; i--)
   {
      double c = iClose(sym, tf, i);
      if(isBuy)
      {
         if(c < (obLow - buffer))
            return true;
      }
      else
      {
         if(c > (obHigh + buffer))
            return true;
      }
   }

   return false;
}

bool BuildBuySignal(string sym, int symIndex, int spreadPoints, double &obLow, double &obHigh, double &obMid)
{
   obLow = 0.0;
   obHigh = 0.0;
   obMid = 0.0;
   int obShift = -1;

   if(!DetectBullishOB(sym, Timeframe, spreadPoints, obShift, obLow, obHigh, obMid))
      return false;

   if(IsOBExpired(obShift))
   {
      LogSym(sym, "OB skipped: expired");
      return false;
   }

   if(IsOBInvalidatedByClose(sym, Timeframe, true, obShift, obLow, obHigh))
   {
      LogSym(sym, "OB skipped: invalidated by close");
      return false;
   }

   if(!ValidateOBFilters(sym, true, symIndex, obLow, obHigh, obMid))
      return false;

   double barLow = iLow(sym, Timeframe, 1);
   double barHigh = iHigh(sym, Timeframe, 1);
   bool retest = (barLow <= obHigh && barHigh >= obLow);
   if(!retest)
      return false;

   double c = iClose(sym, Timeframe, 1);
   double o = iOpen(sym, Timeframe, 1);
   bool confirmation = (c > o) || (c > obMid);
   if(!confirmation)
      return false;

   return true;
}

bool BuildSellSignal(string sym, int symIndex, int spreadPoints, double &obLow, double &obHigh, double &obMid)
{
   obLow = 0.0;
   obHigh = 0.0;
   obMid = 0.0;
   int obShift = -1;

   if(!DetectBearishOB(sym, Timeframe, spreadPoints, obShift, obLow, obHigh, obMid))
      return false;

   if(IsOBExpired(obShift))
   {
      LogSym(sym, "OB skipped: expired");
      return false;
   }

   if(IsOBInvalidatedByClose(sym, Timeframe, false, obShift, obLow, obHigh))
   {
      LogSym(sym, "OB skipped: invalidated by close");
      return false;
   }

   if(!ValidateOBFilters(sym, false, symIndex, obLow, obHigh, obMid))
      return false;

   double barLow = iLow(sym, Timeframe, 1);
   double barHigh = iHigh(sym, Timeframe, 1);
   bool retest = (barLow <= obHigh && barHigh >= obLow);
   if(!retest)
      return false;

   double c = iClose(sym, Timeframe, 1);
   double o = iOpen(sym, Timeframe, 1);
   bool confirmation = (c < o) || (c < obMid);
   if(!confirmation)
      return false;

   return true;
}

bool IsTrendUp(string sym)
{
   double c = iClose(sym, Timeframe_Trend, 0);
   double ema = iMA(sym, Timeframe_Trend, Trend_EMA_Period, 0, MODE_EMA, PRICE_CLOSE, 0);
   return (c > ema);
}

bool IsTrendDown(string sym)
{
   double c = iClose(sym, Timeframe_Trend, 0);
   double ema = iMA(sym, Timeframe_Trend, Trend_EMA_Period, 0, MODE_EMA, PRICE_CLOSE, 0);
   return (c < ema);
}

double NormalizeLots(string sym, double lots)
{
   double minLot = MarketInfo(sym, MODE_MINLOT);
   double maxLot = MarketInfo(sym, MODE_MAXLOT);
   double step = MarketInfo(sym, MODE_LOTSTEP);

   if(step <= 0.0)
      step = 0.01;

   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / step) * step;

   if(lots < minLot)
      lots = 0.0;

   int lotDigits = 2;
   if(step >= 1.0)
      lotDigits = 0;
   else if(step >= 0.1)
      lotDigits = 1;

   return NormalizeDouble(lots, lotDigits);
}

double BaseLot()
{
   if(Posisi_Size_Automatically)
   {
      double val = Use_Equity_Instead_of_Balance ? AccountEquity() : AccountBalance();
      double lot = 0.0;
      if(Position_Size_Adjust_Factor > 0.0)
         lot = val / Position_Size_Adjust_Factor;
      lot = MathMax(lot, Posisi_Size_Fixed);
      return lot;
   }

   return Posisi_Size_Fixed;
}

double CalcDesiredLot(int level)
{
   double base = BaseLot();
   if(level < 0)
      level = 0;

   if(!Enable_Martingale)
      return base;

   return base * MathPow(Martingale_Multiplier, level);
}

bool AllowNewTradesGlobally(string sym, string &reason)
{
   reason = "";

   if(!AntiMC_Enable)
      return true;

   if(AntiMC_BlockNewsMinutes && IsHighImpactNewsNow(sym))
   {
      reason = "[AntiMC] News block window active";
      return false;
   }

   double dd = DrawdownPct();
   if(dd >= AntiMC_MaxEquityDrawdownPercent)
   {
      reason = "[AntiMC] Max drawdown reached";
      return false;
   }

   double ml = MarginLevelPct();
   if(ml < AntiMC_MinMarginLevelPercent)
   {
      reason = "[AntiMC] BlockNewTrade marginLevel=" + DoubleToString(ml, 2);
      return false;
   }

   return true;
}

bool ApplyAntiMCCapsForOrder(string sym, double &lot, int symbolOrderCount, double symbolLots)
{
   if(!AntiMC_Enable)
      return true;

   int totalOrdersEA;
   double totalLotsEA;
   CollectGlobalEAStats(totalOrdersEA, totalLotsEA);

   if(totalOrdersEA >= AntiMC_MaxTotalOrdersEA)
   {
      LogSym(sym, "[AntiMC] MaxTotalOrdersEA reached");
      return false;
   }

   if(symbolOrderCount >= AntiMC_MaxOrdersPerSymbol)
   {
      LogSym(sym, "[AntiMC] MaxOrdersPerSymbol reached");
      return false;
   }

   double remainTotalLots = AntiMC_MaxLotsTotal - totalLotsEA;
   double remainSymLots = AntiMC_MaxLotsPerSymbol - symbolLots;
   double remain = MathMin(remainTotalLots, remainSymLots);

   if(remain <= 0.0)
   {
      LogSym(sym, "[AntiMC] Lots cap reached");
      return false;
   }

   if(lot > remain)
   {
      lot = remain;
      LogSym(sym, "[AntiMC] Lot reduced by caps to " + DoubleToString(lot, 2));
   }

   lot = NormalizeLots(sym, lot);
   if(lot <= 0.0)
   {
      LogSym(sym, "[AntiMC] Remaining lot below min lot");
      return false;
   }

   return true;
}

bool SendOrderWithRetry(string sym, int cmd, double lots)
{
   int digits = DigitsOf(sym);
   double price = (cmd == OP_BUY) ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
   price = NormalizeDouble(price, digits);

   for(int i = 0; i < 3; i++)
   {
      RefreshRates();
      price = (cmd == OP_BUY) ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID);
      price = NormalizeDouble(price, digits);

      int ticket = OrderSend(sym, cmd, lots, price, SlippagePoints, 0, 0, "KilatArthaEA", MagicNumber, 0, clrNONE);
      if(ticket > 0)
      {
         if(OrderSelect(ticket, SELECT_BY_TICKET))
         {
            int idx = FindSymbolIndex(sym);
            if(idx >= 0)
            {
               if(cmd == OP_BUY)
                  g_lastEntryPriceBuy[idx] = OrderOpenPrice();
               else if(cmd == OP_SELL)
                  g_lastEntryPriceSell[idx] = OrderOpenPrice();
            }
         }
         return true;
      }

      int err = GetLastError();
      if(err == ERR_TRADE_CONTEXT_BUSY || err == ERR_REQUOTE || err == ERR_SERVER_BUSY || err == ERR_PRICE_CHANGED)
      {
         Sleep(300);
         ResetLastError();
         continue;
      }

      LogSym(sym, "OrderSend failed err=" + IntegerToString(err));
      return false;
   }

   return false;
}

void HandleBasketCloseByMoney(string sym)
{
   int cb, cs;
   double sumProfit, lotsB, lotsS, totalLots;
   datetime tb, ts;
   double pb, ps;
   CollectSymbolEAStats(sym, cb, cs, sumProfit, lotsB, lotsS, totalLots, tb, ts, pb, ps);

   if(cb + cs <= 0)
      return;

   if(sumProfit >= Minimum_Profit_In_Money_for_Martingale)
   {
      int closed = CloseAllEAOrders(sym);
      LogSym(sym, "Basket TP money hit. closed=" + IntegerToString(closed));
      return;
   }

   if(Enable_Auto_Cut_Loss && sumProfit <= -Cut_Loss_if_Floating_Minus_More_Than)
   {
      int closedCut = CloseAllEAOrders(sym);
      LogSym(sym, "Basket cut loss hit. closed=" + IntegerToString(closedCut));
   }
}

bool CanOpenDirectionBySide(int cmd)
{
   if(Trading_Side == BOTH_SIDE)
      return true;
   if(Trading_Side == BUY_ONLY && cmd == OP_BUY)
      return true;
   if(Trading_Side == SELL_ONLY && cmd == OP_SELL)
      return true;
   return false;
}

bool ProcessDirection(string sym,
                      int symIndex,
                      int cmd,
                      bool freshSignal,
                      int countBuy,
                      int countSell,
                      double totalLotsSymbol,
                      double lastBuyPrice,
                      double lastSellPrice,
                      double marginLevel)
{
   if(g_tradesOpenedThisBar[symIndex] >= MaxNewTradesPerBar)
      return false;

   if(!CanOpenDirectionBySide(cmd))
      return false;

   int countDir = (cmd == OP_BUY) ? countBuy : countSell;
   int countOpp = (cmd == OP_BUY) ? countSell : countBuy;

   if(Disable_Place_Opposite_Order && countOpp > 0)
   {
      LogSym(sym, "Opposite order blocked by Disable_Place_Opposite_Order");
      return false;
   }

   int levelOpp = countOpp - 1;
   if(levelOpp > Disable_New_Opposite_Order_When_Averaging_More_Than)
   {
      LogSym(sym, "Opposite order blocked by averaging threshold");
      return false;
   }

   if(Ignore_Counter_Trend)
   {
      if(cmd == OP_BUY && IsTrendDown(sym))
      {
         LogSym(sym, "Counter-trend BUY blocked");
         return false;
      }
      if(cmd == OP_SELL && IsTrendUp(sym))
      {
         LogSym(sym, "Counter-trend SELL blocked");
         return false;
      }
   }

   bool shouldOpen = false;
   int nextLevel = countDir;

   if(!Enable_Martingale && Disable_Place_New_Order_When_No_Martingale)
   {
      LogSym(sym, "No new order: martingale disabled and new orders disabled");
      return false;
   }

   if(countDir <= 0)
   {
      shouldOpen = freshSignal;
      nextLevel = 0;
   }
   else
   {
      if(!Enable_Martingale)
      {
         shouldOpen = false;
      }
      else
      {
         int effectiveCap = AllowedMartingaleByMargin(marginLevel);
         int currentLevel = countDir - 1;
         if(currentLevel >= effectiveCap)
         {
            LogSym(sym, "Max martingale reached. level=" + IntegerToString(currentLevel) + " cap=" + IntegerToString(effectiveCap));
            return false;
         }

         if(Averaging_Distance_Pips > 0)
         {
            double dist = Averaging_Distance_Pips * PipPoint(sym);
            double bid = MarketInfo(sym, MODE_BID);
            double ask = MarketInfo(sym, MODE_ASK);
            if((cmd == OP_BUY && lastBuyPrice <= 0.0) || (cmd == OP_SELL && lastSellPrice <= 0.0))
            {
               LogSym(sym, "Averaging skipped: last entry price unavailable");
               return false;
            }
            if(cmd == OP_BUY)
               shouldOpen = (ask <= (lastBuyPrice - dist));
            else
               shouldOpen = (bid >= (lastSellPrice + dist));
         }
         else
         {
            shouldOpen = freshSignal;
         }
      }
   }

   if(!shouldOpen)
      return false;

   double lot = CalcDesiredLot(nextLevel);
   lot = NormalizeLots(sym, lot);
   if(lot <= 0.0)
   {
      LogSym(sym, "Lot invalid after normalization");
      return false;
   }

   int symbolOrderCount = countBuy + countSell;
   if(!ApplyAntiMCCapsForOrder(sym, lot, symbolOrderCount, totalLotsSymbol))
      return false;

   int spreadPoints = (int)MarketInfo(sym, MODE_SPREAD);
   double maxSpread = MaxSpreadForSymbol(sym);
   if(spreadPoints > maxSpread)
   {
      LogSym(sym, "Spread too high. spread=" + IntegerToString(spreadPoints) + " allowed=" + DoubleToString(maxSpread, 1));
      return false;
   }

   if(SendOrderWithRetry(sym, cmd, lot))
   {
      g_tradesOpenedThisBar[symIndex]++;
      LogSym(sym, (cmd == OP_BUY ? "BUY" : "SELL") + " opened lot=" + DoubleToString(lot, 2));
      return true;
   }

   return false;
}

void ProcessSymbol(string sym, int symIndex)
{
   if(MarketInfo(sym, MODE_BID) <= 0.0 || MarketInfo(sym, MODE_ASK) <= 0.0)
   {
      LogSym(sym, "price unavailable");
      return;
   }

   HandleBasketCloseByMoney(sym);

   datetime t = iTime(sym, Timeframe, 0);
   if(t == 0)
      return;

   bool isNewBar = false;
   if(t != g_lastBarTime[symIndex])
   {
      g_lastBarTime[symIndex] = t;
      g_tradesOpenedThisBar[symIndex] = 0;
      isNewBar = true;
   }

   if(!isNewBar)
      return;

   int spreadPoints = (int)MarketInfo(sym, MODE_SPREAD);
   double maxSpread = MaxSpreadForSymbol(sym);
   if(spreadPoints > maxSpread)
   {
      LogSym(sym, "Spread too high. spread=" + IntegerToString(spreadPoints) + " allowed=" + DoubleToString(maxSpread, 1));
      return;
   }

   if(!IsInsideTradingSession())
   {
      LogSym(sym, "Session filter blocked new entries");
      return;
   }

   string globalReason = "";
   if(!AllowNewTradesGlobally(sym, globalReason))
   {
      LogSym(sym, globalReason);
      return;
   }

   int countBuy, countSell;
   double sumProfit, lotsB, lotsS, totalLots;
   datetime tb, ts;
   double lastBuyPrice, lastSellPrice;
   CollectSymbolEAStats(sym, countBuy, countSell, sumProfit, lotsB, lotsS, totalLots, tb, ts, lastBuyPrice, lastSellPrice);

   if(lastBuyPrice <= 0.0)
      lastBuyPrice = g_lastEntryPriceBuy[symIndex];
   if(lastSellPrice <= 0.0)
      lastSellPrice = g_lastEntryPriceSell[symIndex];

   double buyLow, buyHigh, buyMid;
   double sellLow, sellHigh, sellMid;
   bool buySignal = BuildBuySignal(sym, symIndex, spreadPoints, buyLow, buyHigh, buyMid);
   bool sellSignal = BuildSellSignal(sym, symIndex, spreadPoints, sellLow, sellHigh, sellMid);

   if(buySignal)
      g_lastOBMidBuy[symIndex] = buyMid;
   if(sellSignal)
      g_lastOBMidSell[symIndex] = sellMid;

   double ml = MarginLevelPct();

   ProcessDirection(sym, symIndex, OP_BUY, buySignal, countBuy, countSell, totalLots, lastBuyPrice, lastSellPrice, ml);

   // Recollect counts after potential BUY open so SELL checks use latest state.
   CollectSymbolEAStats(sym, countBuy, countSell, sumProfit, lotsB, lotsS, totalLots, tb, ts, lastBuyPrice, lastSellPrice);
   if(lastBuyPrice <= 0.0)
      lastBuyPrice = g_lastEntryPriceBuy[symIndex];
   if(lastSellPrice <= 0.0)
      lastSellPrice = g_lastEntryPriceSell[symIndex];

   ProcessDirection(sym, symIndex, OP_SELL, sellSignal, countBuy, countSell, totalLots, lastBuyPrice, lastSellPrice, ml);
}

int OnInit()
{
   if(!ParseSymbolsInput())
   {
      Print("[KilatArthaEA] Failed to parse Symbols input.");
      return INIT_FAILED;
   }

   ParseSpreadOverrides();

   if(Session_Start_Hour_Server < 0 || Session_Start_Hour_Server > 23 || Session_End_Hour_Server < 0 || Session_End_Hour_Server > 23)
      Print("[KilatArthaEA] Session hours invalid, session filter will be ignored.");

   g_peakEquity = AccountEquity();

   Print("[KilatArthaEA] Initialized. Symbols count=", ArraySize(g_symbols), ", spreadOverrides=", ArraySize(g_spreadOverrideSymbols));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("[KilatArthaEA] Deinitialized reason=", reason);
}

void OnTick()
{
   UpdatePeakEquity();

   HandleAntiMCPanicClose();
   HandleAntiMCMaxDD();

   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      ProcessSymbol(g_symbols[i], i);
   }
}
