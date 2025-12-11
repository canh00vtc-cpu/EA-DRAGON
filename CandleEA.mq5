//+------------------------------------------------------------------+
//|     CandleEA v7.43 - MAIN FIXED TP                              |
//|     ✅ NEW: TP cố định cho MAIN (có thể bật/tắt)                |
//|     ✅ Khi hedge khớp → XÓA TP MAIN, quay về logic cũ           |
//+------------------------------------------------------------------+
#property strict
#property version "7.43"

#define MAGIC_MAIN  123456
#define MAGIC_HEDGE 789012

input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M5;
input double          InpLotSize   = 0.1;
input double          InpStopLoss  = 50;
input double          InpTakeProfitPips = 100;
input double          InpTakeProfitMoney = 100;

// ✅✅✅ THÊM INPUT MỚI - TP CỐ ĐỊNH CHO MAIN
input bool   InpUseMainFixedTP      = true;    // Dùng TP cố định cho MAIN?
input double InpMainFixedTPPips     = 100;     // TP cố định cho MAIN (pips)

input bool   InpUseBreakEven        = true;
input double InpBreakEvenPips       = 10;
input double InpBreakEvenOffsetPips = 2;

input double InpDistancePips        = 0;

input bool   InpUseHedge            = true;
input double InpHedgeDistancePips   = 200;
input double InpHedgeLotSize        = 0.03;
input double InpHedgeTakeProfitPips = 150;
input double InpHedgeStopLossPips   = 70;

input bool   InpAutoRecoverHedge    = true;
input double InpHedgeSafeDistancePips = 50;
input double InpHedgeUrgentDistancePips = 10;

input bool   InpUseHedgeMartingale  = true;
input double InpHedgeMultiplier     = 3.0;
input int    InpMaxHedgeLevels      = 5;

input bool   InpUseTimeFilter       = true;
input int    InpStartHour           = 0;
input int    InpStartMinute         = 0;
input int    InpStopHour            = 23;
input int    InpStopMinute          = 59;

//+------------------------------------------------------------------+
//| ✅ ENUM: Trạng thái hedge                                       |
//+------------------------------------------------------------------+
enum ENUM_HEDGE_STATE
{
   HEDGE_STATE_PENDING,      // Pending order (chờ khớp)
   HEDGE_STATE_POSITION,     // Position (đã khớp)
   HEDGE_STATE_CLOSED        // Đã đóng
};

//+------------------------------------------------------------------+
//| ✅ STRUCT LƯU THÔNG TIN HEDGE - BẢN ĐẦY ĐỦ NHẤT                |
//+------------------------------------------------------------------+
struct HedgeInfo
{
   ulong ticket;                    // Ticket hiện tại (pending hoặc position)
   ulong originalPendingTicket;     // Ticket pending gốc (để tracking)
   ENUM_ORDER_TYPE type;            // BUY_STOP hoặc SELL_STOP
   ENUM_HEDGE_STATE state;          // PENDING, POSITION, hoặc CLOSED
   double lot;                      // Khối lượng
   double price;                    // Giá đặt lệnh
   double sl;                       // Stop Loss
   double tp;                       // Take Profit
   int level;                       // Level martingale (0, 1, 2...)
   datetime timeCreated;            // Thời gian tạo
   datetime timeLastUpdate;         // Thời gian cập nhật cuối
   bool shouldRecover;              // Có nên khôi phục không
};

//+------------------------------------------------------------------+
//| ✅ DYNAMIC ARRAY LƯU TẤT CẢ HEDGE                               |
//+------------------------------------------------------------------+
HedgeInfo hedgeList[];
int hedgeCount = 0;

datetime lastBarTime = 0;
int hedgeLevel = 0;
bool eaActive = true;
bool isDeletingHedgeIntentionally = false;
bool isOpeningHedge = false;
bool isClosingAllPositions = false;

//+------------------------------------------------------------------+
//| ✅ THÊM HEDGE VÀO DANH SÁCH                                     |
//+------------------------------------------------------------------+
void AddHedgeToList(ulong ticket, ENUM_ORDER_TYPE type, double lot, double price, 
                    double sl, double tp, int level)
{
   ArrayResize(hedgeList, hedgeCount + 1);
   
   hedgeList[hedgeCount].ticket = ticket;
   hedgeList[hedgeCount].originalPendingTicket = ticket;
   hedgeList[hedgeCount].type = type;
   hedgeList[hedgeCount].state = HEDGE_STATE_PENDING;
   hedgeList[hedgeCount].lot = lot;
   hedgeList[hedgeCount].price = price;
   hedgeList[hedgeCount].sl = sl;
   hedgeList[hedgeCount].tp = tp;
   hedgeList[hedgeCount].level = level;
   hedgeList[hedgeCount].timeCreated = TimeCurrent();
   hedgeList[hedgeCount].timeLastUpdate = TimeCurrent();
   hedgeList[hedgeCount].shouldRecover = true;
   
   hedgeCount++;
   
   PrintFormat("✅ [ADD] %s ticket %I64u | Lot %.2f | Price %.5f | Level %d | State: PENDING", 
              EnumToString(type), ticket, lot, price, level);
   PrintFormat("   Total hedges: %d", hedgeCount);
}

