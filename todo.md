You are Codex, an autonomous coding agent. Build a MetaTrader 4 Expert Advisor (MQL4) implementing an “Inova Prime”-style Order Block + Trend Filter + Grid/Martingale system + Anti-MC based on the spec below.

IMPORTANT:
- Do NOT over-ask. Ask at most 3 clarifying questions ONLY if truly blocking implementation. Otherwise proceed with defaults and document assumptions in README.
- Target broker: HFM (HF Markets). Multi-pair EA (single chart EA trades multiple symbols).
- Produce clean, readable MQL4 with strong logging + safety checks. Must compile with no errors in MetaEditor.

========================
1) PROJECT OUTPUT
========================
Create:
- /KilatArthaEA.mq4  (main EA)
- /README.md         (install + inputs + assumptions + testing)
- /CHANGELOG.md      (brief)
No external libraries.

========================
2) INPUTS (match names closely)
========================
[General]
input string Symbols = "EURUSD,GBPUSD,USDJPY,XAUUSD";  // comma-separated, multi-pair
input ENUM_TIMEFRAMES Timeframe = PERIOD_H1;
input int MagicNumber = 89786579;
input int SlippagePoints = 30;
input int MaxNewTradesPerBar = 1; // per symbol per new bar (including averaging)

[OrderBlock Filters]
input bool Minimum_OrderBlock_to_OrderBlock_in_Pips = false;
input double Min_OrderBlock_in_Pips = 40.0;
input double Min_OBtoOB_in_Daily_ATR = 0.7;
input int ATR_Period = 14;

input bool OBtoOB_UseDistanceBetweenOBs = false;
// If false: "Minimum_OrderBlock_to_OrderBlock_in_Pips" means OB thickness (High-Low).
// If true: it means distance between the MID price of current OB vs previous OB MID (same symbol+direction).

[Trend Management]
input bool Ignore_Counter_Trend = true;
input ENUM_TIMEFRAMES Timeframe_Trend = PERIOD_MN1;
input int Trend_EMA_Period = 200;  // default method

[Lot Management]
input bool Posisi_Size_Automatically = true;
input double Position_Size_Adjust_Factor = 50000.0; // baseLot = Balance/Equity / factor
input double Posisi_Size_Fixed = 0.05;              // used as minimum/base lot
input bool Use_Equity_Instead_of_Balance = false;

[Martingale Management]
input bool Enable_Martingale = true;
input double Martingale_Multiplier = 1.3;
input int Maximum_Martingale = 5;
input double Minimum_Profit_In_Money_for_Martingale = 100.0; // basket profit in deposit currency

[Trade Management]
enum TradingSideEnum { BUY_ONLY=0, SELL_ONLY=1, BOTH_SIDE=2 };
input TradingSideEnum Trading_Side = BOTH_SIDE;
input bool Disable_Place_New_Order_When_No_Martingale = false;
input bool Disable_Place_Opposite_Order = false;
input int Disable_New_Opposite_Order_When_Averaging_More_Than = 3;

input bool Enable_Auto_Cut_Loss = false;
input double Cut_Loss_if_Floating_Minus_More_Than = 10.0; // DEFAULT UNIT: MONEY (deposit currency)

input double Maximum_Spread = 30; // DEFAULT UNIT: POINTS (as returned by MODE_SPREAD in MT4)

[Grid/Averaging]
input double Averaging_Distance_Pips = 0;
// If 0: averaging only when a fresh valid OB entry signal occurs while positions exist in that direction.
// If >0: allow averaging when price goes against last entry by this distance.

========================
3) TECHNICAL RULES (MT4) - MUST FOLLOW
========================
3.1 Multi-pair and New Bar (MUST)
- Parse Symbols into an array (trim spaces, ignore empty tokens).
- Maintain per-symbol state arrays/maps:
  lastBarTime[sym], lastOBMidBuy[sym], lastOBMidSell[sym], lastEntryPriceBuy[sym], lastEntryPriceSell[sym], tradesOpenedThisBar[sym].
