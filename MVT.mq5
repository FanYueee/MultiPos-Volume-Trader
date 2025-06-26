//+------------------------------------------------------------------+
//|                                       MultiPos-Volume-Trader.mq5 |
//|                                 Volume Baseline Trading System   |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025"
#property link      ""
#property version   "1.10"

#include <Trade/Trade.mqh>

//--- Input parameters
input double InpLotSize = 0.01;                    // Lot size
input int    InpMagicNumber = 987654;              // Magic number
input int    InpSlippage = 10;                     // Slippage points
input bool   InpEnableDebug = true;                // Enable debug output
input int InpMaxSpread = 50;                     // Maximum spread in points (50 for Gold, 30 for Forex)
input int    InpMinVolume = 10;                    // Minimum tick volume for trading
input bool   InpEnableTimeFilter = true;           // Enable trading time filter
input int    InpStartHour = 0;                     // Trading start hour (0-23)
input int    InpEndHour = 23;                      // Trading end hour (0-23)

//--- Global variables
CTrade trade;
datetime lastCandleTime = 0;
double volumeBaseline = 0;
bool tradingActive = false;
datetime positionOpenTime = 0;
int positionTicket = 0;

//--- Position tracking structure
struct PositionInfo {
    bool isOpen;
    ulong ticket;
    datetime openTime;
    datetime targetCloseTime;
    ENUM_ORDER_TYPE type;
    string comment;
};

PositionInfo positions[100]; // 支持最多100個同時持倉
int positionCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    // Setup trading parameters
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpSlippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC);
    
    // Initialize position tracking array
    for(int i = 0; i < 100; i++) {
        positions[i].isOpen = false;
        positions[i].ticket = 0;
        positions[i].openTime = 0;
        positions[i].targetCloseTime = 0;
    }
    positionCount = 0;
    
    Print("====================================================");
    Print("🚀 Volume Baseline Trading System STARTED");
    Print("====================================================");
    Print("📋 Settings:");
    Print("   - Lot Size: ", InpLotSize);
    Print("   - Magic Number: ", InpMagicNumber);
    Print("   - Timeframe: M1 (1 minute)");
    Print("   - Trading Window: 30 seconds data collection + 30 seconds execution");
    Print("   - Hold Time: 90 seconds per position");
    Print("   - Multiple Positions: Up to 100 concurrent positions for volume generation");
    Print("====================================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    Print("====================================================");
    Print("🛑 Volume Baseline Trading System STOPPED");
    Print("====================================================");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // Get current time info
    datetime currentTime = TimeCurrent();
    MqlDateTime timeStruct;
    TimeToStruct(currentTime, timeStruct);
    
    // Check if we're in a new candle
    datetime currentCandleTime = iTime(_Symbol, PERIOD_M1, 0);
    bool isNewCandle = (currentCandleTime != lastCandleTime);
    
    if(isNewCandle) {
        lastCandleTime = currentCandleTime;
        OnNewCandle();
    }
    
    // Main trading logic based on seconds within the minute
    int currentSeconds = timeStruct.sec;
    
    // Phase 1: Data collection (0-30 seconds)
    if(currentSeconds >= 0 && currentSeconds < 30) {
        CollectVolumeData();
    }
    // Phase 2: Trading execution (30 seconds)
    else if(currentSeconds == 30 && !tradingActive) {
        ExecuteTrading();
        tradingActive = true;
    }
    // Reset trading flag for next cycle
    else if(currentSeconds == 31) {
        tradingActive = false;
    }
    
    // Check position management
    ManagePositions();
}

//+------------------------------------------------------------------+
//| New candle event handler                                         |
//+------------------------------------------------------------------+
void OnNewCandle() {
    if(InpEnableDebug) {
        Print("📊 New M1 candle at ", TimeToString(TimeCurrent()));
        Print("📈 Active positions: ", GetActivePositionCount());
    }
}

