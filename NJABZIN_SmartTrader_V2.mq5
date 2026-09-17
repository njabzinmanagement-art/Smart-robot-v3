//+------------------------------------------------------------------+
//| NJABZIN_SmartTrader_V2.mq5                                      |
//| MT5 EA + HTTPS bridge to NJABZIN Smart Trader Android app        |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

input ENUM_TIMEFRAMES SignalTF = PERIOD_M15;
input int FastEMA=20, SlowEMA=50, RSIPeriod=14;
input double BuyRSI=55.0, SellRSI=45.0;
input double RiskPercent=0.50, RewardRisk=2.0;
input int ATRPeriod=14;
input double ATRMultiplier=1.5;
input int MaxSpreadPts=30, MaxTradesDay=5, CooldownBars=1;
input double DailyLossPct=2.0;
input bool UseBreakEven=true;
input double BreakEvenRR=1.0;
input int BreakEvenPlusPts=2;
input ulong MagicNumber=5011520;

// Bridge settings
input string BridgeBaseURL="https://YOUR-VPS-DOMAIN";
input string DeviceToken="CHANGE_DEVICE_TOKEN";
input int PollSeconds=3;

int hFastEMA=INVALID_HANDLE,hSlowEMA=INVALID_HANDLE,hRSI=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime lastBarTime=0,lastTradeTime=0;
double dayStartEquity=0.0;
int dayOfYear=-1;
bool botRunning=false;
int remoteMaxTrades=5;
double remoteRisk=0.50;
double remoteDailyLoss=2.0;
long lastCommandId=-1;

// ---------- Utility ----------
string Url(const string path){ return BridgeBaseURL + path; }

bool BridgeRequest(const string method,const string path,const string body,string &response)
{
   string headers="Content-Type: application/json\r\nX-Device-Token: "+DeviceToken+"\r\n";
   char data[],result[];
   string responseHeaders="";
   StringToCharArray(body,data,0,StringLen(body));
   ResetLastError();
   int code=WebRequest(method,Url(path),headers,7000,data,ArraySize(data)-1,result,responseHeaders);
   if(code<0)
   {
      Print("Bridge WebRequest failed. Error=",GetLastError());
      return false;
   }
   response=CharArrayToString(result);
   return (code>=200 && code<300);
}

string JsonValue(const string json,const string key)
{
   string k="\""+key+"\":";
   int p=StringFind(json,k);
   if(p<0) return "";
   p+=StringLen(k);
   while(p<StringLen(json) && (StringGetCharacter(json,p)==' ' || StringGetCharacter(json,p)=='\"')) p++;
   int e=p;
   while(e<StringLen(json))
   {
      ushort c=StringGetCharacter(json,e);
      if(c==',' || c=='}' || c=='\"') break;
      e++;
   }
   return StringSubstr(json,p,e-p);
}

double JsonDouble(const string j,const string k,double fallback)
{
   string v=JsonValue(j,k);
   if(v=="") return fallback;
   return StringToDouble(v);
}

int JsonInt(const string j,const string k,int fallback)
{
   string v=JsonValue(j,k);
   if(v=="") return fallback;
   return (int)StringToInteger(v);
}

bool JsonBool(const string j,const string k,bool fallback)
{
   string v=JsonValue(j,k);
   if(v=="true") return true;
   if(v=="false") return false;
   return fallback;
}

void PollBridge()
{
   string r;
   if(!BridgeRequest("GET","/api/v1/device/poll","",r)) return;

   lastCommandId=(long)JsonDouble(r,"command_id",(double)lastCommandId);
   botRunning=JsonBool(r,"running",botRunning);
   remoteRisk=JsonDouble(r,"risk",remoteRisk);
   remoteMaxTrades=JsonInt(r,"max_trades",remoteMaxTrades);
   remoteDailyLoss=JsonDouble(r,"daily_loss",remoteDailyLoss);
}

void SendStatus()
{
   MqlTick tick;
   SymbolInfoTick(_Symbol,tick);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double profit=equity-balance;

   string position="NONE";
   double volume=0;
   if(PositionSelect(_Symbol))
   {
      long type=PositionGetInteger(POSITION_TYPE);
      position=(type==POSITION_TYPE_BUY ? "BUY":"SELL");
      volume=PositionGetDouble(POSITION_VOLUME);
   }

   string signal="WAITING";
   string body=StringFormat(
      "{\"balance\":%.2f,\"equity\":%.2f,\"profit\":%.2f,\"symbol\":\"%s\",\"position\":\"%s\",\"position_volume\":%.2f,\"last_signal\":\"%s\",\"running\":%s}",
      balance,equity,profit,_Symbol,position,volume,signal,(botRunning?"true":"false")
   );

   string r;
   BridgeRequest("POST","/api/v1/device/status",body,r);
}

// ---------- Trading logic ----------
int VolumeDigits(double step)
{
   int d=0;
   while(d<8 && MathAbs(step-NormalizeDouble(step,d))>1e-10) d++;
   return d;
}

double CalculateVolumeByRisk(double slDistance)
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney=equity*remoteRisk/100.0;
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(riskMoney<=0 || slDistance<=0 || tickSize<=0 || tickValue<=0) return 0;
   double moneyPerLot=(slDistance/tickSize)*tickValue;
   double volume=riskMoney/moneyPerLot;
   double vMin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vMax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double vStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vStep<=0) vStep=vMin;
   volume=MathFloor(volume/vStep)*vStep;
   volume=MathMax(vMin,MathMin(vMax,volume));
   return NormalizeDouble(volume,VolumeDigits(vStep));
}

