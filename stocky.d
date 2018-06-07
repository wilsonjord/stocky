// Written in the D programming language
// Jordan K. Wilson https://wilsonjord.github.io/

/++
This module provides technical analysis functionality.

Author: $(HTTP wilsonjord.github.io, Jordan K. Wilson)

+/

module stocky;

import std.typecons : Tuple, tuple;
import std.datetime;
import std.stdio;
import std.conv : to;
import std.algorithm;
import std.range;
import std.format : format;
import std.traits;

import dstats : mean, median;

alias Symbol = Tuple!(string,"exchange",string,"name");
alias Record = Tuple!(Symbol,"symbol",DateTime,"time",
                      double,"open",double,"high",double,"low",double,"close",int,"volumn");

/++
    Main data type to store EOD data for a stock
+/
alias EODRecord = Tuple!(DateTime,"time",double,"open",double,"high",double,"low",double,"close",int,"volumn");

enum PriceType {open="open",high="high",low="low",close="close"}

auto get(PriceType pt) (Record rec) {
    return rec.get!(cast(string)pt);
}

auto get(string field) (Record rec) {
    mixin ("return rec." ~ field ~ ";");
}

unittest {
    auto a = Record (Symbol("ABC","ABC"),DateTime.init,1,2,3,4,5);
    assert (a.get!(PriceType.close)==4);
    assert (a.get!"volumn"==5);
}

auto createSMA(T) (T rng, int period) {
    struct SMA(Range) if (isNumeric!(ElementType!Range)) {
        Range rng;
        double period;

        import std.container : DList;
        DList!(ElementType!Range) buffer;

        double currentResult;
        this (Range r, int p) {
            rng=r;
            period=p;
            currentResult=r.front;

            // prepopulate buffer
            buffer.insert (r.front.repeat(p));
        }

        auto front() {
            return currentResult;
        }

        auto popFront() {
            rng.popFront;
            if (!rng.empty){
                currentResult = currentResult + (rng.front / period) - (buffer.back / period);
                buffer.insertFront (rng.front);
                buffer.removeBack;
            }
        }

        auto empty() {
            return rng.empty;
        }
    }
    return SMA!T (rng,period);
}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to average

    Returns:
        A range of simple moving averages
+/
auto sma(string field="", Range) (Range rng, int period) {
    static if (!field.empty) {
        static assert (hasMember!(ElementType!Range,field));
        mixin ("return createSMA(rng.map!(a => a." ~ field ~ "),period);");
    } else {
        return createSMA(rng,period);
    }
}

///
unittest {
    // using simple arrays
    auto a = [25,85,65,45,95,75,15,35];
    auto b = a.sma(3).array;

    import std.math : approxEqual;
    assert (b[0]==25);
    assert (b[1].approxEqual((25+25+85) / 3.0));
    assert (b[2].approxEqual((25+85+65) / 3.0));
    assert (b[3].approxEqual(65));

    // using user type
    auto c = [EODRecord(DateTime(2000,1,1,0,0,0),
                        11,     // open
                        15,     // high
                        10,     // low
                        13,     // close
                        1),     // volumn
              EODRecord(DateTime(2000,1,2,0,0,0),
                        12,
                        16,
                        11,
                        14,
                        1),
              EODRecord(DateTime(2000,1,3,0,0,0),
                        11,
                        15,
                        10,
                        15,
                        1)];

    assert (c.sma!"close"(3)
             .drop(2)
             .front.approxEqual(14));

    assert (c.sma!"open"(3)
             .drop(2)
             .front.approxEqual ((11+12+11) / 3.0));

    assert (c.map!(a => a.open).sma(3).equal
           (c.sma!"open"(3)));

}

auto createEMA(T) (T rng, int period, double seed) {
    struct EMA(Range) if (isNumeric!(ElementType!Range)) {
        double currentValue;
        double weighting;
        Range rng;
        this (Range r, int p, double s) {
            currentValue = s;
            weighting = 2.0 / (p+1);
            rng = r;
        }
        auto front() { return currentValue; }
        auto popFront() {
            rng.popFront;
            if (!rng.empty){
                currentValue += (rng.front - currentValue)*weighting;
            }
        }
        auto empty() { return rng.empty; }
    }
    return EMA!T (rng,period,seed);
}