//+------------------------------------------------------------------+
//| Collect volume data during first 30 seconds                     |
//+------------------------------------------------------------------+
void CollectVolumeData() {
    // Get current candle data
    MqlRates rates[];
    if(CopyRates(_Symbol, PERIOD_M1, 0, 1, rates) <= 0) {
        return;
    }
    
    // Calculate volume-weighted average price for current forming candle
    double high = rates[0].high;
    double low = rates[0].low;
    double open = rates[0].open;
    double close = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    long volume = rates[0].tick_volume;
    
    // Simple volume baseline calculation
    // Using HLOC average weighted by tick volume
    if(volume > 0) {
        volumeBaseline = (high + low + open + close) / 4.0;
    }
    
    static datetime lastDebugTime = 0;
    datetime currentTime = TimeCurrent();
    
    // Debug output every 10 seconds during collection phase
    if(InpEnableDebug && (currentTime - lastDebugTime >= 10)) {
        lastDebugTime = currentTime;
        Print("📊 Volume data collection - Baseline: ", DoubleToString(volumeBaseline, _Digits), 
              " Volume: ", volume, " Current price: ", DoubleToString(close, _Digits));
    }
}

//+------------------------------------------------------------------+
//| Execute trading at 30-second mark                               |
//+------------------------------------------------------------------+
void ExecuteTrading() {
    // Risk management checks
    if(!RiskManagementCheck()) {
        return;
    }
    
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    if(InpEnableDebug) {
        Print("🎯 Trading execution at 30-second mark");
        Print("📊 Current price: ", DoubleToString(currentPrice, _Digits));
        Print("📈 Volume baseline: ", DoubleToString(volumeBaseline, _Digits));
    }
    
    // Trading logic: Buy if price < baseline, Sell if price > baseline
    datetime currentTime = TimeCurrent();
    datetime targetCloseTime = currentTime + 90; // 90秒後平倉
    
    if(currentPrice < volumeBaseline) {
        // Execute BUY order
        string comment = "VB_BUY_" + TimeToString(currentTime, TIME_SECONDS);
        if(trade.Buy(InpLotSize, _Symbol, ask, 0, 0, comment)) {
            AddNewPosition(trade.ResultOrder(), currentTime, targetCloseTime, ORDER_TYPE_BUY, comment);
            
            if(InpEnableDebug) {
                Print("✅ BUY order executed - Ticket: ", trade.ResultOrder());
                Print("💰 Price: ", DoubleToString(ask, _Digits), " vs Baseline: ", DoubleToString(volumeBaseline, _Digits));
                Print("⏰ Target close time: ", TimeToString(targetCloseTime, TIME_SECONDS));
            }
        } else {
            Print("❌ Failed to execute BUY order - Error: ", GetLastError());
        }
    }
    else if(currentPrice > volumeBaseline) {
        // Execute SELL order
        string comment = "VB_SELL_" + TimeToString(currentTime, TIME_SECONDS);
        if(trade.Sell(InpLotSize, _Symbol, currentPrice, 0, 0, comment)) {
            AddNewPosition(trade.ResultOrder(), currentTime, targetCloseTime, ORDER_TYPE_SELL, comment);
            
            if(InpEnableDebug) {
                Print("✅ SELL order executed - Ticket: ", trade.ResultOrder());
                Print("💰 Price: ", DoubleToString(currentPrice, _Digits), " vs Baseline: ", DoubleToString(volumeBaseline, _Digits));
                Print("⏰ Target close time: ", TimeToString(targetCloseTime, TIME_SECONDS));
            }
        } else {
            Print("❌ Failed to execute SELL order - Error: ", GetLastError());
        }
    }
    else {
        if(InpEnableDebug) {
            Print("⚪ No trading signal - price equals baseline");
        }
    }
}

//+------------------------------------------------------------------+
//| Manage positions - close after 90 seconds                      |
//+------------------------------------------------------------------+
void ManagePositions() {
    datetime currentTime = TimeCurrent();
    
    for(int i = 0; i < positionCount; i++) {
        if(!positions[i].isOpen) continue;
        
        // Check if position still exists
        if(!PositionSelectByTicket(positions[i].ticket)) {
            // Position was closed externally
            positions[i].isOpen = false;
            if(InpEnableDebug) {
                Print("📋 Position ", positions[i].ticket, " closed externally");
            }
            continue;
        }
        
        // Force close after 90 seconds
        if(currentTime >= positions[i].targetCloseTime) {
            if(trade.PositionClose(positions[i].ticket)) {
                double profit = PositionGetDouble(POSITION_PROFIT);
                
                if(InpEnableDebug) {
                    Print("🔄 Position ", positions[i].ticket, " force-closed after 90 seconds");
                    Print("💰 Profit/Loss: $", DoubleToString(profit, 2));
                }
                
                positions[i].isOpen = false;
            } else {
                Print("❌ Failed to close position ", positions[i].ticket, " - Error: ", GetLastError());
            }
        }
    }
    
    // Clean up closed positions
    CleanupClosedPositions();
}

