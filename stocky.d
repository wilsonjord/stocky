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

version(unittest) import std.math : approxEqual;

alias Symbol = Tuple!(string,"exchange",string,"name");

/++
    Main data type to store EOD data for a stock
+/
alias EODRecord = Tuple!(DateTime,"time",double,"open",double,"high",double,"low",double,"close",int,"volumn");

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
        A simple moving average range
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

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to average
        seed = optional seed, (default value is the first value of rng)

    Returns:
        An exponential moving average range
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
    auto a = iota(1,100); // range of ints 1 to 100

    assert (a.ema(10) // period 10, default seed of 1 (the first element)
             .drop(9)
             .take(3).approxEqual([6.24,7.10,7.99]));

    assert (a.ema(5,0) // period 5, seed 0
             .take(3).approxEqual([0,0.67,1.44]));

    // test based on
    // http://www.dummies.com/personal-finance/investing/stocks-trading/how-to-calculate-exponential-moving-average-in-trading/
    auto b = [22.81,23.09,22.91,
              23.23,22.83,23.05,
              23.02,23.29,23.41,
              23.49,24.6,24.63,
              24.51,23.73,23.31,
              23.53,23.06,23.25,
              23.12,22.8,22.84];
    assert (b.ema(9)
             .approxEqual([22.81,22.87,22.87,
                           22.95,22.92,22.95,
                           22.96,23.03,23.1,
                           23.18,23.47,23.7,
                           23.86,23.83,23.73,
                           23.69,23.56,23.5,
                           23.42,23.3,23.21]));

    auto c = iota(1,100).map!(a => tuple!("index","value")(a,a));
    assert (c.ema!"value"(10)
             .drop(9)
             .take(3).approxEqual([6.24,7.10,7.99]));
}

auto result (double start, double end) {
    return (end - start) / start;
}

auto result(T) (in T trade) pure {
    return result(trade.front.price,trade.back.price);
}

/++
    Given a range of trades, gives the percentage
    increase/decrease of each sequential $(LREF Trade).

    Params:
        trades = A range of $(LREF Trade)'s

    Returns:
        The percentage increase/decrease of trades
+/
auto results(T) (in T trades) pure {
    return trades.chunks(2)
                 .map!(a => a.result);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,2)),4,Action.sell),
                      Trade(DateTime(Date(2000,1,3)),4.5,Action.buy),
                      Trade(DateTime(Date(2000,1,4)),4,Action.sell)];

    assert (trades.results
                  .approxEqual([0.333,-0.111]));
}

/++
    Given a range of trades, return the total number
    of days holding each trade.

    Params:
        trades = A range of $(LREF Trade)'s

+/
auto daysHeld(T) (in T trades) pure {
    return trades.chunks(2)
                 .map!(a => (a[1].time - a[0].time).total!"days")
                 .sum;
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),4.5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),4,Action.sell)];
    assert (trades.daysHeld==27);
}

/++
    Given a range of trades, return the
    average number of trades per year.

    Serves as an indication of how "busy"
    a particular trading strategy could be
    during the year.

    Params:
        trades = A range of $(LREF Trade)'s
+/
auto tradesPerYear(T) (in T trades) pure {
    return (trades.count/2).to!double / (((trades.back.time-trades.front.time).total!"days")/365.25);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),4.5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),4,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4,Action.sell)
                      ];

    // 3 trades, over 2 years + 1 day
    assert (trades.tradesPerYear
                  .approxEqual(3 / ((365*2+1)/365.25)));
}

/++
    Given a range of trades, return the
    percentage gain/loss of the first trade
    with the last trade.

    Params:
        trades = A range of $(LREF Trade)'s
+/
auto marketReturn(T) (in T trades) pure {
    return result (trades.front.price,trades.back.price);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.8,Action.sell)
                      ];

    assert (trades.marketReturn.approxEqual((4.8-3)/3));
}