//+------------------------------------------------------------------+
//| ✅ TÌM HEDGE THEO PENDING TICKET                                |
//+------------------------------------------------------------------+
int FindHedgeByPendingTicket(ulong ticket)
{
   for(int i = 0; i < hedgeCount; i++)
   {
      if(hedgeList[i].originalPendingTicket == ticket)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| ✅ TÌM HEDGE THEO POSITION TICKET                               |
//+------------------------------------------------------------------+
int FindHedgeByPositionTicket(ulong ticket)
{
   for(int i = 0; i < hedgeCount; i++)
   {
      if(hedgeList[i].state == HEDGE_STATE_POSITION && hedgeList[i].ticket == ticket)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| ✅ CẬP NHẬT: Pending → Position khi khớp                        |
//+------------------------------------------------------------------+
void UpdateHedgePendingToPosition(ulong pendingTicket, ulong positionTicket, double fillPrice)
{
   int index = FindHedgeByPendingTicket(pendingTicket);
   if(index >= 0)
   {
      hedgeList[index].ticket = positionTicket;
      hedgeList[index].state = HEDGE_STATE_POSITION;
      hedgeList[index].price = fillPrice;
      hedgeList[index].timeLastUpdate = TimeCurrent();
      
      PrintFormat("🔄 [UPDATE] Pending %I64u → Position %I64u | Level %d | State: POSITION", 
                 pendingTicket, positionTicket, hedgeList[index].level);
   }
}

//+------------------------------------------------------------------+
//| ✅ ĐÁNH DẤU HEDGE ĐÃ ĐÓNG                                       |
//+------------------------------------------------------------------+
void MarkHedgeClosed(int index, string reason)
{
   if(index >= 0 && index < hedgeCount)
   {
      hedgeList[index].state = HEDGE_STATE_CLOSED;
      hedgeList[index].timeLastUpdate = TimeCurrent();
      
      PrintFormat("🔴 [CLOSE] %s ticket %I64u | Level %d | Reason: %s", 
                 EnumToString(hedgeList[index].type), 
                 hedgeList[index].ticket, 
                 hedgeList[index].level, 
                 reason);
   }
}

//+------------------------------------------------------------------+
//| ✅ XÓA HEDGE KHÔNG CẦN KHÔI PHỤC                                |
//+------------------------------------------------------------------+
void DisableHedgeRecovery(int index, string reason)
{
   if(index >= 0 && index < hedgeCount)
   {
      hedgeList[index].shouldRecover = false;
      PrintFormat("⛔ [DISABLE] Hedge ticket %I64u Level %d | No recover: %s", 
                 hedgeList[index].ticket, hedgeList[index].level, reason);
   }
}

//+------------------------------------------------------------------+
//| ✅ XÓA TẤT CẢ HEDGE TRONG DANH SÁCH                             |
//+------------------------------------------------------------------+
void ClearHedgeList()
{
   PrintFormat("🗑️ [CLEAR] Xoa toan bo danh sach (%d hedges)", hedgeCount);
   ArrayResize(hedgeList, 0);
   hedgeCount = 0;
}

//+------------------------------------------------------------------+
//| ✅ DỌN DẸP HEDGE CŨ (đã đóng > 1 giờ)                          |
//+------------------------------------------------------------------+
void CleanupOldClosedHedges()
{
   datetime now = TimeCurrent();
   int cleanupCount = 0;
   
   for(int i = hedgeCount - 1; i >= 0; i--)
   {
      if(hedgeList[i].state == HEDGE_STATE_CLOSED)
      {
         if(now - hedgeList[i].timeLastUpdate > 3600)
         {
            // Xóa phần tử khỏi array
            for(int j = i; j < hedgeCount - 1; j++)
            {
               hedgeList[j] = hedgeList[j + 1];
            }
            hedgeCount--;
            ArrayResize(hedgeList, hedgeCount);
            cleanupCount++;
         }
      }
   }
   
   if(cleanupCount > 0)
      PrintFormat("🧹 [CLEANUP] Da don dep %d hedge cu", cleanupCount);
}

//+------------------------------------------------------------------+
//| ✅ IN DANH SÁCH HEDGE                                           |
//+------------------------------------------------------------------+
void PrintHedgeList()
{
   Print("========== DANH SÁCH HEDGE ==========");
   PrintFormat("Total: %d hedges", hedgeCount);
   
   int pendingCount = 0, positionCount = 0, closedCount = 0;
   
   for(int i = 0; i < hedgeCount; i++)
   {
      string stateStr = "";
      if(hedgeList[i].state == HEDGE_STATE_PENDING) { stateStr = "PENDING"; pendingCount++; }
      else if(hedgeList[i].state == HEDGE_STATE_POSITION) { stateStr = "POSITION"; positionCount++; }
      else { stateStr = "CLOSED"; closedCount++; }
      
      PrintFormat("  [%d] %s ticket %I64u | Lot %.2f | Level %d | State: %s | Recover: %s",
                 i, EnumToString(hedgeList[i].type), hedgeList[i].ticket,
                 hedgeList[i].lot, hedgeList[i].level, stateStr,
                 hedgeList[i].shouldRecover ? "YES" : "NO");
   }
   
   PrintFormat("Summary: %d PENDING | %d POSITION | %d CLOSED", 
              pendingCount, positionCount, closedCount);
   Print("=====================================");
}

//+------------------------------------------------------------------+
//| ✅ KIỂM TRA CÓ HEDGE ACTIVE (PENDING hoặc POSITION) KHÔNG       |
//+------------------------------------------------------------------+
bool HasActiveHedgeTypeInList(ENUM_ORDER_TYPE hedgeType)
{
   // Kiểm tra trong array
   for(int i = 0; i < hedgeCount; i++)
   {
      if(hedgeList[i].type == hedgeType && 
         (hedgeList[i].state == HEDGE_STATE_PENDING || hedgeList[i].state == HEDGE_STATE_POSITION))
      {
         PrintFormat("   → Found in list: %s ticket %I64u Level %d State: %s", 
                    EnumToString(hedgeType), hedgeList[i].ticket, hedgeList[i].level,
                    hedgeList[i].state == HEDGE_STATE_PENDING ? "PENDING" : "POSITION");
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| ✅ KIỂM TRA THỰC TẾ TRONG MT5 (double check)                   |
//+------------------------------------------------------------------+
bool HasActiveHedgeTypeInMT5(ENUM_ORDER_TYPE hedgeType)
{
   // Check pending orders
   int ordersTotal = OrdersTotal();
   for(int i = 0; i < ordersTotal; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MAGIC_HEDGE) continue;
      
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == hedgeType)
      {
         PrintFormat("   → Found in MT5 orders: %s ticket %I64u", 
                    EnumToString(hedgeType), ticket);
         return true;
      }
   }
   
   // Check positions
   ENUM_POSITION_TYPE posType = (hedgeType == ORDER_TYPE_BUY_STOP) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   
   int posTotal = PositionsTotal();
   for(int i = 0; i < posTotal; i++)
   {
      string sym = PositionGetSymbol(i);
      if(sym != _Symbol) continue;
      
      ulong magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != MAGIC_HEDGE) continue;
      
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type == posType)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         PrintFormat("   → Found in MT5 positions: %s ticket %I64u", 
                    (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), ticket);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| ✅ KIỂM TRA TOÀN DIỆN: Array + MT5                              |
//+------------------------------------------------------------------+
bool HasActiveHedgeType(ENUM_ORDER_TYPE hedgeType)
{
   PrintFormat("🔍 [CHECK] Co %s hedge active khong?", EnumToString(hedgeType));
   
   bool inList = HasActiveHedgeTypeInList(hedgeType);
   bool inMT5 = HasActiveHedgeTypeInMT5(hedgeType);
   
   if(inList || inMT5)
   {
      PrintFormat("✅ Result: CO (List:%s | MT5:%s)", inList?"YES":"NO", inMT5?"YES":"NO");
      return true;
   }
   
   PrintFormat("❌ Result: KHONG CO");
   return false;
}

int OnInit()
{
   Print("==========================================================");
   Print("CandleEA v7.43 - MAIN FIXED TP");
   Print("- NEW: TP co dinh cho MAIN (co the bat/tat)");
   Print("- Khi hedge khop → XOA TP MAIN, quay ve logic cu");
   Print("- Theo doi PENDING hedge (cho khop)");
   Print("- Theo doi POSITION hedge (da khop)");
   Print("- Phat hien hedge bi xoa/dong BAT KY luc nao");
   Print("- Khoi phuc 100% CHINH XAC: lot, gia, loai lenh");
   Print("==========================================================");
   
   ENUM_ACCOUNT_MARGIN_MODE accountMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   string modeName = "";
   
   if(accountMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      modeName = "NETTING MODE";
   else if(accountMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      modeName = "HEDGE MODE";
   else if(accountMode == ACCOUNT_MARGIN_MODE_EXCHANGE)
      modeName = "EXCHANGE MODE";
   
   PrintFormat("BROKER: %s", AccountInfoString(ACCOUNT_COMPANY));
   PrintFormat("ACCOUNT MODE: %s", modeName);
   PrintFormat("ACCOUNT NUMBER: %d", AccountInfoInteger(ACCOUNT_LOGIN));
   
   // ✅✅✅ IN THÔNG TIN TP MỚI
   Print("==========================================================");
   if(InpUseMainFixedTP)
      PrintFormat("MAIN FIXED TP: BAT - %.1f pips", InpMainFixedTPPips);
   else
      PrintFormat("MAIN FIXED TP: TAT - Dung TP thong thuong %.1f pips", InpTakeProfitPips);
   Print("==========================================================");
   
   hedgeLevel = 0;
   ClearHedgeList();
   
   if(InpUseTimeFilter)
   {
      if(InpStartHour < 0 || InpStartHour > 23 || InpStopHour < 0 || InpStopHour > 23)
      {
         Print("Gio phai tu 0-23!");
         return(INIT_PARAMETERS_INCORRECT);
      }
      if(InpStartMinute < 0 || InpStartMinute > 59 || InpStopMinute < 0 || InpStopMinute > 59)
      {
         Print("Phut phai tu 0-59!");
         return(INIT_PARAMETERS_INCORRECT);
      }
      PrintFormat("Time Filter: BAT %02d:%02d -> TAT %02d:%02d", 
                  InpStartHour, InpStartMinute, InpStopHour, InpStopMinute);
   }
   
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   if(Bars(_Symbol, InpTimeframe) < 10) return;
   
   // Dọn dẹp hedge cũ mỗi 5 phút
   static datetime lastCleanup = 0;
   if(TimeCurrent() - lastCleanup > 300)
   {
      CleanupOldClosedHedges();
      lastCleanup = TimeCurrent();
   }
   
   if(InpUseTimeFilter)
   {
      if(!IsWithinTradingHours())
      {
         if(eaActive)
         {
            if(!HasAnyOpenPositions())
            {
               Print("Ngoai gio - TAT EA");
               DeleteAllPendingOrders();
               eaActive = false;
               Comment(StringFormat("EA TAT\nBAT: %02d:%02d", InpStartHour, InpStartMinute));
               return;
            }
            else
            {
               Comment(StringFormat("CHO DONG\nCon %d lenh", CountOpenPositions()));
               ManageOpenPosition();
               return;
            }
         }
         else
         {
            Comment(StringFormat("EA TAT\nBAT: %02d:%02d", InpStartHour, InpStartMinute));
            return;
         }
      }
      else
      {
         if(!eaActive)
         {
            Print("Vao gio - BAT EA");
            eaActive = true;
         }
         Comment(StringFormat("EA CHAY\nTAT: %02d:%02d", InpStopHour, InpStopMinute));
      }
   }
   
   ManageOpenPosition();
   CheckAndRecoverMissingHedge();

   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 1);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   bool hasMainPosition = HasMainPosition();
   
   if(hasMainPosition)
   {
      DeletePendingByMagic(MAGIC_MAIN);
   }
   else
   {
      DeleteAllPendingOrders();
      ResetHedgeLevel();
      PlaceBreakoutOrders();
   }
}

bool IsWithinTradingHours()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   int currentMinutes = dt.hour * 60 + dt.min;
   int startMinutes = InpStartHour * 60 + InpStartMinute;
   int stopMinutes = InpStopHour * 60 + InpStopMinute;
   
   if(startMinutes > stopMinutes)
      return (currentMinutes >= startMinutes || currentMinutes < stopMinutes);
   else
      return (currentMinutes >= startMinutes && currentMinutes < stopMinutes);
}

int CountOpenPositions()
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      string sym = PositionGetSymbol(i);
      if(sym == _Symbol)
      {
         ulong magic = PositionGetInteger(POSITION_MAGIC);
         if(magic == MAGIC_MAIN || magic == MAGIC_HEDGE)
            count++;
      }
   }
   return count;
}

bool HasMainPosition()
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      string sym = PositionGetSymbol(i);
      if(sym == _Symbol)
      {
         ulong magic = PositionGetInteger(POSITION_MAGIC);
         if(magic == MAGIC_MAIN)
            return true;
      }
   }
   return false;
}

bool HasAnyOpenPositions()
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      string sym = PositionGetSymbol(i);
      if(sym == _Symbol)
      {
         ulong magic = PositionGetInteger(POSITION_MAGIC);
         if(magic == MAGIC_MAIN || magic == MAGIC_HEDGE)
            return true;
      }
   }
   return false;
}

