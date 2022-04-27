import std.stdio;
import std.algorithm;
import std.range;
import std.random : uniform, randomCover, randomShuffle;
import std.typecons : tuple, Tuple;
import core.time : days;
import std.datetime.date;
import std.file : readText;
import std.json : parseJSON;
import std.conv : to;
import std.math : isNaN;
import std.format : format;

import stocky;
import dstats : stdev, median;
import commandr;

auto getRandomTrade(T)(T records) {
    auto start = uniform(0, records.length - 2);
    auto end = uniform(start, records.length - 1);
    return tuple!("start", "end")(records[start], records[end]);
}

auto getRandomTradeYear(T)(T records) {
    auto startRecord = records.filter!(
            a => a.time < (records.back.time - 365.days)).array.randomCover.front;

    auto endRecord = records.find!(a => a.time >= startRecord.time + 365.days)
        .front;

    return tuple!("time", "result")(endRecord.time,
            (endRecord.close - startRecord.close) / startRecord.close);
}

auto weighted(T)(T data) { // TODO only seems to work with arrays, make it work with ranges
    return data.enumerate(1).map!(a => a.index * a.value).sum / iota(1, data
            .count + 1).sum;
}

alias Records = Tuple!(string, "symbol", EODRecord[], "records");
alias Records2 = Tuple!(string, "symbol", EODRecord2[], "records");

enum EndTime = DateTime(Date(2040, 1, 1));
enum StartTime = DateTime(Date(2000, 1, 1));

auto macdSignal(T)(T trade) {
    if (((trade[1].fast - trade[1].slow) >= trade[1].signal)
            && ((trade[0].fast - trade[0].slow) < trade[0].signal)) {
        return Action.buy;
    }

    if (((trade[1].fast - trade[1].slow) <= trade[1].signal)
            && ((trade[0].fast - trade[0].slow) > trade[0].signal)) {
        return Action.sell;
    }

    return Action.none;
}

/++
    Read Tiingo format JSON file
+/

auto readJsonTiingo(string fileName) {
    import std.file : readText;
    import std.json : parseJSON;
    import std.datetime.date : Date;
    import std.typecons : tuple;

    fileName.writeln;

    try {
        auto json = fileName.readText.parseJSON;

        return json.array
            .map!(a => a.object)
            .map!(a => EODRecord(DateTime.fromISOExtString(
                    a["date"].str[0 .. 19]), a["adjOpen"].floating,
                    a["adjHigh"].floating, a["adjLow"].floating,
                    a["adjClose"].floating, a["adjVolume"].integer))
            .array
            .sort!((a, b) => a.time < b.time)
            .array;
    } catch (Exception ex) {
        return null;
    }

}

auto dollars(T)(T trade, double amount, double brokerage) {
    auto quan = ((amount - brokerage) / trade[0].price).to!int; // rounds down
    auto sell = trade[1].price * quan - brokerage;
    auto buy = trade[0].price * quan + brokerage;
    return sell - buy;
}

auto maWithLookback(T)(T records, uint ma, uint lb) {

    auto trades = zip(records.map!(a => a.close), zip(records,
            records.ema!"close"(ma)).drop(lb)).map!((a) {
        auto lookback = a[0];
        auto close = a[1][0].close;
        auto ema = a[1][1];
        if (close > lookback && close > ema)
            return Trade(a[1][0].time, close, Action.buy);
        if (close < lookback && close < ema)
            return Trade(a[1][0].time, close, Action.sell);
        return Trade(a[1][0].time, close, Action.none);
    })
        .filter!(a => a.action != Action.none)
        .uniq!((a, b) => a.action == b.action)
        .array
        .tradify;

    return trades;
}

enum StartingCapital = 500_000.0;
enum TradeSize = 4000.0;
enum Brokerage = 8.0;

alias StrategyResults = Tuple!(double, "capitalReturn", double, "years",);

auto benchmark(T)(T market, DateTime start, DateTime end) {
    auto spy = market.find!(a => a.symbol == "SPY").front;
    auto startPrice = spy.records.find!(a => a.time >= start).front.close;
    auto endPrice = (spy.records.back.time < end) ? spy.records.back.close
        : spy.records.find!(a => a.time >= end).front.close;

    auto quan = (StartingCapital - Brokerage) / startPrice;

    return ((quan * endPrice - Brokerage) - (quan * startPrice + Brokerage)) / StartingCapital;
}

struct ExecutedTrade {
    private Trade _trade;
    alias _trade this;

    auto opDispatch(string name)() const {
        return mixin("_trade." ~ name);
    }

    string symbol;
    double quantity;

    this(Trade t, string s, double q) {
        _trade = t;
        symbol = s;
        quantity = q;
    }
}

auto maWithLookback(T)(T market, uint period, uint lookback, DateTime start, DateTime end) {
    auto capital = StartingCapital;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

    auto trades = market.map!(a => a.records.maWithLookback(period,
            lookback).filter!(a => a.time >= start && a.time <= end)
            .array
            .tradify
            .map!(b => tuple!("symbol", "tradeSignal")(a.symbol, b))
            .array)
        .joiner
        .array
        .randomShuffle
        .sort!((a, b) => a.tradeSignal.time < b.tradeSignal.time)
        .chunkBy!((a, b) => a.tradeSignal.time == b.tradeSignal.time);

    foreach (signals; trades) {

        foreach (sell; signals.filter!(a => a.tradeSignal.action == Action.sell)) {
            if (sell.symbol in holdings) {
                capital += (holdings[sell.symbol].quantity * sell.tradeSignal
                        .price) - Brokerage;
                rvalue ~= [
                    holdings[sell.symbol],
                    ExecutedTrade(sell.tradeSignal, sell.symbol,
                            holdings[sell.symbol].quantity)
                ];
                holdings.remove(sell.symbol);
            }
        }

        foreach (buy; signals.filter!(a => a.tradeSignal.action == Action.buy)) {
            if (capital < TradeSize)
                break;
            if (buy.symbol in holdings)
                writeln(buy.symbol, " already bought.");
            assert(buy.symbol !in holdings);
            auto tradeSize = (capital < TradeSize * 2) ? (capital - 1) : TradeSize;
            holdings[buy.symbol] = ExecutedTrade(buy.tradeSignal,
                    buy.symbol, (tradeSize - Brokerage) / buy.tradeSignal.price);
            capital -= Brokerage;
            capital -= holdings[buy.symbol].quantity * buy.tradeSignal.price;
            assert(capital >= 0);
        }
    }

    return tuple((capital - StartingCapital) / StartingCapital, rvalue);
}

auto maWithLookbackOrderedBySharpe(T, S)(T market, uint period,
        uint lookback, DateTime start, DateTime end, S sharpeRatios) {
    auto capital = StartingCapital;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

    auto trades = market.map!(a => a.records.maWithLookback(period,
            lookback).filter!(a => a.time >= start && a.time <= end)
            .array
            .tradify
            .map!(b => tuple!("symbol", "tradeSignal")(a.symbol, b))
            .array)
        .joiner
        .array
        .sort!((a, b) => a.tradeSignal.time < b.tradeSignal.time)
        .chunkBy!((a, b) => a.tradeSignal.time == b.tradeSignal.time);

    foreach (signals; trades) {

        foreach (sell; signals.filter!(a => a.tradeSignal.action == Action.sell)) {
            if (sell.symbol in holdings) {
                capital += (holdings[sell.symbol].quantity * sell.tradeSignal
                        .price) - Brokerage;
                rvalue ~= [
                    holdings[sell.symbol],
                    ExecutedTrade(sell.tradeSignal, sell.symbol,
                            holdings[sell.symbol].quantity)
                ];
                holdings.remove(sell.symbol);
            }
        }

        foreach (buy; signals.filter!(a => a.tradeSignal.action == Action.buy)
                .array
                .sort!((a, b) => sharpeRatios[a.symbol][a.tradeSignal.time]
                    > sharpeRatios[b.symbol][b.tradeSignal.time])) {
            if (capital < TradeSize)
                break;
            if (buy.tradeSignal.price < 4)
                break;
            if (buy.symbol in holdings)
                writeln(buy.symbol, " already bought.");
            assert(buy.symbol !in holdings);
            auto tradeSize = (capital < TradeSize * 2) ? (capital - 1) : TradeSize;
            holdings[buy.symbol] = ExecutedTrade(buy.tradeSignal,
                    buy.symbol, (tradeSize - Brokerage) / buy.tradeSignal.price);
            capital -= Brokerage;
            capital -= holdings[buy.symbol].quantity * buy.tradeSignal.price;
            assert(capital >= 0);
        }
    }

    return tuple((capital - StartingCapital) / StartingCapital, rvalue);
}