auto winlossRate(string type, T) (in T trades, Flag!"weighted" flag, double subtract) pure {
    static assert (type=="win" || type=="loss");
    import std.functional : greaterThan, lessThan;

    static if (type=="win") {
        alias myCompare = greaterThan;
    } else {
        alias myCompare = lessThan;
    }

    if (flag==Yes.weighted) {
        return trades.results
                     .enumerate(1)
                     .map!(a => (myCompare(a.value-subtract,0)) ? a.index : 0)
                     .sum / iota(1,trades.results.count+1).sum.to!double;
    } else {
        return trades.results.count!(a => myCompare(a-subtract,0)) / trades.results.count.to!double;
    }
}

/++
    Given a range of trades, return the
    win rate.

    Params:
        trades = A range of $(LREF Trade)'s
        flag = Whether the results are time weighted (default No)
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto winRate(T) (in T trades, double subtract=0, Flag!"weighted" flag = No.weighted) pure {
    return winlossRate!"win" (trades,flag,subtract);
}

auto winRate(T) (in T trades, Flag!"weighted" flag = No.weighted, double subtract=0) pure {
    return winlossRate!"win" (trades,flag,subtract);
}

auto winRate(T) (in T trades) pure {
    return winlossRate!"win" (trades,No.weighted,0);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell)
                      ];

    // 4 trades, 2 winning, 1 losing
    assert (trades.winRate
                  .approxEqual(2.0 / 4));

    assert (trades.winRate(0.1)             // subtract brokerage of 10%
                  .approxEqual(1.0 / 4));   // only one winner now


    // sequentially, trades go: win, win, loss, draw
    // the wins are given less weighting, as they
    // are the "oldest"
    assert (trades.winRate(Yes.weighted)
                  .approxEqual(0.3));

    assert (trades.winRate(Yes.weighted,0.01) // subtract brokerage of 1%
                  .approxEqual(0.3));         // no change, same number of winners
}




/++
    Given a range of trades, return the
    loss rate.

    Params:
        trades = A range of $(LREF Trade)'s
        flag = Whether the results are time weighted (default No)
        subtract = A percentage to subtract from
                   each result (i.e. brokerage). Default 0
+/
auto lossRate(T) (in T trades, double subtract=0, Flag!"weighted" flag = No.weighted) pure {
    return winlossRate!"loss" (trades,flag,subtract);
}

auto lossRate(T) (in T trades, Flag!"weighted" flag = No.weighted, double subtract=0) pure {
    return winlossRate!"loss" (trades,flag,subtract);
}

auto lossRate(T) (in T trades) pure {
    return winlossRate!"loss" (trades,No.weighted,0);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell)
                      ];

    // 4 trades, 2 winning, 1 losing
    assert (trades.lossRate
                  .approxEqual(1.0 / 4));

    assert (trades.lossRate(0.01)
                  .approxEqual(2.0 / 4));      // two losses now, due to
                                               // brokerage of 1%

    // sequentially, trades go: win, win, loss, draw
    // the loss is given more weighting than wins, as
    // it is "newer"
    assert (trades.lossRate(Yes.weighted)
                  .approxEqual(0.3));

    assert (trades.lossRate(Yes.weighted,0.01) // subtract brokerage of 1%
                  .approxEqual(0.7));          // loss rate increase, as the
                                               // final pair is now a loss
}

auto winslosses(string type,T) (in T trades, double subtract) pure {
    static assert (type=="win" || type=="loss");
    import std.functional : greaterThan, lessThan;

    static if (type=="win") {
        alias myCompare = greaterThan;
    } else {
        alias myCompare = lessThan;
    }

    import std.math : abs;
    return trades.results
                 .filter!(a => myCompare(a-subtract,0))
                 .map!(a => (a-subtract).abs);
}

/++
    Given a range of trades, return the
    winners as a range of results.

    Params:
        trades = A range of $(LREF Trade)'s
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto wins(T) (in T trades, double subtract=0) pure {
    return trades.winslosses!"win"(subtract);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell),
                      Trade(DateTime(Date(2002,2,4)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,5)),4.9,Action.sell)
                      ];

    assert (trades.wins
                  .approxEqual([
                                0.333,   // from the first buy/sell pair (3 and 4)
                                0.1,     // from the second buy/sell pair (5 and 5.5)
                                0.0889   // from the last buy/sell pair (4.5 and 4.9)
                               ]));

    assert (trades.wins(0.01)            // 1% commision
                  .approxEqual([
                                0.333-0.01,
                                0.1-0.01,
                                0.0889-0.01
                               ]));
}

