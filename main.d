module main;

import std.stdio;
import std.typecons : Tuple, tuple;
import std.datetime;
import std.algorithm;
import std.range;
import std.conv : to;

import stocky : ema, sma, Action;
import dstats : mean;

auto tradeAction(T) (T data) {
    if (data.count % 2 != 0) {
        throw new Exception ("Argument data must be even number in length");
    }

    auto firstHalf = data.take(data.count / 2);
    auto lastHalf = data.drop(data.count / 2);

    // test sell
    if (firstHalf.all!(a => a[2] <= a[0]-a[1]) &&
        lastHalf.all!(a => a[2] > a[0]-a[1])) {
        return Action.sell;
    }

    // test buy
    if (firstHalf.all!(a => a[2] >= a[0]-a[1]) &&
        lastHalf.all!(a => a[2] < a[0]-a[1])) {
        return Action.buy;
    }

    return Action.none;
}

void main(){
    import std.csv;
    import std.file : readText;

    auto records = File(`appl.csv`,"r")
                       .byLine
                       .drop(1) // ignore header
                       .map!(a => a.splitter(",").array)
                       .map!(a => tuple!("time","close")
                                        (Date.fromISOExtString(a[0]),a[4].to!double))
                       .array
                       .sort!((a,b) => a.time < b.time);    // sort by time, not required if you know your data is already sorted

    records.sma!"close" (200)
           .drop(199)
           .take(10)
           .writeln; // 24.11125,24.065,24.02065...

    // with time stamp
    zip(records.map!(a => a.time),records.sma!"close"(200))
        .drop(199)
        .take(10)
        .each!(a => writeln(a[0]," @ ",a[1])); // 1985-Jun-21 @ 24.1112
                                               // 1985-Jun-24 @ 24.065
                                               // 1985-Jun-25 @ 24.0206

    // a macd strategy

    auto prices = zip(records.map!(a => a.time),records.map!(a => a.close))
                    .map!(a => tuple!("time","price")(a.expand));

    auto fastPeriod=12;
    auto slowPeriod=24;
    auto signalPeriod=9;
    auto fast = records.sma!"close"(fastPeriod).array;
    auto slow = records.sma!"close"(slowPeriod).array;
    auto signalLine = zip(fast,slow).map!(a => a[0]-a[1]).sma(signalPeriod).array;

    auto windowSize=2;
    auto signals = zip(fast,slow,signalLine)
                     .array
                     .retro
                     .slide!(No.withPartial)(windowSize)
                     .map!(a => tradeAction(a))
                     .retro;

    // combine signal with prices and get all trades
    auto trades = zip(signals,prices.drop(windowSize-1))
                    .map!(a => tuple!("signal","record")(a.expand))
                    .drop(slowPeriod) // ignore the first few trades, to
                                      // allow for the moving averages to build up
                    .filter!(a => a.signal!=Action.none);

    trades.take(10)
          .each!(a => writeln(a.record.time," ",a.signal," @ ",a.record.price));
            // 1984-Oct-18 sell @ 25.62

    // the above uses minimal functions of the stocky library
    // transform to the stocky usertypes to allow more function use

    import stocky;
    auto stockyTrades = trades.map!(a => Trade(cast(DateTime)a.record.time,a.record.price,a.signal))
                              .array
                              .completedOnly;
    assert(stockyTrades.front.action==Action.buy);
    assert(stockyTrades.back.action==Action.sell);

    writeln;
    writeln ("Apple stock stats using 12-24-9 SMA macd");
    auto appleResults = stockyTrades.results;
    writefln ("win rate (%%): %0.2f",appleResults.winRate*100);
    writefln ("loss rate (%%): %0.2f",appleResults.lossRate*100);
    writefln ("average win (%%): %0.2f",appleResults.wins.mean*100);
    writefln ("average loss (%%): %0.2f",appleResults.losses.mean*100);
    writefln ("profit factor: %0.2f",(appleResults.winRate*appleResults.wins.mean) /
                                     (appleResults.lossRate*appleResults.losses.mean));

    writeln;

    fast = records.ema!"close"(fastPeriod).array;
    slow = records.ema!"close"(slowPeriod).array;
    signalLine = zip(fast,slow).map!(a => a[0]-a[1]).ema(signalPeriod).array;

    auto emaTrades = zip(fast,slow,signalLine)
                         .array
                         .retro
                         .slide!(No.withPartial)(windowSize)
                         .map!(a => tradeAction(a))
                         .retro
                         .zip(prices.drop(windowSize-1))
                         .map!(a => Trade(cast(DateTime)a[1].time,a[1].price,a[0]))
                         .drop(slowPeriod)
                         .filter!(a => a.action!=Action.none)
                         .array
                         .completedOnly;

    writeln ("Apple stock stats using 12-24-9 EMA macd");
    auto appleResultsEma = emaTrades.results;
    writefln ("win rate (%%): %0.2f",appleResultsEma.winRate*100);
    writefln ("loss rate (%%): %0.2f",appleResultsEma.lossRate*100);
    writefln ("average win (%%): %0.2f",appleResultsEma.wins.mean*100);
    writefln ("average loss (%%): %0.2f",appleResultsEma.losses.mean*100);
    writefln ("profit factor: %0.2f",(appleResultsEma.winRate*appleResultsEma.wins.mean) /
                                     (appleResultsEma.lossRate*appleResultsEma.losses.mean));

	return;
}