- NEW BAR check must use iTime(sym, Timeframe, 0):
  datetime t = iTime(sym, Timeframe, 0);
  if(t == 0) skip (no data).
  if(t != lastBarTime[sym]) { lastBarTime[sym]=t; tradesOpenedThisBar[sym]=0; } else continue processing only non-bar actions if needed (default: bar-only logic).

3.2 Symbol availability
- For each symbol, if MarketInfo(sym, MODE_BID) <= 0 OR MODE_ASK <= 0, log "[SYMBOL] price unavailable" and skip.
- Use RefreshRates() for chart symbol, but get prices for each sym via MarketInfo(sym, MODE_BID/MODE_ASK).

3.3 Spread filter (MUST)
- spreadPoints = (int)MarketInfo(sym, MODE_SPREAD); // points
- Block any NEW order if spreadPoints > Maximum_Spread. Log reason.

3.4 Pips conversion helper (MUST)
Implement:
- double PointOf(sym) => MarketInfo(sym, MODE_POINT)
- int DigitsOf(sym) => (int)MarketInfo(sym, MODE_DIGITS)
- double PipPoint(sym):
    if DigitsOf(sym)==5 or DigitsOf(sym)==3 => 10*PointOf(sym)
    else => PointOf(sym)
All *_Pips inputs must be converted using PipPoint(sym).

3.5 OrderSend safety
- Normalize lots:
  minLot=MODE_MINLOT, maxLot=MODE_MAXLOT, step=MODE_LOTSTEP
  lot = clamp(lot, minLot, maxLot); lot = floor(lot/step)*step
- Normalize prices to digits.
- Retry OrderSend 2-3 times if TradeContextBusy / requote, with Sleep(200-400ms).
- Never touch manual trades or other EAs: filter strictly by MagicNumber AND symbol.

========================
4) STRATEGY DEFAULTS (use these unless a detail is missing)
========================
4.1 Order Block Definition (SMC-style default)
- Bullish OB:
  the LAST bearish candle (Close < Open) immediately before an impulsive bullish move that breaks above a recent swing high (BOS).
  OB zone = [Low, High] of that bearish candle.
- Bearish OB:
  the LAST bullish candle (Close > Open) immediately before an impulsive bearish move that breaks below a recent swing low.
  OB zone = [Low, High] of that bullish candle.

Swings (fractal-like):
- Use L=2 (internal const).
- swingHigh at bar i if High[i] is the maximum among i-L..i+L.
- swingLow similarly.

BOS confirmation:
- A BOS occurs if Close breaks beyond the latest swing by at least buffer:
  bufferPrice = max(spreadPoints*PointOf(sym), 2*PointOf(sym))
- For bullish BOS: Close > lastSwingHigh + bufferPrice
- For bearish BOS: Close < lastSwingLow  - bufferPrice

4.2 OB Validity / Filters
A) OB thickness / OB-to-OB distance:
- If Minimum_OrderBlock_to_OrderBlock_in_Pips is true:
  - If OBtoOB_UseDistanceBetweenOBs is false:
      require (OB_High - OB_Low) >= Min_OrderBlock_in_Pips * PipPoint(sym)
  - If OBtoOB_UseDistanceBetweenOBs is true:
      store lastOBMid per direction; require abs(currOBMid - lastOBMid) >= Min_OrderBlock_in_Pips * PipPoint(sym)

B) Daily ATR filter:
- atr = iATR(sym, PERIOD_D1, ATR_Period, 0)
- require (OB_High - OB_Low) >= Min_OBtoOB_in_Daily_ATR * atr
If any filter fails, skip and log.

4.3 Entry Trigger (retest + confirmation)
- Retest means price trades into OB zone during the current H1 bar:
  For BUY: Ask is inside [OB_Low, OB_High]
  For SELL: Bid is inside [OB_Low, OB_High]