import std.typecons : Nullable;

/++
    Params:
        pred = Optional predicate
        rng = InputRange
        period = number of time periods to average
        seed = optional seed, (default value is the first value of rng)

    Returns:
        A range of exponential moving averages
+/
auto ema(string field="", Range) (Range rng, int period, double seed = double.init) {
    import std.math : isNaN;
    static if (!field.empty) {
        static assert (hasMember!(ElementType!Range,field));
        mixin ("return createEMA(rng.map!(a => a." ~ field ~ "),period,seed.isNaN ? rng.map!(a => a." ~ field ~ ").front : seed);");
    } else {
        return createEMA(rng, period, seed.isNaN ? rng.front : seed);
    }
}

///
unittest {
    import std.math : approxEqual;

    auto a = iota(1,100); // range of ints 1 to 100

    assert (a.ema(10) // period 10, default seed of 1 (the first element)
             .drop(9)
             .take(3).approxEqual([6.24,7.10,7.99]));

    assert (a.ema(5,0) // period 5, seed 0
             .take(3).approxEqual([0,0.67,1.44]));

    // test based on
    // http://www.dummies.com/personal-finance/investing/stocks-trading/how-to-calculate-exponential-moving-average-in-trading/
    auto b = [22.81,23.09,22.91,23.23,22.83,23.05,23.02,23.29,23.41,23.49,24.6,24.63,24.51,23.73,23.31,23.53,23.06,23.25,23.12,22.8,22.84];
    assert (b.ema(9)
             .approxEqual([22.81,22.87,22.87,22.95,22.92,22.95,22.96,23.03,23.1,23.18,23.47,23.7,23.86,23.83,23.73,23.69,23.56,23.5,23.42,23.3,23.21]));

    auto c = iota(1,100).map!(a => tuple!("index","value")(a,a));
    assert (c.ema!"value"(10)
             .drop(9)
             .take(3).approxEqual([6.24,7.10,7.99]));
}

auto toDateTime (string s) {
    if (s.canFind("T")){
        return DateTime.fromISOString (s);
    } else {
        return Date.fromISOString(s).to!DateTime;
    }
}

auto between(Range) (Range records, string startDate, string endDate) {
    return records.filter!(a => a.time >= startDate.toDateTime)
                  .filter!(a => a.time <= endDate.toDateTime);
}

auto profit (double start, double end) {
    // returns profit as a percentage of start
    return (end - start) / start;
}

auto profit(T) (in T p) pure {
    assert (p.count == 2);
    return profit(p.front.price,p.back.price);
}

auto profits(T) (in T trades) pure {
    return trades.chunks(2)
                 .map!(a => a.profit);
}

auto daysHeld(T) (in T trades) pure {
    return trades.chunks(2)
                 .map!(a => (a[1].time - a[0].time).total!"days")
                 .sum;
}

auto tradesPerYear(T) (in T trades) pure {
    return (trades.count/2).to!double / (((trades.back.time-trades.front.time).total!"days")/365.25);
}

// if you just held for the duration
auto marketReturn(T) (in T trades) pure {
    assert (trades.count >= 2);
    return profit (trades.front.price,trades.back.price);
}

auto winRate(T) (T profitRange) pure {
    return profitRange.count!(a => a > 0) / profitRange.count.to!double;
}

auto winRateWeighted(T) (T profitRange) pure {
    return profitRange.enumerate(1)
                      .map!(a => (a.value > 0) ? a.index : 0)
                      .sum / iota(1,profitRange.count+1).sum.to!double;
}

auto years(T) (in T trades) pure {
    // assume sorted
    return (trades.back.time - trades.front.time).total!"days" / 365.0;
}