void PlaceBreakoutOrders()
{
   double highPrev = iHigh(_Symbol, InpTimeframe, 1);
   double lowPrev  = iLow(_Symbol,  InpTimeframe, 1);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipValue = point * ((SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 ||
                               SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) ? 10 : 1);

   double buyPrice  = NormalizeDouble(highPrev + (2 + InpDistancePips) * pipValue, _Digits);
   double sellPrice = NormalizeDouble(lowPrev  - (2 + InpDistancePips) * pipValue, _Digits);

   double slBuy  = NormalizeDouble(buyPrice  - InpStopLoss * pipValue, _Digits);
   double slSell = NormalizeDouble(sellPrice + InpStopLoss * pipValue, _Digits);
   double tpBuy  = NormalizeDouble(buyPrice  + InpTakeProfitPips * pipValue, _Digits);
   double tpSell = NormalizeDouble(sellPrice - InpTakeProfitPips * pipValue, _Digits);

   PlacePendingOrder(ORDER_TYPE_BUY_STOP,  buyPrice,  InpLotSize, slBuy,  tpBuy, MAGIC_MAIN, "MAIN", -1);
   PlacePendingOrder(ORDER_TYPE_SELL_STOP, sellPrice, InpLotSize, slSell, tpSell, MAGIC_MAIN, "MAIN", -1);
}

void ManageOpenPosition()
{
   if(!PositionSelect(_Symbol)) return;

   double profit = PositionGetDouble(POSITION_PROFIT);
   ulong  ticket = PositionGetInteger(POSITION_TICKET);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipValue = point * ((SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 ||
                               SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) ? 10 : 1);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(InpTakeProfitMoney > 0 && profit >= InpTakeProfitMoney)
   {
      PrintFormat("TP tien: %.2f USD", profit);
      CloseOrderAtPrice(ticket, (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY,
                        volume, (posType == POSITION_TYPE_BUY) ? bid : ask);
      DeleteHedgeOrders(posType);
      return;
   }

   if(InpUseBreakEven && InpBreakEvenPips > 0)
   {
      double moveDistancePips = 0;
      double newSL = sl;

      if(posType == POSITION_TYPE_BUY)
      {
         moveDistancePips = (bid - openPrice) / pipValue;
         if(moveDistancePips >= InpBreakEvenPips && sl < openPrice)
            newSL = NormalizeDouble(openPrice + InpBreakEvenOffsetPips * pipValue, _Digits);
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         moveDistancePips = (openPrice - ask) / pipValue;
         if(moveDistancePips >= InpBreakEvenPips && sl > openPrice)
            newSL = NormalizeDouble(openPrice - InpBreakEvenOffsetPips * pipValue, _Digits);
      }

      if(newSL != sl)
      {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);

         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = _Symbol;
         req.position = ticket;
         req.sl       = newSL;
         req.tp       = PositionGetDouble(POSITION_TP);

         if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE)
            PrintFormat("BreakEven: SL -> %.5f", newSL);
      }
   }
}

ulong PlacePendingOrder(ENUM_ORDER_TYPE orderType, double price, double lot, 
                        double sl, double tp, ulong magic, string comment, int level)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) 
   {
      PrintFormat("⚠️ LOI: Lot %.2f vuot MAX %.2f - Giam xuong MAX", lot, maxLot);
      lot = maxLot;
   }
   
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = NormalizeDouble(lot, 2);
   
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_PENDING;
   request.symbol       = _Symbol;
   request.volume       = lot;
   request.type         = orderType;
   request.price        = price;
   request.sl           = sl;
   request.tp           = tp;
   request.deviation    = 30;
   request.magic        = magic;
   request.comment      = comment;
   request.type_filling = ORDER_FILLING_RETURN;
   request.type_time    = ORDER_TIME_GTC;

   if(!OrderSend(request, result))
   {
      PrintFormat("❌ Loi gui lenh %s", EnumToString(orderType));
      return 0;
   }

   if(result.retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("❌ Lenh tu choi %s - Code %d", EnumToString(orderType), result.retcode);
      return 0;
   }

   PrintFormat("✅ %s [%s] @ %.5f | Lot %.2f | Ticket %I64u", 
              EnumToString(orderType), comment, price, lot, result.order);
   
   // ✅ THÊM VÀO DANH SÁCH NẾU LÀ HEDGE
   if(magic == MAGIC_HEDGE && level >= 0)
   {
      AddHedgeToList(result.order, orderType, lot, price, sl, tp, level);
   }
   
   return result.order;
}