- Confirmation (default):
  - BUY: current H1 candle closes bullish (Close > Open) OR Close > OB_mid
  - SELL: closes bearish (Close < Open) OR Close < OB_mid
- Only open at most MaxNewTradesPerBar per symbol per new bar (including averaging).
- Respect Trading_Side (BUY_ONLY/SELL_ONLY/BOTH).

4.4 Trend Filter (Higher TF)
- trendUp if Close(Timeframe_Trend,0) > EMA(Timeframe_Trend, Trend_EMA_Period)
- trendDown if Close < EMA
- If Ignore_Counter_Trend is true:
  block SELL when trendUp; block BUY when trendDown

4.5 Hedging / Opposite Orders Rules
- If Disable_Place_Opposite_Order is true:
  if any EA position exists in opposite direction (same sym + MagicNumber), block opposite entries.
- If averaging level > Disable_New_Opposite_Order_When_Averaging_More_Than:
  disallow opening opposite-direction orders (keep only same direction logic).

4.6 Martingale / Averaging Rules
Basket definition:
- per symbol + MagicNumber.
- Compute: countBuy, countSell, sumProfitMoney, sumLotsBuy, sumLotsSell, totalEAOrdersAllSymbols.

Level:
- For a direction: level = countDirection - 1.
- Never exceed Maximum_Martingale (or reduced by AntiMC dynamic cap if enabled).

When to add:
- If Enable_Martingale is true:
  - If Averaging_Distance_Pips > 0:
      add next order in same direction when price moves against lastEntryPrice by >= Averaging_Distance_Pips*PipPoint(sym)
  - Else:
      add only when a fresh OB entry signal triggers while positions already exist in that direction.
- If Enable_Martingale is false:
  - If Disable_Place_New_Order_When_No_Martingale is true: block all new orders.
  - Else: allow single entries (no averaging), one per direction depending on rules.

4.7 Lot Sizing
- baseLot:
  if Posisi_Size_Automatically:
    baseLot = (Use_Equity_Instead_of_Balance ? AccountEquity() : AccountBalance()) / Position_Size_Adjust_Factor
    baseLot = max(baseLot, Posisi_Size_Fixed) // fixed as minimum/base
  else:
    baseLot = Posisi_Size_Fixed
- lot(level n) = baseLot * pow(Martingale_Multiplier, n)
- Normalize lot to broker constraints.

4.8 Basket Close & Cut Loss (Money)
- sumProfitMoney = sum(OrderProfit + OrderSwap + OrderCommission) across EA orders for symbol.
- If sumProfitMoney >= Minimum_Profit_In_Money_for_Martingale: close ALL EA orders for that symbol.
- If Enable_Auto_Cut_Loss and sumProfitMoney <= -Cut_Loss_if_Floating_Minus_More_Than: close ALL EA orders for that symbol.

========================
5) ANTI-MARGIN-CALL MODULE (MUST IMPLEMENT)
========================
Add robust risk controls to minimize margin call probability. Provide inputs and enforce them strictly.

[Anti-MC Inputs]
input bool   AntiMC_Enable = true;

input double AntiMC_MinMarginLevelPercent = 200.0;
// marginLevel = (AccountEquity()/AccountMargin())*100 when AccountMargin()>0
// if marginLevel < AntiMC_MinMarginLevelPercent: block NEW trades.

input double AntiMC_PanicCloseMarginLevelPercent = 120.0;
// if marginLevel < this: panic close (configurable below)

input bool   AntiMC_CloseAllEAOnPanic = true;
// true: close all EA orders (MagicNumber) across all symbols
// false: close worst baskets first (most negative sumProfitMoney per symbol) until marginLevel recovers.

input double AntiMC_MaxEquityDrawdownPercent = 25.0;
// Track peakEquity since EA start. drawdown% = (peakEquity-Equity)/peakEquity*100