auto longOnlyMACD(T, S)(T market, S fastAverage, S slowAverage,
        S sharpeRatios, DateTime start, DateTime end) {
    auto capital = StartingCapital;

    auto maxHoldings = 10;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

    auto macdToSignal(A, B)(A symbol, B time) {
        auto macd = fastAverage[symbol][time] - slowAverage[symbol][time];
        if (macd > 0)
            return Action.buy;
        if (macd < 0)
            return Action.sell;
        return Action.none;
    }

    auto trades = market.map!(a => a.records
            .map!(b => Trade(b.time, b.close, macdToSignal(a.symbol, b.time)))
            .filter!(a => a.action != Action.none)
            .filter!(a => a.time >= start && a.time <= end)
            .array
            .uniq!((a, b) => a.action == b.action)
            .array
            .tradify
            .map!(b => tuple!("symbol", "tradeSignal")(a.symbol, b))
            .array)
        .joiner
        .array
        .randomShuffle
        .sort!((a, b) => a.tradeSignal.time < b.tradeSignal.time)
        .chunkBy!((a, b) => a.tradeSignal.time == b.tradeSignal.time);

    auto marketSize = sharpeRatios.keys.length;
    foreach (signals; trades) {

        foreach (sell; signals.filter!(a => a.tradeSignal.action == Action.sell)) {
            if (sell.symbol in holdings) {
                capital += (holdings[sell.symbol].quantity * sell.tradeSignal
                        .price) - Brokerage;
                rvalue ~= [
                    holdings[sell.symbol],
                    ExecutedTrade(sell.tradeSignal, sell.symbol,
                            holdings[sell.symbol].quantity)
                ];
                holdings.remove(sell.symbol);
            }
        }

        foreach (buy; signals.filter!(a => a.tradeSignal.action == Action.buy)) {
            if (capital < TradeSize)
                break;

            auto sharpeThreshold = sharpeRatios.byValue
                .map!(a => a.get(buy.tradeSignal.time, double.init))
                .filter!(a => !a.isNaN)
                .array
                .sort!((a, b) => a > b)
                .array
                .drop((marketSize * 0.2).to!int).front;

            if (buy.symbol in holdings)
                writeln(buy.symbol, " already bought.");
            assert(buy.symbol !in holdings);

            if (sharpeRatios[buy.symbol].get(buy.tradeSignal.time,
                    double.min_normal) > sharpeThreshold) {
                //auto tradeSize = (capital / (maxHoldings - holdings.byKey.count)) - Brokerage;
                auto tradeSize = ((capital >= TradeSize * 2) ? TradeSize : capital) - Brokerage;
                holdings[buy.symbol] = ExecutedTrade(buy.tradeSignal,
                        buy.symbol, (tradeSize - Brokerage) / buy.tradeSignal
                        .price);
                capital -= Brokerage;
                capital -= holdings[buy.symbol].quantity * buy.tradeSignal.price;
                assert(capital >= 0);
            }
        }
    }

    writeln((capital - StartingCapital) / StartingCapital);
    return tuple((capital - StartingCapital) / StartingCapital, rvalue);
}

auto fullMACD(T, S)(T market, S fastAverage, S slowAverage, S signal,
        S sharpeRatios, DateTime start, DateTime end) {
    auto capital = StartingCapital;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

    auto macdToSignal(A, B)(A symbol, B time) {
        auto macd = fastAverage[symbol][time] - slowAverage[symbol][time];
        auto signal = signal[symbol][time];

        if (macd > signal)
            return Action.buy;
        if (macd < signal)
            return Action.sell;
        return Action.none;
    }

    auto trades = market.map!(a => a.records
            .map!(b => Trade(b.time, b.close, macdToSignal(a.symbol, b.time)))
            .filter!(a => a.action != Action.none)
            .filter!(a => a.time >= start && a.time <= end)
            .array
            .uniq!((a, b) => a.action == b.action)
            .array
            .tradify
            .map!(b => tuple!("symbol", "tradeSignal")(a.symbol, b))
            .array)
        .joiner
        .array
        .randomShuffle
        .sort!((a, b) => a.tradeSignal.time < b.tradeSignal.time)
        .chunkBy!((a, b) => a.tradeSignal.time == b.tradeSignal.time);

    auto marketSize = sharpeRatios.keys.length;
    foreach (signals; trades) {

        foreach (sell; signals.filter!(a => a.tradeSignal.action == Action.sell)) {
            if (sell.symbol in holdings) {
                capital += (holdings[sell.symbol].quantity * sell.tradeSignal
                        .price) - Brokerage;
                rvalue ~= [
                    holdings[sell.symbol],
                    ExecutedTrade(sell.tradeSignal, sell.symbol,
                            holdings[sell.symbol].quantity)
                ];
                holdings.remove(sell.symbol);
            }
        }

        foreach (buy; signals.filter!(a => a.tradeSignal.action == Action.buy)) {
            if (capital < TradeSize)
                break;

            auto sharpeThreshold = sharpeRatios.byValue
                .map!(a => a.get(buy.tradeSignal.time, double.init))
                .filter!(a => !a.isNaN)
                .array
                .sort!((a, b) => a > b)
                .array
                .drop((marketSize * 0.05).to!int).front;

            if (buy.symbol in holdings)
                writeln(buy.symbol, " already bought.");
            assert(buy.symbol !in holdings);

            if (sharpeRatios[buy.symbol].get(buy.tradeSignal.time,
                    double.min_normal) > sharpeThreshold) {
                auto tradeSize = ((capital >= TradeSize * 2) ? TradeSize : capital) - Brokerage;
                holdings[buy.symbol] = ExecutedTrade(buy.tradeSignal,
                        buy.symbol, (tradeSize - Brokerage) / buy.tradeSignal
                        .price);
                capital -= Brokerage;
                capital -= holdings[buy.symbol].quantity * buy.tradeSignal.price;
                assert(capital >= 0);
            }
        }
    }

    return tuple((capital - StartingCapital) / StartingCapital, rvalue);
}

auto fullMACDWithRSI(T, S)(T market, S fastAverage, S slowAverage,
        S signal, S rsi, DateTime start, DateTime end) {
    auto capital = StartingCapital;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

    auto macdToSignal(A, B)(A symbol, B time) {
        auto macd = fastAverage[symbol][time] - slowAverage[symbol][time];
        auto signal = signal[symbol][time];

        if (macd > signal && rsi[symbol].get(time, 9999) < 30)
            return Action.buy;
        if (macd < signal && rsi[symbol].get(time, 0) > 70)
            return Action.sell;
        return Action.none;
    }

    auto trades = market.map!(a => a.records
            .map!(b => Trade(b.time, b.close, macdToSignal(a.symbol, b.time)))
            .filter!(a => a.action != Action.none)
            .filter!(a => a.time >= start && a.time <= end)
            .array
            .uniq!((a, b) => a.action == b.action)
            .array
            .tradify
            .map!(b => tuple!("symbol", "tradeSignal")(a.symbol, b))
            .array)
        .joiner
        .array
        .randomShuffle
        .sort!((a, b) => a.tradeSignal.time < b.tradeSignal.time)
        .chunkBy!((a, b) => a.tradeSignal.time == b.tradeSignal.time);

    foreach (signals; trades) {

        foreach (sell; signals.filter!(a => a.tradeSignal.action == Action.sell)) {
            if (sell.symbol in holdings) {
                capital += (holdings[sell.symbol].quantity * sell.tradeSignal
                        .price) - Brokerage;
                rvalue ~= [
                    holdings[sell.symbol],
                    ExecutedTrade(sell.tradeSignal, sell.symbol,
                            holdings[sell.symbol].quantity)
                ];
                holdings.remove(sell.symbol);
            }
        }

        foreach (buy; signals.filter!(a => a.tradeSignal.action == Action.buy)) {
            if (capital < TradeSize)
                break;

            if (buy.symbol in holdings)
                writeln(buy.symbol, " already bought.");
            assert(buy.symbol !in holdings);

            auto tradeSize = ((capital >= TradeSize * 2) ? TradeSize : capital) - Brokerage;
            holdings[buy.symbol] = ExecutedTrade(buy.tradeSignal,
                    buy.symbol, (tradeSize - Brokerage) / buy.tradeSignal.price);
            capital -= Brokerage;
            capital -= holdings[buy.symbol].quantity * buy.tradeSignal.price;
            assert(capital >= 0);

        }
    }

    writeln((capital - StartingCapital) / StartingCapital);
    {
        auto file = File("trades.csv", "w");
        foreach (trade; rvalue) {
            file.writeln(trade.symbol, ",", trade.time, ",",
                    trade.price, ",", trade.action);

        }
    }
    return tuple((capital - StartingCapital) / StartingCapital, rvalue);
}