bool UpdatePositionTPSL(ulong positionTicket, double newSL, double newTP)
{
   if(!PositionSelectByTicket(positionTicket))
      return false;
   
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   if(MathAbs(newSL - currentSL) < _Point && MathAbs(newTP - currentTP) < _Point)
   {
      return true;
   }
   
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = positionTicket;
   req.sl       = newSL;
   req.tp       = newTP;
   
   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE)
      return false;
   
   PrintFormat("Cap nhat TPSL ticket %I64u: SL %.5f TP %.5f", positionTicket, newSL, newTP);
   return true;
}

bool RemovePositionTPSL(ulong positionTicket)
{
   if(!PositionSelectByTicket(positionTicket))
      return false;
   
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   if(currentSL == 0 && currentTP == 0)
      return true;
   
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = positionTicket;
   req.sl       = 0;
   req.tp       = 0;
   
   if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE)
      return false;
   
   PrintFormat("XOA TPSL ticket %I64u (SL %.5f TP %.5f)", positionTicket, currentSL, currentTP);
   return true;
}

//+------------------------------------------------------------------+
//| ✅✅✅ NEW: XÓA TP CỦA TẤT CẢ LỆNH MAIN                         |
//+------------------------------------------------------------------+
void RemoveAllMainPositionTP()
{
   Print("========================================================");
   Print("🔴 XOA TP CO DINH CUA TAT CA MAIN (Hedge da khop)");
   
   int totalRemoved = 0;
   
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) continue;
      
      ulong posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posMagic != MAGIC_MAIN) continue;
      
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentSL = PositionGetDouble(POSITION_SL);
      
      if(currentTP != 0)
      {
         PrintFormat("  Tim thay MAIN ticket %I64u co TP %.5f", ticket, currentTP);
         
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         
         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = _Symbol;
         req.position = ticket;
         req.sl       = currentSL;  // ✅ GIỮ LẠI SL
         req.tp       = 0;          // ✅ XÓA TP
         
         if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE)
         {
            PrintFormat("  ✅ Da xoa TP ticket %I64u (Giu SL %.5f)", ticket, currentSL);
            totalRemoved++;
         }
         else
            PrintFormat("  ❌ Loi xoa TP ticket %I64u", ticket);
      }
   }
   
   if(totalRemoved > 0)
      PrintFormat("✅ TONG KET: Da xoa TP cua %d lenh MAIN", totalRemoved);
   else
      Print("ℹ️ Khong co lenh MAIN nao co TP");
   
   Print("========================================================");
}

void RemoveAllOldSameTypeTPSL(ulong newTicket, ENUM_POSITION_TYPE newType, ulong newMagic)
{
   string typeName = (newType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   string newMagicName = (newMagic == MAGIC_MAIN) ? "MAIN" : "HEDGE";
   
   Print("======================================================");
   PrintFormat("LENH MOI: [%s] %s ticket %I64u", newMagicName, typeName, newTicket);
   PrintFormat("XOA TAT CA LENH %s CU (BAT KE MAIN/HEDGE)", typeName);
   
   int totalRemoved = 0;
   
   for(int pass = 1; pass <= 5; pass++)
   {
      PrintFormat("--- QUET LAN %d ---", pass);
      
      ulong ticketsToRemove[];
      int removeCount = 0;
      
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         
         if(ticket == newTicket) continue;
         
         if(!PositionSelectByTicket(ticket)) continue;
         
         string sym = PositionGetString(POSITION_SYMBOL);
         if(sym != _Symbol) continue;
         
         ulong posMagic = PositionGetInteger(POSITION_MAGIC);
         
         if(posMagic != MAGIC_MAIN && posMagic != MAGIC_HEDGE) continue;
         
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         if(posType == newType)
         {
            double posSL = PositionGetDouble(POSITION_SL);
            double posTP = PositionGetDouble(POSITION_TP);
            
            if(posSL != 0 || posTP != 0)
            {
               string posMagicName = (posMagic == MAGIC_MAIN) ? "MAIN" : "HEDGE";
               PrintFormat("  Tim thay [%s] ticket %I64u (SL %.5f TP %.5f)", 
                          posMagicName, ticket, posSL, posTP);
               
               ArrayResize(ticketsToRemove, removeCount + 1);
               ticketsToRemove[removeCount] = ticket;
               removeCount++;
            }
         }
      }
      
      if(removeCount == 0)
      {
         PrintFormat("  Lan %d: Khong con lenh %s nao co TPSL", pass, typeName);
         break;
      }
      
      int successCount = 0;
      for(int i = 0; i < removeCount; i++)
      {
         if(RemovePositionTPSL(ticketsToRemove[i]))
            successCount++;
         else
            PrintFormat("  LOI: Khong xoa duoc ticket %I64u", ticketsToRemove[i]);
      }
      
      totalRemoved += successCount;
      PrintFormat("  Lan %d: Da xoa %d/%d lenh", pass, successCount, removeCount);
   }
   
   PrintFormat("TONG KET: Da xoa %d lenh %s TPSL", totalRemoved, typeName);
   Print("======================================================");
}

void DeleteHedgeOrders(ENUM_POSITION_TYPE closedType)
{
   isDeletingHedgeIntentionally = true;
   
   ENUM_ORDER_TYPE targetType = (closedType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
   
   Print("--- XOA TAT CA HEDGE TUONG UNG ---");
   PrintFormat("Main %s dong → Xoa tat ca %s hedge", 
              (closedType == POSITION_TYPE_BUY ? "BUY" : "SELL"),
              EnumToString(targetType));
   
   // Đánh dấu không recover các hedge này
   for(int i = 0; i < hedgeCount; i++)
   {
      if(hedgeList[i].type == targetType)
      {
         DisableHedgeRecovery(i, "Main dong");
      }
   }
   
   int deleteCount = 0;
   int total = OrdersTotal();
   
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      
      string sym = OrderGetString(ORDER_SYMBOL);
      if(sym != _Symbol) continue;
      
      ulong magic = OrderGetInteger(ORDER_MAGIC);
      if(magic != MAGIC_HEDGE) continue;
      
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == targetType)
      {
         double price = OrderGetDouble(ORDER_PRICE_OPEN);
         
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = ticket;
         req.symbol = _Symbol;

         if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE)
         {
            PrintFormat("Xoa %s ticket %I64u @ %.5f", EnumToString(type), ticket, price);
            
            int index = FindHedgeByPendingTicket(ticket);
            if(index >= 0)
               MarkHedgeClosed(index, "Main dong - xoa pending");
            
            deleteCount++;
         }
      }
   }
   
   PrintFormat("Tong: Da xoa %d lenh hedge", deleteCount);
   isDeletingHedgeIntentionally = false;
}