/++
    Given a range of trades, return the
    losers as a range of results.

    Note: losses are expressed as a positive percentage.

    Params:
        trades = A range of $(LREF Trade)'s
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto losses(T) (in T trades, double subtract=0) pure {
    return trades.winslosses!"loss"(subtract);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell),
                      Trade(DateTime(Date(2002,2,4)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,5)),4.9,Action.sell)
                      ];

    assert (trades.losses
                  .approxEqual([
                                0.0667   // from the third buy/sell pair (4.5 and 4.2)
                               ]));

    assert (trades.losses(0.01)          // 1% commision
                  .approxEqual([
                                 0.0667+0.01,
                                 0.01
                               ]));
}

/++
    Given a range of trades, return the
    profit factor.

    Params:
        trades = A range of $(LREF Trade)'s
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto profitFactor(T) (in T trades, double subtract=0) pure {
    return (trades.wins(subtract).mean * trades.winRate(subtract)) /
           (trades.losses(subtract).mean * trades.lossRate(subtract));
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell),
                      Trade(DateTime(Date(2002,2,4)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,5)),4.9,Action.sell)
                      ];

    assert (trades.profitFactor
                  .approxEqual((0.174*0.6) / (0.067*0.2)));  // avg wins * win rate / avg loss * loss rate

    assert (trades.profitFactor(0.01)
                  .approxEqual((0.164*0.6) / (0.0433*0.4)));
}

auto years(T) (in T trades) pure {
    // assume sorted
    return (trades.back.time - trades.front.time).total!"days" / 365.0;
}

/++
    Given a range of trades and initial capital,
    return the Internal Rate of Return (IRR) assuming
    trades are reinvested.

    Params:
        trades = A range of $(LREF Trade)'s
        startValue = Initial capital
        brokerage = Brokeraage/commision for each trade
+/
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

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell)
                      ];
}





auto weighted(T) (T profitRange) pure {
     return profitRange.enumerate(1)
                       .map!(a => a.index * a.value)
                       .sum / iota(1,profitRange.count+1).sum;
}

auto staticInvest(T) (in T trades, double invest, double brokerage=0) pure {
    auto rvalue=0.0;
    foreach (pair; trades.chunks(2)) {
        auto buyTrade = pair[0];
        auto sellTrade = pair[1];

        // buy
        import std.math : floor;
        auto bought = floor(invest / buyTrade.price);
        rvalue -= bought * buyTrade.price;
        rvalue -= brokerage;

        // sell
        rvalue += bought*sellTrade.price;
        rvalue -= brokerage;
    }
    return rvalue;
}

enum Action {buy,sell,none}

alias Trade = Tuple!(DateTime,"time",double,"price",Action,"action");

auto completedOnly(Range) (Range trades) {
    auto rvalue = trades.filter!(a => a.action != Action.none)
                        .uniq!((a,b) => a.action == b.action)
                        .array;

    if (rvalue.empty) return rvalue;
    if (rvalue.front.action==Action.sell) {
        rvalue.popFront;
    }

    if (rvalue.back.action==Action.buy) {
        rvalue.popBack;
    }

    assert (rvalue.count % 2 == 0);
    return rvalue;
}

auto tradeAction(T) (T data) {
    if (data.count % 2 != 0) {
        throw new Exception ("Argument data must be even number in length");
    }

    auto firstHalf = data.take(data.count / 2);
    auto lastHalf = data.drop(data.count / 2);

    // test sell
    if (firstHalf.all!(a => a[2] < a[0]-a[1]) &&
        lastHalf.all!(a => a[2] >= a[0]-a[1])) {
        return Action.sell;
    }

    // test buy
    if (firstHalf.all!(a => a[2] > a[0]-a[1]) &&
        lastHalf.all!(a => a[2] <= a[0]-a[1])) {
        return Action.buy;
    }

    return Action.none;
}