alias Band = Tuple!(double, "upper", double, "lower");

auto bollingerBandsWithRSI(T, R, S)(T market, R bands, S rsi,
        S sharpeRatios, DateTime start, DateTime end) {
    auto capital = StartingCapital;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

    auto getSignal(A, B)(A symbol, B time, double price) {
        if (symbol !in bands) {
            symbol.writeln;
            return Action.none;
        }

        auto band = bands[symbol].get(time, Band.init);
        auto rsi = rsi[symbol].get(time, double.nan);

        if ([band.upper, band.lower, rsi].canFind!(a => a.isNaN))
            return Action.none;

        if (price >= band.upper && rsi > 50)
            return Action.sell;
        if (price <= band.lower && rsi < 50)
            return Action.buy;

        return Action.none;
    }

    auto trades = market.map!(a => a.records
            .map!(b => Trade(b.time, b.close, getSignal(a.symbol, b.time, b.close)))
            .filter!(a => a.action != Action.none)
            .filter!(a => a.time >= start && a.time <= end)
            .array
            .uniq!((a, b) => a.action == b.action)
            .array //.tradify
            .map!(b => tuple!("symbol", "tradeSignal")(a.symbol, b))
            .array)
        .joiner
        .array
        .randomShuffle
        .sort!((a, b) => a.tradeSignal.time < b.tradeSignal.time)
        .chunkBy!((a, b) => a.tradeSignal.time == b.tradeSignal.time);

    foreach (signals; trades) {

        foreach (sell; signals.filter!(a => a.tradeSignal.action == Action.sell)) {
            if (sell.symbol in holdings) {
                capital += (holdings[sell.symbol].quantity * sell.tradeSignal
                        .price) - Brokerage;
                rvalue ~= [
                    holdings[sell.symbol],
                    ExecutedTrade(sell.tradeSignal, sell.symbol,
                            holdings[sell.symbol].quantity)
                ];
                holdings.remove(sell.symbol);
            }
        }

        foreach (buy; signals.filter!(a => a.tradeSignal.action == Action.buy)
                .array.randomShuffle) {

            if (capital < TradeSize)
                break;

            if (buy.symbol in holdings)
                writeln(buy.symbol, " already bought.");
            assert(buy.symbol !in holdings);

            auto tradeSize = ((capital >= TradeSize * 2) ? TradeSize : capital) - Brokerage;
            holdings[buy.symbol] = ExecutedTrade(buy.tradeSignal,
                    buy.symbol, (tradeSize - Brokerage) / buy.tradeSignal.price);
            capital -= Brokerage;
            capital -= holdings[buy.symbol].quantity * buy.tradeSignal.price;
            assert(capital >= 0);

        }
    }

    {
        auto file = File("signals-bollinger.csv", "w");
        file.writeln("name,time,price,rsi,sharpe,action");
        foreach (trade; chain(holdings.byValue, rvalue)) {
            file.writeln(trade.symbol, ",",
                    trade.time.toISOExtString.splitter("T")
                    .front.replace("-", "/")
                    .to!string, ",",
                    trade.price, ",", rsi[trade.symbol][trade.time], ",",
                    (trade.symbol in sharpeRatios
                        && trade.time in sharpeRatios[trade.symbol]) ? sharpeRatios[trade
                        .symbol][trade.time].to!string : "", ",", trade.action);
        }
    }

    return tuple((capital - StartingCapital) / StartingCapital, rvalue);

}

auto simpleMeanReversion(T)(T, DateTime start, DateTime end) {
    auto capital = StartingCapital;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

}

// works with inverse ETF
auto rsi75Strategy(T)(T market) {
    writeln("RSI75");
    auto capital = StartingCapital;
    enum Signal {
        above,
        below,
        na
    }

    auto data = market.map!(a => tuple!("symbol", "date", "close",
            "ma", "rsi")(a.symbol, a.records.map!(a => Date(a.time.year,
            a.time.month, a.time.day)).array, a.records.map!(a => a.close)
            .array, a.records.sma!"close"(200).array, a.records.rsi!"close"(4)
            .array)).array;

    alias TradeResult = Tuple!(Date, "date", string, "symbol",
            double, "held", Date, "start", double, "result");

    TradeResult[] results;
    foreach (stock; data) {
        stock.symbol.writeln;
        auto holding = false;
        Date start;
        double buyPrice;
        foreach (date, close, ma, rsi; zip(stock.date, stock.close, stock.ma, stock
                .rsi)) {
            if (close < ma && rsi > 75 && !holding) {
                holding = true;
                start = date;
                buyPrice = close;
            }

            if (rsi < 45 && holding) {
                holding = false;
                results ~= TradeResult(date, stock.symbol, (date - start)
                        .total!"days", start, (close - buyPrice) / buyPrice);
            }
        }
    }

    return results;

    results.sort!((a, b) => a.symbol < b.symbol)
        .chunkBy!((a, b) => a.symbol == b.symbol)
        .each!(a => writeln(a.front.symbol, " ", a.map!(b => b.held)
                .mean, " ", a.map!(b => b.result).mean, " ",
                a.map!(b => b.result).minElement, " ",
                a.map!(b => b.result).maxElement, " ",
                a.count!(b => b.result > 0) / a.count.to!double));

    results.sort!((a, b) => a.date < b.date);
    int[Date] openOrders;
    import core.time : dur;

    foreach (result; results) {
        for (Date date = result.start; date <= result.date; date += 1.dur!"days") {
            openOrders[date] = openOrders.get(date, 0) + 1;
        }
    }

    auto ordersHeld = openOrders.byKeyValue
        .array
        .sort!((a, b) => a.key < b.key)
        .filter!(a => a.key >= Date(2015, 1, 1))
        .chunkBy!((a, b) => a.key.year == b.key.year);

    writeln("% year held,num per day");
    ordersHeld.each!(a => writeln(a.count / 252.0, " ", a.map!(b => b.value).mean));

    results.map!(a => a.result).mean.writeln;

    results.chunkBy!((a, b) => a.date.year == b.date.year && a.date.month == b
            .date.month)
        .map!(a => a.count)
        .mean
        .writeln;

}

auto rsi2Strategy(T)(T market) {
    writeln("RSI2");
    auto capital = StartingCapital;
    enum Signal {
        above,
        below,
        na
    }

    auto data = market.map!(a => tuple!("symbol", "date", "close",
            "ma", "rsi")(a.symbol, a.records.map!(a => Date(a.time.year,
            a.time.month, a.time.day)).array, a.records.map!(a => a.close)
            .array, a.records.sma!"close"(200).array, a.records.rsi!"close"(2)
            .array)).array;

    alias TradeResult = Tuple!(Date, "date", string, "symbol",
            double, "held", Date, "start", double, "result");

    TradeResult[] results;
    foreach (stock; data) {
        auto holding = false;
        Date start;
        double buyPrice;
        foreach (date, close, ma, rsi; zip(stock.date, stock.close, stock.ma, stock
                .rsi).slide(3).map!(a => tuple(a.map!(a => a[0])
                .array, a.map!(a => a[1]).array, a.map!(a => a[2])
                .array, a.map!(a => a[3]).array))) {

            if (close.back > ma.back && rsi[2] < rsi[1]
                    && rsi[1] < rsi[0] && rsi[0] < 60 && rsi[2] < 10 && !holding) {
                holding = true;
                start = date.back;
                buyPrice = close.back;
            }

            if (rsi.front > 70 && holding) {
                holding = false;
                results ~= TradeResult(date.front, stock.symbol,
                        (date.front - start)
                        .total!"days", start, (close.front - buyPrice) / buyPrice);
            }
        }
    }

    return results;
}