void DeleteOrderByTicket(ulong ticket)
{
   if(ticket == 0) return;
   
   if(!OrderSelect(ticket))
   {
      PrintFormat("CANH BAO: Khong tim thay order ticket %I64u", ticket);
      return;
   }
   
   ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   double price = OrderGetDouble(ORDER_PRICE_OPEN);
   ulong magic = OrderGetInteger(ORDER_MAGIC);
   string magicName = (magic == MAGIC_MAIN) ? "MAIN" : "HEDGE";
   
   if(magic == MAGIC_HEDGE)
      isDeletingHedgeIntentionally = true;
   
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   
   req.action = TRADE_ACTION_REMOVE;
   req.order  = ticket;
   req.symbol = _Symbol;

   bool sent = OrderSend(req, res);
   if(sent && res.retcode == TRADE_RETCODE_DONE)
   {
      PrintFormat("XOA LENH CHO [%s]: %s ticket %I64u @ %.5f", 
                  magicName, EnumToString(orderType), ticket, price);
      
      if(magic == MAGIC_HEDGE)
      {
         int index = FindHedgeByPendingTicket(ticket);
         if(index >= 0)
         {
            DisableHedgeRecovery(index, "Xoa thu cong");
            MarkHedgeClosed(index, "Xoa thu cong");
         }
      }
   }
   else
      PrintFormat("LOI XOA LENH CHO [%s]: %s ticket %I64u - Code %d", 
                  magicName, EnumToString(orderType), ticket, res.retcode);
   
   isDeletingHedgeIntentionally = false;
}

void DeletePendingByMagic(ulong targetMagic)
{
   string magicName = (targetMagic == MAGIC_MAIN) ? "MAIN" : "HEDGE";
   Print("--- XOA LENH CHO ", magicName, " ---");
   
   if(targetMagic == MAGIC_HEDGE)
      isDeletingHedgeIntentionally = true;
   
   int deleteCount = 0;
   int total = OrdersTotal();
   
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      
      string sym = OrderGetString(ORDER_SYMBOL);
      if(sym != _Symbol) continue;
      
      ulong magic = OrderGetInteger(ORDER_MAGIC);
      if(magic != targetMagic) continue;
      
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
      {
         double price = OrderGetDouble(ORDER_PRICE_OPEN);
         
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = ticket;
         req.symbol = _Symbol;

         bool sent = OrderSend(req, res);
         if(sent && res.retcode == TRADE_RETCODE_DONE)
         {
            PrintFormat("Xoa [%s] %s ticket %I64u @ %.5f", 
                       magicName, EnumToString(type), ticket, price);
            
            if(magic == MAGIC_HEDGE)
            {
               int index = FindHedgeByPendingTicket(ticket);
               if(index >= 0)
               {
                  DisableHedgeRecovery(index, "Xoa theo magic");
                  MarkHedgeClosed(index, "Xoa theo magic");
               }
            }
            
            deleteCount++;
         }
         else
            PrintFormat("Loi xoa [%s] pending ticket %I64u - Code %d", 
                       magicName, ticket, res.retcode);
      }
   }
   
   PrintFormat("Tong: Da xoa %d lenh cho %s", deleteCount, magicName);
   
   isDeletingHedgeIntentionally = false;
}

void DeleteAllPendingOrders()
{
   Print("=== XOA TAT CA LENH CHO (MAIN + HEDGE) ===");
   
   isDeletingHedgeIntentionally = true;
   
   int deleteCount = 0;
   int total = OrdersTotal();
   
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      
      string sym = OrderGetString(ORDER_SYMBOL);
      if(sym != _Symbol) continue;
      
      ulong magic = OrderGetInteger(ORDER_MAGIC);
      if(magic != MAGIC_MAIN && magic != MAGIC_HEDGE) continue;
      
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
      {
         string magicName = (magic == MAGIC_MAIN) ? "MAIN" : "HEDGE";
         double price = OrderGetDouble(ORDER_PRICE_OPEN);
         
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = ticket;
         req.symbol = _Symbol;

         bool sent = OrderSend(req, res);
         if(sent && res.retcode == TRADE_RETCODE_DONE)
         {
            PrintFormat("Xoa [%s] %s ticket %I64u @ %.5f", 
                       magicName, EnumToString(type), ticket, price);
            
            if(magic == MAGIC_HEDGE)
            {
               int index = FindHedgeByPendingTicket(ticket);
               if(index >= 0)
               {
                  DisableHedgeRecovery(index, "Xoa tat ca");
                  MarkHedgeClosed(index, "Xoa tat ca");
               }
            }
            
            deleteCount++;
         }
         else
            PrintFormat("Loi xoa all pending ticket %I64u - Code %d", ticket, res.retcode);
      }
   }
   
   PrintFormat("Tong: Da xoa %d lenh cho", deleteCount);
   
   isDeletingHedgeIntentionally = false;
}

void CloseAllPositions()
{
   Print("Dong TAT CA");
   
   isClosingAllPositions = true;
   
   // Đánh dấu tất cả hedge không recover
   for(int i = 0; i < hedgeCount; i++)
   {
      DisableHedgeRecovery(i, "Dong tat ca");
   }
   
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      if(!PositionSelectByTicket(ticket)) continue;
      
      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != _Symbol) continue;
      
      ulong magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != MAGIC_MAIN && magic != MAGIC_HEDGE) continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      ENUM_ORDER_TYPE closeType = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      double price = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);

      CloseOrderAtPrice(ticket, closeType, volume, price);
      
      if(magic == MAGIC_HEDGE)
      {
         int index = FindHedgeByPositionTicket(ticket);
         if(index >= 0)
            MarkHedgeClosed(index, "Dong tat ca");
      }
   }
   
   DeleteAllPendingOrders();
   ResetHedgeLevel();
   
   isClosingAllPositions = false;
}

bool CloseOrderAtPrice(ulong positionTicket, ENUM_ORDER_TYPE closeType, double volume, double price)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.position     = positionTicket;
   request.symbol       = _Symbol;
   request.volume       = volume;
   request.type         = closeType;
   request.price        = NormalizeDouble(price, _Digits);
   request.deviation    = 30;
   request.type_filling = ORDER_FILLING_IOC;

   if(!OrderSend(request, result) || result.retcode != TRADE_RETCODE_DONE)
      return false;

   PrintFormat("Dong lenh ticket %I64u @ %.5f", positionTicket, result.price);
   return true;
}

void ResetHedgeLevel()
{
   PrintFormat("=== RESET HEDGE LEVEL ===");
   PrintFormat("Truoc: Level=%d", hedgeLevel);
   
   hedgeLevel = 0;
   ClearHedgeList();
   
   PrintFormat("Sau: Level=%d | Hedge list cleared", hedgeLevel);
   PrintFormat("=========================");
}

