import std.stdio;

import fastcsv;

import stocky;

import std.algorithm;

import std.range;

import std.conv : to;
import std.datetime;
import std.typecons : Nullable, Tuple, tuple;
import std.math : isNaN;
import std.format : format;
import std.conv : to;

auto weightedReturns(T)(T trades) {

    auto t = trades.sort!((a, b) => a.time < b.time).array;

    if (t.front.action == Action.sell)
        t.popFront;

    if (t.back.action == Action.buy)
        t.popBack;

    import dstats;

    return tuple!("weighted", "mean", "winRate", "count")(t.results.weighted,
            t.results.mean, t.winRate, t.count);

}

void returnOverTime(T)(string file, T fast, T slow) {
    auto signals = csvFromUtf8File(file).drop(1)
        .map!(a => NamedTrade(a[0].to!string,
                DateTime(Date.fromISOString(a[1].replace("/", ""))),
                a[2].to!double, (a.back == "buy") ? Action.buy : Action.sell))
        .array
        .multiSort!((a, b) => a.symbol < b.symbol, (a, b) => a.time < b.time)
        .chunkBy!((a, b) => a.symbol == b.symbol)
        .map!(a => a.array.tradify)
        .joiner
        .array
        ;

    foreach (pair; signals.chunks(2)) {
        assert(pair[0].action == Action.buy);
        assert(pair[1].action == Action.sell);
        assert(pair[0].time < pair[1].time);
        assert(pair[0].symbol == pair[1].symbol);
    }

    writeln("average per trade");
    signals.chunks(2).map!(a => (a[1].price - a[0].price) / a[0].price).mean
        .writeln;

    writeln("total trades");
    signals.chunks(2).count.writeln;

    writeln("average per trade filtered");
    signals.chunks(2).filter!(a => a[0].symbol in slow)
        .filter!(a => fast[a[0].symbol][a[0].time] > slow[a[0].symbol][a[0].time])
        .map!(a => (a[1].price - a[0].price) / a[0].price)
        .mean
        .writeln;

    writeln("total trades");
    signals.chunks(2).filter!(a => a[0].symbol in slow)
        .filter!(a => fast[a[0].symbol][a[0].time] > slow[a[0].symbol][a[0].time])
        .count
        .writeln;
}

enum PickStrategy {
    winRate,
    weightedReturns,
    winReturns,
    averageReturns,
    meanReturns,
    averageWeightedFactor,
    sharpeWeighted,
    weightedReturnsAll
}