auto rsi10Strategy(T)(T market) {
    writeln("RSI10");
    auto capital = StartingCapital;
    enum Signal {
        above,
        below,
        na
    }

    auto data = market.map!(a => tuple!("symbol", "date", "close",
            "ma", "fastMa", "rsi")(a.symbol,
            a.records.map!(a => Date(a.time.year, a.time.month, a.time.day))
            .array, a.records.map!(a => a.close)
            .array, a.records.sma!"close"(200).array,
            a.records.sma!"close"(5).array, a.records.rsi!"close"(2).array))
        .array;

    alias TradeResult = Tuple!(Date, "date", string, "symbol",
            double, "held", Date, "start", double, "result");

    TradeResult[] results;
    foreach (stock; data) {
        auto holding = false;
        Date start;
        double buyPrice;
        foreach (date, close, ma, rsi, fastMa; zip(stock.date,
                stock.close, stock.ma, stock.rsi, stock.fastMa)) {
            if (close > ma && rsi < 10 && !holding) {
                holding = true;
                start = date;
                buyPrice = close;
            }

            if (close > fastMa && holding) {
                holding = false;
                results ~= TradeResult(date, stock.symbol, (date - start)
                        .total!"days", start, (close - buyPrice) / buyPrice);
            }
        }
    }

    return results;
}

auto emaTrendStrategy(T)(T market, int fast, int slow, int rsiThreshold = 25) {
    writeln("EMA ", fast, " ", slow);
    auto capital = StartingCapital;
    enum Signal {
        above,
        below,
        na
    }

    auto data = market.map!(a => tuple!("symbol", "date", "close",
            "ma", "fastMa", "rsi")(a.symbol,
            a.records.map!(a => Date(a.time.year, a.time.month, a.time.day))
            .array, a.records.map!(a => a.close)
            .array, a.records.ema!"close"(slow).array,
            a.records.ema!"close"(fast).array, a.records.rsi!"close"(2).array))
        .array;

    alias TradeResult = Tuple!(Date, "date", string, "symbol",
            double, "held", Date, "start", double, "result");

    TradeResult[] results;
    string[][string] outputs;
    foreach (stock; data) {
        outputs[stock.symbol] = string[].init;
        auto holding = false;
        Date start;
        double buyPrice;
        foreach (date, close, ma, rsi, fastMa; zip(stock.date,
                stock.close, stock.ma, stock.rsi, stock.fastMa)) {
            if (fastMa > ma && rsi < rsiThreshold && !holding) {
                outputs[stock.symbol] ~= format("%s %s %s %s", date,
                        stock.symbol, "BUY", close);
                holding = true;
                start = date;
                buyPrice = close;
            }

            if (fastMa < ma && holding) {
                outputs[stock.symbol] ~= format("%s %s %s %s", date,
                        stock.symbol, "SELL", close);
                holding = false;
                results ~= TradeResult(date, stock.symbol, (date - start)
                        .total!"days", start, (close - buyPrice) / buyPrice);
            }
        }
    }

    foreach (output; outputs.byValue) {
        output.retro.take(5).retro.each!(a => a.writeln);
    }

    return results;
}

auto rsi25Strategy(T)(T market) {
    writeln("RSI25");
    auto capital = StartingCapital;
    enum Signal {
        above,
        below,
        na
    }

    auto data = market.map!(a => tuple!("symbol", "date", "close",
            "ma", "rsi")(a.symbol, a.records.map!(a => Date(a.time.year,
            a.time.month, a.time.day)).array, a.records.map!(a => a.close)
            .array, a.records.sma!"close"(200).array, a.records.rsi!"close"(4)
            .array)).array;

    alias TradeResult = Tuple!(Date, "date", string, "symbol",
            double, "held", Date, "start", double, "result");

    TradeResult[] results;
    foreach (stock; data) {
        auto holding = false;
        Date start;
        double buyPrice;
        foreach (date, close, ma, rsi; zip(stock.date, stock.close, stock.ma, stock
                .rsi)) {
            if (close > ma && rsi < 25 && !holding) {
                holding = true;
                start = date;
                buyPrice = close;
            }

            if (rsi > 55 && holding) {
                holding = false;
                results ~= TradeResult(date, stock.symbol, (date - start)
                        .total!"days", start, (close - buyPrice) / buyPrice);
            }
        }
    }

    return results;

    results.sort!((a, b) => a.symbol < b.symbol)
        .chunkBy!((a, b) => a.symbol == b.symbol)
        .each!(a => writeln(a.front.symbol, " ", a.map!(b => b.held)
                .mean, " ", a.map!(b => b.result).mean, " ",
                a.map!(b => b.result).minElement, " ",
                a.map!(b => b.result).maxElement, " ",
                a.count!(b => b.result > 0) / a.count.to!double, " ",
                a.filter!(b => b.start >= Date(2015, 1, 1)).count));

    results.sort!((a, b) => a.date < b.date);
    int[Date] openOrders;
    import core.time : dur;

    foreach (result; results) {
        for (Date date = result.start; date <= result.date; date += 1.dur!"days") {
            openOrders[date] = openOrders.get(date, 0) + 1;
        }
    }

    auto ordersHeld = openOrders.byKeyValue
        .array
        .sort!((a, b) => a.key < b.key)
        .filter!(a => a.key >= Date(2015, 1, 1))
        .chunkBy!((a, b) => a.key.year == b.key.year);

    writeln("% year held,num per day");
    ordersHeld.each!(a => writeln(a.count / 252.0, " ", a.map!(b => b.value).mean));

    results.map!(a => a.result).mean.writeln;

    results.chunkBy!((a, b) => a.date.year == b.date.year && a.date.month == b
            .date.month)
        .map!(a => a.count)
        .mean
        .writeln;

}

auto vixStrategy(T)(T market) {
    // VIXY, SPY, SH, IWM, RWM
    auto capital = StartingCapital;

    auto vix = market.find!(a => a.symbol == "VIXY").front.records;

    auto ma = vix.sma!"close"(50).array;
    auto fastma = vix.ema!"close"(5).array;

    enum Signal {
        above,
        below
    }

    auto signals = zip(vix.map!(a => a.time), fastma, ma).map!(
            a => tuple!("time", "signal")(a[0], a[1] < a[2] ? Signal.below : Signal
            .above))
        .chunkBy!((a, b) => a.signal == b.signal)
        .filter!(a => a.count > 1)
        .map!(a => a.drop(1).front)
        .chunkBy!((a, b) => a.signal == b.signal)
        .map!(a => a.front)
        .array;

    import std.format : format;

    foreach (signal; signals) {
        writeln(signal.time.toISOString, " ", signal.signal, " ",
                ["SPY", "SH", "IWM", "RWM"].map!(a => format("%s",
                    market.find!(b => b.symbol == a)
                    .front
                    .records
                    .find!(b => b.time == signal.time)
                    .front
                    .close)).joiner(" "));
    }

    double[string] holdings;
    holdings["SPY"] = 0;
    holdings["RWM"] = 0;
    holdings["IWM"] = 0;

    double[] results;

    foreach (signal; signals) {
        switch (signal.signal) {
        default:
            assert(0);
        case Signal.above:
            // sell SPY, buy RWM
            auto sell = (holdings["SPY"] * market.find!(a => a.symbol == "SPY")
                    .front
                    .records
                    .find!(a => a.time == signal.time)
                    .front
                    .close);
            if (sell != 0) {
                writeln("SPY: ", (sell - 1000) / 1000.0);
                results ~= (sell - 1000) / 1000.0;
            }

            capital += sell;
            holdings["SPY"] = 0;

            auto buyAmount = 1000.0 / market.find!(a => a.symbol == "IWM")
                .front
                .records
                .find!(a => a.time == signal.time)
                .front
                .close;
            capital -= 1000;
            holdings["IWM"] = buyAmount;
            break;
        case Signal.below:
            // sell RWM, buy SPY
            auto sell = (holdings["IWM"] * market.find!(a => a.symbol == "IWM")
                    .front
                    .records
                    .find!(a => a.time == signal.time)
                    .front
                    .close);

            if (sell != 0) {
                writeln("IWM: ", (sell - 1000) / 1000.0);
                results ~= (sell - 1000) / 1000.0;
            }
            capital += sell;
            holdings["IWM"] = 0;

            auto buyAmount = 1000.0 / market.find!(a => a.symbol == "SPY")
                .front
                .records
                .find!(a => a.time == signal.time)
                .front
                .close;
            capital -= 1000;
            holdings["SPY"] = buyAmount;
            break;
        }
    }
    capital.writeln;
    writeln("SPY: ", holdings["SPY"] * market.find!(a => a.symbol == "SPY")
            .front.records.back.close);

    writeln("IWM: ", holdings["IWM"] * market.find!(a => a.symbol == "IWM")
            .front.records.back.close);

    results.count.writeln;
    results.mean.writeln;
    writeln(results.count!(a => a > 0) / results.count.to!double);
    return signals;
}