//+------------------------------------------------------------------+
//| ✅ MỞ LẠI HEDGE CHÍNH XÁC                                       |
//+------------------------------------------------------------------+
bool RecoverHedgeExact(HedgeInfo &info, string reason)
{
   Print(">>> BAT DAU KHOI PHUC HEDGE <<<");
   PrintFormat("Ly do: %s", reason);
   PrintFormat("Thong tin hedge bi mat:");
   PrintFormat("  Type: %s", EnumToString(info.type));
   PrintFormat("  Lot: %.2f", info.lot);
   PrintFormat("  Price: %.5f", info.price);
   PrintFormat("  SL: %.5f | TP: %.5f", info.sl, info.tp);
   PrintFormat("  Level: %d", info.level);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipValue = point * ((SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 ||
                               SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) ? 10 : 1);
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double currentPrice = (info.type == ORDER_TYPE_BUY_STOP) ? ask : bid;
   double distancePips = 0;
   
   if(info.type == ORDER_TYPE_BUY_STOP)
      distancePips = (info.price - ask) / pipValue;
   else
      distancePips = (bid - info.price) / pipValue;
   
   PrintFormat("Khoang cach den gia hedge: %.1f pips", distancePips);
   
   // ✅ NẾU CÒN AN TOÀN → MỞ LẠI PENDING
   if(distancePips >= InpHedgeSafeDistancePips)
   {
      PrintFormat("✅ AN TOAN: Con %.1f pips - MO LAI PENDING", distancePips);
      
      ulong ticket = PlacePendingOrder(info.type, info.price, info.lot, 
                                       info.sl, info.tp, MAGIC_HEDGE, 
                                       StringFormat("HEDGE-RECOVER-L%d", info.level), 
                                       info.level);
      
      if(ticket > 0)
      {
         Print("✅ THANH CONG: Da khoi phuc PENDING hedge chinh xac!");
         Print(">>> KET THUC KHOI PHUC <<<");
         return true;
      }
      else
      {
         Print("❌ LOI: Khong mo duoc PENDING - Thu mo MARKET");
      }
   }
   
   // ✅ NẾU KHẨN CẤP → MỞ MARKET
   PrintFormat("⚠️ KHAN CAP - MO MARKET NGAY!");
   
   ENUM_ORDER_TYPE marketType = (info.type == ORDER_TYPE_BUY_STOP) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double trialLots[] = {info.lot, info.lot * 0.5, info.lot * 0.25, minLot};
   
   for(int i = 0; i < ArraySize(trialLots); i++)
   {
      double tryLot = NormalizeDouble(trialLots[i], 2);
      if(tryLot < minLot) tryLot = minLot;
      if(tryLot > maxLot) tryLot = maxLot;
      
      PrintFormat("Lan thu %d: Thu mo MARKET %.2f lot", i+1, tryLot);
      
      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      request.action       = TRADE_ACTION_DEAL;
      request.symbol       = _Symbol;
      request.volume       = tryLot;
      request.type         = marketType;
      request.price        = currentPrice;
      request.sl           = info.sl;
      request.tp           = info.tp;
      request.deviation    = 50;
      request.magic        = MAGIC_HEDGE;
      request.comment      = StringFormat("HEDGE-EMERGENCY-L%d", info.level);
      request.type_filling = ORDER_FILLING_IOC;

      if(!OrderSend(request, result))
      {
         PrintFormat("  ❌ Loi gui lenh %.2f lot", tryLot);
         continue;
      }

      if(result.retcode == TRADE_RETCODE_DONE)
      {
         if(tryLot < info.lot)
            PrintFormat("✅ THANH CONG: Mo MARKET %.2f lot @ %.5f (Giam tu %.2f)", 
                       tryLot, result.price, info.lot);
         else
            PrintFormat("✅ THANH CONG: Mo MARKET %.2f lot @ %.5f", 
                       tryLot, result.price);
         
         // ✅ THÊM VÀO DANH SÁCH (position trực tiếp)
         HedgeInfo newInfo = info;
         newInfo.ticket = result.order;
         newInfo.originalPendingTicket = 0;
         newInfo.state = HEDGE_STATE_POSITION;
         newInfo.price = result.price;
         newInfo.lot = tryLot;
         
         ArrayResize(hedgeList, hedgeCount + 1);
         hedgeList[hedgeCount] = newInfo;
         hedgeCount++;
         
         Print(">>> KET THUC KHOI PHUC <<<");
         return true;
      }
      else if(result.retcode == TRADE_RETCODE_NO_MONEY)
      {
         PrintFormat("  ⚠️ Khong du tien cho %.2f lot", tryLot);
         continue;
      }
      else
      {
         PrintFormat("  ❌ Tu choi %.2f lot - Code %d", tryLot, result.retcode);
         continue;
      }
   }
   
   PrintFormat("❌ THAT BAI: Khong khoi phuc duoc hedge!");
   Print(">>> KET THUC KHOI PHUC <<<");
   return false;
}

//+------------------------------------------------------------------+
//| ✅ KIỂM TRA VÀ KHÔI PHỤC HEDGE BỊ MẤT                           |
//+------------------------------------------------------------------+
void CheckAndRecoverMissingHedge()
{
   if(!InpAutoRecoverHedge) return;
   if(!InpUseHedge) return;
   if(isOpeningHedge) return;
   
   // ✅ Kiểm tra có Main không
   bool hasMainBuy = false;
   bool hasMainSell = false;
   double mainBuyPrice = 0;
   double mainSellPrice = 0;
   
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      string sym = PositionGetSymbol(i);
      if(sym != _Symbol) continue;
      
      ulong magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != MAGIC_MAIN) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      
      if(posType == POSITION_TYPE_BUY)
      {
         hasMainBuy = true;
         mainBuyPrice = openPrice;
      }
      else
      {
         hasMainSell = true;
         mainSellPrice = openPrice;
      }
   }
   
   if(!hasMainBuy && !hasMainSell) return;
   
   // ✅ Kiểm tra hedge tương ứng
   if(hasMainBuy)
   {
      if(HasActiveHedgeType(ORDER_TYPE_SELL_STOP))
      {
         return;
      }
      else
      {
         Print("");
         Print("========================================================");
         Print("⚠️ PHAT HIEN: Main BUY THIEU SELL hedge!");
         PrintFormat("Main BUY @ %.5f", mainBuyPrice);
         
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double pipValue = point * ((SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 ||
                                     SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) ? 10 : 1);
         
         double hedgePrice = NormalizeDouble(mainBuyPrice - InpHedgeDistancePips * pipValue, _Digits);
         double sl = NormalizeDouble(hedgePrice + InpHedgeStopLossPips * pipValue, _Digits);
         double tp = NormalizeDouble(hedgePrice - InpHedgeTakeProfitPips * pipValue, _Digits);
         
         double currentHedgeLot = InpHedgeLotSize;
         for(int i = 0; i < hedgeLevel; i++)
         {
            currentHedgeLot *= InpHedgeMultiplier;
         }
         currentHedgeLot = NormalizeDouble(currentHedgeLot, 2);
         
         HedgeInfo recoveryInfo;
         recoveryInfo.type = ORDER_TYPE_SELL_STOP;
         recoveryInfo.lot = currentHedgeLot;
         recoveryInfo.price = hedgePrice;
         recoveryInfo.sl = sl;
         recoveryInfo.tp = tp;
         recoveryInfo.level = hedgeLevel;
         recoveryInfo.shouldRecover = true;
         
         isOpeningHedge = true;
         RecoverHedgeExact(recoveryInfo, "Main BUY thieu SELL hedge");
         isOpeningHedge = false;
         
         Print("========================================================");
         Print("");
      }
   }
   
   if(hasMainSell)
   {
      if(HasActiveHedgeType(ORDER_TYPE_BUY_STOP))
      {
         return;
      }
      else
      {
         Print("");
         Print("========================================================");
         Print("⚠️ PHAT HIEN: Main SELL THIEU BUY hedge!");
         PrintFormat("Main SELL @ %.5f", mainSellPrice);
         
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double pipValue = point * ((SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 ||
                                     SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) ? 10 : 1);
         
         double hedgePrice = NormalizeDouble(mainSellPrice + InpHedgeDistancePips * pipValue, _Digits);
         double sl = NormalizeDouble(hedgePrice - InpHedgeStopLossPips * pipValue, _Digits);
         double tp = NormalizeDouble(hedgePrice + InpHedgeTakeProfitPips * pipValue, _Digits);
         
         double currentHedgeLot = InpHedgeLotSize;
         for(int i = 0; i < hedgeLevel; i++)
         {
            currentHedgeLot *= InpHedgeMultiplier;
         }
         currentHedgeLot = NormalizeDouble(currentHedgeLot, 2);
         
         HedgeInfo recoveryInfo;
         recoveryInfo.type = ORDER_TYPE_BUY_STOP;
         recoveryInfo.lot = currentHedgeLot;
         recoveryInfo.price = hedgePrice;
         recoveryInfo.sl = sl;
         recoveryInfo.tp = tp;
         recoveryInfo.level = hedgeLevel;
         recoveryInfo.shouldRecover = true;
         
         isOpeningHedge = true;
         RecoverHedgeExact(recoveryInfo, "Main SELL thieu BUY hedge");
         isOpeningHedge = false;
         
         Print("========================================================");
         Print("");
      }
   }
}