//+------------------------------------------------------------------+
//| Add new position to tracking array                              |
//+------------------------------------------------------------------+
void AddNewPosition(ulong ticket, datetime openTime, datetime closeTime, ENUM_ORDER_TYPE type, string comment) {
    // Find empty slot
    for(int i = 0; i < 100; i++) {
        if(!positions[i].isOpen) {
            positions[i].isOpen = true;
            positions[i].ticket = ticket;
            positions[i].openTime = openTime;
            positions[i].targetCloseTime = closeTime;
            positions[i].type = type;
            positions[i].comment = comment;
            
            if(i >= positionCount) {
                positionCount = i + 1;
            }
            
            if(InpEnableDebug) {
                Print("📝 Added position to slot ", i, " - Total active: ", GetActivePositionCount());
            }
            break;
        }
    }
}

//+------------------------------------------------------------------+
//| Get count of active positions                                   |
//+------------------------------------------------------------------+
int GetActivePositionCount() {
    int count = 0;
    for(int i = 0; i < positionCount; i++) {
        if(positions[i].isOpen) count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Clean up closed positions from array                            |
//+------------------------------------------------------------------+
void CleanupClosedPositions() {
    // Compact array by moving active positions to front
    int writeIndex = 0;
    for(int readIndex = 0; readIndex < positionCount; readIndex++) {
        if(positions[readIndex].isOpen) {
            if(writeIndex != readIndex) {
                positions[writeIndex] = positions[readIndex];
            }
            writeIndex++;
        }
    }
    
    // Clear remaining slots
    for(int i = writeIndex; i < positionCount; i++) {
        positions[i].isOpen = false;
        positions[i].ticket = 0;
        positions[i].openTime = 0;
        positions[i].targetCloseTime = 0;
        positions[i].comment = "";
    }
    
    positionCount = writeIndex;
}

//+------------------------------------------------------------------+
//| Risk management checks                                           |
//+------------------------------------------------------------------+
bool RiskManagementCheck() {
    // Check spread
    long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double spread = spreadPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    if(InpEnableDebug) {
        Print("📊 Current spread: ", spreadPoints, " points (", DoubleToString(spread, _Digits), ")");
        Print("📊 Max allowed: ", InpMaxSpread, " points");
    }
    
    if(spreadPoints > InpMaxSpread) {
        if(InpEnableDebug) {
            Print("⚠️ Trading blocked - Spread too high: ", spreadPoints, " points (", DoubleToString(spread, _Digits), ")");
        }
        return false;
    }
    
    // Check minimum volume
    MqlRates rates[];
    if(CopyRates(_Symbol, PERIOD_M1, 0, 1, rates) > 0) {
        if(rates[0].tick_volume < InpMinVolume) {
            if(InpEnableDebug) {
                Print("⚠️ Trading blocked - Volume too low: ", rates[0].tick_volume);
            }
            return false;
        }
    }
    
    // Check trading time
    if(InpEnableTimeFilter) {
        MqlDateTime timeStruct;
        TimeToStruct(TimeCurrent(), timeStruct);
        
        if(InpStartHour <= InpEndHour) {
            // Normal time range (e.g., 9 to 17)
            if(timeStruct.hour < InpStartHour || timeStruct.hour > InpEndHour) {
                if(InpEnableDebug) {
                    Print("⚠️ Trading blocked - Outside trading hours: ", timeStruct.hour);
                }
                return false;
            }
        } else {
            // Overnight range (e.g., 22 to 6)
            if(timeStruct.hour > InpEndHour && timeStruct.hour < InpStartHour) {
                if(InpEnableDebug) {
                    Print("⚠️ Trading blocked - Outside trading hours: ", timeStruct.hour);
                }
                return false;
            }
        }
    }
    
    // Check if market is open
    if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)) {
        if(InpEnableDebug) {
            Print("⚠️ Trading blocked - Market closed");
        }
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Trade transaction event                                          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result) {
    
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.symbol == _Symbol) {
        if(HistoryDealSelect(trans.deal)) {
            long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
            
            if(dealMagic == InpMagicNumber) {
                long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
                double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                ulong dealPosition = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
                
                if(dealEntry == DEAL_ENTRY_OUT && InpEnableDebug) {
                    Print("📊 Position ", dealPosition, " closed - P&L: $", DoubleToString(dealProfit, 2));
                    Print("📈 Remaining active positions: ", GetActivePositionCount());
                }
            }
        }
    }
}