input bool   AntiMC_CloseEAOnMaxDD = true;

input int    AntiMC_MaxTotalOrdersEA = 20;
input int    AntiMC_MaxOrdersPerSymbol = 7;

input double AntiMC_MaxLotsTotal = 2.0;
input double AntiMC_MaxLotsPerSymbol = 0.5;

input bool   AntiMC_UseDynamicMartingaleCap = true;
// if marginLevel>=500 -> allow Maximum_Martingale
// 300-499 -> allow min(Maximum_Martingale,3)
// 200-299 -> allow min(Maximum_Martingale,2)
// <200 -> allow 0 (no averaging + block new trades)

input bool   AntiMC_BlockNewsMinutes = false;
input int    AntiMC_NewsBlockWindowMin = 15;
// Provide placeholder IsHighImpactNewsNow(sym)=false by default. Document limitation in README.

[Behavior Requirements]
1) MarginLevel guard:
- If AccountMargin() <= 0: treat marginLevel as very high (e.g., 99999) and never panic close.
- If AntiMC_Enable:
  - If marginLevel < AntiMC_MinMarginLevelPercent: block any NEW trades and log [AntiMC] BlockNewTrade.
  - Enforce AntiMC_MaxTotalOrdersEA / AntiMC_MaxOrdersPerSymbol.
  - Enforce AntiMC_MaxLotsTotal / AntiMC_MaxLotsPerSymbol; if adding a new order exceeds, reduce lot to remaining allowed; if below minLot then skip.

2) Panic Close:
- If AntiMC_Enable and AccountMargin()>0 and marginLevel < AntiMC_PanicCloseMarginLevelPercent:
  - If AntiMC_CloseAllEAOnPanic: close ALL EA orders across all symbols immediately.
  - Else: compute basket profit per symbol, close the worst (most negative) basket first; repeat until marginLevel >= AntiMC_MinMarginLevelPercent or no EA orders remain.
  - Must handle trade context busy; retry with short delays.
  - Log [AntiMC] PanicClose actions.

3) Equity Drawdown Guard:
- Track peakEquity since EA start.
- If AntiMC_Enable and drawdown% >= AntiMC_MaxEquityDrawdownPercent:
  - Block new trades.
  - If AntiMC_CloseEAOnMaxDD: close all EA orders.
  - Log [AntiMC] MaxDD.

4) Dynamic Martingale Cap:
- If AntiMC_UseDynamicMartingaleCap:
  compute allowedMaxMartingale based on marginLevel mapping above.
  Use allowedMaxMartingale as the effective cap (min of configured Maximum_Martingale and allowed cap).

========================
6) LOGGING & SAFETY
========================
- Log why signals are skipped: spread too high, counter-trend, ATR filter fail, max martingale reached, opposite blocked, max orders/lots, etc.
- Prefix: [KilatArthaEA][SYMBOL] and for anti-mc include [AntiMC] tags.
- Ensure EA NEVER touches manual trades or other EAs (MagicNumber + symbol filter).

========================
7) ACCEPTANCE CRITERIA
========================
- Compiles cleanly in MT4.
- Multi-pair loop works: EA can open orders on symbols listed in Symbols input.
- New-bar detection is correct per symbol using iTime(sym, Timeframe, 0).
- Spread filter uses MODE_SPREAD (points) and blocks entries above Maximum_Spread.
- Pips conversion helper implemented and used for all *_Pips inputs.
- Trend filter works on MN1 EMA(Trend_EMA_Period) by default.
- OB detection + retest entry implemented with fractal BOS logic.
- Martingale levels/multiplier apply correctly and never exceed effective cap (including AntiMC dynamic cap).
- Basket closes on profit target; optional cut-loss closes on loss threshold.
- AntiMC module blocks new trades below margin threshold and performs panic close below panic threshold.
- README documents assumptions + MT4 Strategy Tester limitation: multi-symbol backtests are limited; forward testing recommended.

Now implement.