auto IIR(T) (in T trades, double startValue, double brokerage=0) pure {
    auto rvalue=startValue;
    foreach (pair; trades.chunks(2)){
        auto buyTrade = pair[0];
        auto sellTrade = pair[1];

        // buy
        import std.math : floor;
        auto bought = floor((rvalue - brokerage) / buyTrade.price);
        rvalue -= bought*buyTrade.price;
        rvalue -= brokerage;

        // sell
        rvalue += bought*sellTrade.price;
        rvalue -= brokerage;
    }

    if (rvalue==startValue) return 0;
    if (rvalue==0) return -1;

    import std.math : pow;
    return pow((rvalue / startValue),1/trades.years)-1;
}

auto lossRate(T) (T profitRange) pure {
    return profitRange.count!(a => a < 0) / profitRange.count.to!double;
}

auto wins(T) (T profitRange) pure {
    return profitRange.filter!(a => a > 0);
}

auto losses(T) (T profitRange) pure {
    return profitRange.filter!(a => a < 0);
}

auto weighted(T) (T profitRange) pure {
     return profitRange.enumerate(1)
                       .map!(a => a.index * a.value)
                       .sum / iota(1,profitRange.count+1).sum;
}

auto avgTradingVolumn(Range) (Range rng, int period) {
    return rng.retro.take(period).map!(a => a.get!"volumn").mean;
}

alias GrossInfo = Tuple!(double,"profit",
                         double,"loss",
                         double,"adjustedProfit",
                         double,"adjustedLoss");

alias StrategyResult = Tuple!(Duration,"duration",
                            int,"count",
                            double,"winRate",
                            GrossInfo,"grossInfo",
                            double,"netPercent",
                            Tuple!(double,"mean",double,"median"),"profitPerTrade");

auto profit (StrategyResult t) {
    Tuple!(double,"gross",double,"net",double,"netPercent",Tuple!(double,"mean",double,"median"),"perTrade",double,"factor", double,"adjustedFactor") rvalue;
    rvalue.gross = t.grossInfo.profit;
    rvalue.net = t.grossInfo.profit-t.grossInfo.loss;
    rvalue.netPercent = t.netPercent;
    rvalue.perTrade = t.profitPerTrade;
    rvalue.factor = t.grossInfo.profit / t.grossInfo.loss;
    rvalue.adjustedFactor = t.grossInfo.adjustedProfit / t.grossInfo.adjustedLoss;

    return rvalue;
}

void macdStats(PriceType priceType=PriceType.close,Flag!"consectutiveDays" flag=No.consectutiveDays, Range)
         (Range records, int fastPeriod, int slowPeriod, int signalPeriod, string outputFile="") if (isInputRange!Range) {

    import std.functional : unaryFun;
    static if (flag==Yes.consectutiveDays) {
        auto windowSize=4;
        alias isBuy =  unaryFun!("a[0].signal <= a[0].line && a[1].signal <= a[1].line && a[2].signal > a[2].line && a[3].signal > a[3].line");
        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal >= a[1].line && a[2].signal < a[2].line && a[3].signal < a[3].line");
    } else {
        auto windowSize=2;
        alias isBuy = unaryFun!("a[0].signal <= a[0].line && a[1].signal > a[1].line");
        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal < a[1].line");
    }

    StrategyResult rvalue;

    auto times = records.map!(a => a.time);
    auto closes = records.map!(a => a.get!priceType);
    auto slow = closes.ema(slowPeriod);
    auto fast = closes.ema(fastPeriod);
    auto macd = zip(fast,slow).map!(a => a[0]-a[1]);
    auto signal = macd.ema(signalPeriod);

    auto file = File("output2.csv","w");
    foreach (timePoint; zip(times,macd,signal)){
        file.writeln (timePoint[0],",",timePoint[1],",",timePoint[2]);
    }
}

enum Action {buy,sell}
alias Trade = Tuple!(DateTime,"time",double,"price",Action,"action");