auto fullMACDWithRSIWithSharpe(T, S)(T market, S fastAverage, S slowAverage,
        S signal, S rsi, S sharpeRatios, DateTime start, DateTime end) {
    auto capital = StartingCapital;

    ExecutedTrade[string] holdings;
    ExecutedTrade[] rvalue;

    auto macdToSignal(A, B)(A symbol, B time) {
        auto macd = fastAverage[symbol][time] - slowAverage[symbol][time];
        auto signal = signal[symbol][time];

        if (macd > signal && rsi[symbol].get(time, 9999) < 40)
            return Action.buy;
        if (macd < signal && rsi[symbol].get(time, 0) > 60)
            return Action.sell;

        return Action.none;
    }

    auto trades = market.map!(a => a.records
            .map!(b => Trade(b.time, b.close, macdToSignal(a.symbol, b.time)))
            .filter!(a => a.action != Action.none)
            .filter!(a => a.time >= start && a.time <= end)
            .array
            .uniq!((a, b) => a.action == b.action)
            .array //.tradify
            .map!(b => tuple!("symbol", "tradeSignal")(a.symbol, b))
            .array)
        .joiner
        .array
        .randomShuffle
        .sort!((a, b) => a.tradeSignal.time < b.tradeSignal.time)
        .chunkBy!((a, b) => a.tradeSignal.time == b.tradeSignal.time);

    auto marketSize = sharpeRatios.keys.length;
    auto maxHoldings = 40;

    foreach (signals; trades) {

        foreach (sell; signals.filter!(a => a.tradeSignal.action == Action.sell)) {
            if (sell.symbol in holdings) {
                capital += (holdings[sell.symbol].quantity * sell.tradeSignal
                        .price) - Brokerage;
                rvalue ~= [
                    holdings[sell.symbol],
                    ExecutedTrade(sell.tradeSignal, sell.symbol,
                            holdings[sell.symbol].quantity)
                ];
                holdings.remove(sell.symbol);

            }
        }

        foreach (buy; signals.filter!(a => a.tradeSignal.action == Action.buy)
                .array
                .sort!((a, b) => sharpeRatios[a.symbol].get(a.tradeSignal.time,
                    double.min_normal) > sharpeRatios[b.symbol].get(
                    b.tradeSignal.time, double.min_normal))) {

            if (capital < TradeSize)
                break;

            if (buy.symbol in holdings)
                writeln(buy.symbol, " already bought.");
            assert(buy.symbol !in holdings);

            auto tradeSize = (capital / (maxHoldings - holdings.byKey.count)) - Brokerage;
            holdings[buy.symbol] = ExecutedTrade(buy.tradeSignal,
                    buy.symbol, (tradeSize - Brokerage) / buy.tradeSignal.price);
            capital -= Brokerage;
            capital -= holdings[buy.symbol].quantity * buy.tradeSignal.price;
            assert(capital >= 0);
        }
    }

    writeln(((capital + holdings.byValue.map!(
            a => (a.price * a.quantity) - Brokerage).sum) - StartingCapital) / StartingCapital);
    {
        auto file = File("signals.csv", "w");
        file.writeln("name,time,price,rsi,sharpe,action");
        foreach (trade; chain(holdings.byValue, rvalue)) {
            file.writeln(trade.symbol, ",",
                    trade.time.toISOExtString.splitter("T")
                    .front.replace("-", "/").to!string, ",",
                    trade.price, ",", rsi[trade.symbol][trade.time],
                    ",", sharpeRatios[trade.symbol][trade.time], ",", trade
                    .action);

        }
    }

    return tuple(((capital + holdings.byValue.map!(
            a => (a.price * a.quantity) - Brokerage).sum) - StartingCapital) / StartingCapital,
            rvalue);
}