auto moneyManagement(string file, PickStrategy ps) {
    auto data = csvFromUtf8File(file).drop(1);
    Trade[][string] trades;

    alias TradeSignal = Tuple!(string, "symbol", Trade, "trade");
    auto signals = data.map!(a => TradeSignal(a[0].to!string,
            Trade(DateTime(Date.fromISOString(a[1].replace("/",
            ""))), a[2].to!double, (a.back == "buy") ? Action.buy : Action.sell)))
        .array
        .sort!((a, b) => a.trade.time < b.trade.time)
        .array
        .idup;

    import dstats;

    auto getMetric(string symbol, DateTime t, PickStrategy pick) {
        Nullable!double rvalue;

        auto trades = signals.filter!(a => a.symbol == symbol)
            .map!(a => a.trade)
            .array
            .tradify;

        if (trades.empty)
            return rvalue;

        if (trades.count <= 20)
            return rvalue;

        auto pastTrades = trades.take(
                trades.count!(a => a.action == Action.sell && a.time < t) * 2);

        switch (pick) {
        default:
            assert(0);
        case PickStrategy.winRate:
            auto w = pastTrades.winRate;
            if (!w.isNaN) {
                rvalue = w;
            }
            break;
        case PickStrategy.weightedReturns:
            auto w = pastTrades.wins.weighted;
            if (!w.isNaN) {
                rvalue = w;
            }
            break;
        case PickStrategy.winReturns:
            auto w = pastTrades.wins.weighted * (pastTrades.winRate * 0.5);
            if (!w.isNaN) {
                rvalue = w;
            }
            break;
        case PickStrategy.averageReturns:
            auto w = pastTrades.wins.mean.to!double;
            if (!w.isNaN) {
                rvalue = w;
            }
            break;
        case PickStrategy.averageWeightedFactor:
            auto w = pastTrades.wins.mean.to!double * pastTrades.wins.weighted;
            if (!w.isNaN) {
                rvalue = w;
            }
            break;
        case PickStrategy.sharpeWeighted:
            auto w = (pastTrades.wins.mean
                    / pastTrades.wins.stdev) * pastTrades.wins.weighted;
            if (!w.isNaN) {
                rvalue = w;
            }
            break;
        case PickStrategy.weightedReturnsAll:
            auto w = pastTrades.results.weighted;
            if (!w.isNaN) {
                rvalue = w;
            }
            break;

        }

        return rvalue;
    }

    auto symbols = signals.map!(a => a.symbol).array.dup.sort.uniq.array;
    auto dates = signals.map!(a => a.trade.time)
        .filter!(a => a >= DateTime(Date(2008, 1, 1)))
        .array
        .dup
        .sort
        .uniq
        .array;

    double[] returns;

    foreach (i; 0 .. 2_000) {
        i.writeln;
        import std.random : uniform;

        auto date = dates[uniform(0, dates.length)];

        auto buySignals = signals.filter!(a => a.trade.action == Action.buy
                && a.trade.time == date).array;

        if (buySignals.count > 1) {
            import std.math : isNaN;

            auto x = buySignals.map!(a => tuple(a.symbol,
                    getMetric(a.symbol, date, ps))).array;

            auto y = x.filter!(a => !a[1].isNull).array;
            assert(!y.empty);
            auto z = y.sort!((a, b) => a[1].get > b[1].get);
            auto metrics = z.array;

            // get return

            auto start = signals.find!(a => a.symbol == metrics.front[0]
                    && a.trade.time == date);
            assert(start.front.trade.action == Action.buy);

            auto startPrice = start.front.trade.price;

            auto end = start.find!(a => a.symbol == metrics.front[0] && a
                    .trade.time > date);

            if (!end.empty) {
                assert(end.front.trade.action == Action.sell);

                auto endPrice = end.front.trade.price;

                returns ~= (endPrice - startPrice) / startPrice;

                writeln("avg: ", returns.mean);
                writeln("mean: ", returns.median);
            }
        }
    }

    returns = returns.sort.array;
    returns = returns.drop(10).array;
    returns = returns.dropBack(10).array;

    writeln("avg: ", returns.mean);
    writeln("mean: ", returns.median);

    return;

}

void selected(string file) {

    auto data = csvFromUtf8File(file).drop(1);

    Trade[][string] trades;

    foreach (row; data) {

        import std.datetime;

        if (row[0]!in trades)
            trades[row[0]] = Trade[].init;

        trades[row[0]] ~= Trade(DateTime(Date.fromISOString(row[1].replace("/",
                ""))), row[2].to!double, (row.back == "buy") ? Action.buy : Action
                .sell);
    }

    trades.byKey
        .map!(a => trades[a].map!(b => tuple!("symbol", "trade")(a, b)).array)
        .joiner
        .array
        .sort!((a, b) => a.trade.time > b.trade.time)
        .filter!(a => a.trade.action == Action.buy)
        .map!(a => tuple!("tradeAction", "tradeMetrics")(a,
                trades[a.symbol].weightedReturns))
        .array //.filter!(a => a[1][0] >= 0.015)
        .take(80).array
        .multiSort!((a,
                b) => a.tradeAction.trade.time > b.tradeAction.trade.time, (a,
                b) => a.tradeMetrics.weighted > b.tradeMetrics.weighted)
        .array
        .each!(a => writeln(format("%s\t%s\t%s\t%s\t%s", a.tradeAction.symbol,
                a.tradeAction.trade.time, a.tradeAction.trade.price,
                a.tradeAction.trade.action, a.tradeMetrics.weighted)));

    trades.byKey
        .map!(a => trades[a].map!(b => tuple!("symbol", "trade")(a, b)).array)
        .joiner
        .array
        .sort!((a, b) => a.trade.time > b.trade.time)
        .filter!(a => a.trade.action == Action.sell)
        .map!(a => tuple!("tradeAction", "tradeMetrics")(a,
                trades[a.symbol].weightedReturns))
        .array
        .filter!(a => a[1][0] >= 0.015)
        .take(30).array
        .multiSort!((a,
                b) => a.tradeAction.trade.time > b.tradeAction.trade.time, (a,
                b) => a.tradeMetrics.weighted > b.tradeMetrics.weighted)
        .array
        .each!(a => writeln(format("%s\t%s\t%s\t%s\t%s", a.tradeAction.symbol,
                a.tradeAction.trade.time, a.tradeAction.trade.price,
                a.tradeAction.trade.action, a.tradeMetrics.weighted)));

    return;

}