auto macdActions (PriceType priceType=PriceType.close,Flag!"consectutiveDays" flag=No.consectutiveDays, Range)
         (Range records, int fastPeriod, int slowPeriod, int signalPeriod, string outputFile="") if (isInputRange!Range) {

    import std.functional : unaryFun;
    static if (flag==Yes.consectutiveDays) {
        auto windowSize=4;
        alias isBuy =  unaryFun!("a[0].signal <= a[0].line && a[1].signal <= a[1].line && a[2].signal > a[2].line && a[3].signal > a[3].line");
        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal >= a[1].line && a[2].signal < a[2].line && a[3].signal < a[3].line");
    } else {
        auto windowSize=2;
        alias isBuy = unaryFun!("a[0].signal <= a[0].line && a[1].signal > a[1].line");
        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal < a[1].line");
    }

    StrategyResult rvalue;

    auto times = records.map!(a => a.time);
    auto closes = records.map!(a => a.get!priceType);
    auto slow = closes.ema(slowPeriod);
    auto fast = closes.ema(fastPeriod);
    auto macd = zip(fast,slow).map!(a => a[0]-a[1]);
    auto signal = macd.ema(signalPeriod);

    auto timeSeries = zip(times,closes,macd,signal)
                          .map!(a => Tuple!(DateTime,"time",
                                            double,"price",
                                            double,"line",
                                            double,"signal")(a.expand))
                          .array
                          .slide!(No.withPartial)(windowSize)
                          .filter!(a => isBuy(a) || isSell(a))
                          .map!(a => Trade(a.back.time,a.back.price,(isBuy(a)) ? Action.buy : Action.sell))
                          .array;

    return timeSeries;
    //return timeSeries.retro.take(2).array;


}

//auto macd(Flag!"consectutiveDays" flag=No.consectutiveDays, FastRange, SlowRange)
//         (FastRange fastRng, SlowRange slowRng) if (isInputRange!FastRange && isInputRange!SlowRange) {
//
//    static if (flag) {
//        return macd!(Yes.consectutiveDays)(fastRng,slowRng,fastRng.count);
//    } else {
//        return macd!(No.consectutiveDays)(fastRng,slowRng,fastRng.count);
//    }
//}

auto macd(FastRange, SlowRange) (FastRange fast, SlowRange slow) {
    return zip(fast,slow).map!(a => a[0]-a[1]);
}

//auto macd(Flag!"consectutiveDays" flag=No.consectutiveDays, FastRange, SlowRange)
//         (FastRange fastRng, SlowRange slowRng, int signalPeriod) if (isInputRange!FastRange && isInputRange!SlowRange) {
//
//    import std.functional : unaryFun;
//    static if (flag==Yes.consectutiveDays) {
//        auto windowSize=4;
//        alias isBuy =  unaryFun!("a[0].signal <= a[0].line && a[1].signal <= a[1].line && a[2].signal > a[2].line && a[3].signal > a[3].line");
//        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal >= a[1].line && a[2].signal < a[2].line && a[3].signal < a[3].line");
//    } else {
//        auto windowSize=2;
//        alias isBuy = unaryFun!("a[0].signal <= a[0].line && a[1].signal > a[1].line");
//        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal < a[1].line");
//    }
//
//    auto macd = zip(fastRng,slowRng).map!(a => a[0]-a[1]);
//    //auto signal = macd.
//
//    return 0;
//}