void loadDatabase() {
    import d2sqlite3;
    import std.file : dirEntries, SpanMode, readText;
    import std.json : parseJSON;
    import std.path : baseName, stripExtension;

    auto db = Database("/home/jordan/databases/tiingo-eod.db");
    auto statement = db.prepare("insert into eod
                                  values (:symbol, :date, :close, :high, :low, :open, :volumn,
                                          :adjClose, :adjHigh, :adjLow, :adjOpen, :adjVolumn,
                                          :divCash, :splitFactor)");

    db.begin;
    foreach (entry; dirEntries(`/mnt/g/tiingo`, SpanMode.shallow)) {
        entry.name.writeln;
        try {
            auto json = entry.name.readText.parseJSON;
            foreach (obj; json.array) {
                statement.inject(entry.name.stripExtension.baseName,
                        obj["date"].str,
                        obj["close"].floating, obj["high"].floating,
                        obj["low"].floating,
                        obj["open"].floating, obj["volume"].integer,
                        obj["adjClose"].floating,
                        obj["adjHigh"].floating, obj["adjLow"].floating,
                        obj["adjOpen"].floating, obj["adjVolume"].integer,
                        obj["divCash"].floating, obj["splitFactor"].floating);
            }
        } catch (Exception ex) {
            ex.msg.writeln;
        }
    }
    db.commit;
}

auto predictDividendDates(T)(T db, int num = 50) {
    import std.datetime.systime : SysTime, Clock;
    import core.time : dur;

    auto data = db.execute("select symbol, date from eod where date(date) > date('2019-01-01') and divCash > 0")
        .map!(a => tuple!("symbol", "date")(a["symbol"].as!string,
                Date.fromISOExtString(a["date"].as!string[0 .. 10])))
        .map!(a => tuple!("symbol", "date", "predicted")(a.symbol,
                a.date, (a.date + dur!"days"(365))))
        .array;

    auto currentTime = Clock.currTime.to!Date;

    return data.filter!(a => a.predicted > (currentTime - dur!"days"(2)))
        .array
        .sort!((a, b) => a.predicted < b.predicted)
        .take(num).array;

}

auto timeBetweenPayouts(T)(T db) {
    import std.datetime.systime : SysTime, Clock;
    import core.time : dur;

    auto data = db.execute("select symbol, date from eod where divCash > 0")
        .map!(a => tuple!("symbol",
                "date")(a["symbol"].as!string,
                Date.fromISOExtString(a["date"].as!string[0 .. 10])))
        .array
        .multiSort!((a, b) => a.symbol < b.symbol, (a, b) => a.date < b.date)
        .chunkBy!((a, b) => a.symbol == b.symbol)
        .filter!(a => a.count > 1)
        .map!(a => tuple!("symbol", "period")(a.front.symbol,
                a.slide(2).map!(b => (b.drop(1)
                .front.date - b.front.date).total!"days").mean))
        .array;

    return data;
}

auto getRecords(T, Rng)(T db, Rng symbols) {
    import std.format : format;

    Records2[] rvalue;
    foreach (symbol; symbols) {
        rvalue ~= Records2(symbol,
                db.execute(format("select * from eod where symbol = '%s'",
                    symbol)).map!(a => EODRecord2(DateTime.fromISOExtString(
                    a["date"].as!string[0 .. 19]), a["adjOpen"].as!double,
                    a["adjHigh"].as!double,
                    a["adjLow"].as!double, a["adjClose"].as!double,
                    a["adjVolumn"].as!size_t,
                    a["divCash"].as!double / a["close"].as!double))
                .array
                .sort!((a, b) => a.time < b.time)
                .array);
    }
    return rvalue;
}

void main(string[] args) {
    import d2sqlite3;
    import std.format : format;
    import std.string : center;

    Database db;

    writeln("loading");
    db = Database("/home/jordan/databases/tiingo-eod.db");

    auto divPeriods = db.timeBetweenPayouts.assocArray;

    auto divDates = db.predictDividendDates(100);
    auto divRecords = db.getRecords(divDates.map!(a => a.symbol));
    auto stats = divRecords.map!(a => tuple(a.symbol.center(6, ' '),
            divDates.find!(b => b.symbol == a.symbol).front.predicted,
            a.records.ema!"divReturn"(20).array.back * 100,
            a.records.rsi!"close"(14).back, divPeriods.get(a.symbol, -1)))
        .array
        .sort!((a, b) => a[4] > b[4])
        .each!(a => writeln(format("%s %s %0.6f %0.6f %f", a[0], a[1], a[2], a[3],
                a[4])));

    return;

    auto cmdline = new Program("stocky").summary("Stock Analyser")
        .author("Jordan K. Wilson <wilsonjord@gmail.com>")
        .add(new Option(null,
                "list", "List of symbols to use").acceptsFiles).parse(args);

    //loadDatabase;
    //return;

    //import selector;
    //moneyManagement("signals-bollinger - Copy.csv",PickStrategy.weightedReturnsAll);
    //returnOverTime("signals-bollinger.csv",fastAverage,slowAverage);

    //return;

    writeln("Loading database...");

    Records[] market;

    auto symbols = (cmdline.option("list") is null) ? db.execute(
            "select symbol from symbols")
        .map!(a => a["symbol"].as!string) //.filter!(a => a == "SNN")
        .array.randomCover.take(500).array : File(cmdline.option("list"), "r") // no header
        .byLine
        .map!(a => a.to!string)
        .filter!(a => !a.empty)
        .array;

    foreach (symbol; symbols) {
        symbol.writeln;
        import std.format : format;

        market ~= Records(symbol,
                db.execute(format("select * from eod where symbol = '%s'",
                    symbol)).map!(a => EODRecord(DateTime.fromISOExtString(
                    a["date"].as!string[0 .. 19]), a["adjOpen"].as!double,
                    a["adjHigh"].as!double,
                    a["adjLow"].as!double, a["adjClose"].as!double,
                    a["adjVolumn"].as!size_t))
                .array
                .sort!((a, b) => a.time < b.time)
                .array);

    }

    // adhoc
    {
        foreach (pair; [ //tuple("RSI2",market.rsi2Strategy),
                //tuple("RSI25",market.rsi25Strategy),
                //tuple("RSI10",market.rsi10Strategy),
                tuple("EMA4/16", market.emaTrendStrategy(4, 16,
                    500)),
                tuple("EMA8/32", market.emaTrendStrategy(8, 32, 500)),
                //tuple("EMA16/64",market.emaTrendStrategy(16,64)),
                //tuple("ALL",market.emaTrendStrategy(8,32) ~ market.emaTrendStrategy(16,64) ~ market.rsi25Strategy ~ market.rsi2Strategy ~ market.rsi10Strategy)]) {
            ]) {

            pair[0].writeln;
            auto results = pair[1];

            //results = results.filter!(a => a.symbol != "LQD" && a.symbol != "HYG").array;
            results = results.filter!(a => a.start.year >= 2019).array;

            results = results.multiSort!((a, b) => a.start < b.start,
                    (a, b) => a.symbol < b.symbol)
                .uniq!((a, b) => a.start == b.start && a.symbol == b.symbol)
                .array;

            results.sort!((a, b) => a.symbol < b.symbol)
                .chunkBy!((a, b) => a.symbol == b.symbol)
                .each!(a => writeln(a.front.symbol, " ",
                        a.map!(b => b.held).mean, " ", a.map!(b => b.result)
                        .mean, " ", a.map!(b => b.result).minElement,
                        " ", a.map!(b => b.result).maxElement, " ",
                        a.count!(b => b.result > 0) / a.count.to!double));

            results.map!(a => a.result).mean.writeln;

            results.sort!((a, b) => a.date < b.date)
                .chunkBy!((a, b) => a.date.year == b.date.year
                        && a.date.month == b.date.month)
                .map!(a => a.count)
                .mean
                .writeln;
            results.count.writeln;

            results.retro.take(10).each!(a => a.writeln);

        }
        //market.rsi75Strategy;
    }
    return;
    //{
    //auto results = market.vixStrategy;
    //results.each!(a => a.writeln);
    //}

    //return;

    //{
    //auto players = market.map!(a => a.symbol);
    //double[string][DateTime] prices;

    //auto file = File ("results.csv","w");
    //file.writeln ("week,stock1,stock2,winner");
    //foreach (symbol; market) {
    //foreach (day; symbol.records) {
    //prices[day.time][symbol.symbol] = day.close;
    //}
    //}

    //foreach (dateRange; prices.keys
    //.sort!((a,b) => a < b)
    //.slide!(No.withPartial)(2)) {

    //auto previousDate = dateRange[0];
    //auto date = dateRange[1];
    //if (prices[date].byKey.count >= 2) {
    //auto matchups = cartesianProduct (prices[date].byKey,prices[date].byKey)
    //.map!(a => (a[0] > a[1]) ? tuple!(string,string)(a[1],a[0]) : a)
    //.filter!(a => a[0] != a[1])
    //.array
    //.multiSort!((a,b) => a[0] < b[0], (a,b) => a[1] < b[1])
    //.uniq
    //.filter!(a => a[0] in prices[previousDate] &&
    //a[1] in prices[previousDate])
    //;

    //foreach (match; matchups) {
    //auto p1Return = (prices[date][match[0]] - prices[previousDate][match[0]]) / prices[previousDate][match[0]];
    //auto p2Return = (prices[date][match[1]] - prices[previousDate][match[1]]) / prices[previousDate][match[1]];
    //file.writeln (date.year*100 + date.month,",",match[0],",",match[1],",",(p1Return > p2Return) ? 1 : ((p1Return == p2Return) ? 0.5 : 0));
    //}
    //}
    //}

    //}

    //return;

    //  auto currentSymbol="";
    //  auto market = db.execute("select * from eod order by symbol, date")
    //                  .tee!((a) {
    //                              if (a["symbol"].as!string != currentSymbol) {
    //                                      currentSymbol = a["symbol"].as!string;
    //                                      currentSymbol.writeln;
    //                              }
    //                            })
    //                  .map!(a => tuple!("symbol","record")
    //                                   (a["symbol"].as!string,
    //                                    EODRecord (DateTime.fromISOExtString(a["date"].as!string[0..19]),
    //                                               a["adjOpen"].as!double,
    //                                               a["adjHigh"].as!double,
    //                                               a["adjLow"].as!double,
    //                                               a["adjClose"].as!double,
    //                                               a["adjVolumn"].as!int)))
    //                  .array
    //                  //.multiSort!((a,b) => a.symbol < b.symbol, (a,b) => a.record.time < b.record.time)
    //                  .sort!((a,b) => a.symbol < b.symbol)
    //                  .chunkBy!((a,b) => a.symbol == b.symbol)
    //                  .map!(a => tuple!("symbol","records")
    //                                   (a.front.symbol, a.map!(b => b.record).array))
    //                  .array;

    writeln("generating moving averages");
    double[DateTime][string] fastAverage;
    double[DateTime][string] slowAverage;
    double[DateTime][string] signal;
    double[DateTime][string] rsi;
    foreach (stock; market) {
        auto fast = stock.records.ema!"close"(50).array;
        auto slow = stock.records.sma!"close"(100).array;
        auto _signal = zip(fast, slow).map!(a => a[0] - a[1]).ema(9).array;
        auto _rsi = stock.records.rsi!"close"(14).array;
        foreach (avg; zip(stock.records.map!(a => a.time), fast, slow, _signal, _rsi)) {
            fastAverage[stock.symbol][avg[0]] = avg[1];
            slowAverage[stock.symbol][avg[0]] = avg[2];
            signal[stock.symbol][avg[0]] = avg[3];
            rsi[stock.symbol][avg[0]] = avg[4];
        }
    }

    scope (exit) {
        //TA_Shutdown;
    }
    //TA_Initialize;

    alias Trades = Trade[];

    writeln("generating ratios");

    double[DateTime][string] sharpeRatios;

    Band[DateTime][string] bollingerBands;

    foreach (stock; market) {
        foreach (ratio; zip(stock.records.map!(a => a.time),
                stock.records.sharpeRatio!"close"(20))) {
            if (!ratio[1].isNaN)
                sharpeRatios[stock.symbol][ratio[0]] = ratio[1];
        }

        foreach (dev; zip(stock.records.map!(a => a.time),
                stock.records.sma!"close"(10), stock.records.stdDeviation!"close"(
                10))) {
            if (!dev[1].isNaN && !dev[2].isNaN)
                bollingerBands[stock.symbol][dev[0]] = Band(
                        dev[1] + 1.5 * dev[2], dev[1] - 1.5 * dev[2]);
        }
    }

    writeln("done");

    // REALTIME
    auto x = market.fullMACDWithRSIWithSharpe(fastAverage, slowAverage, signal,
            rsi, sharpeRatios, DateTime(2017, 1, 1), DateTime(2020, 1, 1));
    //auto x = market.bollingerBandsWithRSI(bollingerBands,rsi,sharpeRatios, StartTime,EndTime);
    x[0].writeln;
    x[1].results.mean.writeln;
    x[1].results.median.writeln;
    auto y = x[1].results.array.sort.array.drop(20).dropBack(20);
    y.mean.writeln;

    import selector;

    selected("signals-bollinger.csv");

    return;

    // SIMULATION
    market.benchmark(StartTime, EndTime).writeln;
    //market.longOnlyMACD(fastAverage,slowAverage,sharpeRatios,StartTime,EndTime);
    //market.longOnlyMACD(fastAverage,slowAverage,sharpeRatios,StartTime,EndTime);
    //market.longOnlyMACD(fastAverage,slowAverage,sharpeRatios,StartTime,EndTime);
    //return; 

    writeln;

    /+  {
        /+ auto results = generate!(() => market.maWithLookback(300,30,StartTime,EndTime)).take(100)
                                .map!(a => tuple(a[0],a[1].results))
                                .array; +/

        //auto trade = generate!(() => market.fullMACD(fastAverage,slowAverage,signal,sharpeRatios,StartTime,EndTime)).take(50)
        //auto trade = generate!(() => market.fullMACDWithRSI(fastAverage,slowAverage,signal,rsi,StartTime,EndTime)).take(1)
        auto trade = generate!(() => market.bollingerBandsWithRSI(bollingerBands,rsi,sharpeRatios, StartTime,EndTime)).take(50)
                                .map!(a => tuple(a[0],a[1]))
                                .array;
                                
        
        writeln ("average total return: ",trade.map!(a => a[0]).mean);
        writeln ("median total return: ",trade.map!(a => a[0]).median);
        writeln ("average per trade: ",trade.map!(a => a[1]).joiner.array.results.mean);
        writeln ("median per trade: ",trade.map!(a => a[1]).joiner.array.results.median);
        writeln ("win rate: ",trade.map!(a => a[1]).joiner.array.winRate);
        writeln ("trades per year: ",trade.map!(a => a[1]).joiner.array.tradesPerYear);
        writeln ("average days held: ",trade.map!(a => a[1]).joiner.array.daysHeld2.mean);
        writeln ("median days held: ",trade.map!(a => a[1]).joiner.array.daysHeld2.median);

        foreach (year; 2016..2019) {
            year.writeln;
            auto sims = 
                trade.map!(a => a[1])
                    .joiner
                    .chunks(2)
                    .map!(a => a.array)
                    .filter!(a => a.front.time.year==year && a.back.time.year==year)
                    .joiner
                    .array
                    .repeat(100)
                    .map!((a) { auto rnd = a.randomShuffle.take(100).array;
                                return tuple(rnd.results.mean,rnd.results.median); })
                    .array;

            writeln (sims.map!(a => a[0]).mean," ",sims.map!(a => a[1]).mean," ",sims.map!(a => a[0]).minElement," ",sims.map!(a => a[0]).maxElement);
        }
        //trade.map!(a => a[1]).joiner.array.sort!((a,b) => a.time < b.time).chunkBy!((a,b) => a.time.year==b.time.year).map!(a => a.count).mean.writeln;
        
    } +/

    /+ double[string] tmp;
    foreach (records; allRecords) {
        //records.records.maWithLookback(200,20).writeln;
        //records.records.sharpeRatio!"close"(20).writeln;

        readln;
    }
    tmp.byPair.array.sort!((a,b) => a.value > b.value).each!(a => a.writeln); +/
    return;

    // buy when close is above n-day average, sell when below
    // with lookback

    /+  alias SimResult = Tuple!(uint,"tradesPerYear",
                             double,"returnPerTrade",
                             double,"profitPerTrade",
                             double,"avgDaysHeld");

    SimResult[size_t][size_t] results;
    foreach (ma; iota(190,301,10)) {
        foreach (lookback; iota(10,61,10)) {
            writeln (ma," ",lookback);
            auto trades = allRecords.maWithLookback(ma,lookback);

            double[] counts;
            foreach (tradesInYear; trades.dup.sort!((a,b) => a.time < b.time)
                                             .chunkBy!((a,b) => a.time.year==b.time.year)) {
                counts ~= tradesInYear.count;
            }

            SimResult result;
            result.tradesPerYear = counts.drop(5).mean.to!uint;
            result.returnPerTrade = trades.results.mean;
            result.profitPerTrade = trades.chunks(2)
                                          .map!(a => a.dollars(2500,8))
                                          .mean;
            result.avgDaysHeld = trades.averageDaysHeld;
            results[ma][lookback] = result;
        }
    }
    auto file = File("output1.csv","w");

    file.writeln("MA/LB,",iota(10,81,10).map!(a => format("%s",a)).joiner(","));
    foreach (ma; iota(100,301,10)) {
        file.write(ma,",");
        foreach (lookback; iota(10,81,10)) {
            file.write(results[ma][lookback].profitPerTrade," | ",
                       results[ma][lookback].tradesPerYear," | ",
                       results[ma][lookback].profitPerTrade*results[ma][lookback].tradesPerYear," | ",
                       results[ma][lookback].avgDaysHeld,",");
        }
        file.writeln;
    }
    return; +/

    /+  auto records = `G:\tiingo\JNJ.json`.readJsonTiingo
                                       .array;
                                    
    auto train = records.filter!(a => a.time < EndTime && a.time > StartTime).array;
    //auto train = records;
    
    auto totalDays = (records.back.time - records.front.time).total!"days";

    double[][int] emaArrays;
    double[][int] smaArrays;
    double[][int] rsiArrays;

    foreach (period; 5..250) {
        emaArrays[period] = records.ema!"close"(period).array;
        emaArrays[period] = records.sma!"close"(period).array;
    }

    foreach (period; 5..20) {
        rsiArrays[period] = records.rsi!"close"(period).array;
    }

        
    enum TradingActivity {low, med, high}
    auto runSimulation (int fast, int slow, int signal, int ma, int rsi, int rsiLow, int rsiHigh) {
        auto fastArray = emaArrays[fast];
        auto slowArray = emaArrays[slow];
        auto rsiArray = rsiArrays[rsi];
        auto rsiEma = rsiArray.ema(5).array;
        auto movAvg = records.sma!"close"(ma).array;

        auto data = zip (
                            records,
                            fastArray,
                             slowArray,
                             zip(fastArray,slowArray).map!(a => a[0]-a[1])
                                                     .ema(signal)
                                                     .array,
                             movAvg,
                             rsiArray,
                             rsiEma
                             ).map!(a => tuple!("record","fast","slow","signal","ma","rsi","rsiEma")(a.expand))
                              .array;

        
        auto buySignals = data.retro
                                 .slide!(No.withPartial)(2)
                                 .filter!(a => (a[0].record.close > a[0].ma) &&
                                               //(a[1].record.close > a[1].ma) &&  
                                               ((a[0].fast - a[0].slow) > a[0].signal) &&
                                               //(a[0].rsi > a[0].rsiEma) &&
                                               //(a[1].rsi > a[1].rsiEma) &&
                                               //(a[0].rsi > rsiLow))
                                               (true))
                                 .map!(a => a.front)
                                 .map!(a => tuple!("record","action")(a.record,Action.buy))
                                 .array
                                 .retro
                                 .array;

        auto sellSignals = data.retro
                                 .slide!(No.withPartial)(4)
                                 .filter!(a => (a[0].record.close < a[0].ma) &&
                                               //(a[1].record.close < a[1].ma) &&  
                                               ((a[0].fast - a[0].slow) < a[0].signal) &&
                                               //(a[0].rsi < a[0].rsiEma) &&
                                               //(a[1].rsi < a[1].rsiEma) &&
                                               //(a[0].rsi < rsiHigh))
                                               (true))
                                 .map!(a => a.front)
                                 .map!(a => tuple!("record","action")(a.record,Action.sell))
                                 .array
                                 .retro
                                 .array;

        auto signals = chain(buySignals,sellSignals)
                            .array
                            .sort!((a,b) => a.record.time < b.record.time)
                            .uniq!((a,b) => a.action==b.action)
                            .array;

        if (signals.back.action==Action.buy) signals.popBack;
        if (signals.front.action==Action.sell) signals.popFront;

        auto trades = signals.chunks(2).array;
        auto tradesPerYear = trades.length.to!double / ((EndTime - StartTime).total!"days"/365.25);
        TradingActivity activity;
        if (tradesPerYear < 5) {
            activity = TradingActivity.low;
        } else if (tradesPerYear >= 5 && tradesPerYear < 15) {
            activity = TradingActivity.med;
        } else {
            activity = TradingActivity.high;
        }
        return tuple!("activity","value") (activity,
                                            trades  
                                            .map!(a => ((((a[1].record.close - a[0].record.close)/a[0].record.close)*2500)-16))
                                            .mean);

    }

    auto bestResults = [TradingActivity.low : 0.0,
                                           TradingActivity.med : 0.0,
                                           TradingActivity.high : 0.0];

    int[][TradingActivity] bestSettings;

    foreach (slow; 30..250) {
        slow.writeln;
        bestResults.writeln;
        bestSettings.writeln;
        foreach (fast; 5..100) {
            foreach (sma; iota(100,250,5)) {
                if (fast < slow) {
                    auto currentResult = runSimulation (fast, slow, 9, sma, 14, 30, 70);
                    if (currentResult.value > bestResults[currentResult.activity]) {
                        bestResults[currentResult.activity] = currentResult.value;
                        bestSettings[currentResult.activity] =  [fast,slow,sma];
                    }
                }
            }
        }
    }
    bestResults.writeln;
    bestSettings.writeln;
    

    /+ auto trading =
                    zip(macdSignals,records,rsi).filter!(a => a[0]!=Action.none)
                                            .filter!(a => (a[0]==Action.buy && a[2] < 40) || (a[0]==Action.sell && a[2] > 60))
                                            .map!(a => Trade(cast(DateTime)a[1].time,a[1].close,a[0]))
                                            .uniq!((a,b) => a.action==b.action)
                                            .array
                                            .find!(a => a.action==Action.buy)
                                            .array;
    
    //trading = trading.filter!(a => a.time.year>=2017).array;
    if (trading.back.action==Action.buy) trading.popBack;
    if (trading.front.action==Action.sell) trading.popFront;
    writeln;
    trading.tradesPerYear.writeln;
    trading.averageDaysHeld.writeln;
    trading.results.mean.writeln;
    trading.winRate.writeln; +/

    return;



/+  auto data = [105.68, 93.74, 92.72, 90.52, 95.22, 100.35, 97.92, 98.83, 95.33,
                             93.4, 95.89, 96.68, 98.78, 98.66, 104.21, 107.48, 108.18, 109.36,
                             106.94, 107.73, 103.13, 114.92, 112.71, 113.05, 114.06, 117.63,
                             116.6, 113.72, 108.84, 108.43, 110.06, 111.79, 109.9, 113.95,
                             115.97, 116.52, 115.82, 117.91, 119.04, 120, 121.95, 129.08,
                             132.12, 135.72, 136.66, 139.78, 139.14, 139.99, 140.64, 143.66]; +/

    import std.random : uniform;

    double[] data;
    foreach (i; 0..1000) {
        data ~= uniform(0,1.0);
    }

    data = [44.34,44.0902,44.1497,43.6124,44.3278,44.8264,45.0955,45.4245,45.8433,46.0826,45.8931,46.0328,45.614,46.282,46.282,46.0028,46.0328,46.4116,46.2222,45.6439,46.2122,46.2521,45.7137,46.4515,45.7835,45.3548,44.0288,44.1783,44.2181,44.5672,43.4205,42.6628,43.1314];
    import std.format : format;
    import std.math : isNaN;
    
    auto outD = new double[data.length];

    size_t outB;
    size_t outE;

    import std.datetime.stopwatch;

    auto sw = StopWatch();
    sw.start;
    foreach (i; 0..10_000) {
        /+ TA_RSI (0,data.length-1,data.ptr,14,&outB, &outE, outD.ptr);
        
        foreach (x; chain(double.init.repeat(14),outD.take(outD.length-14).map!(a => a*1))) {
            
        }
 +/
        foreach (x; data.rsi(14)) {

        }
    }
    sw.stop;
    sw.peek.total!"msecs".writeln;

    auto high = [127.009,127.6159,126.5911,127.3472,128.173,128.4317,127.3671,126.422,126.8995,126.8498,125.646,125.7156,127.1582,127.7154,127.6855,128.2228,128.2725,128.0934,128.2725,127.7353,128.77,129.2873,130.0633,129.1182,129.2873,128.4715,128.0934,128.6506,129.1381,128.6406];
    auto low = [125.3574,126.1633,124.9296,126.0937,126.8199,126.4817,126.034,124.8301,126.3921,125.7156,124.5615,124.5715,125.0689,126.8597,126.6309,126.8001,126.7105,126.8001,126.1335,125.9245,126.9891,127.8148,128.4715,128.0641,127.6059,127.596,126.999,126.8995,127.4865,127.397];
    //auto close = [double.init,double.init,double.init,double.init,double.init,double.init,double.init,double.init,double.init,double.init,double.init,double.init,double.init,127.2876,127.1781,128.0138,127.1085,127.7253,127.0587,127.3273,128.7103,127.8745,128.5809,128.6008,127.9342,128.1133,127.596,127.596,128.6904,128.2725];
    auto close = [127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.2876,127.1781,128.0138,127.1085,127.7253,127.0587,127.3273,128.7103,127.8745,128.5809,128.6008,127.9342,128.1133,127.596,127.596,128.6904,128.2725];

    
    auto k = new double[high.length];
    auto d = new double[high.length];

    TA_STOCH(0,k.length-1,high.ptr,low.ptr,close.ptr,9,3,TA_MAType_SMA,3,TA_MAType_SMA,&outB,&outE,k.ptr,d.ptr).writeln;

    k.writeln;
    d.writeln;



    return;

    TA_RSI (0,data.length-1,data.ptr,14,&outB, &outE, outD[14..$].ptr);
    outD.writeln;
    data.rsi(14).array.filter!(a => !a.isNaN).writeln;
    data.rsi(14).drop(14).writeln;


    
    equal(data.sma(26).filter!(a => !a.isNaN).map!(a => format("%0.5f",a)),
        outD.filter!(a => !a.isNaN).map!(a => format("%0.5f",a))).writeln;
        
        
    return;
    

 +/
}