//+------------------------------------------------------------------+
//| ✅ ON TRADE TRANSACTION - PHÁT HIỆN MỌI SỰ KIỆN HEDGE          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // =========================================================================
   // ✅ PHÁT HIỆN PENDING HEDGE BỊ XÓA - FIX v7.42: LUÔN KHÔI PHỤC
   // =========================================================================
   if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      if(trans.deal > 0)
         return;  // pending vừa khớp thành deal => không recover
      
      ulong deletedTicket = trans.order;
      int hedgeIndex = FindHedgeByPendingTicket(deletedTicket);
      
      if(hedgeIndex >= 0 && hedgeList[hedgeIndex].state == HEDGE_STATE_PENDING)
      {
         if(!isDeletingHedgeIntentionally)
         {
            Print("");
            Print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            Print("!!! 🚨 PENDING HEDGE BI XOA BAT THUONG !!!");
            Print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            
            HedgeInfo deletedHedge = hedgeList[hedgeIndex];
            
            PrintFormat("Pending hedge bi xoa:");
            PrintFormat("  Ticket: %I64u", deletedHedge.ticket);
            PrintFormat("  Type: %s", EnumToString(deletedHedge.type));
            PrintFormat("  Lot: %.2f", deletedHedge.lot);
            PrintFormat("  Price: %.5f", deletedHedge.price);
            PrintFormat("  Level: %d", deletedHedge.level);
            
            if(deletedHedge.shouldRecover)
            {
               Print("→ LUON KHOI PHUC HEDGE VUA BI XOA!");
               MarkHedgeClosed(hedgeIndex, "Bi xoa - dang khoi phuc");
               RecoverHedgeExact(deletedHedge, "Pending hedge bi xoa");
            }
            else
            {
               Print("→ KHONG RECOVER (shouldRecover = false)");
               MarkHedgeClosed(hedgeIndex, "Bi xoa - khong recover");
            }
            
            Print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            Print("");
         }
         else
         {
            MarkHedgeClosed(hedgeIndex, "Xoa co chu y");
         }
      }
   }
   
   // =========================================================================
   // XU LY DEAL
   // =========================================================================
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal_ticket = trans.deal;
   if(!HistoryDealSelect(deal_ticket)) return;
   
   string symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   if(symbol != _Symbol) return;

   ulong deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   if(deal_magic != MAGIC_MAIN && deal_magic != MAGIC_HEDGE) return;
   
   ENUM_DEAL_ENTRY entryType = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   ENUM_DEAL_TYPE  dealType  = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);

   double openPrice = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipValue = point * ((SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 ||
                               SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3) ? 10 : 1);

   // =========================================================================
   // ✅✅✅ FIXED: HEDGE POSITION ĐÓNG (TP/SL/Manual) → ĐÓNG TOÀN BỘ ✅✅✅
   // =========================================================================
   if(deal_magic == MAGIC_HEDGE && entryType == DEAL_ENTRY_OUT)
   {
      ulong positionTicket = trans.position;
      int hedgeIndex = FindHedgeByPositionTicket(positionTicket);
      
      if(hedgeIndex >= 0)
      {
         if(!isClosingAllPositions)
         {
            Print("");
            Print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            Print("!!! 🚨 POSITION HEDGE DONG TP/SL !!!");
            Print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            
            HedgeInfo closedHedge = hedgeList[hedgeIndex];
            
            PrintFormat("Position hedge dong:");
            PrintFormat("  Ticket: %I64u", closedHedge.ticket);
            PrintFormat("  Type: %s", EnumToString(closedHedge.type));
            PrintFormat("  Lot: %.2f", closedHedge.lot);
            PrintFormat("  Level: %d", closedHedge.level);
            
            // ✅✅✅ FIX: ĐÓNG TOÀN BỘ LỆNH (GIỐNG NHƯ MAIN ĐÓNG)
            Print("→ HEDGE DONG - DONG TAT CA LENH!");
            MarkHedgeClosed(hedgeIndex, "Dong - dong tat ca");
            CloseAllPositions();  // ✅✅✅ THÊM DÒNG NÀY
            
            Print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            Print("");
         }
         else
         {
            MarkHedgeClosed(hedgeIndex, "Dong tat ca");
         }
      }
   }

   // =========================================================================
   // LENH MAIN KHOP
   // =========================================================================
   if(deal_magic == MAGIC_MAIN && entryType == DEAL_ENTRY_IN)
   {
      ulong newTicket = trans.position;
      ENUM_POSITION_TYPE newType = (dealType == DEAL_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      
      Print("");
      Print("***********************************************************");
      PrintFormat("LENH MAIN %s KHOP ticket %I64u @ %.5f", 
                  (newType == POSITION_TYPE_BUY ? "BUY" : "SELL"), newTicket, openPrice);
      Print("***********************************************************");
      
      // ✅✅✅ NEW LOGIC: ĐẶT TP CỐ ĐỊNH HOẶC TP THÔNG THƯỜNG
      double newSL = 0, newTP = 0;
      if(dealType == DEAL_TYPE_BUY)
      {
         newSL = NormalizeDouble(openPrice - InpStopLoss * pipValue, _Digits);
         
         // ✅ NẾU BẬT TP CỐ ĐỊNH → DÙNG InpMainFixedTPPips
         if(InpUseMainFixedTP && InpMainFixedTPPips > 0)
            newTP = NormalizeDouble(openPrice + InpMainFixedTPPips * pipValue, _Digits);
         else
            newTP = NormalizeDouble(openPrice + InpTakeProfitPips * pipValue, _Digits);
      }
      else
      {
         newSL = NormalizeDouble(openPrice + InpStopLoss * pipValue, _Digits);
         
         // ✅ NẾU BẬT TP CỐ ĐỊNH → DÙNG InpMainFixedTPPips
         if(InpUseMainFixedTP && InpMainFixedTPPips > 0)
            newTP = NormalizeDouble(openPrice - InpMainFixedTPPips * pipValue, _Digits);
         else
            newTP = NormalizeDouble(openPrice - InpTakeProfitPips * pipValue, _Digits);
      }
      
      Print("BUOC 1: Cap nhat TP/SL cho lenh MAIN moi");
      if(InpUseMainFixedTP && InpMainFixedTPPips > 0)
         PrintFormat("  → Dung TP CO DINH: %.1f pips (TP @ %.5f)", InpMainFixedTPPips, newTP);
      else
         PrintFormat("  → Dung TP THONG THUONG: %.1f pips (TP @ %.5f)", InpTakeProfitPips, newTP);
      
      UpdatePositionTPSL(newTicket, newSL, newTP);
      
      Print("BUOC 2: XOA TAT CA TP/SL cac lenh MAIN cu");
      RemoveAllOldSameTypeTPSL(newTicket, newType, MAGIC_MAIN);
      
      if(InpUseHedge)
      {
         Print("BUOC 3: Kiem tra va dat lenh HEDGE");
         
         ENUM_ORDER_TYPE hedgeType = (dealType == DEAL_TYPE_BUY) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
         
         if(HasActiveHedgeType(hedgeType))
         {
            Print("✅ DA CO HEDGE TUONG UNG - KHONG DAT LAI!");
         }
         else
         {
            Print("✅ CHUA CO HEDGE TUONG UNG - BAT DAU DAT LENH");
            
            isOpeningHedge = true;
            ResetHedgeLevel();
            
            if(dealType == DEAL_TYPE_BUY)
            {
               double sellPrice = NormalizeDouble(openPrice - InpHedgeDistancePips * pipValue, _Digits);
               double sl = NormalizeDouble(sellPrice + InpHedgeStopLossPips * pipValue, _Digits);
               double tp = NormalizeDouble(sellPrice - InpHedgeTakeProfitPips * pipValue, _Digits);
               
               PlacePendingOrder(ORDER_TYPE_SELL_STOP, sellPrice, 
                               InpHedgeLotSize, sl, tp, MAGIC_HEDGE, "HEDGE-L0", 0);
            }
            else
            {
               double buyPrice = NormalizeDouble(openPrice + InpHedgeDistancePips * pipValue, _Digits);
               double sl = NormalizeDouble(buyPrice - InpHedgeStopLossPips * pipValue, _Digits);
               double tp = NormalizeDouble(buyPrice + InpHedgeTakeProfitPips * pipValue, _Digits);
               
               PlacePendingOrder(ORDER_TYPE_BUY_STOP, buyPrice, 
                               InpHedgeLotSize, sl, tp, MAGIC_HEDGE, "HEDGE-L0", 0);
            }
            
            isOpeningHedge = false;
         }
      }
      Print("***********************************************************");
      Print("");
   }

   // =========================================================================
   // ✅ HEDGE PENDING KHỚP → CẬP NHẬT THÀNH POSITION
   // =========================================================================
   else if(deal_magic == MAGIC_HEDGE && entryType == DEAL_ENTRY_IN)
   {
      ulong positionTicket = trans.position;
      ulong originalOrder = trans.order;
      ENUM_POSITION_TYPE newType = (dealType == DEAL_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      
      Print("");
      Print("***********************************************************");
      PrintFormat("LENH HEDGE %s KHOP ticket %I64u @ %.5f (L%d)", 
                  (newType == POSITION_TYPE_BUY ? "BUY" : "SELL"), positionTicket, openPrice, hedgeLevel);
      Print("***********************************************************");
      
      // ✅ Cập nhật pending → position
      UpdateHedgePendingToPosition(originalOrder, positionTicket, openPrice);
      
      // ✅✅✅ NEW: XÓA TP CỐ ĐỊNH CỦA MAIN (NẾU CÓ)
      if(InpUseMainFixedTP && InpMainFixedTPPips > 0)
      {
         Print("BUOC 1A: XOA TP CO DINH CUA MAIN (Hedge da khop)");
         RemoveAllMainPositionTP();
      }
      
      double newSL = 0, newTP = 0;
      if(dealType == DEAL_TYPE_BUY)
      {
         newSL = NormalizeDouble(openPrice - InpHedgeStopLossPips * pipValue, _Digits);
         newTP = NormalizeDouble(openPrice + InpHedgeTakeProfitPips * pipValue, _Digits);
      }
      else
      {
         newSL = NormalizeDouble(openPrice + InpHedgeStopLossPips * pipValue, _Digits);
         newTP = NormalizeDouble(openPrice - InpHedgeTakeProfitPips * pipValue, _Digits);
      }
      
      Print("BUOC 1B: Cap nhat TP/SL cho lenh HEDGE moi");
      UpdatePositionTPSL(positionTicket, newSL, newTP);
      
      Print("BUOC 2: XOA TAT CA TP/SL cac lenh HEDGE cu");
      RemoveAllOldSameTypeTPSL(positionTicket, newType, MAGIC_HEDGE);
      
      if(!InpUseHedgeMartingale || hedgeLevel >= InpMaxHedgeLevels - 1)
      {
         Print("DUNG: Da dat MAX level hoac tat Martingale");
         Print("***********************************************************");
         Print("");
         return;
      }
      
      Print("BUOC 3: Kiem tra va dat lenh HEDGE Martingale level moi");
      
      hedgeLevel++;
      
      if(hedgeLevel > InpMaxHedgeLevels)
      {
         PrintFormat("❌ LOI: hedgeLevel=%d > MAX=%d - RESET!", hedgeLevel, InpMaxHedgeLevels);
         ResetHedgeLevel();
         Print("***********************************************************");
         Print("");
         return;
      }
      
      double nextLot = InpHedgeLotSize;
      for(int i = 0; i < hedgeLevel; i++)
      {
         nextLot *= InpHedgeMultiplier;
      }
      nextLot = NormalizeDouble(nextLot, 2);
      
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      if(nextLot > maxLot)
      {
         PrintFormat("❌ LOI: Lot %.2f vuot MAX %.2f - DUNG Martingale!", 
                    nextLot, maxLot);
         Print("***********************************************************");
         Print("");
         return;
      }
      
      PrintFormat("Level %d: Lot %.2f", hedgeLevel, nextLot);
      
      isOpeningHedge = true;
      
      if(dealType == DEAL_TYPE_BUY)
      {
         double sellPrice = NormalizeDouble(openPrice - InpHedgeDistancePips * pipValue, _Digits);
         double sl = NormalizeDouble(sellPrice + InpHedgeStopLossPips * pipValue, _Digits);
         double tp = NormalizeDouble(sellPrice - InpHedgeTakeProfitPips * pipValue, _Digits);
         
         PlacePendingOrder(ORDER_TYPE_SELL_STOP, sellPrice, nextLot, sl, tp, 
                         MAGIC_HEDGE, StringFormat("HEDGE-L%d", hedgeLevel), hedgeLevel);
      }
      else
      {
         double buyPrice = NormalizeDouble(openPrice + InpHedgeDistancePips * pipValue, _Digits);
         double sl = NormalizeDouble(buyPrice - InpHedgeStopLossPips * pipValue, _Digits);
         double tp = NormalizeDouble(buyPrice + InpHedgeTakeProfitPips * pipValue, _Digits);
         
         PlacePendingOrder(ORDER_TYPE_BUY_STOP, buyPrice, nextLot, sl, tp, 
                         MAGIC_HEDGE, StringFormat("HEDGE-L%d", hedgeLevel), hedgeLevel);
      }
      
      isOpeningHedge = false;
      
      PrintHedgeList();
      
      Print("***********************************************************");
      Print("");
   }

   // =========================================================================
   // LENH MAIN DONG
   // =========================================================================
   else if(deal_magic == MAGIC_MAIN && entryType == DEAL_ENTRY_OUT)
   {
      PrintFormat("Main dong - DONG TAT CA");
      CloseAllPositions();
   }
}
//+------------------------------------------------------------------+