auto macd(PriceType priceType=PriceType.close,Flag!"consectutiveDays" flag=No.consectutiveDays, Range)
         (Range records, int fastPeriod, int slowPeriod, int signalPeriod, string outputFile="") if (isInputRange!Range) {

    import std.functional : unaryFun;
    static if (flag==Yes.consectutiveDays) {
        auto windowSize=4;
        alias isBuy =  unaryFun!("a[0].signal <= a[0].line && a[1].signal <= a[1].line && a[2].signal > a[2].line && a[3].signal > a[3].line");
        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal >= a[1].line && a[2].signal < a[2].line && a[3].signal < a[3].line");
    } else {
        auto windowSize=2;
        alias isBuy = unaryFun!("a[0].signal <= a[0].line && a[1].signal > a[1].line");
        alias isSell = unaryFun!("a[0].signal >= a[0].line && a[1].signal < a[1].line");
    }

    Trade[][] rvalue;

    if (records.count < 2) return rvalue;

    auto times = records.map!(a => a.time);
    auto closes = records.map!(a => a.get!priceType);
    auto slow = closes.ema(slowPeriod);
    auto fast = closes.ema(fastPeriod);
    auto macd = zip(fast,slow).map!(a => a[0]-a[1]);
    auto signal = macd.ema(signalPeriod);

    auto timeSeries = zip(times,closes,macd,signal)
                          .map!(a => Tuple!(DateTime,"time",
                                            double,"price",
                                            double,"line",
                                            double,"signal")(a.expand))
                          .array;



    Trade[] trades;
    trades.reserve(400);
    foreach (timeSlice; timeSeries.slide!(No.withPartial)(windowSize)) {
        if (isBuy(timeSlice) && (trades.empty || trades.back.action==Action.sell)) {
            trades ~= Trade(timeSlice.back.time,timeSlice.back.price,Action.buy);
        } else if (isSell(timeSlice) && (trades.empty || trades.back.action==Action.buy)) {
            trades ~= Trade(timeSlice.back.time,timeSlice.back.price,Action.sell);
        }
    }

    auto completeTrades = trades.find!(a => a.action==Action.buy)
                                .slide!(No.withPartial)(2,2)
                                .array
                                .sort!((a,b) => a[1].price-a[0].price < b[1].price-b[0].price)
                                .array;


    return completeTrades;
}

auto isBuy(Flag!"consectutiveDays" flag=No.consectutiveDays,T) (T data) {
    static if (flag==Yes.consectutiveDays) {
        return data[0].signal <= (data[0].fast-data[0].slow) && data[1].signal <= (data[1].fast-data[1].slow) && data.signal > (data.fast-data.slow) && data.signal > (data.fast-data.slow);
    } else {
        return data[0].signal <= (data[0].fast-data[0].slow) && data[1].signal > (data[1].fast-data[1].slow);
    }
}

auto isSell(Flag!"consectutiveDays" flag=No.consectutiveDays,T) (T data) {
    static if (flag==Yes.consectutiveDays) {
        return data.signal >= (data.fast-data.slow) && data.signal >= (data.fast-data.slow) && data.signal < (data.fast-data.slow) && data.signal < (data.fast-data.slow);
    } else {
        return data[0].signal >= (data[0].fast-data[0].slow) && data[1].signal < (data[1].fast-data[1].slow);
    }
}

auto signals(Flag!"consectutiveDays" flag=No.consectutiveDays, Range) (Range rng) {
    struct Signal {
        Range rng;
        static if (flag==Yes.consectutiveDays) {
            auto windowSize=4;
        } else {
            auto windowSize=2;
        }

        import std.container : DList;
        DList!(ElementType!Range) buffer;


        this (Range r) {
            rng = r;
            foreach (e; rng.take(windowSize)) buffer.insert(e);
            rng.popFrontN(windowSize/2);
        }

        auto front() {
            auto tmp = buffer.array;
            if (tmp.isBuy!flag) {
                return tuple("buy",rng.front);
            } else if (tmp.isSell!flag) {
                return tuple("sell",rng.front);
            } else {
                return tuple("none",rng.front);
            }
        }

        auto empty() { return rng.take(windowSize).count < windowSize; }

        void popFront() {
            rng.popFront;
            if (!rng.empty) {
                buffer.insert(rng.front);
                buffer.removeFront;
            }
        }
    }
    return Signal(rng);
}

//struct SMA(Range) if (isNumeric!(ElementType!Range)) {
//        Range rng;
//        double period;
//
//        import std.container : DList;
//        DList!(ElementType!Range) buffer;
//
//        double currentResult;
//        this (Range r, int p) {
//            rng=r;
//            period=p;
//            currentResult=r.front;
//
//            // prepopulate buffer
//            buffer.insert (r.front.repeat(p));
//        }
//
//        auto front() {
//            return currentResult;
//        }
//
//        auto popFront() {
//            rng.popFront;
//            if (!rng.empty){
//                currentResult = currentResult + (rng.front / period) - (buffer.back / period);
//                buffer.insertFront (rng.front);
//                buffer.removeBack;
//            }
//        }
//
//        auto empty() {
//            return rng.empty;
//        }
//    }
//    return SMA!T (rng,period);