bool IsNewBar()
{
   datetime t=iTime(_Symbol,SignalTF,0);
   if(t==0 || t==lastBarTime) return false;
   lastBarTime=t;
   return true;
}

void ResetDay()
{
   MqlDateTime n; TimeToStruct(TimeCurrent(),n);
   if(n.day_of_year!=dayOfYear)
   {
      dayOfYear=n.day_of_year;
      dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

double DailyLoss()
{
   if(dayStartEquity<=0) return 0;
   double loss=(dayStartEquity-AccountInfoDouble(ACCOUNT_EQUITY))/dayStartEquity*100.0;
   return MathMax(0.0,loss);
}

int TodayTrades()
{
   MqlDateTime d; TimeToStruct(TimeCurrent(),d);
   d.hour=0;d.min=0;d.sec=0;
   if(!HistorySelect(StructToTime(d),TimeCurrent())) return 0;
   int c=0;
   uint total=HistoryDealsTotal();
   for(uint i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_IN) c++;
   }
   return c;
}

void OpenTrade(ENUM_ORDER_TYPE type,double atr)
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double spread=(tick.ask-tick.bid)/_Point;
   if(spread>MaxSpreadPts) return;

   double slDist=atr*ATRMultiplier;
   double minStop=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(slDist<minStop) slDist=minStop;

   double entry=(type==ORDER_TYPE_BUY?tick.ask:tick.bid);
   double sl=(type==ORDER_TYPE_BUY?entry-slDist:entry+slDist);
   double tp=(type==ORDER_TYPE_BUY?entry+slDist*RewardRisk:entry-slDist*RewardRisk);
   sl=NormalizeDouble(sl,_Digits); tp=NormalizeDouble(tp,_Digits);

   double vol=CalculateVolumeByRisk(slDist);
   if(vol<=0) return;

   bool ok=(type==ORDER_TYPE_BUY)
      ? trade.Buy(vol,_Symbol,0,sl,tp,"NJABZIN V2 BUY")
      : trade.Sell(vol,_Symbol,0,sl,tp,"NJABZIN V2 SELL");

   if(ok) lastTradeTime=TimeCurrent();
}

void ManagePosition()
{
   if(!UseBreakEven || !PositionSelect(_Symbol)) return;
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) return;

   ENUM_POSITION_TYPE t=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   if(sl<=0 || tp<=0) return;

   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double risk=MathAbs(open-sl);
   double gain=(t==POSITION_TYPE_BUY?tick.bid-open:open-tick.ask);
   if(gain<risk*BreakEvenRR) return;

   double newSL=(t==POSITION_TYPE_BUY?open+BreakEvenPlusPts*_Point:open-BreakEvenPlusPts*_Point);
   newSL=NormalizeDouble(newSL,_Digits);

   if((t==POSITION_TYPE_BUY && newSL>sl) || (t==POSITION_TYPE_SELL && newSL<sl))
      trade.PositionModify(_Symbol,newSL,tp);
}

void Evaluate()
{
   if(!botRunning) return;
   if(PositionSelect(_Symbol) && (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) return;
   if(TodayTrades()>=remoteMaxTrades || DailyLoss()>=remoteDailyLoss) return;

   double fast[3],slow[3],rsi[3],atr[3];
   if(CopyBuffer(hFastEMA,0,1,3,fast)<3) return;
   if(CopyBuffer(hSlowEMA,0,1,3,slow)<3) return;
   if(CopyBuffer(hRSI,0,1,3,rsi)<3) return;
   if(CopyBuffer(hATR,0,1,3,atr)<3) return;

   MqlRates rates[3];
   if(CopyRates(_Symbol,SignalTF,1,3,rates)<3) return;

   double c1=rates[2].close,c2=rates[1].close;
   bool buy=fast[2]>slow[2] && c1>fast[2] && rsi[2]>=BuyRSI && c2<=fast[1];
   bool sell=fast[2]<slow[2] && c1<fast[2] && rsi[2]<=SellRSI && c2>=fast[1];

   if(buy) OpenTrade(ORDER_TYPE_BUY,atr[2]);
   else if(sell) OpenTrade(ORDER_TYPE_SELL,atr[2]);
}

// ---------- Events ----------
int OnInit()
{
   hFastEMA=iMA(_Symbol,SignalTF,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlowEMA=iMA(_Symbol,SignalTF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,SignalTF,RSIPeriod,PRICE_CLOSE);
   hATR=iATR(_Symbol,SignalTF,ATRPeriod);
   if(hFastEMA==INVALID_HANDLE || hSlowEMA==INVALID_HANDLE || hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   EventSetTimer(MathMax(2,PollSeconds));
   ResetDay();
   PollBridge();
   SendStatus();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   IndicatorRelease(hFastEMA);
   IndicatorRelease(hSlowEMA);
   IndicatorRelease(hRSI);
   IndicatorRelease(hATR);
}

void OnTimer()
{
   PollBridge();
   SendStatus();
}

void OnTick()
{
   ResetDay();
   ManagePosition();
   if(IsNewBar()) Evaluate();
}
